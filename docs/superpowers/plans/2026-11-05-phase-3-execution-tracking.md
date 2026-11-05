# 阶段三：执行追踪与验收 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** 交付可追踪的任务执行闭环：验收标准、交付证据、验收/返工、任务依赖、跨部门交接和变更控制。

**Architecture:** 在现有任务、项目、审批和决策中心上增加执行追踪层。任务完成必须经过“待验收/返工/已验收”；依赖延期自动计算下游影响；变更申请产生工期、成本、资源影响并进入统一审批/决策队列。桌面新增“执行追踪”页，手机端补齐验收和交接操作。

**Tech Stack:** Python 3.13、PyQt6、Supabase Postgres/RLS/RPC、Capacitor、Vanilla JS、unittest、pglast。

**Spec:** `docs/superpowers/specs/2026-11-03-enterprise-operating-system-design.md`

## Global Constraints

- 未满足验收标准的任务不能标记为最终完成。
- 验收人不能是提交人本人，除非具备明确的管理权限并留下审计。
- 依赖、交接和变更写入必须服务端校验。
- 变更未批准不得覆盖原计划。
- 高风险、超预算或跨部门变更进入决策队列/审批。
- SQL 纯 ASCII，SECURITY DEFINER，最小权限，RLS。
- 桌面和手机必须使用真实 RPC，不允许死按钮。
- 每个任务先失败测试，再实现并提交。

## File Structure

New: `execution_rules.py`, `tests/test_execution_rules.py`, `mobile/sql/execution-tracking-v1.sql`, `tests/test_execution_sql.py`, `tests/test_execution_client.py`, `execution_ui.py`, `tests/test_execution_ui.py`, `mobile/execution.js`.

Modify: `community_client.py`, `main.py`, `db.py`/cloud integration as needed, `mobile/index.html`, `mobile/app.js`, `mobile/account.js`, `mobile/identity.js`, `mobile/style.css`, `mobile/build-www.js`, `mobile/selfcheck.js`, `README.md`, `sync_manifest.txt`, `mobile/sql/install-unified.sql`.

---

## Task 1: 执行规则

**Files:** Create `execution_rules.py`, `tests/test_execution_rules.py`

- [ ] **Step 1: 写失败测试**

```python
import unittest
from execution_rules import acceptance_result, downstream_delay, change_requires_approval

class ExecutionRulesTest(unittest.TestCase):
    def test_acceptance_requires_evidence_and_reviewer(self):
        self.assertFalse(acceptance_result("", "u1", "u2")["valid"])
        self.assertFalse(acceptance_result("done", "u1", "u1")["valid"])
        self.assertTrue(acceptance_result("done", "u1", "u2")["valid"])
    def test_downstream_delay(self):
        self.assertEqual(downstream_delay(3, 2), 5)
    def test_change_approval(self):
        self.assertTrue(change_requires_approval(60000, 2, "严重"))
        self.assertFalse(change_requires_approval(1000, 0, "健康"))
```

- [ ] **Step 2: 实现**

```python
def acceptance_result(evidence, submitter, reviewer):
    if not str(evidence or "").strip(): return {"valid": False, "reason": "evidence required"}
    if str(submitter) == str(reviewer): return {"valid": False, "reason": "independent reviewer required"}
    return {"valid": True, "reason": ""}
def downstream_delay(upstream_days, dependency_lag=0):
    return max(int(upstream_days or 0) + int(dependency_lag or 0), 0)
def change_requires_approval(amount, days, risk):
    return amount >= 50000 or days > 3 or risk in ("严重", "风险")
```

- [ ] **Step 3: 测试并提交**

Run: `.venv\Scripts\python.exe -m unittest tests.test_execution_rules -v`

Expected: PASS。

```bash
git add execution_rules.py tests/test_execution_rules.py
git commit -m "feat: add execution tracking rules"
```

---

## Task 2: 验收、依赖、交接和变更数据库

**Files:** Create `mobile/sql/execution-tracking-v1.sql`, `tests/test_execution_sql.py`

- [ ] **Step 1: 写 SQL 契约测试**

```python
import unittest
from pathlib import Path
import pglast
class ExecutionSqlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql=Path("mobile/sql/execution-tracking-v1.sql").read_text(encoding="utf-8")
    def test_parse_ascii(self):
        pglast.parse_sql(self.sql); self.assertTrue(all(ord(c)<128 for c in self.sql))
    def test_objects(self):
        for name in ("task_acceptance","task_dependencies","task_handoffs",
                     "change_requests","review_task_acceptance","accept_task_handoff",
                     "create_change_request","decide_change_request","get_execution_board"):
            self.assertIn(name,self.sql)
```

