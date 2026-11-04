# 阶段一：治理与权限 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把现有企业身份原型升级为可复制、可版本化、可审计的治理系统，并落地董事会、有限积分和简单/高级模式。

**Architecture:** 在 `enterprise-identity.sql` 之上新增 `enterprise-governance-v2.sql`。服务端负责模板版本、四维权限、多人兼任、股份快照、董事会和积分账本；PyQt 与 Capacitor 客户端只通过 RPC 读写并缓存展示状态。

**Tech Stack:** Python 3.13、PyQt6、Supabase Postgres/RLS/RPC、Capacitor、Vanilla JavaScript、unittest、pglast。

**Spec:** `docs/superpowers/specs/2026-11-03-enterprise-operating-system-design.md`

## Global Constraints

- 当前目录不是 Git 仓库；执行时必须在已同步仓库中提交，或先获得用户授权再初始化 Git。
- SQL 文件纯 ASCII；治理写入全部走 `SECURITY DEFINER` RPC。
- 普通事项：50% 股份出席、有效赞成超过 50%、3 天。
- 重大事项：全体股份 2/3 以上赞成、5 天。
- 股份调整必须重大表决；提案创建时锁定股份快照。
- 董事会一名董事一票，过半数董事出席，出席董事过半数赞成。
- 积分池按季度由董事会批准，未发额默认不结转；发放后的积分永久有效。
- 董事长只能在董事会额度内发放，不能给自己发。
- 简单模式默认开放；高级模式按管理、财务、审计或治理权限显示。
- 视觉 token：`Ink #1F2B27`、`Paper #F4F6F2`、`Mint #47B7A1`、`Mint Deep #217766`、`Signal #D86A45`、`Info #6F8FBE`。
- 每个任务先写失败测试，再写实现，测试通过后提交。

## File Structure

新增：`identity_rules.py`、`role_templates_ui.py`、`today_ui.py`、`mobile/today.js`、`mobile/sql/enterprise-governance-v2.sql`、`tests/test_identity_rules.py`、`tests/test_enterprise_governance_sql.py`、`tests/test_identity_client.py`、`tests/test_identity_ui.py`、`tests/test_identity_docs.py`。

修改：`community_client.py`、`identity_ui.py`、`main.py`、`mobile/index.html`、`mobile/app.js`、`mobile/account.js`、`mobile/identity.js`、`mobile/style.css`、`mobile/store.js`、`mobile/build-www.js`、`mobile/selfcheck.js`、`README.md`、`sync_manifest.txt`。

---

## Task 1: 纯规则模块

**Files:** Create `identity_rules.py`、`tests/test_identity_rules.py`

**Interfaces:** Produces `PermissionGrant`、`merge_permissions()`、`has_permission()`、`motion_class()`、`required_threshold_bps()`、`evaluate_vote()`、`can_manage_template()`、`can_use_advanced_mode()`、`point_balance()`。

- [ ] **Step 1: 写失败测试**

```python
# tests/test_identity_rules.py
import unittest
from datetime import datetime, timedelta, timezone
from identity_rules import (
    PermissionGrant, can_manage_template, can_use_advanced_mode,
    evaluate_vote, has_permission, merge_permissions, motion_class,
    point_balance, required_threshold_bps,
)

class IdentityRulesTest(unittest.TestCase):
    def test_expired_grant_is_ignored(self):
        now = datetime(2026, 11, 3, tzinfo=timezone.utc)
        grants = [PermissionGrant("projects.manage", expires_at=now - timedelta(seconds=1))]
        self.assertFalse(has_permission(grants, "projects.manage", now))
        self.assertEqual(merge_permissions(grants, now), {})

    def test_high_risk_forces_major(self):
        self.assertEqual(motion_class(["projects.manage"]), "ordinary")
        self.assertEqual(motion_class(["finance.manage"]), "major")
        self.assertEqual(required_threshold_bps("ordinary"), 5001)
        self.assertEqual(required_threshold_bps("major"), 6667)

    def test_ordinary_vote(self):
        result = evaluate_vote(100, 30, 20, 0, 5000, 5001)
        self.assertTrue(result.passed)
        self.assertEqual((result.turnout_bps, result.approval_bps), (5000, 6000))

    def test_major_vote_needs_two_thirds_of_all_shares(self):
        result = evaluate_vote(100, 60, 40, 0, 0, 6667, "total")
        self.assertFalse(result.passed)
        self.assertEqual(result.approval_bps, 6000)

    def test_admin_cannot_edit_self_or_overgrant(self):
        actor = [PermissionGrant("people.manage")]
        self.assertFalse(can_manage_template("u1", "u1", actor, ["people.manage"]))
        self.assertFalse(can_manage_template("u1", "u2", actor, ["finance.manage"]))
        self.assertTrue(can_manage_template("u1", "u2", actor, ["people.manage"]))

    def test_modes_and_points(self):
        self.assertFalse(can_use_advanced_mode([PermissionGrant("community.post")]))
        self.assertTrue(can_use_advanced_mode([PermissionGrant("projects.manage")]))
        self.assertEqual(point_balance([{"amount": 100}, {"amount": -30}]), 70)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行并确认失败**

Run: `.venv\Scripts\python.exe -m unittest tests.test_identity_rules -v`

Expected: FAIL，`identity_rules` 不存在。

- [ ] **Step 3: 实现规则**

```python
# identity_rules.py
from __future__ import annotations
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Iterable

