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
import uuid

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
    if (("decision" in lower or "approval_requests" in lower)
            and ("does not exist" in lower or "could not find" in lower)):
        return ("经营决策中心还没有安装。\n\n"
                "请让管理员在 Supabase 的 SQL Editor 运行：\n"
                "mobile/sql/decision-approvals-v1.sql")
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
        payload = json.loads(raw)
    except ValueError as error:
        raise CommunityError("社区服务器返回了无法识别的数据。") from error
    if (isinstance(payload, dict) and payload.get("ok") is False
            and payload.get("code") == "permission_denied"):
        raise CommunityError(_translate_error(_error_message(payload)))
    return payload


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

    # ------------------------------------------------------ community foundation
    def boards(self, session):
        data = _request(
            "POST", "/rest/v1/rpc/get_community_boards",
            token=session.access_token, body={},
        )
        return data if isinstance(data, dict) else {}

    def list_posts_v2(self, session, board_id=None, search="", before=None,
                      limit=20, bookmarked=False):
        data = _request(
            "POST", "/rest/v1/rpc/list_community_posts_v2",
            token=session.access_token,
            body={
                "p_board": str(board_id) if board_id else None,
                "p_search": str(search or "").strip(),
                "p_before": before,
                "p_limit": max(1, min(50, int(limit or 20))),
                "p_bookmarked": bool(bookmarked),
            },
        )
        return data if isinstance(data, dict) else {}

    def post_detail(self, session, post_id):
        data = _request(
            "POST", "/rest/v1/rpc/get_community_post",
            token=session.access_token,
            body={"p_post": str(post_id)},
        )
        return data if isinstance(data, dict) else {}

    def publish_v2(self, session, content, board_id=None, topic="share",
                   unlock_cost=0, is_required=False):
        content = str(content or "").strip()
        if not content:
            raise CommunityError("先写点内容再发送。")
        if len(content) > 2000:
            raise CommunityError("消息太长了，请控制在 2000 字以内。")
        return _request(
            "POST", "/rest/v1/rpc/post_community_message_v2",
            token=session.access_token,
            body={
                "p_content": content,
                "p_topic": str(topic or "share"),
                "p_unlock_cost": max(0, int(unlock_cost or 0)),
                "p_is_required": bool(is_required),
                "p_board": str(board_id) if board_id else None,
            },
        )

    def add_comment(self, session, post_id, body, parent_id=None):
        body = str(body or "").strip()
        if not body:
            raise CommunityError("先写评论再发送。")
        if len(body) > 4000:
            raise CommunityError("评论请控制在 4000 字以内。")
        return _request(
            "POST", "/rest/v1/rpc/add_community_comment",
            token=session.access_token,
            body={
                "p_post": str(post_id),
                "p_body": body,
                "p_parent": str(parent_id) if parent_id else None,
            },
        )

    def toggle_like(self, session, post_id):
        return _request(
            "POST", "/rest/v1/rpc/toggle_community_like",
            token=session.access_token,
            body={"p_post": str(post_id)},
        )

    def toggle_bookmark(self, session, post_id):
        return _request(
            "POST", "/rest/v1/rpc/toggle_community_bookmark",
            token=session.access_token,
            body={"p_post": str(post_id)},
        )

    def follow_board(self, session, board_id, follow=True):
        return _request(
            "POST", "/rest/v1/rpc/follow_community_board",
            token=session.access_token,
            body={"p_board": str(board_id), "p_follow": bool(follow)},
        )

    def report_content(self, session, post_id=None, comment_id=None,
                       reason="", detail=""):
        return _request(
            "POST", "/rest/v1/rpc/report_community_content",
            token=session.access_token,
            body={
                "p_post": str(post_id) if post_id else None,
                "p_comment": str(comment_id) if comment_id else None,
                "p_reason": str(reason or "").strip(),
                "p_detail": str(detail or "").strip(),
            },
        )

    def notifications(self, session, limit=20):
        data = _request(
            "POST", "/rest/v1/rpc/get_community_notifications",
            token=session.access_token,
            body={"p_limit": max(1, min(50, int(limit or 20)))},
        )
        return data if isinstance(data, dict) else {}

    def mark_notifications_read(self, session, notification_id=None):
        return _request(
            "POST", "/rest/v1/rpc/mark_community_notifications_read",
            token=session.access_token,
            body={"p_notification": str(notification_id) if notification_id else None},
        )

    def create_board(self, session, name, slug, description="",
                     visibility="public", permissions=None, icon="*"):
        return _request(
            "POST", "/rest/v1/rpc/create_community_board",
            token=session.access_token,
            body={
                "p_name": str(name or "").strip(),
                "p_slug": str(slug or "").strip().lower(),
                "p_description": str(description or "").strip(),
                "p_visibility": str(visibility or "public"),
                "p_required_permissions": list(permissions or []),
                "p_icon": str(icon or "*"),
            },
        )

    def update_board(self, session, board_id, name, description="",
                     visibility="public", permissions=None, icon="*",
                     archived=False):
        return _request(
            "POST", "/rest/v1/rpc/update_community_board",
            token=session.access_token,
            body={
                "p_board": str(board_id),
                "p_name": str(name or "").strip(),
                "p_description": str(description or "").strip(),
                "p_visibility": str(visibility or "public"),
                "p_required_permissions": list(permissions or []),
                "p_icon": str(icon or "*"),
                "p_archived": bool(archived),
            },
        )

    def admin_stats(self, session):
        data = _request(
            "POST", "/rest/v1/rpc/get_community_admin_stats",
            token=session.access_token, body={},
        )
        return data if isinstance(data, dict) else {}

    def moderate_post(self, session, post_id, pinned=False, featured=False,
                      deleted=False):
        return _request(
            "POST", "/rest/v1/rpc/moderate_community_post",
            token=session.access_token,
            body={
                "p_post": str(post_id),
                "p_pinned": bool(pinned),
                "p_featured": bool(featured),
                "p_deleted": bool(deleted),
            },
        )

    def resolve_report(self, session, report_id, status="resolved"):
        return _request(
            "POST", "/rest/v1/rpc/resolve_community_report",
            token=session.access_token,
            body={"p_report": str(report_id), "p_status": str(status)},
        )

    # ---------------------------------------------------- organization equity
    def organization_state(self, session):
        data = _request(
            "POST", "/rest/v1/rpc/get_organization_state",
            token=session.access_token, body={},
        )
        return data if isinstance(data, dict) else {}

    def organizations(self, session):
        data = _request(
            "POST", "/rest/v1/rpc/list_my_organizations",
            token=session.access_token, body={},
        )
        return data if isinstance(data, dict) else {}

    def create_organization(self, session, name, founder_codes=None):
        return _request(
            "POST", "/rest/v1/rpc/create_organization",
            token=session.access_token,
            body={
                "p_name": str(name or "").strip(),
                "p_founder_codes": list(founder_codes or []),
            },
        )

    def invite_organization_founder(self, session, enterprise_id, code):
        return _request(
            "POST", "/rest/v1/rpc/invite_organization_founder",
            token=session.access_token,
            body={"p_enterprise": str(enterprise_id), "p_code": str(code or "").strip()},
        )

    def respond_organization_founder_invite(self, session, invite_id, accept):
        return _request(
            "POST", "/rest/v1/rpc/respond_organization_founder_invite",
            token=session.access_token,
            body={"p_invite": str(invite_id), "p_accept": bool(accept)},
        )

    def set_active_organization(self, session, enterprise_id):
        return _request(
            "POST", "/rest/v1/rpc/set_active_organization",
            token=session.access_token,
            body={"p_enterprise": str(enterprise_id)},
        )

    def propose_initial_split(self, session, allocations, reason="",
                              closes_at=None):
        return _request(
            "POST", "/rest/v1/rpc/propose_initial_split",
            token=session.access_token,
            body={
                "p_allocations": list(allocations or []),
                "p_reason": str(reason or "").strip(),
                "p_closes_at": closes_at,
            },
        )

    def create_equity_motion(self, session, kind, payload, reason="",
                             closes_at=None):
        return _request(
            "POST", "/rest/v1/rpc/create_equity_motion",
            token=session.access_token,
            body={
                "p_kind": str(kind or ""),
                "p_payload": dict(payload or {}),
                "p_reason": str(reason or "").strip(),
                "p_closes_at": closes_at,
            },
        )

    def cast_equity_vote(self, session, motion_id, choice):
        return _request(
            "POST", "/rest/v1/rpc/cast_equity_vote",
            token=session.access_token,
            body={"p_motion": str(motion_id), "p_choice": str(choice)},
        )

    def cancel_equity_motion(self, session, motion_id, reason=""):
        return _request(
            "POST", "/rest/v1/rpc/cancel_equity_motion",
            token=session.access_token,
            body={"p_motion": str(motion_id), "p_reason": str(reason or "")},
        )

    def grant_employee_equity(self, session, profile_id, units,
                              vesting_start=None):
        return _request(
            "POST", "/rest/v1/rpc/grant_employee_equity",
            token=session.access_token,
            body={
                "p_profile": str(profile_id),
                "p_units": float(units),
                "p_vesting_start": vesting_start,
            },
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

    # ---------------------------------------------------------- decisions
    @staticmethod
    def new_idempotency_key(prefix="decision"):
        return f"{prefix}:{uuid.uuid4()}"

    def decision_center(self, session):
        data = _request(
            "POST", "/rest/v1/rpc/get_decision_center",
            token=session.access_token, body={},
        )
        return data if isinstance(data, dict) else {}

    def act_on_decision(self, session, decision_id, action, owner_id=None,
                        note="", idempotency_key=""):
        action = str(action or "").strip().lower()
        if action not in {
            "acknowledged", "assigned", "deferred", "resolved", "dismissed",
        }:
            raise ValueError("invalid decision action")
        key = idempotency_key or self.new_idempotency_key("decision")
        return _request(
            "POST", "/rest/v1/rpc/act_on_decision",
            token=session.access_token,
            body={
                "p_decision": str(decision_id),
                "p_action": action,
                "p_owner": str(owner_id) if owner_id else None,
                "p_note": note,
                "p_idempotency_key": key,
            },
        )

    def act_on_approval(self, session, approval_id, action, note="",
                        idempotency_key=""):
        from decision_rules import normalize_approval_action

        normalized = normalize_approval_action(action)
        if not normalized:
            raise ValueError("invalid approval action")
        key = idempotency_key or self.new_idempotency_key("approval")
        return _request(
            "POST", "/rest/v1/rpc/act_on_approval",
            token=session.access_token,
            body={
                "p_approval": str(approval_id),
                "p_action": normalized,
                "p_note": note,
                "p_idempotency_key": key,
            },
        )

    def set_ui_mode(self, session, mode):
        if mode not in ("simple", "advanced"):
            raise ValueError("mode must be simple or advanced")
        return _request(
            "POST", "/rest/v1/rpc/set_enterprise_ui_mode",
            token=session.access_token,
            body={"p_mode": mode},
        )

    # ---------------------------------------------------------- operations
    def operations_dashboard(self, session, weeks=None):
        body = {}
        if weeks is not None:
            body["p_weeks"] = int(weeks)
        data = _request(
            "POST", "/rest/v1/rpc/get_operations_dashboard",
            token=session.access_token, body=body,
        )
        return data if isinstance(data, dict) else {}

    def upsert_project_economics(self, session, project_id, data):
        return _request(
            "POST", "/rest/v1/rpc/upsert_project_economics",
            token=session.access_token,
            body={
                "p_project": str(project_id),
                "p_data": dict(data or {}),
            },
        )

    def upsert_profile_skill(self, session, profile_id, skill, data):
        return _request(
            "POST", "/rest/v1/rpc/upsert_profile_skill",
            token=session.access_token,
            body={
                "p_profile": str(profile_id),
                "p_skill": str(skill or ""),
                "p_data": dict(data or {}),
            },
        )

    def upsert_capacity_demand(self, session, demand_id, data):
        return _request(
            "POST", "/rest/v1/rpc/upsert_capacity_demand",
            token=session.access_token,
            body={
                "p_demand": str(demand_id) if demand_id else None,
                "p_data": dict(data or {}),
            },
        )

    def get_worklog_dimensions(self, session, worklog_id):
        return _request(
            "POST", "/rest/v1/rpc/get_worklog_dimensions",
            token=session.access_token,
            body={"p_worklog": str(worklog_id)},
        )

    def upsert_worklog_dimensions(self, session, worklog_id, data):
        return _request(
            "POST", "/rest/v1/rpc/upsert_worklog_dimensions",
            token=session.access_token,
            body={
                "p_worklog": str(worklog_id),
                "p_data": dict(data or {}),
            },
        )

    def worklog_dimensions(self, session, worklog_id, data):
        return self.upsert_worklog_dimensions(session, worklog_id, data)

    def my_performance_evidence(self, session):
        data = _request(
            "POST", "/rest/v1/rpc/get_my_performance_evidence",
            token=session.access_token, body={},
        )
        return data if isinstance(data, dict) else {"items": []}

    def submit_performance_statement(self, session, evidence_id, statement):
        return _request(
            "POST", "/rest/v1/rpc/submit_performance_statement",
            token=session.access_token,
            body={
                "p_evidence": str(evidence_id),
                "p_statement": str(statement or ""),
            },
        )

    def review_performance_evidence(self, session, evidence_id, note):
        return _request(
            "POST", "/rest/v1/rpc/review_performance_evidence",
            token=session.access_token,
            body={
                "p_evidence": str(evidence_id),
                "p_note": str(note or ""),
            },
        )

    def upsert_performance_evidence(self, session, profile_id, period, data):
        return _request(
            "POST", "/rest/v1/rpc/upsert_performance_evidence",
            token=session.access_token,
            body={
                "p_profile": str(profile_id),
                "p_period": str(period or ""),
                "p_data": dict(data or {}),
            },
        )

    # ---------------------------------------------------------- execution
    def execution_board(self, session, enterprise_id=None):
        body = {}
        if enterprise_id:
            body["p_enterprise"] = str(enterprise_id)
        data = _request(
            "POST", "/rest/v1/rpc/get_execution_board",
            token=session.access_token, body=body,
        )
        return data if isinstance(data, dict) else {}

    def submit_task_acceptance(self, session, task_id, criteria, evidence,
                               reviewer_id, note=""):
        criteria = str(criteria or "").strip()
        evidence = str(evidence or "").strip()
        reviewer_id = str(reviewer_id or "").strip()
        if not criteria:
            raise ValueError("acceptance criteria required")
        if not evidence:
            raise ValueError("evidence required")
        if not reviewer_id:
            raise ValueError("reviewer required")
        return _request(
            "POST", "/rest/v1/rpc/submit_task_acceptance",
            token=session.access_token,
            body={
                "p_task": str(task_id),
                "p_criteria": criteria,
                "p_evidence": evidence,
                "p_reviewer": reviewer_id,
                "p_note": str(note or ""),
            },
        )

    def review_task_acceptance(self, session, task_id, decision, note=""):
        normalized = str(decision or "").strip().lower()
        if normalized not in ("accepted", "rework"):
            raise ValueError("decision must be accepted or rework")
        return _request(
            "POST", "/rest/v1/rpc/review_task_acceptance",
            token=session.access_token,
            body={
                "p_task": str(task_id),
                "p_decision": normalized,
                "p_note": str(note or ""),
            },
        )

    def upsert_task_dependency(self, session, task_id, depends_on_task_id,
                               lag_days=0, required=True):
        try:
            lag_days = max(int(lag_days or 0), 0)
        except (TypeError, ValueError) as error:
            raise ValueError("lag days must be a non-negative integer") from error
        return _request(
            "POST", "/rest/v1/rpc/upsert_task_dependency",
            token=session.access_token,
            body={
                "p_task": str(task_id),
                "p_depends_on": str(depends_on_task_id),
                "p_lag_days": lag_days,
                "p_required": bool(required),
            },
        )

    def delete_task_dependency(self, session, task_id, depends_on_task_id):
        return _request(
            "POST", "/rest/v1/rpc/delete_task_dependency",
            token=session.access_token,
            body={
                "p_task": str(task_id),
                "p_depends_on": str(depends_on_task_id),
            },
        )

    def create_task_handoff(self, session, task_id, to_profile_id, artifact,
                            note=""):
        artifact = str(artifact or "").strip()
        if not artifact:
            raise ValueError("handoff artifact required")
        return _request(
            "POST", "/rest/v1/rpc/create_task_handoff",
            token=session.access_token,
            body={
                "p_task": str(task_id),
                "p_to": str(to_profile_id),
                "p_artifact": artifact,
                "p_note": str(note or ""),
            },
        )

    def accept_task_handoff(self, session, handoff_id, decision, note=""):
        normalized = str(decision or "").strip().lower()
        if normalized not in ("accepted", "rejected"):
            raise ValueError("decision must be accepted or rejected")
        return _request(
            "POST", "/rest/v1/rpc/accept_task_handoff",
            token=session.access_token,
            body={
                "p_handoff": str(handoff_id),
                "p_decision": normalized,
                "p_note": str(note or ""),
            },
        )

    def create_change_request(self, session, project_id, data):
        from execution_rules import validate_change_request

        payload = dict(data or {})
        validation = validate_change_request(payload)
        if not validation["valid"]:
            raise ValueError(validation["reason"])
        return _request(
            "POST", "/rest/v1/rpc/create_change_request",
            token=session.access_token,
            body={
                "p_project": str(project_id),
                "p_data": payload,
            },
        )

    def decide_change_request(self, session, change_id, decision, note="",
                              idempotency_key=""):
        normalized = str(decision or "").strip().lower()
        if normalized not in ("approved", "rejected", "returned"):
            raise ValueError("decision must be approved, rejected, or returned")
        key = idempotency_key or self.new_idempotency_key("change")
        return _request(
            "POST", "/rest/v1/rpc/decide_change_request",
            token=session.access_token,
            body={
                "p_change": str(change_id),
                "p_decision": normalized,
                "p_note": str(note or ""),
                "p_idempotency_key": key,
            },
        )

    # ---------------------------------------------------------- work intake
    def intake_board(self, session, enterprise_id=None):
        body = {}
        if enterprise_id:
            body["p_enterprise"] = str(enterprise_id)
        data = _request(
            "POST", "/rest/v1/rpc/get_intake_board",
            token=session.access_token, body=body,
        )
        return data if isinstance(data, dict) else {}

    def my_intake_requests(self, session):
        data = _request(
            "POST", "/rest/v1/rpc/get_my_intake_requests",
            token=session.access_token, body={},
        )
        return data if isinstance(data, dict) else {}

    def create_intake_request(self, session, data):
        from intake_rules import validate_submission

        payload = dict(data or {})
        validation = validate_submission(payload, external=False)
        if not validation["valid"]:
            raise ValueError(validation["reason"])
        return _request(
            "POST", "/rest/v1/rpc/create_intake_request",
            token=session.access_token, body={"p_data": payload},
        )

    def create_intake_form(self, session, data=None):
        return _request(
            "POST", "/rest/v1/rpc/create_intake_form",
            token=session.access_token, body={"p_data": dict(data or {})},
        )

    def update_intake_form(self, session, form_id, data=None):
        return _request(
            "POST", "/rest/v1/rpc/update_intake_form",
            token=session.access_token,
            body={"p_form": str(form_id), "p_data": dict(data or {})},
        )

    def upsert_intake_settings(self, session, data=None):
        return _request(
            "POST", "/rest/v1/rpc/upsert_intake_settings",
            token=session.access_token, body={"p_data": dict(data or {})},
        )

    def create_intake_email_alias(self, session, label=""):
        return _request(
            "POST", "/rest/v1/rpc/create_intake_email_alias",
            token=session.access_token, body={"p_label": str(label or "")},
        )

    def triage_intake_request(self, session, request_id, owner_id=None,
                              request_type=None, priority_override=None,
                              reason="", status="triage"):
        reason = str(reason or "").strip()
        if priority_override is not None and not reason:
            raise ValueError("priority override reason required")
        normalized_status = str(status or "triage").strip().lower()
        if normalized_status not in ("triage", "in_progress", "resolved", "closed"):
            raise ValueError("invalid triage status")
        body = {
            "p_request": str(request_id),
            "p_owner": str(owner_id) if owner_id else None,
            "p_request_type": str(request_type) if request_type else None,
            "p_priority_override": (
                float(priority_override) if priority_override is not None else None
            ),
            "p_reason": reason,
            "p_status": normalized_status,
        }
        return _request(
            "POST", "/rest/v1/rpc/triage_intake_request",
            token=session.access_token, body=body,
        )

    def add_intake_message(self, session, request_id, body, public=True):
        from intake_rules import validate_message

        validation = validate_message(body, bool(public))
        if not validation["valid"]:
            raise ValueError(validation["reason"])
        return _request(
            "POST", "/rest/v1/rpc/add_intake_message",
            token=session.access_token,
            body={
                "p_request": str(request_id),
                "p_body": str(body or "").strip(),
                "p_public": bool(public),
            },
        )

    def find_intake_duplicates(self, session, request_id, limit=5):
        try:
            limit = min(max(int(limit or 5), 1), 20)
        except (TypeError, ValueError) as error:
            raise ValueError("duplicate limit must be an integer") from error
        return _request(
            "POST", "/rest/v1/rpc/find_intake_duplicates",
            token=session.access_token,
            body={"p_request": str(request_id), "p_limit": limit},
        )

    def merge_intake_request(self, session, source_id, target_id, note=""):
        if not source_id or not target_id:
            raise ValueError("source and target request are required")
        if str(source_id) == str(target_id):
            raise ValueError("cannot merge a request into itself")
        return _request(
            "POST", "/rest/v1/rpc/merge_intake_request",
            token=session.access_token,
            body={
                "p_source": str(source_id),
                "p_target": str(target_id),
                "p_note": str(note or ""),
            },
        )

    def convert_intake_request(self, session, request_id, kind, data=None):
        from intake_rules import validate_conversion

        payload = dict(data or {})
        validation = validate_conversion(kind, payload)
        if not validation["valid"]:
            raise ValueError(validation["reason"])
        return _request(
            "POST", "/rest/v1/rpc/convert_intake_request",
            token=session.access_token,
            body={
                "p_request": str(request_id),
                "p_kind": str(kind or "").strip().lower(),
                "p_data": payload,
            },
        )

    def intake_escalate_sla(self, session, enterprise_id=None):
        body = {}
        if enterprise_id:
            body["p_enterprise"] = str(enterprise_id)
        return _request(
            "POST", "/rest/v1/rpc/intake_escalate_sla",
            token=session.access_token, body=body,
        )

    def public_intake_form(self, token):
        return _request(
            "POST", "/rest/v1/rpc/get_public_intake_form",
            token="", body={"p_token": str(token or "")},
        )

    def submit_public_intake(self, token, data):
        from intake_rules import validate_submission

        payload = dict(data or {})
        validation = validate_submission(payload, external=True)
        if not validation["valid"]:
            raise ValueError(validation["reason"])
        return _request(
            "POST", "/rest/v1/rpc/submit_public_intake",
            token="", body={"p_token": str(token or ""), "p_data": payload},
        )

    def public_intake_status(self, tracking_code, email):
        if not str(tracking_code or "").strip() or not str(email or "").strip():
            raise ValueError("tracking code and email are required")
        return _request(
            "POST", "/rest/v1/rpc/get_public_intake_status",
            token="",
            body={
                "p_tracking_code": str(tracking_code or "").strip(),
                "p_email": str(email or "").strip(),
            },
        )

    def ingest_intake_email(self, alias_token, sender, subject, body,
                            request_type="customer"):
        from intake_rules import validate_submission

        payload = {
            "title": subject, "detail": body,
            "request_type": request_type,
        }
        validation = validate_submission(payload, external=False)
        if not validation["valid"]:
            raise ValueError(validation["reason"])
        return _request(
            "POST", "/rest/v1/rpc/ingest_intake_email",
            token="",
            body={
                "p_alias_token": str(alias_token or ""),
                "p_from": str(sender or ""),
                "p_subject": str(subject or ""),
                "p_body": str(body or ""),
                "p_request_type": str(request_type or "customer"),
            },
        )

    # ---------------------------------------------------------- shareholder meetings
    def shareholder_meetings(self, session, enterprise_id=None):
        body = {}
        if enterprise_id:
            body["p_enterprise"] = str(enterprise_id)
        data = _request(
            "POST", "/rest/v1/rpc/get_shareholder_meetings",
            token=session.access_token, body=body,
        )
        return data if isinstance(data, dict) else {}

    def initiate_shareholder_meeting(self, session, title, agenda,
                                     scheduled_at, reason):
        title = str(title or "").strip()
        agenda = str(agenda or "").strip()
        reason = str(reason or "").strip()
        if not title or not agenda:
            raise ValueError("title and agenda are required")
        if not reason:
            raise ValueError("special meeting reason required")
        if not scheduled_at:
            raise ValueError("scheduled time is required")
        return _request(
            "POST", "/rest/v1/rpc/initiate_shareholder_meeting",
            token=session.access_token,
            body={
                "p_title": title, "p_agenda": agenda,
                "p_scheduled_at": str(scheduled_at),
                "p_reason": reason,
            },
        )

    def vote_shareholder_meeting(self, session, meeting_id, choice, note=""):
        choice = str(choice or "").strip().lower()
        if choice not in ("yes", "no", "abstain"):
            raise ValueError("vote choice must be yes, no, or abstain")
        return _request(
            "POST", "/rest/v1/rpc/vote_shareholder_meeting",
            token=session.access_token,
            body={
                "p_meeting": str(meeting_id), "p_choice": choice,
                "p_note": str(note or "").strip(),
            },
        )

    def record_shareholder_meeting_attendance(self, session, meeting_id,
                                               status, note=""):
        from meeting_rules import validate_attendance

        status = str(status or "").strip().lower()
        note = str(note or "").strip()
        validation = validate_attendance(status, note)
        if not validation["valid"]:
            raise ValueError(validation["reason"])
        return _request(
            "POST", "/rest/v1/rpc/record_shareholder_meeting_attendance",
            token=session.access_token,
            body={
                "p_meeting": str(meeting_id), "p_status": status,
                "p_note": note,
            },
        )

    def complete_shareholder_meeting(self, session, meeting_id, minutes):
        minutes = str(minutes or "").strip()
        if not minutes:
            raise ValueError("meeting minutes required")
        return _request(
            "POST", "/rest/v1/rpc/complete_shareholder_meeting",
            token=session.access_token,
            body={"p_meeting": str(meeting_id), "p_minutes": minutes},
        )