- [ ] **Step 2: 实现表**

```sql
create table if not exists public.task_acceptance (
  task_id uuid primary key references public.tasks(id) on delete cascade,
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  criteria text not null default '',
  evidence text not null default '',
  submitter_id uuid not null references public.profiles(id),
  reviewer_id uuid references public.profiles(id),
  status text not null default 'pending'
    check(status in ('pending','accepted','rework','cancelled')),
  review_note text not null default '',
  submitted_at timestamptz,
  reviewed_at timestamptz
);
create table if not exists public.task_dependencies (
  task_id uuid not null references public.tasks(id) on delete cascade,
  depends_on_task_id uuid not null references public.tasks(id) on delete cascade,
  lag_days integer not null default 0,
  required boolean not null default true,
  primary key(task_id,depends_on_task_id),
  check(task_id<>depends_on_task_id)
);
create table if not exists public.task_handoffs (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  task_id uuid not null references public.tasks(id) on delete cascade,
  from_profile_id uuid not null references public.profiles(id),
  to_profile_id uuid not null references public.profiles(id),
  artifact text not null default '',
  note text not null default '',
  status text not null default 'pending'
    check(status in ('pending','accepted','rejected')),
  created_at timestamptz not null default now(),
  accepted_at timestamptz
);
create table if not exists public.change_requests (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,
  requester_id uuid not null references public.profiles(id),
  title text not null,
  content text not null default '',
  urgency text not null default 'normal',
  schedule_impact_days integer not null default 0,
  cost_impact numeric not null default 0,
  resource_impact text not null default '',
  status text not null default 'pending'
    check(status in ('pending','approved','rejected','returned')),
  approver_id uuid references public.profiles(id),
  decision_note text not null default '',
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
```

RPC `get_execution_board()` 返回验收、依赖影响、待处理交接和变更；`review_task_acceptance()` 只允许指定验收人或管理权限；`accept_task_handoff()` 只允许接收人；`create_change_request()` 自动将高风险变更写入 2A `decision_items`；`decide_change_request()` 仅授权管理身份。所有表启用 RLS，直接写入拒绝，成功/拒绝写审计。

- [ ] **Step 3: 测试并提交**

Run: `.venv\Scripts\python.exe -m unittest tests.test_execution_sql -v`

```bash
git add mobile/sql/execution-tracking-v1.sql tests/test_execution_sql.py
git commit -m "feat: add execution tracking schema"
```

---

## Task 3: Python 客户端

**Files:** Modify `community_client.py`, Create `tests/test_execution_client.py`

- [ ] **Step 1: 写失败测试**

```python
import unittest
from unittest.mock import patch
from community_client import CommunityClient, CommunitySession
class ExecutionClientTest(unittest.TestCase):
    def setUp(self): self.s=CommunitySession("token",expires_at=9999999999); self.c=CommunityClient()
    @patch("community_client._request")
    def test_board(self,request):
        request.return_value={"acceptance":[]}; self.c.execution_board(self.s)
        request.assert_called_once_with("POST","/rest/v1/rpc/get_execution_board",token="token",body={})
    @patch("community_client._request")
    def test_review(self,request):
        request.return_value={"ok":True}; self.c.review_task_acceptance(self.s,"t1","accepted","ok")
        self.assertEqual(request.call_args.kwargs["body"]["p_task"],"t1")
```

- [ ] **Step 2: 实现方法**

```python
    def execution_board(self, session):
        data=_request("POST","/rest/v1/rpc/get_execution_board",token=session.access_token,body={})
        return data if isinstance(data,dict) else {}
    def review_task_acceptance(self, session, task_id, decision, note=""):
        return _request("POST","/rest/v1/rpc/review_task_acceptance",token=session.access_token,
            body={"p_task":str(task_id),"p_decision":decision,"p_note":note})
    def accept_task_handoff(self, session, handoff_id, decision, note=""):
        return _request("POST","/rest/v1/rpc/accept_task_handoff",token=session.access_token,
            body={"p_handoff":str(handoff_id),"p_decision":decision,"p_note":note})
    def create_change_request(self, session, project_id, data):
        return _request("POST","/rest/v1/rpc/create_change_request",token=session.access_token,
            body={"p_project":str(project_id),"p_data":dict(data or {})})
```

- [ ] **Step 3: 测试并提交**

```bash
git add community_client.py tests/test_execution_client.py
git commit -m "feat: expose execution tracking RPCs"
```

---

## Task 4: 桌面执行追踪页

**Files:** Create `execution_ui.py`, `tests/test_execution_ui.py`, Modify `main.py`

- [ ] **Step 1: 写失败 UI 测试**

