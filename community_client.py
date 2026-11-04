"""知识星球社区客户端：复用手机版的 Supabase 账号和后端。

桌面端不引入额外网络依赖，直接用标准库访问 Supabase REST。
密码只用于换取登录令牌，不会写入本地设置；本地仅保存刷新令牌。
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

__all__ = ["CommunityClient", "CommunityError", "CommunitySession",
           "CLOUD_URL"]

CLOUD_URL = "https://edchntmyqqjqvpngylgc.supabase.co"
CLOUD_ANON_KEY = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
    "eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVkY2hudG15cXFqcXZwbmd5bGdjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE1ODY5ODksImV4cCI6MjEwNzE2Mjk4OX0."
    "6vfi2zxvdbmdLSHoV2U0r4R8zd10UCtO5XGaToqBc7I"
)
REQUEST_TIMEOUT = 12


def community_setup_sql():
    """返回社区安装脚本。源码运行和 PyInstaller 打包后都能找到。"""
    candidates = []
    bundle = getattr(sys, "_MEIPASS", None)
    if bundle:
        candidates.append(os.path.join(bundle, "community.sql"))
    here = os.path.dirname(os.path.abspath(__file__))
    candidates.append(os.path.join(here, "mobile", "sql", "community.sql"))
    for path in candidates:
        try:
            with open(path, "r", encoding="utf-8") as file:
                return file.read()
        except OSError:
            continue
    return ""


class CommunityError(RuntimeError):
    pass


class CommunitySession:
    """登录会话。只序列化令牌和公开资料，不保存密码。"""

    def __init__(self, access_token, refresh_token="", expires_at=0,
                 profile=None):
        self.access_token = str(access_token or "")
        self.refresh_token = str(refresh_token or "")
        self.expires_at = float(expires_at or 0)
        self.profile = dict(profile or {})

    @property
    def user_id(self):
        return str(self.profile.get("id") or "")

    @property
    def name(self):
        return str(self.profile.get("name") or self.profile.get("code") or "成员")

    @property
    def role(self):
        return str(self.profile.get("role") or "employee")

    def is_expired(self):
        return not self.access_token or time.time() >= self.expires_at - 60

    def to_dict(self):
        return {
            "access_token": self.access_token,
            "refresh_token": self.refresh_token,
            "expires_at": self.expires_at,
            "profile": self.profile,
        }

    @classmethod
    def from_dict(cls, data):
        if not isinstance(data, dict):
            return None
        session = cls(
            data.get("access_token", ""),
            data.get("refresh_token", ""),
            data.get("expires_at", 0),
            data.get("profile", {}),
        )
        return session if session.access_token else None


def _error_message(payload):
    if isinstance(payload, dict):
        for key in ("message", "msg", "error_description", "details", "hint"):
            value = payload.get(key)
            if value:
                return str(value)
        error = payload.get("error")
        if isinstance(error, str) and error:
            return error
        if isinstance(error, dict):
            return str(error.get("message") or error)
    return str(payload or "社区请求失败")


def _translate_error(message):
    text = str(message or "")
    lower = text.lower()
    if ("community_posts" in lower and
            ("does not exist" in lower or "could not find" in lower)):
        return ("社区数据表还没有创建。\n\n"
                "请让管理员在 Supabase 的 SQL Editor 运行：\n"
                "mobile/sql/community.sql")
    if (("could not find the function" in lower or "does not exist" in lower)
            and ("enterprise" in lower or "identity" in lower)):
        return ("企业身份服务还没有安装。\n\n"
                "请让管理员在 Supabase 的 SQL Editor 运行：\n"
                "mobile/sql/enterprise-identity.sql")
    if "only shareholders may vote" in lower:
        return "只有持股股东可以投票。"
    if "only shareholders may propose" in lower:
        return "只有持股股东可以发起任免提案。"
    if "only the enterprise owner may change shares" in lower:
        return "只有企业所有者可以调整股份。"
    if "voting is still in progress" in lower:
        return "投票还在进行，需等投票期结束或全部股东完成投票。"
    if "cannot change shares while a role vote is open" in lower:
        return "有任免投票正在进行，结束前不能调整股份。"
    if "voting period has ended" in lower or "motion is closed" in lower:
        return "这次投票已经结束。"
    if "target already holds this role" in lower:
        return "该成员已经担任这个身份。"
    if "target already has the base employee role" in lower:
        return "该成员目前就是普通员工，无需发起免职。"
    if "open role motion" in lower:
        return "该成员已有一项进行中的任免提案。"
    if "could not find the function" in lower or "does not exist" in lower:
        if "login_email" in lower:
            return ("账号登录服务还没有安装。\n\n"
                    "请让管理员先运行 mobile/sql/login-by-password.sql")
        return ("社区服务还没有安装。\n\n"
                "请让管理员在 Supabase 的 SQL Editor 运行：\n"
                "mobile/sql/community.sql")
    if "invalid login credentials" in lower:
        return "密码不对，请重新输入。"
    if "email not confirmed" in lower:
        return "账号还没有完成确认，请联系管理员。"
    if "jwt expired" in lower or "not signed in" in lower:
        return "登录状态已过期，请重新登录社区。"
    if "message is empty" in lower:
        return "先写点内容再发送。"
    if "message is too long" in lower:
        return "消息太长了，请控制在 2000 字以内。"
    if "rate limit" in lower or "too many requests" in lower:
        return "发送太频繁了，等几秒再试。"
    return text or "社区请求失败。"

def _request(method, path, *, body=None, token="", params=None,
             timeout=REQUEST_TIMEOUT):
    url = CLOUD_URL.rstrip("/") + path
    if params:
        query = urllib.parse.urlencode(params, doseq=True)
        url += ("&" if "?" in url else "?") + query
    headers = {
        "apikey": CLOUD_ANON_KEY,
        "Authorization": "Bearer " + (token or CLOUD_ANON_KEY),
        "Accept": "application/json",
    }
    data = None
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers,
                                     method=method.upper())
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw) if raw else {}
        except ValueError:
            payload = {"message": raw}
        raise CommunityError(_translate_error(_error_message(payload))) from error
    except urllib.error.URLError as error:
        reason = getattr(error, "reason", error)
        raise CommunityError(
            "连不上社区服务器，请检查网络或稍后再试。\n"
            f"技术信息：{reason}"
        ) from error
    except TimeoutError as error:
        raise CommunityError("社区服务器响应超时，请稍后再试。") from error
    if not raw.strip():
        return None
    try:
        return json.loads(raw)
    except ValueError as error:
        raise CommunityError("社区服务器返回了无法识别的数据。") from error


class CommunityClient:
    def login(self, code, password):
        code = str(code or "").strip()
        password = str(password or "")
        if not code:
            raise CommunityError("请填账号或员工号。")
        if not password:
            raise CommunityError("请填密码。")

        if "@" in code:
            email = code.lower()
        else:
            lookup = _request(
                "POST", "/rest/v1/rpc/login_email",
                body={"p_code": code, "p_password": password},
            )
            status = (lookup or {}).get("status")
            if status == "no_account":
                raise CommunityError("没有这个账号，请检查账号或员工号。")
            if status == "bad_password":
                raise CommunityError("密码不对，请重新输入。")
            email = (lookup or {}).get("email")
            if not email:
                raise CommunityError("登录失败：服务端没有返回账号信息。")

        auth = _request(
            "POST", "/auth/v1/token",
            params={"grant_type": "password"},
            body={"email": email, "password": password},
        )
        return self._session_from_auth(auth)

    def refresh(self, session):
        if not session or not session.refresh_token:
            raise CommunityError("登录状态已过期，请重新登录社区。")
        auth = _request(
            "POST", "/auth/v1/token",
            params={"grant_type": "refresh_token"},
            body={"refresh_token": session.refresh_token},
        )
        return self._session_from_auth(auth, old_profile=session.profile)

    def _session_from_auth(self, auth, old_profile=None):
        if not isinstance(auth, dict) or not auth.get("access_token"):
            raise CommunityError("登录失败：没有拿到访问令牌。")
        user = auth.get("user") or {}
        user_id = str(user.get("id") or "")
        profile = dict(old_profile or {})
        if user_id:
            try:
                rows = _request(
                    "GET", "/rest/v1/profiles",
                    token=auth["access_token"],
                    params={"select": "*", "id": f"eq.{user_id}", "limit": 1},
                )
                if isinstance(rows, list) and rows:
                    profile = dict(rows[0])
            except CommunityError:
                if not profile:
                    meta = user.get("user_metadata") or {}
                    profile = {
                        "id": user_id,
                        "name": meta.get("name") or user.get("email", ""),
                        "role": meta.get("role") or "employee",
                        "code": meta.get("code") or "",
                    }
        expires_in = int(auth.get("expires_in") or 3600)
        return CommunitySession(
            auth.get("access_token"),
            auth.get("refresh_token", ""),
            time.time() + expires_in,
            profile,
        )

    def list_posts(self, session, limit=80):
        data = _request(
            "POST", "/rest/v1/rpc/list_knowledge_posts",
            token=session.access_token,
            body={"p_limit": max(1, min(100, int(limit)))},
        )
        return data if isinstance(data, list) else []

    def publish(self, session, content, topic="share",
                unlock_cost=0, is_required=False):
        content = str(content or "").strip()
        if not content:
            raise CommunityError("先写点内容再发送。")
        if len(content) > 2000:
            raise CommunityError("消息太长了，请控制在 2000 字以内。")
        cost = max(0, int(unlock_cost or 0))
        return _request(
            "POST", "/rest/v1/rpc/post_community_message",
            token=session.access_token,
            body={
                "p_content": content,
                "p_topic": str(topic or "share"),
                "p_unlock_cost": cost,
                "p_is_required": bool(is_required),
            },
        )

    def delete_post(self, session, post_id):
        return _request(
            "POST", "/rest/v1/rpc/delete_my_community_message",
            token=session.access_token,
            body={"p_post_id": str(post_id)},
        )

    # ------------------------------------------------------ enterprise identity
    def identity_state(self, session):
        """Return the current enterprise, member roles, shares and motions."""
        return _request(
            "POST", "/rest/v1/rpc/get_enterprise_identity_state",
            token=session.access_token,
            body={},
        )

    def propose_role_change(self, session, target_profile_id, kind,
                            role_key="employee", department="", title="",
                            reason="", days=None, conflict_disclosed=False):
        return _request(
            "POST", "/rest/v1/rpc/propose_enterprise_role",
            token=session.access_token,
            body={
                "p_target": str(target_profile_id),
                "p_kind": str(kind or ""),
                "p_role_key": str(role_key or "employee"),
                "p_department": str(department or ""),
                "p_title": str(title or ""),
                "p_reason": str(reason or ""),
                "p_days": int(days) if days is not None else None,
                "p_conflict_disclosed": bool(conflict_disclosed),
            },
        )

    def cast_role_vote(self, session, motion_id, choice):
        return _request(
            "POST", "/rest/v1/rpc/cast_enterprise_role_vote",
            token=session.access_token,
            body={"p_motion": str(motion_id), "p_choice": str(choice or "")},
        )

    def close_role_vote(self, session, motion_id):
        return _request(
            "POST", "/rest/v1/rpc/close_enterprise_role_vote",
            token=session.access_token,
            body={"p_motion": str(motion_id)},
        )

    def cancel_role_vote(self, session, motion_id):
        return _request(
            "POST", "/rest/v1/rpc/cancel_enterprise_role_vote",
            token=session.access_token,
            body={"p_motion": str(motion_id)},
        )

    def propose_share_change(self, session, profile_id, shares,
                             reason, days=5, conflict_disclosed=False):
        return _request(
            "POST", "/rest/v1/rpc/propose_enterprise_share_change",
            token=session.access_token,
            body={
                "p_profile": str(profile_id),
                "p_shares": float(shares or 0),
                "p_reason": str(reason or ""),
                "p_days": int(days or 5),
                "p_conflict_disclosed": bool(conflict_disclosed),
            },
        )

    def set_shareholder(self, session, profile_id, shares):
        """Bootstrap/internal compatibility only; UI must use a motion."""
        return _request(
            "POST", "/rest/v1/rpc/set_enterprise_shareholder",
            token=session.access_token,
            body={"p_profile": str(profile_id), "p_shares": float(shares or 0)},
        )

    # ------------------------------------------------------- role templates
    def role_templates(self, session):
        data = _request(
            "POST", "/rest/v1/rpc/get_enterprise_role_templates",
            token=session.access_token, body={},
        )
        return data if isinstance(data, list) else []

    def clone_role_template(self, session, source_id, key, name,
                            reason="", days=5, conflict_disclosed=False):
        return _request(
            "POST", "/rest/v1/rpc/clone_role_template",
            token=session.access_token,
            body={
                "p_source_template": str(source_id),
                "p_key": str(key or ""),
                "p_name": str(name or ""),
                "p_reason": str(reason or ""),
                "p_days": int(days or 5),
                "p_conflict_disclosed": bool(conflict_disclosed),
            },
        )

    def update_role_template(self, session, template_id, name, permissions,
                             reason="", days=5, conflict_disclosed=False):
        return _request(
            "POST", "/rest/v1/rpc/update_role_template",
            token=session.access_token,
            body={
                "p_template": str(template_id),
                "p_name": str(name or ""),
                "p_permissions": list(permissions or []),
                "p_reason": str(reason or ""),
                "p_days": int(days or 5),
                "p_conflict_disclosed": bool(conflict_disclosed),
            },
        )
    def set_role_assignment(self, session, profile_id, template_id,
                            ends_at=None, reason=""):
        return _request(
            "POST", "/rest/v1/rpc/set_member_role_assignment",
            token=session.access_token,
            body={
                "p_profile": str(profile_id),
                "p_template": str(template_id),
                "p_ends_at": ends_at,
                "p_reason": str(reason or ""),
            },
        )

    def propose_template_change(self, session, template_id, name,
                                permissions, reason, days=5,
                                conflict_disclosed=False):
        return _request(
            "POST", "/rest/v1/rpc/propose_template_change",
            token=session.access_token,
            body={
                "p_template": str(template_id),
                "p_name": str(name or ""),
                "p_permissions": list(permissions or []),
                "p_reason": str(reason or ""),
                "p_days": int(days or 5),
                "p_conflict_disclosed": bool(conflict_disclosed),
            },
        )

    # -------------------------------------------------------- board motions
    def create_board_motion(self, session, title, kind, payload,
                            conflict_disclosed=False):
        return _request(
            "POST", "/rest/v1/rpc/create_board_motion",
            token=session.access_token,
            body={
                "p_title": title,
                "p_kind": kind,
                "p_payload": payload,
                "p_conflict_disclosed": bool(conflict_disclosed),
            },
        )

    def cast_board_vote(self, session, motion_id, choice):
        return _request(
            "POST", "/rest/v1/rpc/cast_board_vote",
            token=session.access_token,
            body={"p_motion": str(motion_id), "p_choice": choice},
        )

    def finalize_board_motion(self, session, motion_id):
        return _request(
            "POST", "/rest/v1/rpc/finalize_board_motion",
            token=session.access_token,
            body={"p_motion": str(motion_id)},
        )

    # -------------------------------------------------------- points/modes
    def point_state(self, session):
        data = _request(
            "POST", "/rest/v1/rpc/get_point_state",
            token=session.access_token, body={},
        )
        return data if isinstance(data, dict) else {}

    def award_points(self, session, profile_id, amount, evidence_type,
                     evidence_id, reason):
        return _request(
            "POST", "/rest/v1/rpc/award_points",
            token=session.access_token,
            body={
                "p_profile": str(profile_id),
                "p_amount": int(amount),
                "p_evidence_type": evidence_type,
                "p_evidence_id": str(evidence_id),
                "p_reason": reason,
            },
        )

    def unlock_knowledge(self, session, post_id):
        return _request(
            "POST", "/rest/v1/rpc/unlock_knowledge_content",
            token=session.access_token,
            body={"p_post": str(post_id)},
        )

    def set_ui_mode(self, session, mode):
        if mode not in ("simple", "advanced"):
            raise ValueError("mode must be simple or advanced")
        return _request(
            "POST", "/rest/v1/rpc/set_enterprise_ui_mode",
            token=session.access_token,
            body={"p_mode": mode},
        )