BPS = 10000
HIGH_RISK_PERMISSIONS = {
    "identity.manage_templates", "identity.manage_shares", "governance.vote",
    "governance.manage", "finance.manage", "finance.approve_company",
    "data.export_all", "data.delete_all", "company.delete",
}
MANAGEMENT_PERMISSIONS = {
    "company.manage", "projects.view_all", "projects.manage", "people.view_all",
    "people.manage", "worklogs.approve", "tasks.assign", "tasks.grade",
    "finance.view", "finance.manage", "reports.view", "audit.read",
    "identity.manage_templates", "governance.manage",
}

@dataclass(frozen=True)
class PermissionGrant:
    key: str
    scope: str = "self"
    conditions: dict = field(default_factory=dict)
    expires_at: datetime | None = None
    high_risk: bool = False

@dataclass(frozen=True)
class VoteResult:
    passed: bool
    turnout_bps: int
    approval_bps: int
    reason: str

def _active(grant, now):
    if not grant.expires_at:
        return True
    expires = grant.expires_at
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    return expires > now

def merge_permissions(grants: Iterable[PermissionGrant], now=None):
    current = now or datetime.now(timezone.utc)
    merged = {}
    for grant in grants:
        if grant.key and _active(grant, current):
            merged.setdefault(grant.key, []).append(grant)
    return merged

def has_permission(grants, key, now=None):
    return bool(merge_permissions(grants, now).get(key))

def motion_class(permission_keys):
    return "major" if any(key in HIGH_RISK_PERMISSIONS for key in permission_keys) else "ordinary"

def required_threshold_bps(kind):
    if kind == "major": return 6667
    if kind == "ordinary": return 5001
    raise ValueError(f"unknown motion class: {kind}")

def evaluate_vote(total_shares, yes_shares, no_shares, abstain_shares,
                  quorum_bps, approval_bps, approval_basis="decisive"):
    total = max(float(total_shares), 0.0)
    yes = max(float(yes_shares), 0.0)
    no = max(float(no_shares), 0.0)
    cast = yes + no + max(float(abstain_shares), 0.0)
    turnout = int(cast / total * BPS) if total else 0
    decisive = yes + no
    denominator = total if approval_basis == "total" else decisive
    approval = int(yes / denominator * BPS) if denominator else 0
    if total <= 0:
        return VoteResult(False, 0, 0, "no_voting_shares")
    if turnout < quorum_bps:
        return VoteResult(False, turnout, approval, "quorum_not_reached")
    if approval < approval_bps:
        return VoteResult(False, turnout, approval, "approval_not_reached")
    return VoteResult(True, turnout, approval, "passed")

def can_manage_template(actor_id, target_id, grants, requested, allow_high_risk=False):
    if str(actor_id) == str(target_id):
        return False
    granted = merge_permissions(grants)
    if not granted.get("identity.manage_templates"):
        return False
    for key in requested:
        if key not in granted:
            return False
        if key in HIGH_RISK_PERMISSIONS and not allow_high_risk:
            return False
    return True

def can_use_advanced_mode(grants):
    return any(has_permission(grants, key) for key in MANAGEMENT_PERMISSIONS)

def point_balance(entries):
    return sum(int(entry.get("amount") or 0) for entry in entries)
```

- [ ] **Step 4: 运行测试并确认通过**

Run: `.venv\Scripts\python.exe -m unittest tests.test_identity_rules -v`

Expected: 6 tests PASS。

- [ ] **Step 5: 提交**

```bash
git add identity_rules.py tests/test_identity_rules.py
git commit -m "feat: add enterprise identity rule engine"
```

---

## Task 2: 模板、版本和多人兼任 SQL

**Files:** Create `mobile/sql/enterprise-governance-v2.sql`、`tests/test_enterprise_governance_sql.py`

**Interfaces:** Produces `enterprise_role_templates`、`enterprise_role_template_versions`、`enterprise_role_template_permissions`、`enterprise_role_assignments`、`enterprise_members.preferred_mode`、`get_enterprise_role_templates()`。

- [ ] **Step 1: 写 SQL 契约测试**

```python
# tests/test_enterprise_governance_sql.py
import unittest
from pathlib import Path
import pglast

class EnterpriseGovernanceSqlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = Path("mobile/sql/enterprise-governance-v2.sql").read_text(encoding="utf-8")

    def test_sql_parses_and_is_ascii(self):
        pglast.parse_sql(self.sql)
        self.assertTrue(all(ord(ch) < 128 for ch in self.sql))

    def test_required_schema(self):
        for name in ("enterprise_role_templates", "enterprise_role_template_versions",
                     "enterprise_role_template_permissions", "enterprise_role_assignments",
                     "enterprise_single_office_idx", "preferred_mode"):
            self.assertIn(name, self.sql)

    def test_governance_and_points(self):
        for name in ("motion_class", "share_snapshot", "enterprise_board_motions",
                     "enterprise_point_pools", "enterprise_point_ledger",
                     "unlock_knowledge_content", "points_are_permanent"):
            self.assertIn(name, self.sql)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行并确认失败**

Run: `.venv\Scripts\python.exe -m unittest tests.test_enterprise_governance_sql -v`

Expected: FAIL，SQL 文件不存在。

- [ ] **Step 3: 创建模板和兼任结构**

