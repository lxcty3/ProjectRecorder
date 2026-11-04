"""Desktop management view for Phase 2B operations economics."""

from __future__ import annotations

import json

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (
    QAbstractItemView,
    QDialog,
    QDialogButtonBox,
    QDoubleSpinBox,
    QFormLayout,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QPushButton,
    QSplitter,
    QTableWidget,
    QTableWidgetItem,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from community_client import CommunityClient
from community_ui import CommunityWorker
from widgets import SectionTitle, label, muted


STATUS_LABELS = {
    "draft": "草稿",
    "submitted": "待复核",
    "reviewed": "已复核",
}


def _number(value):
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def _money(value):
    return f"¥{_number(value):,.2f}"


def _hours(value):
    return f"{_number(value):.1f} 小时"


class EconomicsDialog(QDialog):
    """Small audited form for project economics."""

    FIELDS = (
        ("contract_amount", "合同额"),
        ("invoiced_amount", "已开票"),
        ("collected_amount", "已回款"),
        ("outsourced_committed", "外包承诺"),
        ("outsourced_paid", "外包已付"),
        ("labor_cost", "人力成本"),
        ("estimated_completion_cost", "预计完工成本"),
        ("other_cost", "其他直接成本"),
    )

    def __init__(self, project, parent=None):
        super().__init__(parent)
        self.setWindowTitle(f"经营数据 · {project.get('name') or '项目'}")
        self.setMinimumWidth(420)
        root = QVBoxLayout(self)
        root.setContentsMargins(22, 18, 22, 16)
        form = QFormLayout()
        self.inputs = {}
        for key, title in self.FIELDS:
            spin = QDoubleSpinBox()
            spin.setRange(0, 999999999999)
            spin.setDecimals(2)
            spin.setGroupSeparatorShown(True)
            spin.setValue(_number(project.get(key)))
            self.inputs[key] = spin
            form.addRow(title, spin)
        root.addLayout(form)
        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Cancel
            | QDialogButtonBox.StandardButton.Save
        )
        buttons.rejected.connect(self.reject)
        buttons.accepted.connect(self.accept)
        root.addWidget(buttons)

    def data(self):
        return {key: spin.value() for key, spin in self.inputs.items()}


