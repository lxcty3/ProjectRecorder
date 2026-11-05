"""Desktop execution tracking page for Phase 3."""

from __future__ import annotations

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (
    QAbstractItemView,
    QCheckBox,
    QComboBox,
    QHBoxLayout,
    QInputDialog,
    QSpinBox,
    QLabel,
    QPushButton,
    QTabWidget,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from community_client import CommunityClient
from community_ui import CommunityWorker
from widgets import SectionTitle, label, muted


STATUS_LABELS = {
    "pending": "待验收",
    "accepted": "已验收",
    "rework": "返工",
    "cancelled": "已取消",
    "approved": "已批准",
    "rejected": "已拒绝",
    "returned": "已退回",
}


def _number(value):
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def _money(value):
    return f"¥{_number(value):,.2f}"


def _date(value):
    return str(value or "").replace("T", " ")[:16] or "—"


def _status(value):
    return STATUS_LABELS.get(str(value or ""), str(value or "—"))


class ExecutionPage(QWidget):
    def __init__(self, window):
        super().__init__()
        self.window = window
        self.session = None
        self.snapshot = self._empty_snapshot()
        self.workers = []
        self._busy = False
        self._build()

    @staticmethod
    def _empty_snapshot():
        return {
            "acceptance": [],
            "dependencies": [],
            "handoffs": [],
            "changes": [],
            "access": {},
        }

    @staticmethod
    def _table(headers):
        table = QTableWidget(0, len(headers))
        table.setHorizontalHeaderLabels(headers)
        table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        table.verticalHeader().setVisible(False)
        table.horizontalHeader().setStretchLastSection(True)
        return table

    @staticmethod
    def _put_row(table, values, item):
        row = table.rowCount()
        table.insertRow(row)
        for column, value in enumerate(values):
            cell = QTableWidgetItem(str(value))
            if column == 0:
                cell.setData(Qt.ItemDataRole.UserRole, item)
            table.setItem(row, column, cell)

    def _build(self):
        root = QVBoxLayout(self)
        root.setContentsMargins(18, 16, 18, 14)
        root.setSpacing(9)
        header = QHBoxLayout()
        title_box = QVBoxLayout()
        title_box.setSpacing(2)
        title_box.addWidget(label("执行追踪", "KnowledgeTitle"))
        title_box.addWidget(muted(
            "验收、依赖、交接和变更均由服务端校验并写入审计。"
        ))
        header.addLayout(title_box, 1)
        self.refresh_button = QPushButton("刷新")
        self.refresh_button.setObjectName("GhostButton")
        self.refresh_button.clicked.connect(self.refresh)
        header.addWidget(self.refresh_button)
        root.addLayout(header)

        self.summary_label = QLabel("登录管理账号后加载执行追踪。")
        self.summary_label.setWordWrap(True)
        root.addWidget(self.summary_label)
        self.status_label = QLabel("")
        self.status_label.setWordWrap(True)
        root.addWidget(self.status_label)

        self.tabs = QTabWidget()
        root.addWidget(self.tabs, 1)
        self._build_acceptance_tab()
        self._build_dependency_tab()
        self._build_handoff_tab()
        self._build_change_tab()

    def _build_acceptance_tab(self):
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 8, 0, 0)
        layout.addWidget(SectionTitle("待验收与返工"))
        self.acceptance_table = self._table([
            "任务", "状态", "提交人", "验收人", "验收标准", "交付证据", "提交时间",
        ])
        self.acceptance_table.itemSelectionChanged.connect(self._sync_actions)
        layout.addWidget(self.acceptance_table, 1)
        actions = QHBoxLayout()
        self.accept_button = QPushButton("验收通过")
        self.rework_button = QPushButton("退回返工")
        for button in (self.accept_button, self.rework_button):
            button.setObjectName("GhostButton")
            button.setEnabled(False)
        self.accept_button.clicked.connect(
            lambda: self._review_selected("accepted")
        )
        self.rework_button.clicked.connect(
            lambda: self._review_selected("rework")
        )
        actions.addWidget(self.accept_button)
        actions.addWidget(self.rework_button)
        actions.addStretch()
        layout.addLayout(actions)
        self.tabs.addTab(page, "验收")

    def _build_dependency_tab(self):
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 8, 0, 0)
        layout.addWidget(SectionTitle("依赖与下游影响"))
        self.dependency_table = self._table([
            "任务", "依赖上游", "间隔", "要求", "阻塞", "上游状态", "下游影响", "负责人",
        ])
        self.dependency_table.itemSelectionChanged.connect(self._sync_actions)
        layout.addWidget(self.dependency_table, 1)
        controls = QHBoxLayout()
        self.dependency_task_combo = QComboBox()
        self.dependency_upstream_combo = QComboBox()
        self.dependency_lag = QSpinBox()
        self.dependency_lag.setRange(0, 3650)
        self.dependency_required = QCheckBox("必须依赖")
        self.dependency_required.setChecked(True)
        self.dependency_add_button = QPushButton("保存依赖")
        self.dependency_add_button.setObjectName("GhostButton")
        self.dependency_remove_button = QPushButton("删除依赖")
        self.dependency_remove_button.setObjectName("GhostButton")
        self.dependency_add_button.clicked.connect(self._add_dependency)
        self.dependency_remove_button.clicked.connect(
            self._remove_selected_dependency
        )
        controls.addWidget(muted("任务"))
        controls.addWidget(self.dependency_task_combo, 2)
        controls.addWidget(muted("依赖"))
        controls.addWidget(self.dependency_upstream_combo, 2)
        controls.addWidget(self.dependency_lag)
        controls.addWidget(self.dependency_required)
        controls.addWidget(self.dependency_add_button)
        controls.addWidget(self.dependency_remove_button)
        controls.addStretch()
        layout.addLayout(controls)
        self.tabs.addTab(page, "依赖")

    def _build_handoff_tab(self):
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 8, 0, 0)
        layout.addWidget(SectionTitle("跨部门交接"))
        self.handoff_table = self._table([
            "任务", "交接物", "发起人", "接收人", "状态", "发起时间",
        ])
        self.handoff_table.itemSelectionChanged.connect(self._sync_actions)
        layout.addWidget(self.handoff_table, 1)
        actions = QHBoxLayout()
        self.handoff_accept_button = QPushButton("确认接收")
        self.handoff_reject_button = QPushButton("拒绝交接")
        for button in (self.handoff_accept_button, self.handoff_reject_button):
            button.setObjectName("GhostButton")
            button.setEnabled(False)
        self.handoff_accept_button.clicked.connect(
            lambda: self._handoff_selected("accepted")
        )
        self.handoff_reject_button.clicked.connect(
            lambda: self._handoff_selected("rejected")
        )
        actions.addWidget(self.handoff_accept_button)
        actions.addWidget(self.handoff_reject_button)
        actions.addStretch()
        layout.addLayout(actions)
        self.tabs.addTab(page, "交接")

    def _build_change_tab(self):
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 8, 0, 0)
        layout.addWidget(SectionTitle("变更控制"))
        self.change_table = self._table([
            "项目", "变更", "状态", "工期影响", "成本影响", "资源影响", "风险",
        ])
        self.change_table.itemSelectionChanged.connect(self._sync_actions)
        layout.addWidget(self.change_table, 1)
        actions = QHBoxLayout()
        self.change_approve_button = QPushButton("批准变更")
        self.change_reject_button = QPushButton("拒绝变更")
        self.change_return_button = QPushButton("退回补充")
        for button in (
            self.change_approve_button,
            self.change_reject_button,
            self.change_return_button,
        ):
            button.setObjectName("GhostButton")
            button.setEnabled(False)
        self.change_approve_button.clicked.connect(
            lambda: self._change_selected("approved")
        )
        self.change_reject_button.clicked.connect(
            lambda: self._change_selected("rejected")
        )
        self.change_return_button.clicked.connect(
            lambda: self._change_selected("returned")
        )
        actions.addWidget(self.change_approve_button)
        actions.addWidget(self.change_reject_button)
        actions.addWidget(self.change_return_button)
        actions.addStretch()
        layout.addLayout(actions)
        self.tabs.addTab(page, "变更")

    def apply_account_session(self, session):
        self.session = session
        self.refresh()

    def on_activated(self):
        self.refresh()

    def refresh(self):
        if self.session is None:
            self.snapshot = self._empty_snapshot()
            self.render()
            self._set_status("登录管理账号后加载执行追踪。")
            return
        if self._busy:
            return
        self._busy = True
        self.refresh_button.setEnabled(False)
        self._start_worker(
            lambda: CommunityClient().execution_board(self.session),
            self._loaded,
            self._load_failed,
        )

    def _start_worker(self, work, done=None, failed=None):
        worker = CommunityWorker(work, self)
        worker.done.connect(done or self._action_done)
        worker.failed.connect(failed or self._action_failed)
        worker.finished.connect(worker.deleteLater)
        worker.finished.connect(
            lambda: self.workers.remove(worker) if worker in self.workers else None
        )
        self.workers.append(worker)
        worker.start()

    def _loaded(self, data):
        self._busy = False
        self.refresh_button.setEnabled(True)
        if isinstance(data, dict) and data.get("ok") is False:
            self._load_failed(data.get("error") or "执行追踪权限不足")
            return
        self.snapshot = data if isinstance(data, dict) else self._empty_snapshot()
        self.render()
        self._set_status("执行追踪数据已更新。")

    def _load_failed(self, message):
        self._busy = False
        self.refresh_button.setEnabled(True)
        self.snapshot = self._empty_snapshot()
        self.render()
        self._set_status(str(message), error=True)

    def render(self):
        access = self.snapshot.get("access")
        access = access if isinstance(access, dict) else {}
        acceptance = self.snapshot.get("acceptance") or []
        dependencies = self.snapshot.get("dependencies") or []
        handoffs = self.snapshot.get("handoffs") or []
        changes = self.snapshot.get("changes") or []
        pending_acceptance = sum(
            1 for item in acceptance if item.get("status") == "pending"
        )
        pending_handoffs = sum(
            1 for item in handoffs if item.get("status") == "pending"
        )
        pending_changes = sum(
            1 for item in changes if item.get("status") == "pending"
        )
        blocked = sum(1 for item in dependencies if item.get("blocked"))
        self.summary_label.setText(
            f"待验收 {pending_acceptance} · 依赖阻塞 {blocked} · "
            f"待确认交接 {pending_handoffs} · 待决变更 {pending_changes}"
        )
        self._render_acceptance(acceptance, access)
        self._render_dependencies(dependencies, access)
        self._render_handoffs(handoffs, access)
        self._render_changes(changes, access)
        if self.acceptance_table.rowCount():
            self.acceptance_table.selectRow(0)
        if self.handoff_table.rowCount():
            self.handoff_table.selectRow(0)
        if self.change_table.rowCount():
            self.change_table.selectRow(0)
        self._sync_actions()

    def _render_acceptance(self, rows, access):
        self.acceptance_table.setRowCount(0)
        can_review = bool(access.get("can_review_acceptance"))
        for item in rows:
            actions = item.get("actions") if isinstance(item.get("actions"), dict) else {}
            self._put_row(self.acceptance_table, [
                item.get("title") or "任务",
                _status(item.get("status")),
                item.get("submitter_name") or "—",
                item.get("reviewer_name") or "—",
                item.get("criteria") or "—",
                item.get("evidence") or "—",
                _date(item.get("submitted_at")),
            ], item)
            if not actions and item.get("status") == "pending":
                actions = {"accept": can_review, "rework": can_review}

    def _render_dependencies(self, rows, access):
        self.dependency_table.setRowCount(0)
        for item in rows:
            affected = item.get("affected_tasks")
            affected = affected if isinstance(affected, list) else []
            impact = "；".join(
                f"{row.get('title') or row.get('task_id') or '任务'}"
                f" +{int(_number(row.get('delay_days')))} 天"
                for row in affected
            ) or "无"
            delayed = int(_number(item.get("delayed_days")))
            self._put_row(self.dependency_table, [
                item.get("title") or "任务",
                item.get("depends_on_title") or "上游任务",
                f"{int(_number(item.get('lag_days')))} 天",
                "必须" if item.get("required", True) else "可选",
                f"延迟 {delayed} 天" if item.get("blocked") else "正常",
                item.get("upstream_status") or "—",
                impact,
                item.get("employee_name") or item.get("upstream_employee_name") or "—",
            ], item)
        self._sync_dependency_choices(access)

    def _render_handoffs(self, rows, access):
        self.handoff_table.setRowCount(0)
        for item in rows:
            self._put_row(self.handoff_table, [
                item.get("title") or "任务",
                item.get("artifact") or "—",
                item.get("from_name") or "—",
                item.get("to_name") or "—",
                _status(item.get("status")),
                _date(item.get("created_at")),
            ], item)

    def _render_changes(self, rows, access):
        self.change_table.setRowCount(0)
        for item in rows:
            self._put_row(self.change_table, [
                item.get("project_name") or "项目",
                item.get("title") or "变更",
                _status(item.get("status")),
                f"{int(_number(item.get('schedule_impact_days')))} 天",
                _money(item.get("cost_impact")),
                item.get("resource_impact") or "—",
                item.get("risk") or "healthy",
            ], item)

    def _sync_dependency_choices(self, access):
        tasks = [
            item for item in (self.snapshot.get("tasks") or [])
            if isinstance(item, dict) and item.get("id")
        ]
        for combo in (self.dependency_task_combo, self.dependency_upstream_combo):
            current = combo.currentData()
            combo.blockSignals(True)
            combo.clear()
            for item in tasks:
                label = str(item.get("title") or item.get("id"))
                employee = item.get("employee_name")
                if employee:
                    label += f" · {employee}"
                combo.addItem(label, str(item.get("id")))
            if current:
                index = combo.findData(str(current))
                if index >= 0:
                    combo.setCurrentIndex(index)
            combo.blockSignals(False)
        allowed = bool(access.get("can_manage_dependencies"))
        self.dependency_task_combo.setEnabled(allowed and len(tasks) > 0)
        self.dependency_upstream_combo.setEnabled(allowed and len(tasks) > 1)
        self.dependency_lag.setEnabled(allowed)
        self.dependency_required.setEnabled(allowed)
        self.dependency_add_button.setEnabled(allowed and len(tasks) > 1)
        selected = self._selected(self.dependency_table) or {}
        actions = selected.get("actions") if isinstance(
            selected.get("actions"), dict
        ) else {}
        self.dependency_remove_button.setEnabled(
            allowed and bool(actions.get("remove"))
        )

    def _add_dependency(self):
        if self.session is None:
            return
        task_id = self.dependency_task_combo.currentData()
        upstream_id = self.dependency_upstream_combo.currentData()
        if not task_id or not upstream_id or task_id == upstream_id:
            self._set_status("请选择两个不同任务。", error=True)
            return
        self._execute_dependency(
            task_id,
            upstream_id,
            self.dependency_lag.value(),
            self.dependency_required.isChecked(),
        )

    def _remove_selected_dependency(self):
        item = self._selected(self.dependency_table)
        if not item or self.session is None:
            return
        self._execute_dependency_removal(
            item.get("task_id"), item.get("depends_on_task_id")
        )

    def _execute_dependency(self, task_id, upstream_id, lag_days, required):
        return self._start_worker(
            lambda: CommunityClient().upsert_task_dependency(
                self.session, task_id, upstream_id, lag_days, required
            ),
            self._mutation_done,
            self._action_failed,
        )

    def _execute_dependency_removal(self, task_id, upstream_id):
        return self._start_worker(
            lambda: CommunityClient().delete_task_dependency(
                self.session, task_id, upstream_id
            ),
            self._mutation_done,
            self._action_failed,
        )

    def _selected(self, table):
        row = table.currentRow()
        if row < 0:
            return None
        cell = table.item(row, 0)
        item = cell.data(Qt.ItemDataRole.UserRole) if cell else None
        return item if isinstance(item, dict) else None

    def _sync_actions(self):
        acceptance = self._selected(self.acceptance_table) or {}
        handoff = self._selected(self.handoff_table) or {}
        change = self._selected(self.change_table) or {}
        accept_actions = acceptance.get("actions") or {}
        handoff_actions = handoff.get("actions") or {}
        change_actions = change.get("actions") or {}
        self.accept_button.setEnabled(bool(accept_actions.get("accept")))
        self.rework_button.setEnabled(bool(accept_actions.get("rework")))
        self.handoff_accept_button.setEnabled(
            bool(handoff_actions.get("accept"))
        )
        self.handoff_reject_button.setEnabled(
            bool(handoff_actions.get("reject"))
        )
        self.change_approve_button.setEnabled(
            bool(change_actions.get("approve"))
        )
        self.change_reject_button.setEnabled(
            bool(change_actions.get("reject"))
        )
        self.change_return_button.setEnabled(
            bool(change_actions.get("return"))
        )
        self._sync_dependency_choices(self.snapshot.get("access") or {})

    def _note(self, title, prompt, required=False):
        note, accepted = QInputDialog.getMultiLineText(self, title, prompt)
        note = str(note or "").strip()
        if not accepted:
            return None
        if required and not note:
            self._set_status("必须填写原因或处理说明。", error=True)
            return None
        return note

    def _review_selected(self, decision):
        item = self._selected(self.acceptance_table)
        if not item or self.session is None:
            return
        note = self._note(
            "验收通过" if decision == "accepted" else "退回返工",
            "验收说明（会写入审计）：",
            required=decision == "rework",
        )
        if note is None:
            return
        self._execute_acceptance(item, decision, note)

    def _handoff_selected(self, decision):
        item = self._selected(self.handoff_table)
        if not item or self.session is None:
            return
        note = self._note(
            "确认交接" if decision == "accepted" else "拒绝交接",
            "交接确认说明：",
            required=decision == "rejected",
        )
        if note is None:
            return
        self._execute_handoff(item, decision, note)

    def _change_selected(self, decision):
        item = self._selected(self.change_table)
        if not item or self.session is None:
            return
        note = self._note(
            "变更审批",
            "审批说明（拒绝或退回时必填）：",
            required=decision in ("rejected", "returned"),
        )
        if note is None:
            return
        self._execute_change(item, decision, note)

    def _execute_acceptance(self, item, decision, note):
        task_id = item.get("task_id")
        return self._start_worker(
            lambda: CommunityClient().review_task_acceptance(
                self.session, task_id, decision, note
            ),
            self._mutation_done,
            self._action_failed,
        )

    def _execute_handoff(self, item, decision, note):
        handoff_id = item.get("id")
        return self._start_worker(
            lambda: CommunityClient().accept_task_handoff(
                self.session, handoff_id, decision, note
            ),
            self._mutation_done,
            self._action_failed,
        )

    def _execute_change(self, item, decision, note):
        change_id = item.get("id")
        return self._start_worker(
            lambda: CommunityClient().decide_change_request(
                self.session, change_id, decision, note
            ),
            self._mutation_done,
            self._action_failed,
        )

    def _action_done(self, _result):
        self._set_status("操作已完成。")

    def _mutation_done(self, _result):
        self._set_status("执行追踪已更新并写入审计。")
        self.refresh()

    def _action_failed(self, message):
        self._busy = False
        self.refresh_button.setEnabled(True)
        self._set_status(str(message), error=True)

    def _set_status(self, message, error=False):
        self.status_label.setText(str(message))
        self.status_label.setStyleSheet(
            "color: var(--severe);" if error else ""
        )

    def shutdown(self):
        for worker in list(self.workers):
            if worker.isRunning():
                worker.quit()
                worker.wait(1500)