```sql
-- mobile/sql/enterprise-governance-v2.sql
alter table public.enterprise_members
  add column if not exists preferred_mode text not null default 'simple'
  check (preferred_mode in ('simple','advanced'));

create table if not exists public.enterprise_role_templates (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  key text not null,
  name text not null,
  office_key text not null default '',
  is_system boolean not null default false,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  unique (enterprise_id, key)
);

create table if not exists public.enterprise_role_template_versions (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.enterprise_role_templates(id) on delete cascade,
  version integer not null,
  status text not null default 'active' check (status in ('active','retired')),
  created_by uuid references public.profiles(id) on delete set null,
  effective_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (template_id, version)
);

create table if not exists public.enterprise_role_template_permissions (
  template_version_id uuid not null references public.enterprise_role_template_versions(id) on delete cascade,
  permission_key text not null,
  resource text not null,
  action text not null,
  scope text not null default 'self' check (scope in ('self','team','department','company','project')),
  conditions jsonb not null default '{}'::jsonb,
  high_risk boolean not null default false,
  primary key (template_version_id, permission_key)
);

create table if not exists public.enterprise_role_assignments (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  template_version_id uuid not null references public.enterprise_role_template_versions(id) on delete restrict,
  office_key text not null default '',
  is_primary boolean not null default false,
  status text not null default 'active' check (status in ('active','expired','revoked')),
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  appointed_by uuid references public.profiles(id) on delete set null,
  source_motion_id uuid,
  created_at timestamptz not null default now()
);

create unique index if not exists enterprise_primary_role_idx
  on public.enterprise_role_assignments(enterprise_id,profile_id)
  where status='active' and is_primary;

create unique index if not exists enterprise_single_office_idx
  on public.enterprise_role_assignments(enterprise_id,office_key)
  where status='active' and office_key in ('chairperson','identity_admin');

alter table public.enterprise_role_templates enable row level security;
alter table public.enterprise_role_template_versions enable row level security;
alter table public.enterprise_role_template_permissions enable row level security;
alter table public.enterprise_role_assignments enable row level security;
```

实现 `provision_default_role_templates(p_enterprise)`：遍历 `enterprise_role_catalog`，为每个企业创建模板和版本 1，把 catalog 的 `permissions` 拆到四维表；`get_enterprise_role_templates()` 返回模板、当前版本和权限数组。所有函数使用 `security definer`，只授予 `authenticated`。

- [ ] **Step 4: 运行 SQL 测试**

Run: `.venv\Scripts\python.exe -m unittest tests.test_enterprise_governance_sql -v`

Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add mobile/sql/enterprise-governance-v2.sql tests/test_enterprise_governance_sql.py
git commit -m "feat: add versioned role templates"
```

---

## Task 3: 模板复制、修改和兼任 RPC

**Files:** Modify `mobile/sql/enterprise-governance-v2.sql`、`tests/test_enterprise_governance_sql.py`

**Interfaces:** Produces `clone_role_template(source,name,key)`、`update_role_template(template,name,permissions)`、`set_member_role_assignment(profile,template,ends_at)`、`expire_role_assignments()`。

- [ ] **Step 1: 增加失败测试**

```python
    def test_template_rpc_guards(self):
        for text in ("clone_role_template", "update_role_template",
                     "set_member_role_assignment", "cannot edit your own role",
                     "cannot grant permissions you do not hold"):
            self.assertIn(text, self.sql)
```

- [ ] **Step 2: 运行并确认失败**

Run: `.venv\Scripts\python.exe -m unittest tests.test_enterprise_governance_sql -v`

Expected: FAIL。

- [ ] **Step 3: 实现 RPC**

`clone_role_template` 复制源模板当前版本的全部权限到新模板版本 1。`update_role_template` 必须执行：

```sql
if exists (
  select 1 from public.enterprise_role_assignments a
  join public.enterprise_role_template_versions v on v.id=a.template_version_id
   where a.profile_id=auth.uid() and a.status='active' and v.template_id=p_template
) then raise exception 'cannot edit your own role'; end if;

if exists (
  select 1 from jsonb_array_elements_text(v_requested) requested(key)
   where not (public._identity_role_permissions(v_enterprise,auth.uid()) ? requested.key)
) then raise exception 'cannot grant permissions you do not hold'; end if;

if v_high_risk then
  raise exception 'high-risk template changes require a major shareholder motion';
end if;
```

`update_role_template` 将旧版本设为 `retired`，创建新版本并复制客户端提交的四维权限。`set_member_role_assignment` 拒绝给自己任命、拒绝含 `high_risk` 的模板，写入 `office_key`、`starts_at`、`ends_at` 和 `appointed_by`。`expire_role_assignments` 把已过 `ends_at` 的 active 记录标为 expired。

- [ ] **Step 4: 运行测试**

Run: `.venv\Scripts\python.exe -m unittest tests.test_enterprise_governance_sql -v`

Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add mobile/sql/enterprise-governance-v2.sql tests/test_enterprise_governance_sql.py
git commit -m "feat: add role template management"
```

---

## Task 4: 股东会、股份快照和董事会

**Files:** Modify `mobile/sql/enterprise-governance-v2.sql`、`tests/test_enterprise_governance_sql.py`

**Interfaces:** Produces `motion_class`、`share_snapshot`、`required_bps`、`conflict_disclosed`；`enterprise_board_motions`、`enterprise_board_votes`；`create_board_motion()`、`cast_board_vote()`、`finalize_board_motion()`。

