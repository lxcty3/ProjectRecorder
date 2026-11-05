# 阶段二 B：经营、工时、能力与绩效 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox syntax.

**Goal:** 在 2A 决策中心基础上补齐项目经营结果、工时经营维度、人员技能与 2～4 周能力缺口、可追溯绩效证据。

**Architecture:** 新增 `operations-economics-v1.sql`，扩展项目经营字段、工时分类、技能与绩效证据表；所有聚合通过 RPC 返回，桌面端新增“经营分析”页，移动端在管理视图展示经营摘要。

**Tech Stack:** Python 3.13、PyQt6、Supabase、Capacitor、Vanilla JS、unittest、pglast。

**Spec:** `docs/superpowers/specs/2026-11-03-enterprise-operating-system-design.md`

## Global Constraints

- 经营和人员数据只对授权管理身份开放。
- 合同额、回款、成本、毛利和绩效不得进入简单模式或知识星球。
- 所有经营写入使用 SECURITY DEFINER，SQL 纯 ASCII。
- 工时新增字段必须有默认值，兼容历史数据。
- 每个任务先写失败测试，再实现并提交。
- 执行目录为同步 Git 仓库，完成后同步 D 盘。

## File Structure

New: `operations_rules.py`, `tests/test_operations_rules.py`, `mobile/sql/operations-economics-v1.sql`, `tests/test_operations_sql.py`, `tests/test_operations_client.py`, `operations_ui.py`, `tests/test_operations_ui.py`, `mobile/operations.js`.

Modify: `community_client.py`, `main.py`, `mobile/index.html`, `mobile/app.js`, `mobile/account.js`, `mobile/identity.js`, `mobile/style.css`, `mobile/build-www.js`, `mobile/selfcheck.js`, `README.md`, `sync_manifest.txt`.

---

## Task 1: 经营、能力和绩效规则

**Files:** Create `operations_rules.py`, `tests/test_operations_rules.py`

- [ ] **Step 1: 写失败测试**

```python
import unittest
from operations_rules import project_margin, capacity_gap, performance_score

class OperationsRulesTest(unittest.TestCase):
    def test_margin(self):
        result = project_margin(100000, 20000, 45000, 10000)
        self.assertEqual(result["projected_margin"], 25000)
        self.assertEqual(result["projected_margin_percent"], 25.0)

    def test_capacity_gap(self):
        self.assertEqual(capacity_gap([40, 32, 24], [30, 35, 30]), 5)

    def test_performance_score_is_evidence_based(self):
        score = performance_score(on_time=0.9, first_pass=0.8, rework=0.1, collaboration=4.5)
        self.assertGreater(score, 70)
        self.assertLessEqual(score, 100)
```

- [ ] **Step 2: 运行确认失败**

Run: `.venv\Scripts\python.exe -m unittest tests.test_operations_rules -v`

Expected: FAIL，模块不存在。

- [ ] **Step 3: 实现**

```python
def project_margin(contract, invoiced, cost, committed):
    projected_cost = max(float(cost or 0), 0) + max(float(committed or 0), 0)
    margin = float(contract or 0) - projected_cost
    percent = round(margin / float(contract) * 100, 2) if contract else 0.0
    return {"projected_cost": projected_cost, "projected_margin": margin,
            "projected_margin_percent": percent,
            "collection_gap": max(float(contract or 0) - float(invoiced or 0), 0)}

def capacity_gap(required, available):
    return max(sum(required) - sum(available), 0)

def performance_score(on_time, first_pass, rework, collaboration):
    raw = (on_time * 35 + first_pass * 30 + (1 - rework) * 20 + collaboration / 5 * 15)
    return max(0, min(100, round(raw, 1)))
```

- [ ] **Step 4: 测试并提交**

Run: `.venv\Scripts\python.exe -m unittest tests.test_operations_rules -v`

Expected: 3 tests PASS。

```bash
git add operations_rules.py tests/test_operations_rules.py
git commit -m "feat: add operations and performance rules"
```

---

## Task 2: 经营、技能、绩效数据库

**Files:** Create `mobile/sql/operations-economics-v1.sql`, `tests/test_operations_sql.py`

- [ ] **Step 1: 写失败测试**

