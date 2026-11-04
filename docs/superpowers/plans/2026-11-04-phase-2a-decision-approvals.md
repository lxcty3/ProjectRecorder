# 阶段二 A：经营决策中心与统一审批 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付一个可独立验收的经营决策中心：管理者能按影响优先级处理跨模块决策和统一审批，并能下钻到证据、责任人、金额和原始记录。

**Architecture:** 新增 Phase 2A SQL 迁移，建立 `decision_items` 与 `approval_requests` 统一聚合层；通过服务端 RPC 生成、分派、延期、关闭决策，并统一审批请假、工时、费用、采购、奖励、任务延期和身份事项。桌面端新增“经营决策中心”，移动端新增管理审批收件箱；简单模式员工不显示该入口。

**Tech Stack:** Python 3.13、PyQt6、Supabase Postgres/RLS/RPC、Capacitor、Vanilla JavaScript、unittest、pglast。

**Spec:** `docs/superpowers/specs/2026-11-03-enterprise-operating-system-design.md`

## Global Constraints

- 只有具备管理、财务、审计或治理能力的身份可进入高级模式和决策中心。
- 决策依据必须能下钻到任务、工时、审批、变更或治理记录。
- 审批动作必须幂等并写入审计。
- 高风险或超授权金额必须升级审批或拒绝。
- SQL 纯 ASCII，使用 SECURITY DEFINER 和最小权限。
- 前端沿用 `Ink #1F2B27`、`Paper #F4F6F2`、`Mint #47B7A1`、`Mint Deep #217766`、`Signal #D86A45`、`Info #6F8FBE`。
- 每个任务先失败测试，再实现，再提交。
- 当前源码工作目录不是 Git 仓库；执行在同步 Git 仓库中完成，完成后同步回 D 盘。

## File Structure

新增：
- `decision_rules.py`：决策优先级、影响评分、审批升级规则。
- `tests/test_decision_rules.py`
- `mobile/sql/decision-approvals-v1.sql`
- `tests/test_decision_sql.py`
- `tests/test_decision_client.py`
- `decision_ui.py`
- `tests/test_decision_ui.py`

修改：
- `community_client.py`
- `main.py`
- `mobile/index.html`
- `mobile/app.js`
- `mobile/account.js`
- `mobile/identity.js`
- `mobile/style.css`
- `mobile/build-www.js`
- `mobile/selfcheck.js`
- `README.md`
- `sync_manifest.txt`

---

## Task 1: 决策与审批纯规则

**Files:** Create `decision_rules.py`、`tests/test_decision_rules.py`

**Interfaces:** `DecisionSignals`, `score_decision()`, `approval_required_level()`, `normalize_decision_status()`.

- [ ] **Step 1: 写失败测试**

```python
# tests/test_decision_rules.py
import unittest
from decision_rules import DecisionSignals, score_decision, approval_required_level

class DecisionRulesTest(unittest.TestCase):
    def test_high_delivery_impact_outranks_low_value(self):
        high = DecisionSignals(delivery_days=12, amount=0, risk="严重", waiting_days=1)
        low = DecisionSignals(delivery_days=1, amount=50000, risk="健康", waiting_days=1)
        self.assertGreater(score_decision(high), score_decision(low))

    def test_amount_and_risk_raise_approval_level(self):
        self.assertEqual(approval_required_level(1000, "健康"), "manager")
        self.assertEqual(approval_required_level(60000, "关注"), "executive")
        self.assertEqual(approval_required_level(0, "严重"), "executive")

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行并确认失败**

Run: `.venv\Scripts\python.exe -m unittest tests.test_decision_rules -v`

Expected: FAIL，模块不存在。

- [ ] **Step 3: 实现规则**

```python
# decision_rules.py
from dataclasses import dataclass

RISK_WEIGHT = {"严重": 50, "风险": 35, "关注": 20, "健康": 0}

@dataclass(frozen=True)
class DecisionSignals:
    delivery_days: int = 0
    amount: float = 0
    risk: str = "健康"
    waiting_days: int = 0

def score_decision(signals):
    return (
        max(signals.delivery_days, 0) * 4
        + max(signals.waiting_days, 0) * 3
        + max(signals.amount, 0) / 10000
        + RISK_WEIGHT.get(signals.risk, 0)
    )