- [ ] **Step 1: 增加失败测试**

```python
    def test_governance_snapshot_and_board(self):
        for text in ("motion_class", "share_snapshot", "required_bps",
                     "enterprise_board_motions", "enterprise_board_votes",
                     "board_vote_idx", "6667"):
            self.assertIn(text, self.sql)
```

- [ ] **Step 2: 运行并确认失败**

Run: `.venv\Scripts\python.exe -m unittest tests.test_enterprise_governance_sql -v`

Expected: FAIL。

- [ ] **Step 3: 实现治理结构**

```sql
alter table public.enterprise_role_motions
  add column if not exists motion_class text not null default 'ordinary'
    check (motion_class in ('ordinary','major')),
  add column if not exists share_snapshot jsonb not null default '{}'::jsonb,
  add column if not exists required_bps integer not null default 5001,
  add column if not exists conflict_disclosed boolean not null default false;

create table if not exists public.enterprise_board_motions (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  title text not null,
  kind text not null check (kind in ('point_pool','governance','operations')),
  payload jsonb not null default '{}'::jsonb,
  proposer_profile_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'open' check (status in ('open','passed','rejected','cancelled')),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);

create table if not exists public.enterprise_board_votes (
  motion_id uuid not null references public.enterprise_board_motions(id) on delete cascade,
  director_profile_id uuid not null references public.profiles(id) on delete cascade,
  choice text not null check (choice in ('yes','no','abstain')),
  voted_at timestamptz not null default now(),
  primary key (motion_id,director_profile_id)
);

create index if not exists board_vote_idx
  on public.enterprise_board_votes(motion_id,choice);
```

`create_board_motion` 只允许 `office_key in ('chairperson','director')` 的董事发起。`cast_board_vote` 每个董事一票，允许改票。`finalize_board_motion` 在超过半数董事投票后，以出席董事过半数赞成通过。

- [ ] **Step 4: 修改股东会函数**

`propose_enterprise_role` 创建提案时写入股份快照：

```sql
select jsonb_object_agg(s.profile_id::text,s.shares) into v_snapshot
  from public.enterprise_shareholders s
  join public.enterprise_members m
    on m.enterprise_id=s.enterprise_id and m.profile_id=s.profile_id
 where s.enterprise_id=v_eid and s.shares>0 and m.status='active';

v_motion_class:=case when v_role in
  ('chairperson','director','supervisor','ceo','finance') then 'major' else 'ordinary' end;
v_required_bps:=case when v_motion_class='major' then 6667 else 5001 end;
```

`cast_enterprise_role_vote` 从 `share_snapshot` 取票权。`_identity_finalize_motion` 对 major 使用 `yes / total_shares >= 6667`，对 ordinary 使用 50% 出席和过半数赞成。投票期间 `set_enterprise_shareholder` 必须拒绝股份调整。

- [ ] **Step 5: 运行测试并提交**

Run: `.venv\Scripts\python.exe -m unittest tests.test_enterprise_governance_sql -v`

Expected: PASS。

```bash
git add mobile/sql/enterprise-governance-v2.sql tests/test_enterprise_governance_sql.py
git commit -m "feat: add shareholder and board voting"
```

---

## Task 5: 积分池、永久账本和知识解锁

**Files:** Modify `mobile/sql/enterprise-governance-v2.sql`、`tests/test_enterprise_governance_sql.py`

**Interfaces:** Produces `enterprise_point_pools`、`enterprise_point_ledger`、`enterprise_knowledge_unlocks`、`award_points()`、`get_point_state()`、`unlock_knowledge_content()`。

- [ ] **Step 1: 增加失败测试**

```python
    def test_point_guards(self):
        for text in ("enterprise_point_pools", "enterprise_point_ledger",
                     "enterprise_knowledge_unlocks",
                     "chairperson cannot award points to self",
                     "point pool exceeded", "points_are_permanent"):
            self.assertIn(text, self.sql)
```

- [ ] **Step 2: 运行并确认失败**

Run: `.venv\Scripts\python.exe -m unittest tests.test_enterprise_governance_sql -v`

Expected: FAIL。

- [ ] **Step 3: 实现积分结构**

```sql
create table if not exists public.enterprise_point_pools (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  quarter text not null,
  total_amount integer not null check(total_amount>0),
  remaining_amount integer not null check(remaining_amount>=0),
  status text not null default 'active' check(status in ('active','closed')),
  board_motion_id uuid references public.enterprise_board_motions(id) on delete set null,
  approved_at timestamptz not null default now(),
  carries_to uuid references public.enterprise_point_pools(id) on delete set null,
  unique (enterprise_id,quarter)
);

create table if not exists public.enterprise_point_ledger (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  amount integer not null check(amount<>0),
  entry_type text not null check(entry_type in ('award','unlock','correction')),
  pool_id uuid references public.enterprise_point_pools(id) on delete set null,
  evidence_type text not null default '',
  evidence_id uuid,
  reason text not null default '',
  actor_profile_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.enterprise_knowledge_unlocks (
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  post_id uuid not null references public.community_posts(id) on delete cascade,
  cost integer not null check(cost>=0),
  ledger_id uuid not null references public.enterprise_point_ledger(id),
  unlocked_at timestamptz not null default now(),
  primary key (profile_id,post_id)
);

alter table public.community_posts
  add column if not exists unlock_cost integer not null default 0 check(unlock_cost>=0),
  add column if not exists is_required boolean not null default false;
```