```python
import unittest
from pathlib import Path
import pglast

class OperationsSqlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sql = Path("mobile/sql/operations-economics-v1.sql").read_text(encoding="utf-8")
    def test_parse_ascii(self):
        pglast.parse_sql(self.sql)
        self.assertTrue(all(ord(c) < 128 for c in self.sql))
    def test_required_tables(self):
        for name in ("project_economics", "profile_skills", "performance_evidence",
                     "worklog_dimensions", "get_operations_dashboard",
                     "upsert_project_economics"):
            self.assertIn(name, self.sql)
```

- [ ] **Step 2: 运行确认失败**

Run: `.venv\Scripts\python.exe -m unittest tests.test_operations_sql -v`

Expected: FAIL。

- [ ] **Step 3: 实现表**

```sql
create table if not exists public.project_economics (
  project_id uuid primary key references public.projects(id) on delete cascade,
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  contract_amount numeric not null default 0,
  invoiced_amount numeric not null default 0,
  collected_amount numeric not null default 0,
  outsourced_committed numeric not null default 0,
  labor_cost numeric not null default 0,
  estimated_completion_cost numeric not null default 0,
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

create table if not exists public.profile_skills (
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  skill text not null,
  level integer not null default 1 check (level between 1 and 5),
  certified boolean not null default false,
  available_hours numeric not null default 0,
  valid_until date,
  primary key (enterprise_id, profile_id, skill)
);

create table if not exists public.worklog_dimensions (
  worklog_id uuid primary key references public.worklogs(id) on delete cascade,
  billable boolean not null default true,
  overtime boolean not null default false,
  work_kind text not null default 'project',
  rework boolean not null default false,
  waiting boolean not null default false,
  travel boolean not null default false
);

create table if not exists public.performance_evidence (
  id uuid primary key default gen_random_uuid(),
  enterprise_id uuid not null references public.enterprises(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  period text not null,
  on_time_rate numeric not null default 0,
  first_pass_rate numeric not null default 0,
  rework_rate numeric not null default 0,
  collaboration_score numeric not null default 0,
  complexity_score numeric not null default 0,
  business_contribution numeric not null default 0,
  evidence jsonb not null default '{}'::jsonb,
  status text not null default 'draft',
  reviewed_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (enterprise_id, profile_id, period)
);
```

RPC `get_operations_dashboard()` 返回当前企业的项目经营、能力缺口和绩效摘要；`upsert_project_economics()` 仅允许 `finance.manage` 或 `projects.manage`。所有表启用 RLS，直接表访问拒绝，RPC 仅授权 authenticated。

- [ ] **Step 4: 测试并提交**

Run: `.venv\Scripts\python.exe -m unittest tests.test_operations_sql -v`

Expected: PASS。

```bash
git add mobile/sql/operations-economics-v1.sql tests/test_operations_sql.py
git commit -m "feat: add operations economics schema"
```

---

## Task 3: Python 客户端

**Files:** Modify `community_client.py`, Create `tests/test_operations_client.py`

- [ ] **Step 1: 写失败测试**

```python
import unittest
from unittest.mock import patch
from community_client import CommunityClient, CommunitySession

class OperationsClientTest(unittest.TestCase):
    def setUp(self):
        self.session=CommunitySession("token",expires_at=9999999999); self.client=CommunityClient()
    @patch("community_client._request")
    def test_dashboard(self, request):
        request.return_value={"projects":[]}
        self.client.operations_dashboard(self.session)
        request.assert_called_once_with("POST","/rest/v1/rpc/get_operations_dashboard",token="token",body={})
    @patch("community_client._request")
    def test_upsert_economics(self, request):
        request.return_value={"ok":True}
        self.client.upsert_project_economics(self.session,"p1",{"contract_amount":100})
        self.assertEqual(request.call_args.kwargs["body"]["p_project"],"p1")
```

- [ ] **Step 2: 实现客户端**

```python
    def operations_dashboard(self, session):
        data = _request("POST", "/rest/v1/rpc/get_operations_dashboard",
                        token=session.access_token, body={})
        return data if isinstance(data, dict) else {}

    def upsert_project_economics(self, session, project_id, data):
        return _request("POST", "/rest/v1/rpc/upsert_project_economics",
            token=session.access_token,
            body={"p_project": str(project_id), "p_data": dict(data or {})})
```

- [ ] **Step 3: 测试并提交**

Run: `.venv\Scripts\python.exe -m unittest tests.test_operations_client -v`

Expected: PASS。

```bash
git add community_client.py tests/test_operations_client.py
git commit -m "feat: expose operations dashboard RPCs"
```

---

## Task 4: 桌面经营分析页

**Files:** Create `operations_ui.py`, `tests/test_operations_ui.py`, Modify `main.py`