def approval_required_level(amount, risk):
    if risk in ("严重", "风险") or amount >= 50000:
        return "executive"
    if amount >= 5000:
        return "manager"
    return "manager"

def normalize_decision_status(status):
    value = str(status or "").strip().lower()
    return value if value in ("open","acknowledged","assigned","deferred","resolved","dismissed") else "open"
```

- [ ] **Step 4: 测试并提交**

Run: `.venv\Scripts\python.exe -m unittest tests.test_decision_rules -v`

Expected: 2 tests PASS。

```bash
git add decision_rules.py tests/test_decision_rules.py
git commit -m "feat: add decision priority rules"
```

---

## Task 2: 决策与审批数据库

**Files:** Create `mobile/sql/decision-approvals-v1.sql`、`tests/test_decision_sql.py`

**Interfaces:** Tables `decision_items`、`approval_requests`、`approval_events`; RPC `get_decision_center()`, `act_on_decision()`, `act_on_approval()`.

- [ ] **Step 1: 写失败 SQL 契约**

```python
# tests/test_decision_sql.py
import unittest
from pathlib import Path
import pglast

class DecisionSqlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = Path("mobile/sql/decision-approvals-v1.sql").read_text(encoding="utf-8")

    def test_parses_ascii(self):
        pglast.parse_sql(self.sql)
        self.assertTrue(all(ord(ch) < 128 for ch in self.sql))

    def test_required_objects(self):
        for name in ("decision_items","approval_requests","approval_events",
                     "get_decision_center","act_on_decision","act_on_approval"):
            self.assertIn(name, self.sql)

    def test_idempotency_and_audit(self):
        for text in ("idempotency_key","enterprise_identity_audit","FOR UPDATE"):
            self.assertIn(text, self.sql)