`award_points()` 必须验证：调用者是 active chairperson、目标不是自己、金额为正且不超过单次上限、有证据、当前季度池余额足够；然后扣减池余额并写 `award` 账本，返回 `points_are_permanent: true`。`get_point_state()` 返回当前余额、当前积分池和本人账本。`unlock_knowledge_content()` 对必需内容直接开放；对可选内容检查余额、写负向账本和唯一解锁记录，永久保留访问。

- [ ] **Step 4: 运行测试并提交**

Run: `.venv\Scripts\python.exe -m unittest tests.test_enterprise_governance_sql -v`

Expected: PASS。

```bash
git add mobile/sql/enterprise-governance-v2.sql tests/test_enterprise_governance_sql.py
git commit -m "feat: add limited point pools"
```

---

## Task 6: Python 客户端

**Files:** Modify `community_client.py`、Create `tests/test_identity_client.py`

**Interfaces:** Adds `role_templates()`、`clone_role_template()`、`update_role_template()`、`set_role_assignment()`、`create_board_motion()`、`cast_board_vote()`、`point_state()`、`award_points()`、`unlock_knowledge()`、`set_ui_mode()`。

- [ ] **Step 1: 写失败测试**

```python
# tests/test_identity_client.py
import unittest
from unittest.mock import patch
from community_client import CommunityClient, CommunitySession

class IdentityClientTest(unittest.TestCase):
    def setUp(self):
        self.session = CommunitySession("token", expires_at=9999999999)
        self.client = CommunityClient()

    @patch("community_client._request")
    def test_clone_template(self, request):
        request.return_value = {"ok": True}
        self.client.clone_role_template(self.session, "src", "sales", "销售")
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/clone_role_template", token="token",
            body={"p_source_template": "src", "p_key": "sales", "p_name": "销售"},
        )

    @patch("community_client._request")
    def test_award_points(self, request):
        request.return_value = {"ok": True}
        self.client.award_points(self.session, "u2", 50, "acceptance", "e1", "验收通过")
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/award_points", token="token",
            body={"p_profile": "u2", "p_amount": 50,
                  "p_evidence_type": "acceptance", "p_evidence_id": "e1",
                  "p_reason": "验收通过"},
        )

    @patch("community_client._request")
    def test_mode_validation(self, request):
        with self.assertRaises(ValueError):
            self.client.set_ui_mode(self.session, "complex")
        request.assert_not_called()

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行并确认失败**

Run: `.venv\Scripts\python.exe -m unittest tests.test_identity_client -v`

Expected: FAIL。

- [ ] **Step 3: 添加客户端方法**

```python
    def role_templates(self, session):
        data = _request("POST", "/rest/v1/rpc/get_enterprise_role_templates",
                        token=session.access_token, body={})
        return data if isinstance(data, list) else []

    def clone_role_template(self, session, source_id, key, name):
        return _request("POST", "/rest/v1/rpc/clone_role_template",
            token=session.access_token,
            body={"p_source_template": str(source_id), "p_key": key, "p_name": name})

    def update_role_template(self, session, template_id, name, permissions):
        return _request("POST", "/rest/v1/rpc/update_role_template",
            token=session.access_token,
            body={"p_template": str(template_id), "p_name": name,
                  "p_permissions": list(permissions or [])})

    def set_role_assignment(self, session, profile_id, template_id, ends_at=None):
        return _request("POST", "/rest/v1/rpc/set_member_role_assignment",
            token=session.access_token,
            body={"p_profile": str(profile_id), "p_template": str(template_id),
                  "p_ends_at": ends_at})

    def create_board_motion(self, session, title, kind, payload):
        return _request("POST", "/rest/v1/rpc/create_board_motion",
            token=session.access_token,
            body={"p_title": title, "p_kind": kind, "p_payload": payload})

    def cast_board_vote(self, session, motion_id, choice):
        return _request("POST", "/rest/v1/rpc/cast_board_vote",
            token=session.access_token,
            body={"p_motion": str(motion_id), "p_choice": choice})

    def point_state(self, session):
        data = _request("POST", "/rest/v1/rpc/get_point_state",
                        token=session.access_token, body={})
        return data if isinstance(data, dict) else {}

    def award_points(self, session, profile_id, amount, evidence_type,
                     evidence_id, reason):
        return _request("POST", "/rest/v1/rpc/award_points",
            token=session.access_token,
            body={"p_profile": str(profile_id), "p_amount": int(amount),
                  "p_evidence_type": evidence_type, "p_evidence_id": str(evidence_id),
                  "p_reason": reason})

    def unlock_knowledge(self, session, post_id):
        return _request("POST", "/rest/v1/rpc/unlock_knowledge_content",
            token=session.access_token, body={"p_post": str(post_id)})

    def set_ui_mode(self, session, mode):
        if mode not in ("simple", "advanced"):
            raise ValueError("mode must be simple or advanced")
        return _request("POST", "/rest/v1/rpc/set_enterprise_ui_mode",
            token=session.access_token, body={"p_mode": mode})
```

- [ ] **Step 4: 增加模式 RPC 并验证**

```sql
create or replace function public.set_enterprise_ui_mode(p_mode text)
returns jsonb language plpgsql security definer
set search_path=public,auth,pg_temp as $fn$
declare v_uid uuid:=auth.uid(); v_eid uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if p_mode not in ('simple','advanced') then raise exception 'invalid mode'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  update public.enterprise_members set preferred_mode=p_mode,updated_at=now()
   where enterprise_id=v_eid and profile_id=v_uid;
  return jsonb_build_object('ok',true,'mode',p_mode);