class OperationsPage(QWidget):
    """Read aggregate operations data and perform authorized writes."""

    def __init__(self, window):
        super().__init__()
        self.window = window
        self.session = None
        self.snapshot = {
            "projects": [],
            "capacity_gaps": [],
            "performance": [],
            "worklog_summary": {},
        }
        self.workers = []
        self._busy = False

        root = QVBoxLayout(self)
        root.setContentsMargins(18, 16, 18, 14)
        root.setSpacing(9)

        header = QHBoxLayout()
        title_box = QVBoxLayout()
        title_box.setSpacing(2)
        title_box.addWidget(label("经营分析", "KnowledgeTitle"))
        title_box.addWidget(muted(
            "合同、开票、回款、成本、毛利、能力缺口和绩效证据仅对授权管理身份开放。"
        ))
        header.addLayout(title_box, 1)
        self.refresh_button = QPushButton("刷新")
        self.refresh_button.setObjectName("GhostButton")
        self.refresh_button.clicked.connect(self.refresh)
        header.addWidget(self.refresh_button)
        root.addLayout(header)

        self.worklog_label = QLabel("尚无工时经营数据。")
        self.worklog_label.setWordWrap(True)
        self.worklog_label.setObjectName("OperationsWorklogSummary")
        root.addWidget(self.worklog_label)

        splitter = QSplitter(Qt.Orientation.Vertical)
        splitter.setChildrenCollapsible(False)
        root.addWidget(splitter, 1)

        project_box = QWidget()
        project_layout = QVBoxLayout(project_box)
        project_layout.setContentsMargins(0, 0, 0, 0)
        project_layout.setSpacing(5)
        project_layout.addWidget(SectionTitle("项目经营"))
        self.project_table = self._table([
            "项目", "合同额", "已开票", "已回款", "外包承诺",
            "人力成本", "预计完工成本", "预计毛利", "毛利率", "回款缺口",
        ])
        self.project_table.itemSelectionChanged.connect(self._project_selected)
        project_layout.addWidget(self.project_table, 1)
        project_actions = QHBoxLayout()
        self.edit_economics_button = QPushButton("录入经营数据")
        self.edit_economics_button.setObjectName("GhostButton")
        self.edit_economics_button.clicked.connect(
            self._edit_selected_economics
        )
        project_actions.addWidget(self.edit_economics_button)
        project_actions.addStretch()
        project_layout.addLayout(project_actions)
        splitter.addWidget(project_box)

        capacity_box = QWidget()
        capacity_layout = QVBoxLayout(capacity_box)
        capacity_layout.setContentsMargins(0, 0, 0, 0)
        capacity_layout.setSpacing(5)
        capacity_layout.addWidget(SectionTitle("未来 2-4 周能力缺口"))
        self.capacity_table = self._table([
            "技能", "需求工时", "可用工时", "缺口工时", "周期", "状态",
        ])
        capacity_layout.addWidget(self.capacity_table, 1)
        splitter.addWidget(capacity_box)

        performance_box = QWidget()
        performance_layout = QVBoxLayout(performance_box)
        performance_layout.setContentsMargins(0, 0, 0, 0)
        performance_layout.setSpacing(5)
        performance_layout.addWidget(SectionTitle("绩效证据"))
        self.performance_table = self._table([
            "成员", "周期", "得分", "状态", "复核人说明",
        ])
        self.performance_table.itemSelectionChanged.connect(
            self._performance_selected
        )
        performance_layout.addWidget(self.performance_table, 1)
        performance_actions = QHBoxLayout()
        self.review_button = QPushButton("复核绩效证据")
        self.review_button.setObjectName("GhostButton")
        self.review_button.clicked.connect(self._review_selected_performance)
        performance_actions.addWidget(self.review_button)
        performance_actions.addStretch()
        performance_layout.addLayout(performance_actions)
        splitter.addWidget(performance_box)

        detail_box = QWidget()
        detail_layout = QVBoxLayout(detail_box)
        detail_layout.setContentsMargins(0, 0, 0, 0)
        detail_layout.setSpacing(5)
        detail_layout.addWidget(SectionTitle("证据与说明"))
        self.detail_view = QTextEdit()
        self.detail_view.setReadOnly(True)
        self.detail_view.setPlaceholderText(
            "选择项目、能力缺口或绩效记录，查看计算依据和原始证据。"
        )
        detail_layout.addWidget(self.detail_view, 1)
        self.status_label = QLabel("")
        self.status_label.setWordWrap(True)
        detail_layout.addWidget(self.status_label)
        splitter.addWidget(detail_box)
        splitter.setSizes([250, 170, 180, 260])

        self.render()

    @staticmethod
    def _table(headers):
        table = QTableWidget(0, len(headers))
        table.setHorizontalHeaderLabels(headers)
        table.verticalHeader().setVisible(False)
        table.setSelectionBehavior(
            QAbstractItemView.SelectionBehavior.SelectRows
        )
        table.setSelectionMode(
            QAbstractItemView.SelectionMode.SingleSelection
        )
        table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        table.horizontalHeader().setStretchLastSection(True)
        return table

    @staticmethod
    def _put_row(table, values, item):
        row = table.rowCount()
        table.insertRow(row)
        for column, text in enumerate(values):
            cell = QTableWidgetItem(str(text))
            if column == 0:
                cell.setData(Qt.ItemDataRole.UserRole, item)
            table.setItem(row, column, cell)

    def _permissions(self):
        session = self.session
        if session is not None:
            values = session.profile.get("enterprise_permissions")
            if isinstance(values, list):
                return values
            if session.role == "boss":
                return ["*"]
        me = {}
        if self.window is not None and hasattr(self.window, "_identity_me"):
            me = self.window._identity_me()
        values = me.get("permissions")
        return values if isinstance(values, list) else []

    def _can(self, *permissions):
        granted = self._permissions()
        return "*" in granted or any(item in granted for item in permissions)

    def _can_manage_economics(self):
        return self._can("finance.manage", "projects.manage")

    def _can_review_performance(self):
        return self._can("people.manage", "tasks.grade", "company.manage")

    def apply_account_session(self, session):
        changed = self.session is not session
        self.session = session
        if changed:
            self.refresh()

    def on_activated(self):
        self.refresh()

    def refresh(self):
        if self.session is None:
            self.snapshot = {
                "projects": [],
                "capacity_gaps": [],
                "performance": [],
                "worklog_summary": {},
            }
            self.render()
            self._set_status("登录管理账号后加载经营分析。")
            return
        if self._busy:
            return
        self._busy = True
        self.refresh_button.setEnabled(False)
        self._start_worker(
            lambda: CommunityClient().operations_dashboard(self.session),
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
        self.snapshot = data if isinstance(data, dict) else {}
        self.render()
        self._set_status(
            f"经营数据已更新：{len(self.snapshot.get('projects') or [])} 个项目，"
            f"{len(self.snapshot.get('capacity_gaps') or [])} 项能力。"
        )

    def _load_failed(self, message):
        self._busy = False
        self.refresh_button.setEnabled(True)
        self.snapshot = {
            "projects": [],
            "capacity_gaps": [],
            "performance": [],
            "worklog_summary": {},
        }
        self.render()
        self._set_status(str(message), error=True)
        self._flash(str(message), 5000)

    def render(self):
        self.project_table.setRowCount(0)
        for item in self.snapshot.get("projects") or []:
            self._put_row(self.project_table, [
                item.get("name") or "项目",
                _money(item.get("contract_amount")),
                _money(item.get("invoiced_amount")),
                _money(item.get("collected_amount")),
                _money(item.get("outsourced_committed")),
                _money(item.get("labor_cost")),
                _money(item.get("projected_completion_cost")),
                _money(item.get("projected_margin")),
                f"{_number(item.get('projected_margin_percent')):.1f}%",
                _money(item.get("collection_gap")),
            ], item)

        self.capacity_table.setRowCount(0)
        for item in self.snapshot.get("capacity_gaps") or []:
            self._put_row(self.capacity_table, [
                item.get("skill") or "未命名技能",
                _hours(item.get("required_hours")),
                _hours(item.get("available_hours")),
                _hours(item.get("gap_hours")),
                f"{item.get('period_start') or '—'} 至 {item.get('period_end') or '—'}",
                "缺口" if _number(item.get("gap_hours")) > 0 else "已覆盖",
            ], item)

        self.performance_table.setRowCount(0)
        for item in self.snapshot.get("performance") or []:
            self._put_row(self.performance_table, [
                item.get("name") or "成员",
                item.get("period") or "—",
                f"{_number(item.get('score')):.1f}",
                STATUS_LABELS.get(item.get("status"), item.get("status") or "草稿"),
                item.get("reviewer_note") or "—",
            ], item)

        summary = self.snapshot.get("worklog_summary") or {}
        self.worklog_label.setText(
            f"本期工时 {_hours(summary.get('total_hours'))} · "
            f"可计费 {_hours(summary.get('billable_hours'))} · "
            f"加班 {_hours(summary.get('overtime_hours'))} · "
            f"返工 {_hours(summary.get('rework_hours'))} · "
            f"等待 {_hours(summary.get('waiting_hours'))} · "
            f"出差 {_hours(summary.get('travel_hours'))}"
        )

        if self.project_table.rowCount():
            self.project_table.selectRow(0)
        if self.performance_table.rowCount():
            self.performance_table.selectRow(0)
        self._sync_actions()

    def _selected(self, table):
        row = table.currentRow()
        if row < 0:
            return None
        cell = table.item(row, 0)
        item = cell.data(Qt.ItemDataRole.UserRole) if cell else None
        return item if isinstance(item, dict) else None

    def _sync_actions(self):
        project = self._selected(self.project_table)
        performance = self._selected(self.performance_table)
        self.edit_economics_button.setEnabled(
            bool(project and self._can_manage_economics())
        )
        self.review_button.setEnabled(
            bool(
                performance
                and performance.get("status") != "reviewed"
                and self._can_review_performance()
            )
        )

    def _project_selected(self):
        item = self._selected(self.project_table)
        if item:
            lines = [
                f"项目：{item.get('name') or '—'}",
                f"合同额：{_money(item.get('contract_amount'))}",
                f"已开票：{_money(item.get('invoiced_amount'))}",
                f"已回款：{_money(item.get('collected_amount'))}",
                f"外包承诺：{_money(item.get('outsourced_committed'))}",
                f"人力成本：{_money(item.get('labor_cost'))}",
                f"预计完工成本：{_money(item.get('projected_completion_cost'))}",
                f"预计毛利：{_money(item.get('projected_margin'))}",
                f"预计毛利率：{_number(item.get('projected_margin_percent')):.1f}%",
                f"回款缺口：{_money(item.get('collection_gap'))}",
            ]
            self.detail_view.setPlainText("\n".join(lines))
        self._sync_actions()

    def _performance_selected(self):
        item = self._selected(self.performance_table)
        if item:
            evidence = item.get("evidence")
            try:
                evidence_text = json.dumps(
                    evidence if evidence is not None else [],
                    ensure_ascii=False,
                    indent=2,
                )
            except (TypeError, ValueError):
                evidence_text = str(evidence or "")
            evidence_lines = []
            entries = evidence if isinstance(evidence, list) else [evidence]
            for entry in entries:
                if isinstance(entry, dict):
                    kind = entry.get("type") or entry.get("source_type") or "记录"
                    identifier = entry.get("id") or entry.get("source_id") or ""
                    evidence_lines.append(f"· {kind} {identifier}".rstrip())
            lines = [
                f"成员：{item.get('name') or '—'}",
                f"周期：{item.get('period') or '—'}",
                f"得分：{_number(item.get('score')):.1f}",
                f"状态：{STATUS_LABELS.get(item.get('status'), item.get('status') or '草稿')}",
                f"准时率：{_number(item.get('on_time_rate')):.0%}",
                f"一次通过率：{_number(item.get('first_pass_rate')):.0%}",
                f"返工率：{_number(item.get('rework_rate')):.0%}",
                f"协作：{_number(item.get('collaboration_score')):.1f}/5",
                f"复杂度：{_number(item.get('complexity_score')):.1f}/5",
                f"经营贡献：{_number(item.get('business_contribution')):.1f}/5",
                "",
                "员工说明：",
                item.get("employee_statement") or "—",
                "",
                "复核说明：",
                item.get("reviewer_note") or "—",
                "",
                "原始证据：",
                *(evidence_lines or ["暂无结构化证据"]),
                "",
                evidence_text,
                "",
                "绩效分数仅依据交付、质量、返工和协作证据计算，不直接决定工资或晋升。",
            ]
            self.detail_view.setPlainText("\n".join(lines))
        self._sync_actions()

    def _edit_selected_economics(self):
        project = self._selected(self.project_table)
        if not project or not self._can_manage_economics():
            return
        dialog = EconomicsDialog(project, self)
        if dialog.exec() == QDialog.DialogCode.Accepted:
            self._execute_economics(project, dialog.data())

    def _execute_economics(self, project, data):
        if self.session is None:
            return
        project_id = project.get("project_id")
        self._start_worker(
            lambda: CommunityClient().upsert_project_economics(
                self.session, project_id, data
            ),
            self._mutation_done,
            self._action_failed,
        )

    def _review_selected_performance(self):
        item = self._selected(self.performance_table)
        if not item or not self._can_review_performance():
            return
        note, accepted = QInputDialog.getMultiLineText(
            self,
            "复核绩效证据",
            "复核说明（会写入审计）：",
        )
        if accepted and str(note or "").strip():
            self._execute_review(item, str(note).strip())

    def _execute_review(self, item, note):
        if self.session is None:
            return
        self._start_worker(
            lambda: CommunityClient().review_performance_evidence(
                self.session, item.get("id"), note
            ),
            self._mutation_done,
            self._action_failed,
        )

    def _mutation_done(self, _result):
        self._set_status("经营数据已保存并写入审计。")
        self.refresh()

    def _action_done(self, _result):
        self._set_status("操作已完成。")

    def _action_failed(self, message):
        self._busy = False
        self.refresh_button.setEnabled(True)
        self._set_status(str(message), error=True)
        self._flash(str(message), 5000)

    def _set_status(self, message, error=False):
        self.status_label.setText(str(message))
        self.status_label.setStyleSheet(
            "color: var(--severe);" if error else ""
        )

    def _flash(self, message, timeout=4000):
        if self.window is not None and hasattr(self.window, "flash"):
            self.window.flash(str(message), timeout)

    def shutdown(self):
        for worker in list(self.workers):
            if worker.isRunning():
                worker.quit()
                worker.wait(1500)