```

- [ ] **Step 2: 运行并确认失败**

Run: `.venv\Scripts\python.exe -m unittest tests.test_decision_sql -v`

Expected: FAIL，SQL 文件不存在。

- [ ] **Step 3: 实现数据库和 RPC**

```sql
-- decision-approvals-v1.sql
create table if not exists public.decision_items (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  source_type text not null,
  source_id uuid,
  title text not null,
  detail text not null default '',
  risk text not null default 'health',
  impact_days integer not null default 0,
  impact_amount numeric not null default 0,
  waiting_since timestamptz not null default now(),
  owner_profile_id uuid references public.profiles(id) on delete set null,
  status text not null default 'open'
    check (status in ('open','acknowledged','assigned','deferred','resolved','dismissed')),
  resolution text not null default '',
  due_at timestamptz,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.approval_requests (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  kind text not null,
  source_id uuid,
  requester_profile_id uuid not null references public.profiles(id) on delete cascade,
  owner_profile_id uuid references public.profiles(id) on delete set null,
  title text not null,
  amount numeric not null default 0,
  risk text not null default 'health',
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','returned','cancelled')),
  idempotency_key text not null default '',
  decision_note text not null default '',
  due_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists approval_idempotency_idx
  on public.approval_requests(enterprise_id,idempotency_key)
  where idempotency_key<>'';

create table if not exists public.approval_events (
  id bigserial primary key,
  approval_id uuid not null references public.approval_requests(id) on delete cascade,
  actor_profile_id uuid references public.profiles(id) on delete set null,
  action text not null,
  note text not null default '',
  created_at timestamptz not null default now()
);

alter table public.decision_items enable row level security;
alter table public.approval_requests enable row level security;
alter table public.approval_events enable row level security;

create or replace function public.get_decision_center()
returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_uid uuid:=auth.uid(); v_eid uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  v_eid:=public._identity_bootstrap(public._identity_owner_for_uid(v_uid));
  if not (
    public.identity_has_permission('projects.view_all')
    or public.identity_has_permission('people.view_all')
    or public.identity_has_permission('finance.view')
    or public.identity_has_permission('reports.view')
    or public.identity_has_permission('audit.read')
  ) then raise exception 'management permission required'; end if;
  return jsonb_build_object(
    'decisions',(select coalesce(jsonb_agg(to_jsonb(d) order by
      d.impact_days desc,d.impact_amount desc,d.created_at), '[]'::jsonb)
      from public.decision_items d where d.enterprise_id=v_eid),
    'approvals',(select coalesce(jsonb_agg(to_jsonb(a) order by
      a.amount desc,a.created_at), '[]'::jsonb)
      from public.approval_requests a where a.enterprise_id=v_eid)
  );
end;
$fn$;

create or replace function public.act_on_decision(
  p_decision uuid, p_action text, p_owner uuid default null,
  p_note text default '', p_idempotency_key text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_uid uuid:=auth.uid(); v_row public.decision_items%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.decision_items where id=p_decision for update;
  if not found then raise exception 'decision not found'; end if;
  if not public.identity_has_permission('projects.view_all')
     and not public.identity_has_permission('people.view_all')
     and not public.identity_has_permission('reports.view') then
    raise exception 'management permission required';
  end if;
  if p_action not in ('acknowledged','assigned','deferred','resolved','dismissed') then
    raise exception 'invalid action';
  end if;
  update public.decision_items set
    status=p_action,owner_profile_id=coalesce(p_owner,owner_profile_id),
    resolution=case when p_action in ('resolved','dismissed') then p_note else resolution end,
    version=version+1,updated_at=now()
  where id=p_decision;
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,details
  ) values(v_row.enterprise_id,v_uid,'decision.'||p_action,
    jsonb_build_object('decision_id',p_decision,'note',p_note,
      'idempotency_key',p_idempotency_key));
  return jsonb_build_object('ok',true,'status',p_action);
end;
$fn$;

create or replace function public.act_on_approval(
  p_approval uuid, p_action text, p_note text default '',
  p_idempotency_key text default ''
) returns jsonb
language plpgsql security definer
set search_path=public,auth,pg_temp
as $fn$
declare v_uid uuid:=auth.uid(); v_row public.approval_requests%rowtype;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  select * into v_row from public.approval_requests where id=p_approval for update;
  if not found then raise exception 'approval not found'; end if;
  if v_row.status<>'pending' then raise exception 'approval already decided'; end if;
  if p_action not in ('approved','rejected','returned','cancelled') then
    raise exception 'invalid action';
  end if;
  if not (
    public.identity_has_permission('tasks.grade')
    or public.identity_has_permission('worklogs.approve')
    or public.identity_has_permission('people.manage')
    or public.identity_has_permission('finance.manage')
    or public.identity_has_permission('rewards.manage')
    or public.identity_has_permission('leave.approve')
  ) then raise exception 'approval permission required'; end if;
  update public.approval_requests set
    status=p_action,decision_note=p_note,updated_at=now()
  where id=p_approval;
  insert into public.approval_events(
    approval_id,actor_profile_id,action,note
  ) values(p_approval,v_uid,p_action,p_note);
  insert into public.enterprise_identity_audit(
    enterprise_id,actor_profile_id,action,details
  ) values(v_row.enterprise_id,v_uid,'approval.'||p_action,
    jsonb_build_object('approval_id',p_approval,'note',p_note,
      'idempotency_key',p_idempotency_key));
  return jsonb_build_object('ok',true,'status',p_action);
end;
$fn$;

revoke all on function public.get_decision_center() from public;
revoke all on function public.act_on_decision(uuid,text,uuid,text,text) from public;
revoke all on function public.act_on_approval(uuid,text,text,text) from public;
grant execute on function public.get_decision_center() to authenticated;
grant execute on function public.act_on_decision(uuid,text,uuid,text,text) to authenticated;
grant execute on function public.act_on_approval(uuid,text,text,text) to authenticated;
```

- [ ] **Step 4: 测试并提交**

Run: `.venv\Scripts\python.exe -m unittest tests.test_decision_sql -v`

Expected: 3 tests PASS。

```bash
git add mobile/sql/decision-approvals-v1.sql tests/test_decision_sql.py
git commit -m "feat: add decision center data model"
```

---

## Task 3: Python 客户端

**Files:** Modify `community_client.py`、Create `tests/test_decision_client.py`

**Interfaces:** `decision_center(session)`, `act_on_decision()`, `act_on_approval()`.

- [ ] **Step 1: 写失败测试**

```python
# tests/test_decision_client.py
import unittest
from unittest.mock import patch
from community_client import CommunityClient, CommunitySession

class DecisionClientTest(unittest.TestCase):
    def setUp(self):
        self.session = CommunitySession("token", expires_at=9999999999)
        self.client = CommunityClient()

    @patch("community_client._request")
    def test_decision_center_rpc(self, request):
        request.return_value = {"decisions": [], "approvals": []}
        self.client.decision_center(self.session)
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/get_decision_center",
            token="token", body={})

    @patch("community_client._request")
    def test_approval_action(self, request):
        request.return_value = {"ok": True}
        self.client.act_on_approval(self.session,"a1","approved","同意","k1")
        request.assert_called_once_with(
            "POST", "/rest/v1/rpc/act_on_approval", token="token",
            body={"p_approval":"a1","p_action":"approved",
                  "p_note":"同意","p_idempotency_key":"k1"})

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 实现客户端**

```python
    def decision_center(self, session):
        data = _request("POST", "/rest/v1/rpc/get_decision_center",
                        token=session.access_token, body={})
        return data if isinstance(data, dict) else {}

    def act_on_decision(self, session, decision_id, action, owner_id=None,
                        note="", idempotency_key=""):
        return _request("POST", "/rest/v1/rpc/act_on_decision",
            token=session.access_token,
            body={"p_decision":str(decision_id),"p_action":action,
                  "p_owner":str(owner_id) if owner_id else None,
                  "p_note":note,"p_idempotency_key":idempotency_key})

    def act_on_approval(self, session, approval_id, action, note="",
                        idempotency_key=""):
        return _request("POST", "/rest/v1/rpc/act_on_approval",
            token=session.access_token,
            body={"p_approval":str(approval_id),"p_action":action,
                  "p_note":note,"p_idempotency_key":idempotency_key})
```

- [ ] **Step 3: 测试并提交**

Run: `.venv\Scripts\python.exe -m unittest tests.test_decision_client -v`

Expected: 2 tests PASS。

```bash
git add community_client.py tests/test_decision_client.py
git commit -m "feat: expose decision center RPCs"
```

---

## Task 4: 桌面经营决策中心

**Files:** Create `decision_ui.py`、`tests/test_decision_ui.py`; Modify `main.py`

**Interfaces:** `DecisionCenterPage(QWidget)` with `apply_account_session()`, `refresh()`, `render()`.

- [ ] **Step 1: 写离屏失败测试**

```python
# tests/test_decision_ui.py
import os, unittest
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PyQt6.QtWidgets import QApplication
from decision_ui import DecisionCenterPage

class DecisionUiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def test_render_decision_and_approval(self):
        page = DecisionCenterPage(None)
        page.snapshot = {
            "decisions": [{"id":"d1","title":"项目延期","risk":"severe",
                           "impact_days":8,"impact_amount":0,"status":"open"}],
            "approvals": [{"id":"a1","title":"采购审批","amount":12000,
                           "kind":"purchase","status":"pending"}],
        }
        page.render()
        self.assertEqual(page.decision_table.rowCount(), 1)
        self.assertEqual(page.approval_table.rowCount(), 1)
```

- [ ] **Step 2: 实现决策中心**

```python
# decision_ui.py
from PyQt6.QtWidgets import (
    QAbstractItemView, QHBoxLayout, QPushButton, QTableWidget,
    QTableWidgetItem, QVBoxLayout, QWidget,
)
from community_client import CommunityClient
from community_ui import CommunityWorker
from widgets import SectionTitle, label, muted

class DecisionCenterPage(QWidget):
    def __init__(self, window):
        super().__init__()
        self.window = window
        self.session = None
        self.snapshot = {"decisions": [], "approvals": []}
        self.workers = []
        root = QVBoxLayout(self)
        root.setContentsMargins(18, 16, 18, 14)
        root.addWidget(label("经营决策中心", "KnowledgeTitle"))
        root.addWidget(muted("按交付影响、金额和等待时间处理今天必须拍板的事项。"))
        head = QHBoxLayout()
        head.addWidget(SectionTitle("决策队列"))
        head.addStretch()
        self.refresh_button = QPushButton("刷新")
        self.refresh_button.setObjectName("GhostButton")
        head.addWidget(self.refresh_button)
        root.addLayout(head)
        self.decision_table = self._table(["风险", "事项", "影响", "状态"])
        root.addWidget(self.decision_table, 1)
        root.addWidget(SectionTitle("统一审批"))
        self.approval_table = self._table(["类型", "事项", "金额", "状态"])
        root.addWidget(self.approval_table, 1)

    @staticmethod
    def _table(headers):
        table = QTableWidget(0, len(headers))
        table.setHorizontalHeaderLabels(headers)
        table.verticalHeader().setVisible(False)
        table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        table.horizontalHeader().setStretchLastSection(True)
        return table

    def apply_account_session(self, session):
        self.session = session

    def refresh(self):
        if self.session is None:
            self.snapshot = {"decisions": [], "approvals": []}
            self.render()
            return
        worker = CommunityWorker(
            lambda: CommunityClient().decision_center(self.session)
        )
        self.workers.append(worker)
        worker.done.connect(self._loaded)
        worker.failed.connect(lambda message: self.window.flash(message, 5000))
        worker.finished.connect(worker.deleteLater)
        worker.start()

    def _loaded(self, data):
        self.snapshot = data if isinstance(data, dict) else {}
        self.render()

    def render(self):
        self.decision_table.setRowCount(0)
        for item in self.snapshot.get("decisions", []):
            row = self.decision_table.rowCount()
            self.decision_table.insertRow(row)
            values = [item.get("risk", ""), item.get("title", ""),
                      f'{item.get("impact_days", 0)} 天 / {item.get("impact_amount", 0)}',
                      item.get("status", "")]
            for column, text in enumerate(values):
                self.decision_table.setItem(row, column, QTableWidgetItem(str(text)))
        self.approval_table.setRowCount(0)
        for item in self.snapshot.get("approvals", []):
            row = self.approval_table.rowCount()
            self.approval_table.insertRow(row)
            values = [item.get("kind", ""), item.get("title", ""),
                      item.get("amount", 0), item.get("status", "")]
            for column, text in enumerate(values):
                self.approval_table.setItem(row, column, QTableWidgetItem(str(text)))
```

`main.py` adds a `DecisionCenterPage` tab visible only in advanced mode. `refresh()` is called on tab activation and after account login.

- [ ] **Step 3: 测试并提交**

Run: `.venv\Scripts\python.exe -m unittest tests.test_decision_ui -v`

Expected: PASS。

Run: `.venv\Scripts\python.exe check.py`

Expected: all checks pass。

```bash
git add decision_ui.py main.py tests/test_decision_ui.py
git commit -m "feat: add desktop decision center"
```

---

## Task 5: 移动端审批收件箱

**Files:** Modify `mobile/index.html`, `mobile/app.js`, `mobile/account.js`, `mobile/decision.js`, `mobile/style.css`, `mobile/build-www.js`, `mobile/selfcheck.js`

**Interfaces:** `renderDecisionCenter()`, `loadDecisionCenter()`, approval action functions.

- [ ] **Step 1: 写失败自检**

Add to `mobile/selfcheck.js`:

```javascript
test("决策中心页面存在", () => {
  const html = fs.readFileSync(path.join(HERE, "index.html"), "utf8");
  for (const id of ("page-decisions", "decision-list", "approval-list")) {
    if (html.indexOf(`id="${id}"`) === -1) throw new Error(`缺少 ${id}`);
  }
});
```

- [ ] **Step 2: 增加页面**

```html
<section id="page-decisions" class="page hidden">
  <div class="topbar"><div class="grow"><h1>经营决策</h1>
    <div class="sub">先处理影响交付和金额最大的事项</div></div>
    <button class="icon-btn" id="btn-decisions-refresh">↻</button></div>
  <div class="body">
    <div class="section-head"><span>决策队列</span></div>
    <div id="decision-list"></div>
    <div class="section-head"><span>我的审批</span></div>
    <div id="approval-list"></div>
  </div>
</section>
```

Create `mobile/decision.js`:

```javascript
"use strict";
function renderDecisionCenter() {
  const state = DB.decisionCenter || {};
  const decisions = state.decisions || [];
  const approvals = state.approvals || [];
  $("decision-list").innerHTML = decisions.length
    ? decisions.map(item => `<div class="identity-motion">
        <b>${escapeHtml(item.title || "决策")}</b>
        <div class="identity-vote-line">影响 ${num(item.impact_days)} 天 ·
          ${num(item.impact_amount)} 元 · ${escapeHtml(item.status || "")}</div>
      </div>`).join("")
    : '<div class="identity-empty"><b>暂无待决策事项</b></div>';
  $("approval-list").innerHTML = approvals.length
    ? approvals.map(item => `<div class="identity-motion">
        <b>${escapeHtml(item.title || "审批")}</b>
        <div class="identity-vote-line">${escapeHtml(item.kind || "")} ·
          ${num(item.amount)} 元 · ${escapeHtml(item.status || "")}</div>
      </div>`).join("")
    : '<div class="identity-empty"><b>暂无待审批</b></div>';
}
async function loadDecisionCenter() {
  if (!DB.profile || !initCloud()) return;
  const { data, error } = await cloudClient.rpc("get_decision_center");
  if (error) { toast(String(error.message || error)); return; }
  DB.decisionCenter = data || {};
  saveAll(); renderDecisionCenter();
}
```

Register `"decisions"` in `PAGES`, add a management-only nav button and mode gating, load on page entry, add `decision.js` to `build-www.js`, and refresh on login/sync.

- [ ] **Step 3: 测试并提交**

Run: `node build-www.js`

Expected: success, includes `decision.js`。

Run: `node selfcheck.js`

Expected: all checks pass。

```bash
git add mobile/index.html mobile/app.js mobile/account.js mobile/decision.js mobile/style.css mobile/build-www.js mobile/selfcheck.js mobile/www
git commit -m "feat: add mobile decision inbox"
```

---

## Task 6: 文档和全量验证

**Files:** Modify `README.md`、`sync_manifest.txt`、`mobile/sql/install-unified.sql`

- [ ] **Step 1: 写文档测试**

Create `tests/test_decision_docs.py`:

```python
import unittest
from pathlib import Path

class DecisionDocsTest(unittest.TestCase):
    def test_docs_and_manifest(self):
        readme = Path("README.md").read_text(encoding="utf-8")
        manifest = Path("sync_manifest.txt").read_text(encoding="utf-8")
        self.assertIn("decision-approvals-v1.sql", readme)
        self.assertIn("经营决策中心", readme)
        self.assertIn("decision_ui.py", manifest)
        self.assertIn("mobile/decision.js", manifest)
```

- [ ] **Step 2: 更新文档**

Add to README:

```text
阶段 2A 部署顺序：
mobile/sql/enterprise-identity.sql
mobile/sql/community.sql
mobile/sql/enterprise-governance-v2.sql
mobile/sql/decision-approvals-v1.sql
```

Explain decision queue ordering, approval inbox, and advanced-mode-only access.

- [ ] **Step 3: 全量验证**

Run:

```powershell
.venv\Scripts\python.exe -m unittest discover -s tests -v
.venv\Scripts\python.exe check.py
node mobile\build-www.js
node mobile\selfcheck.js
.venv\Scripts\python.exe -c "from pathlib import Path; import pglast; pglast.parse_sql(Path('mobile/sql/decision-approvals-v1.sql').read_text(encoding='utf-8')); print('SQL parse ok')"
node mobile\node_modules\.bin\cap.cmd sync android
```

Expected: all tests pass, SQL parses, mobile build and Capacitor sync succeed.

- [ ] **Step 4: 提交**

```bash
git add README.md sync_manifest.txt mobile/sql/install-unified.sql tests/test_decision_docs.py
git commit -m "docs: document decision center rollout"
```

---

## Self-Review

| Spec area | Task |
|---|---|
| 今日决策队列 | 1、2、4、5 |
| 风险影响和证据 | 1、2、4 |
| 统一审批 | 2、3、4、5 |
| 审批幂等与审计 | 2、3 |
| 高级模式权限 | 1、4、5 |
| 移动端管理入口 | 5 |
| 文档和部署 | 6 |

No placeholder markers remain. Interfaces are consistent: `decision_center()` returns `decisions` and `approvals`; clients render the same keys. Execution must not start Stage 2B until 2A passes integration and UI smoke tests.