end; $fn$;
revoke all on function public.set_enterprise_ui_mode(text) from public;
grant execute on function public.set_enterprise_ui_mode(text) to authenticated;
```

Run: `.venv\Scripts\python.exe -m unittest tests.test_identity_client -v`

Expected: 3 tests PASS。

- [ ] **Step 5: 提交**

```bash
git add community_client.py tests/test_identity_client.py mobile/sql/enterprise-governance-v2.sql
git commit -m "feat: expose governance RPCs"
```

---

## Task 7: 桌面身份模板与权限页

**Files:** Create `role_templates_ui.py`、`tests/test_identity_ui.py`；Modify `identity_ui.py`

**Interfaces:** Produces `RoleTemplatePage(QWidget)`，含 `apply_account_session()`、`refresh()`、`render()`。

- [ ] **Step 1: 写离屏失败测试**

```python
# tests/test_identity_ui.py
import os, unittest
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PyQt6.QtWidgets import QApplication
from role_templates_ui import RoleTemplatePage

class RoleTemplateUiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def test_render_template(self):
        page = RoleTemplatePage(None)
        page.snapshot = {"templates": [{"key": "pm", "name": "项目经理",
                                       "current_version": 1, "permissions": []}]}
        page.render()
        self.assertEqual(page.table.item(0, 1).text(), "项目经理")

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行并确认失败**

Run: `.venv\Scripts\python.exe -m unittest tests.test_identity_ui -v`

Expected: FAIL。

- [ ] **Step 3: 实现模板页**

```python
# role_templates_ui.py
from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import QAbstractItemView, QHBoxLayout, QPushButton, QTableWidget, QTableWidgetItem, QVBoxLayout, QWidget
from widgets import SectionTitle, muted

class RoleTemplatePage(QWidget):
    def __init__(self, window):
        super().__init__()
        self.window = window
        self.session = None
        self.snapshot = {"templates": []}
        root = QVBoxLayout(self)
        head = QHBoxLayout()
        head.addWidget(SectionTitle("身份模板"))
        head.addStretch()
        self.clone_button = QPushButton("复制选中身份")
        self.clone_button.setObjectName("PrimaryButton")
        head.addWidget(self.clone_button)
        root.addLayout(head)
        self.table = QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(["身份", "名称", "版本", "权限数"])
        self.table.verticalHeader().setVisible(False)
        self.table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.horizontalHeader().setStretchLastSection(True)
        root.addWidget(self.table, 1)
        root.addWidget(muted("复制后修改四维权限；高风险权限提交重大股东表决。"))

    def apply_account_session(self, session):
        self.session = session

    def refresh(self):
        self.render()

    def render(self):
        self.table.setRowCount(0)
        for template in self.snapshot.get("templates", []):
            row = self.table.rowCount()
            self.table.insertRow(row)
            values = [template.get("key", ""), template.get("name", ""),
                      str(template.get("current_version", "")),
                      str(len(template.get("permissions", [])))]
            for column, text in enumerate(values):
                item = QTableWidgetItem(str(text))
                if column == 0:
                    item.setData(Qt.ItemDataRole.UserRole, template)
                self.table.setItem(row, column, item)
        self.table.resizeColumnsToContents()
```

在 `identity_ui.py` 中实例化 `RoleTemplatePage` 并加入“身份模板”页签；身份状态刷新后设置 `snapshot = {"templates": state.get("templates", [])}` 并调用 `render()`。

- [ ] **Step 4: 运行 UI 和桌面自检**

Run: `.venv\Scripts\python.exe -m unittest tests.test_identity_ui -v`

Expected: PASS。

Run: `.venv\Scripts\python.exe check.py`

Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add role_templates_ui.py identity_ui.py tests/test_identity_ui.py
git commit -m "feat: add desktop role template page"
```

---

## Task 8: 桌面简单模式和今日工位

**Files:** Create `today_ui.py`；Modify `main.py`、`tests/test_identity_ui.py`

**Interfaces:** Produces `TodayPage(QWidget)` with `refresh()`、`apply_account_session()`、`render()`。

- [ ] **Step 1: 增加失败测试**

```python
from today_ui import TodayPage

    def test_today_page_empty(self):
        page = TodayPage(None)
        page.render()
        self.assertEqual(page.task_list.count(), 0)
```

- [ ] **Step 2: 运行并确认失败**

Run: `.venv\Scripts\python.exe -m unittest tests.test_identity_ui -v`

Expected: FAIL。

- [ ] **Step 3: 实现今日工位**

```python
# today_ui.py
from PyQt6.QtWidgets import QHBoxLayout, QListWidget, QPushButton, QVBoxLayout, QWidget
from widgets import StatCard, label, muted