- [ ] **Step 1: 写失败 UI 测试**

```python
import os,unittest
os.environ.setdefault("QT_QPA_PLATFORM","offscreen")
from PyQt6.QtWidgets import QApplication
from operations_ui import OperationsPage

class OperationsUiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.app=QApplication.instance() or QApplication([])
    def test_render(self):
        page=OperationsPage(None)
        page.snapshot={"projects":[{"name":"A","contract_amount":100000,"projected_margin":25000,"projected_margin_percent":25}],"capacity_gaps":[{"skill":"Python","gap_hours":8}],"performance":[{"name":"张三","score":88}]}
        page.render()
        self.assertEqual(page.project_table.rowCount(),1)
        self.assertEqual(page.capacity_table.rowCount(),1)
        self.assertEqual(page.performance_table.rowCount(),1)
```

- [ ] **Step 2: 实现页面**

```python
from PyQt6.QtWidgets import QAbstractItemView,QHBoxLayout,QTableWidget,QTableWidgetItem,QVBoxLayout,QWidget
from widgets import SectionTitle,label,muted

class OperationsPage(QWidget):
    def __init__(self,window):
        super().__init__(); self.window=window; self.snapshot={"projects":[],"capacity_gaps":[],"performance":[]}
        root=QVBoxLayout(self); root.setContentsMargins(18,16,18,14)
        root.addWidget(label("经营分析","KnowledgeTitle"))
        root.addWidget(muted("合同、回款、毛利、能力缺口和绩效证据。"))
        root.addWidget(SectionTitle("项目经营"))
        self.project_table=self._table(["项目","合同额","回款缺口","预计毛利","毛利率"])
        root.addWidget(self.project_table,1)
        root.addWidget(SectionTitle("未来 2-4 周能力缺口"))
        self.capacity_table=self._table(["技能","缺口工时","建议"])
        root.addWidget(self.capacity_table,1)
        root.addWidget(SectionTitle("绩效证据"))
        self.performance_table=self._table(["成员","得分","状态"])
        root.addWidget(self.performance_table,1)
    @staticmethod
    def _table(headers):
        t=QTableWidget(0,len(headers)); t.setHorizontalHeaderLabels(headers); t.verticalHeader().setVisible(False); t.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows); t.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers); t.horizontalHeader().setStretchLastSection(True); return t
    def render(self):
        self.project_table.setRowCount(0)
        for item in self.snapshot.get("projects",[]):
            r=self.project_table.rowCount(); self.project_table.insertRow(r)
            vals=[item.get("name",""),item.get("contract_amount",0),item.get("collection_gap",0),item.get("projected_margin",0),item.get("projected_margin_percent",0)]
            [self.project_table.setItem(r,c,QTableWidgetItem(str(v))) for c,v in enumerate(vals)]
        self.capacity_table.setRowCount(0)
        for item in self.snapshot.get("capacity_gaps",[]):
            r=self.capacity_table.rowCount(); self.capacity_table.insertRow(r)
            for c,v in enumerate([item.get("skill",""),item.get("gap_hours",0),"招聘/调岗/延期"]): self.capacity_table.setItem(r,c,QTableWidgetItem(str(v)))
        self.performance_table.setRowCount(0)
        for item in self.snapshot.get("performance",[]):
            r=self.performance_table.rowCount(); self.performance_table.insertRow(r)
            for c,v in enumerate([item.get("name",""),item.get("score",0),item.get("status","draft")]): self.performance_table.setItem(r,c,QTableWidgetItem(str(v)))
```

`main.py` adds an advanced-mode-only “经营分析” page and refreshes it on activation.

- [ ] **Step 3: 测试并提交**

Run: `.venv\Scripts\python.exe -m unittest tests.test_operations_ui -v`

Run: `.venv\Scripts\python.exe check.py`

Expected: PASS。

```bash
git add operations_ui.py main.py tests/test_operations_ui.py
git commit -m "feat: add desktop operations dashboard"
```

---

## Task 5: 移动经营摘要与工时标签

**Files:** Modify `mobile/index.html`, `mobile/app.js`, `mobile/account.js`, `mobile/identity.js`, `mobile/style.css`, `mobile/build-www.js`, `mobile/selfcheck.js`, Create `mobile/operations.js`

- [ ] **Step 1: 写失败自检**