```python
import os,unittest
os.environ.setdefault("QT_QPA_PLATFORM","offscreen")
from PyQt6.QtWidgets import QApplication
from execution_ui import ExecutionPage
class ExecutionUiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.app=QApplication.instance() or QApplication([])
    def test_render(self):
        p=ExecutionPage(None); p.snapshot={"acceptance":[{"title":"A"}],"handoffs":[{"title":"B"}],"changes":[{"title":"C"}],"dependencies":[{"title":"D"}]}; p.render()
        self.assertEqual(p.acceptance_table.rowCount(),1); self.assertEqual(p.handoff_table.rowCount(),1)
```

- [ ] **Step 2: 实现页面**

页面包含：
- 待验收表：选择任务，批准/退回返工；
- 交接表：选择交接，确认/拒绝；
- 变更表：显示工期、成本、资源影响，发起审批；
- 依赖表：显示阻塞和下游影响。

使用 `CommunityWorker` 异步加载，所有按钮调用 Task 3 RPC。`main.py` 中新增高级模式专用“执行追踪”页签。

- [ ] **Step 3: 测试并提交**

```bash
git add execution_ui.py main.py tests/test_execution_ui.py
git commit -m "feat: add desktop execution tracking"
```

---

## Task 5: 手机端验收和交接

**Files:** Create `mobile/execution.js`; Modify `mobile/index.html`, `mobile/app.js`, `mobile/account.js`, `mobile/identity.js`, `mobile/style.css`, `mobile/build-www.js`, `mobile/selfcheck.js`

- [ ] **Step 1: 写失败自检**

```javascript
test("执行追踪页面存在",()=>{const h=fs.readFileSync(path.join(HERE,"index.html"),"utf8");for(const id of ("page-execution","execution-acceptance","execution-handoffs")){if(h.indexOf(`id="${id}"`)===-1)throw new Error(`缺少 ${id}`);}});
```

- [ ] **Step 2: 实现**

页面：
```html
<section id="page-execution" class="page hidden">
 <div class="topbar"><div class="grow"><h1>执行追踪</h1><div class="sub">验收、交接和变更</div></div>
 <button class="icon-btn" id="btn-execution-refresh">↻</button></div>
 <div class="body"><div id="execution-acceptance"></div><div id="execution-handoffs"></div><div id="execution-changes"></div></div>
</section>
```

`execution.js` 加载 `get_execution_board`，渲染待验收、交接和变更；按钮调用 `review_task_acceptance` / `accept_task_handoff` / `decide_change_request`，刷新缓存并显示结果。注册页面、权限导航、构建清单和 selfcheck。

- [ ] **Step 3: 测试并提交**

```bash
git add mobile/execution.js mobile/index.html mobile/app.js mobile/account.js mobile/identity.js mobile/style.css mobile/build-www.js mobile/selfcheck.js mobile/www
git commit -m "feat: add mobile execution tracking"
```

---

## Task 6: 文档、安装脚本和全量验证

**Files:** Modify `README.md`, `sync_manifest.txt`, `mobile/sql/install-unified.sql`; Create `tests/test_execution_docs.py`

- [ ] **Step 1: 文档测试**

```python
import unittest
from pathlib import Path
class ExecutionDocsTest(unittest.TestCase):
    def test_docs(self):
        r=Path("README.md").read_text(encoding="utf-8");m=Path("sync_manifest.txt").read_text(encoding="utf-8")
        self.assertIn("execution-tracking-v1.sql",r);self.assertIn("执行追踪",r);self.assertIn("execution_ui.py",m)
```

- [ ] **Step 2: 文档和部署顺序**

README 部署顺序追加：

```text
mobile/sql/execution-tracking-v1.sql
```

位于 operations 之后，说明验收/返工、依赖、交接、变更和决策中心联动。

- [ ] **Step 3: 全量验证**

```powershell
.venv\Scripts\python.exe -m unittest discover -s tests -v
.venv\Scripts\python.exe check.py
node mobile\build-www.js
node mobile\selfcheck.js
.venv\Scripts\python.exe -c "from pathlib import Path; import pglast; pglast.parse_sql(Path('mobile/sql/execution-tracking-v1.sql').read_text(encoding='utf-8')); print('SQL parse ok')"
node mobile\node_modules\.bin\cap.cmd sync android
```

- [ ] **Step 4: 提交**

```bash
git add README.md sync_manifest.txt mobile/sql/install-unified.sql tests/test_execution_docs.py
git commit -m "docs: document execution tracking rollout"
```

---

## Self-Review

覆盖：验收证据、独立验收、返工、依赖延期、交接确认、变更影响、审批和决策联动、桌面/手机 UI、权限与审计、文档与部署。