class TodayPage(QWidget):
    def __init__(self, window):
        super().__init__()
        self.window = window
        self.tasks = []
        root = QVBoxLayout(self)
        root.setContentsMargins(24, 20, 24, 18)
        root.addWidget(label("今天", "KnowledgeTitle"))
        root.addWidget(muted("先完成今天的事，再决定下一步。"))
        cards = QHBoxLayout()
        self.card_done = StatCard("今日完成", "0/0", "", "任务完成情况")
        self.card_points = StatCard("当前积分", "0", "分", "永久有效")
        self.card_streak = StatCard("连续完成", "0", "天", "每天一小步")
        cards.addWidget(self.card_done)
        cards.addWidget(self.card_points)
        cards.addWidget(self.card_streak)
        root.addLayout(cards)
        self.task_list = QListWidget()
        self.task_list.setObjectName("TodayTaskList")
        root.addWidget(self.task_list, 1)
        self.next_button = QPushButton("开始第一项任务")
        self.next_button.setObjectName("PrimaryButton")
        root.addWidget(self.next_button)

    def apply_account_session(self, session):
        self.refresh()

    def refresh(self):
        self.render()

    def render(self):
        self.task_list.clear()
        for task in self.tasks:
            self.task_list.addItem(f"{task.get('title', '任务')}  截止 {task.get('due', '—')}")
        done = sum(1 for task in self.tasks if task.get("done"))
        self.card_done.update_values(f"{done}/{len(self.tasks)}", "", "任务完成情况")
        points = getattr(self.window, "identity_state", {}).get("point_state", {}).get("balance", 0)
        self.card_points.update_values(str(points), "分", "永久有效")
        self.next_button.setEnabled(bool(self.tasks))
```

`main.py` 增加 `TodayPage` 和 `today_tab`。`_refresh_account_ui()` 读取 `identity_state.me.preferred_mode`；如果没有高级权限则强制 simple。simple 只显示“今日”，advanced 显示驾驶舱、协作、治理和身份页。

- [ ] **Step 4: 运行测试**

Run: `.venv\Scripts\python.exe -m unittest tests.test_identity_ui -v`

Expected: PASS。

Run: `.venv\Scripts\python.exe check.py`

Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add today_ui.py main.py tests/test_identity_ui.py
git commit -m "feat: add desktop today workspace"
```

---

## Task 9: 移动端工位、积分和模式

**Files:** Create `mobile/today.js`；Modify `mobile/index.html`、`mobile/app.js`、`mobile/account.js`、`mobile/identity.js`、`mobile/style.css`、`mobile/store.js`、`mobile/build-www.js`、`mobile/selfcheck.js`

**Interfaces:** Produces `renderToday()`、`refreshPointState(force)`、`setMobileUiMode(mode)`；Consumes `DB.pointState`。

- [ ] **Step 1: 写失败自检**

```javascript
test("企业治理：今日工位存在", () => {
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  for (const id of ("page-today", "today-task-list", "btn-mode-toggle")) {
    if (html.indexOf(`id="${id}"`) === -1) throw new Error(`缺少 ${id}`);
  }
});
```

- [ ] **Step 2: 运行并确认失败**

Run: `node selfcheck.js`

Expected: FAIL。

- [ ] **Step 3: 加入页面和脚本**

```html
<section id="page-today" class="page hidden">
  <div class="topbar">
    <div class="grow"><h1>今天</h1><div class="sub" id="today-sub"></div></div>
    <button class="icon-btn" id="btn-mode-toggle" title="切换模式">⇄</button>
  </div>
  <div class="body">
    <div class="identity-me-card" id="today-summary"></div>
    <div class="section-head"><span>今日任务</span><span class="meta" id="today-count"></span></div>
    <div id="today-task-list"></div>
    <div class="section-head"><span>积分与解锁</span><span class="meta" id="today-points"></span></div>
    <div id="today-rewards"></div>
  </div>
</section>
```

创建 `mobile/today.js`：

```javascript
"use strict";
function renderToday() {
  const tasks = (DB.tasks || []).filter(task => !task.done).slice(0, 5);
  const points = DB.pointState || {};
  $("today-sub").textContent = DB.profile ? `${DB.profile.name}，今天先完成 ${tasks.length} 项` : "登录后查看今天的工作";
  $("today-summary").innerHTML = `<div class="identity-me-head">
    <div><div class="identity-eyebrow">我的今日进度</div><div class="identity-role-line"><b>${tasks.length ? "继续推进" : "今天已完成"}</b></div></div>
    <div class="identity-weight"><b>${num(points.balance)}</b><span>可用积分</span></div></div>`;
  $("today-count").textContent = `${tasks.length} 项待处理`;
  $("today-task-list").innerHTML = tasks.length ? tasks.map(task => `<div class="identity-member">
    <div class="identity-member-main"><div class="identity-member-name"><b>${escapeHtml(task.title || "任务")}</b></div>
    <div class="identity-member-meta">截止 ${escapeHtml(task.plan_date || "—")}</div></div>
    <button class="btn">${task.started_at ? "继续" : "开始"}</button></div>`).join("")
    : '<div class="identity-empty"><b>今天没有待办</b><span>可以查看知识星球或休息一下。</span></div>';
  $("today-points").textContent = `${num(points.balance)} 积分`;
  $("today-rewards").innerHTML = points.pool ? `<div class="identity-motion"><b>本期积分池</b><div class="identity-vote-line">剩余 ${num(points.pool.remaining)} / ${num(points.pool.total)}</div></div>` : '<div class="identity-empty"><b>暂无积分池</b></div>';
}
async function refreshPointState(force) {
  if (!DB.profile || !initCloud()) return;
  if (!force && DB.pointState && Date.now() - Number(DB.pointState.at || 0) < 10000) return;
  const { data, error } = await cloudClient.rpc("get_point_state");
  if (error) { toast(String(error.message || error)); return; }
  DB.pointState = Object.assign({}, data || {}, { at: Date.now() });
  saveAll(); renderToday();
}
async function setMobileUiMode(mode) {
  const { error } = await cloudClient.rpc("set_enterprise_ui_mode", { p_mode: mode });
  if (error) { toast(String(error.message || error)); return; }
  DB.uiMode = mode; saveAll(); applyRoleUI();
}
```