```javascript
test("经营摘要存在", () => {
  const html=fs.readFileSync(path.join(HERE,"index.html"),"utf8");
  for (const id of ("page-operations","operations-projects","operations-capacity")) {
    if (html.indexOf(`id="${id}"`)===-1) throw new Error(`缺少 ${id}`);
  }
});
```

- [ ] **Step 2: 增加页面和摘要**

```html
<section id="page-operations" class="page hidden">
 <div class="topbar"><div class="grow"><h1>经营摘要</h1>
  <div class="sub">合同、回款、毛利与能力缺口</div></div>
  <button class="icon-btn" id="btn-operations-refresh">↻</button></div>
 <div class="body"><div id="operations-projects"></div>
  <div class="section-head"><span>能力缺口</span></div><div id="operations-capacity"></div></div>
</section>
```

```javascript
"use strict";
function renderOperations(){
 const s=DB.operations||{};
 $("operations-projects").innerHTML=(s.projects||[]).map(p=>`<div class="identity-motion"><b>${escapeHtml(p.name)}</b><div class="identity-vote-line">毛利 ${num(p.projected_margin)} · ${num(p.projected_margin_percent)}%</div></div>`).join("")||'<div class="identity-empty"><b>暂无经营数据</b></div>';
 $("operations-capacity").innerHTML=(s.capacity_gaps||[]).map(c=>`<div class="identity-motion"><b>${escapeHtml(c.skill)}</b><div class="identity-vote-line">缺口 ${num(c.gap_hours)} 小时</div></div>`).join("")||'<div class="identity-empty"><b>暂无能力缺口</b></div>';
}
async function loadOperations(){ if(!DB.profile||!initCloud())return; const {data,error}=await cloudClient.rpc("get_operations_dashboard"); if(error){toast(String(error.message||error));return;} DB.operations=data||{}; saveAll(); renderOperations(); }
```

Register page in `PAGES`, add management-only nav, load on entry, add `operations.js` to build manifest. Add timesheet checkbox fields to worklog editor and send to `worklog_dimensions` RPC.

- [ ] **Step 3: 测试并提交**

Run: `node build-www.js`

Run: `node selfcheck.js`

Expected: PASS。

```bash
git add mobile/index.html mobile/app.js mobile/account.js mobile/identity.js mobile/style.css mobile/build-www.js mobile/selfcheck.js mobile/operations.js mobile/www
git commit -m "feat: add mobile operations summary"
```

---

## Task 6: 文档和全量验证

**Files:** Modify `README.md`, `sync_manifest.txt`, `mobile/sql/install-unified.sql`, Create `tests/test_operations_docs.py`

- [ ] **Step 1: 文档测试**

```python
import unittest
from pathlib import Path
class OperationsDocsTest(unittest.TestCase):
    def test_docs(self):
        readme=Path("README.md").read_text(encoding="utf-8"); manifest=Path("sync_manifest.txt").read_text(encoding="utf-8")
        self.assertIn("operations-economics-v1.sql",readme); self.assertIn("经营分析",readme); self.assertIn("operations_ui.py",manifest)
```

- [ ] **Step 2: 更新文档与部署顺序**

README 增加：

```text
mobile/sql/operations-economics-v1.sql
```

放在 `decision-approvals-v1.sql` 之后执行。说明经营分析、工时标签、技能缺口、绩效证据只对管理权限开放。

- [ ] **Step 3: 全量验证**

```powershell
.venv\Scripts\python.exe -m unittest discover -s tests -v
.venv\Scripts\python.exe check.py
node mobile\build-www.js
node mobile\selfcheck.js
.venv\Scripts\python.exe -c "from pathlib import Path; import pglast; pglast.parse_sql(Path('mobile/sql/operations-economics-v1.sql').read_text(encoding='utf-8')); print('SQL parse ok')"
node mobile\node_modules\.bin\cap.cmd sync android
```

Expected: all pass。

- [ ] **Step 4: 提交**

```bash
git add README.md sync_manifest.txt mobile/sql/install-unified.sql tests/test_operations_docs.py
git commit -m "docs: document operations rollout"
```

---

## Self-Review

| Spec area | Task |
|---|---|
| 合同、开票、回款、成本、毛利 | 1,2,3,4,5 |
| 工时经营维度 | 2,5 |
| 技能与未来能力缺口 | 2,3,4,5 |
| 多维绩效证据 | 1,2,3,4,5 |
| 管理权限隔离 | 2,4,5 |
| 文档与部署 | 6 |

Execution must not deploy Phase 2B until 2A and 2B full test suites pass.