在 `app.js` 增加 `"today"` 页面和 `renderToday()` 入口；`build-www.js` 加入 `today.js`；`account.js` 登录后进入 `today` 并刷新积分；`applyRoleUI()` 只有高级权限才显示模式切换按钮。

- [ ] **Step 4: 添加 Frontend Design 样式**

```css
.today-task-route { position: relative; padding-left: 18px; }
.today-task-route::before { content: ""; position: absolute; left: 5px; top: 8px; bottom: 8px; width: 2px; background: var(--accent-edge); }
.today-point-stamp { display: inline-grid; place-items: center; min-width: 58px; height: 58px; border: 2px solid var(--accent); border-radius: 50%; color: var(--accent-dim); font-weight: 700; }
```

- [ ] **Step 5: 运行并提交**

Run: `node build-www.js`

Expected: 成功并包含 `today.js`。

Run: `node selfcheck.js`

Expected: 全部通过。

```bash
git add mobile/today.js mobile/index.html mobile/app.js mobile/account.js mobile/identity.js mobile/style.css mobile/store.js mobile/build-www.js mobile/selfcheck.js mobile/www
git commit -m "feat: add mobile today workspace"
```

---

## Task 10: 文档、清单和最终验收

**Files:** Create `tests/test_identity_docs.py`；Modify `README.md`、`sync_manifest.txt`、`mobile/sql/install-unified.sql`

- [ ] **Step 1: 写失败测试**

```python
# tests/test_identity_docs.py
import unittest
from pathlib import Path

class IdentityDocsTest(unittest.TestCase):
    def test_docs(self):
        readme = Path("README.md").read_text(encoding="utf-8")
        manifest = Path("sync_manifest.txt").read_text(encoding="utf-8")
        for text in ("enterprise-governance-v2.sql", "简单模式", "董事会"):
            self.assertIn(text, readme)
        for path in ("identity_rules.py", "role_templates_ui.py", "today_ui.py",
                     "mobile/today.js", "mobile/sql/enterprise-governance-v2.sql"):
            self.assertIn(path, manifest)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行并确认失败**

Run: `.venv\Scripts\python.exe -m unittest tests.test_identity_docs -v`

Expected: FAIL。

- [ ] **Step 3: 更新文档和部署顺序**

README 增加：

```text
阶段一升级顺序：
1. mobile/sql/enterprise-identity.sql
2. mobile/sql/enterprise-governance-v2.sql
```

并说明身份模板、股东会/董事会、永久积分、简单/高级模式。`sync_manifest.txt` 加入所有新文件；`install-unified.sql` 末尾注明 v2 文件需单独执行。

- [ ] **Step 4: 运行完整验收**

Run:

```powershell
.venv\Scripts\python.exe -m unittest tests.test_identity_rules tests.test_enterprise_governance_sql tests.test_identity_client tests.test_identity_ui tests.test_identity_docs -v
.venv\Scripts\python.exe check.py
node build-www.js
node selfcheck.js
.venv\Scripts\python.exe -c "from pathlib import Path; import pglast; pglast.parse_sql(Path('mobile/sql/enterprise-governance-v2.sql').read_text(encoding='utf-8')); print('SQL parse ok')"
node .\node_modules\.bin\cap.cmd sync android
```

Expected: 所有测试通过；SQL 输出 `SQL parse ok`；Capacitor sync 成功。

- [ ] **Step 5: 提交**

```bash
git add README.md sync_manifest.txt mobile/sql/install-unified.sql mobile/www tests/test_identity_docs.py
git commit -m "docs: document phase one rollout"
```

---

## Self-Review

### Spec Coverage

| Spec area | Tasks |
|---|---|
| 可复制身份模板 | 2、3、7 |
| 四维权限 | 1、2、3 |
| 身份管理员限制 | 1、3 |
| 一人多身份和有效期 | 2、3 |
| 股东会普通/重大事项 | 1、4 |
| 股份快照 | 4 |
| 董事会一人一票 | 4 |
| 有限积分池和永久积分 | 5 |
| 知识解锁永久访问 | 5、9 |
| 简单/高级模式 | 6、7、8、9 |
| Frontend Design | 8、9 |
| RPC 与客户端 | 4、5、6 |
| 文档和上线 | 10 |

### Placeholder Scan

每个编码任务都有失败测试、运行命令、实现代码和提交命令；没有未定义文件或未说明接口。

### Type Consistency

- `PermissionGrant` 仅在 Task 1 定义。
- `role_templates()` 返回 list，桌面和移动端读取同一 `templates` 结构。
- `point_state()` 统一返回 `balance`、`pool`、`ledger`。
- `set_ui_mode()` 只接受 `simple` 和 `advanced`。
- `TodayPage` 与 `today.js` 都读取任务标题、截止日期和积分余额。

---

## Execution Handoff

阶段一计划完成。执行时必须按 Task 1 到 Task 10 顺序推进，先写失败测试，再写实现。阶段一通过全部验收前，不进入阶段二。

