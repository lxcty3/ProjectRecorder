"""Desktop management view for Phase 2B operations economics."""

from __future__ import annotations

import json

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (
    QAbstractItemView,
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QDoubleSpinBox,
    QFormLayout,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QLineEdit,
    QPushButton,
    QSpinBox,
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
        self.invoice_due_date = QLineEdit(
            str(project.get("invoice_due_date") or "")
        )
        self.invoice_due_date.setPlaceholderText("YYYY-MM-DD")
        self.payment_terms = QLineEdit(
            str(project.get("payment_terms") or "")
        )
        self.payment_terms.setPlaceholderText("例如 Net 30 / 验收后 30 天")
        form.addRow("开票到期日", self.invoice_due_date)
        form.addRow("付款条款", self.payment_terms)
        root.addLayout(form)
        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Cancel
            | QDialogButtonBox.StandardButton.Save
        )
        buttons.rejected.connect(self.reject)
        buttons.accepted.connect(self.accept)
        root.addWidget(buttons)

    def data(self):
        data = {key: spin.value() for key, spin in self.inputs.items()}
        data["invoice_due_date"] = self.invoice_due_date.text().strip()
        data["payment_terms"] = self.payment_terms.text().strip()
        return data


class SkillDialog(QDialog):
    """Create or update a member's skill without free-form UUID entry."""

    def __init__(self, members, existing=None, parent=None):
        super().__init__(parent)
        existing = dict(existing or {})
        self.setWindowTitle("维护技能")
        self.setMinimumWidth(420)
        root = QVBoxLayout(self)
        form = QFormLayout()
        self.member = QComboBox()
        for item in members or []:
            self.member.addItem(item.get("name") or "成员", item.get("profile_id"))
        self.skill = QLineEdit(str(existing.get("skill") or ""))
        self.level = QSpinBox()
        self.level.setRange(1, 5)
        self.level.setValue(int(_number(existing.get("level")) or 1))
        self.available = QDoubleSpinBox()
        self.available.setRange(0, 9999)
        self.available.setDecimals(2)
        self.available.setValue(_number(existing.get("available_hours")))
        self.certified = QCheckBox("已认证")
        self.certified.setChecked(bool(existing.get("certified")))
        self.certification = QLineEdit(str(existing.get("certification") or ""))
        self.valid_until = QLineEdit(str(existing.get("valid_until") or ""))
        self.valid_until.setPlaceholderText("YYYY-MM-DD，可留空")
        form.addRow("成员", self.member)
        form.addRow("技能", self.skill)
        form.addRow("等级", self.level)
        form.addRow("每周可用工时", self.available)
        form.addRow("认证", self.certified)
        form.addRow("证书", self.certification)
        form.addRow("有效期至", self.valid_until)
        root.addLayout(form)
        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Cancel
            | QDialogButtonBox.StandardButton.Save
        )
        buttons.rejected.connect(self.reject)
        buttons.accepted.connect(self._accept_if_valid)
        root.addWidget(buttons)

    def _accept_if_valid(self):
        if not self.skill.text().strip():
            self.skill.setFocus()
            return
        self.accept()

    def data(self):
        return self.member.currentData(), self.skill.text().strip(), {
            "level": self.level.value(),
            "available_hours": self.available.value(),
            "certified": self.certified.isChecked(),
            "certification": self.certification.text().strip(),
            "valid_until": self.valid_until.text().strip(),
        }


class CapacityDialog(QDialog):
    """Create or edit a dated skill demand for the 2-4 week capacity view."""

    def __init__(self, members, projects, existing=None, parent=None):
        super().__init__(parent)
        existing = dict(existing or {})
        self.setWindowTitle("能力需求")
        self.setMinimumWidth(460)
        root = QVBoxLayout(self)
        form = QFormLayout()
        self.skill = QLineEdit(str(existing.get("skill") or ""))
        self.required = QDoubleSpinBox()
        self.required.setRange(0.1, 999999)
        self.required.setDecimals(2)
        self.required.setValue(_number(existing.get("required_hours")) or 1)
        self.needed_from = QLineEdit(
            str(existing.get("needed_from") or "")
        )
        self.needed_from.setPlaceholderText("YYYY-MM-DD")
        self.needed_until = QLineEdit(
            str(existing.get("needed_until") or "")
        )
        self.needed_until.setPlaceholderText("YYYY-MM-DD")
        self.project = QComboBox()
        self.project.addItem("（不绑定项目）", "")
        for item in projects or []:
            self.project.addItem(
                item.get("name") or "项目", item.get("project_id")
            )
        self.owner = QComboBox()
        self.owner.addItem("（未指派）", "")
        for item in members or []:
            self.owner.addItem(item.get("name") or "成员", item.get("profile_id"))
        self.note = QLineEdit(str(existing.get("note") or ""))
        for combo, key in ((self.project, "project_id"), (self.owner, "owner_profile_id")):
            wanted = str(existing.get(key) or "")
            index = combo.findData(wanted)
            if index >= 0:
                combo.setCurrentIndex(index)
        form.addRow("技能", self.skill)
        form.addRow("需求工时", self.required)
        form.addRow("开始日期", self.needed_from)
        form.addRow("结束日期", self.needed_until)
        form.addRow("项目", self.project)
        form.addRow("责任人", self.owner)
        form.addRow("说明", self.note)
        root.addLayout(form)
        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Cancel
            | QDialogButtonBox.StandardButton.Save
        )
        buttons.rejected.connect(self.reject)
        buttons.accepted.connect(self._accept_if_valid)
        root.addWidget(buttons)

    def _accept_if_valid(self):
        if not self.skill.text().strip():
            self.skill.setFocus()
            return
        if not self.needed_from.text().strip() or not self.needed_until.text().strip():
            self.needed_from.setFocus()
            return
        self.accept()

    def data(self):
        return {
            "skill": self.skill.text().strip(),
            "required_hours": self.required.value(),
            "needed_from": self.needed_from.text().strip(),
            "needed_until": self.needed_until.text().strip(),
            "project_id": self.project.currentData() or None,
            "owner_profile_id": self.owner.currentData() or None,
            "note": self.note.text().strip(),
        }


class EvidenceDialog(QDialog):
    """Build structured, server-validated performance evidence."""

    def __init__(self, members, existing=None, parent=None):
        super().__init__(parent)
        existing = dict(existing or {})
        self.setWindowTitle("绩效证据")
        self.setMinimumWidth(520)
        root = QVBoxLayout(self)
        form = QFormLayout()
        self.member = QComboBox()
        for item in members or []:
            self.member.addItem(item.get("name") or "成员", item.get("profile_id"))
        wanted = str(existing.get("profile_id") or "")
        index = self.member.findData(wanted)
        if index >= 0:
            self.member.setCurrentIndex(index)
        self.period = QLineEdit(str(existing.get("period") or ""))

        def rate(value):
            spin = QDoubleSpinBox()
            spin.setRange(0, 1)
            spin.setDecimals(4)
            spin.setSingleStep(0.05)
            spin.setValue(_number(value))
            return spin

        def score(value):
            spin = QDoubleSpinBox()
            spin.setRange(0, 5)
            spin.setDecimals(2)
            spin.setSingleStep(0.1)
            spin.setValue(_number(value))
            return spin

        self.on_time = rate(existing.get("on_time_rate"))
        self.first_pass = rate(existing.get("first_pass_rate"))
        self.rework = rate(existing.get("rework_rate"))
        self.collaboration = score(existing.get("collaboration_score"))
        self.complexity = score(existing.get("complexity_score"))
        self.contribution = score(existing.get("business_contribution"))
        customer = existing.get("customer_evaluation") or {}
        self.customer_score = score(customer.get("score"))
        self.customer_comment = QLineEdit(str(customer.get("comment") or ""))
        self.customer_name = QLineEdit(str(customer.get("evaluator") or ""))
        self.evidence = QTextEdit()
        self.evidence.setPlaceholderText(
            "每行一条：task:UUID、worklog:UUID 或 approval:UUID"
        )
        entries = existing.get("evidence")
        if isinstance(entries, dict):
            entries = entries.get("items")
        if isinstance(entries, list):
            self.evidence.setPlainText("\n".join(
                f"{item.get('type') or item.get('source_type')}:"
                f"{item.get('id') or item.get('source_id') or ''}"
                for item in entries if isinstance(item, dict)
            ))
        for title, widget in (
            ("成员", self.member), ("周期", self.period),
            ("准时率", self.on_time), ("一次通过率", self.first_pass),
            ("返工率", self.rework), ("协作", self.collaboration),
            ("复杂度", self.complexity), ("经营贡献", self.contribution),
            ("客户评分", self.customer_score), ("客户", self.customer_name),
            ("客户评价", self.customer_comment), ("来源证据", self.evidence),
        ):
            form.addRow(title, widget)
        root.addLayout(form)
        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Cancel
            | QDialogButtonBox.StandardButton.Save
        )
        buttons.rejected.connect(self.reject)
        buttons.accepted.connect(self._accept_if_valid)
        root.addWidget(buttons)

    def _accept_if_valid(self):
        if not self.period.text().strip():
            self.period.setFocus()
            return
        if self.member.currentData() is None:
            return
        self.accept()

    def data(self):
        evidence = []
        for line in self.evidence.toPlainText().splitlines():
            kind, _, identifier = line.strip().partition(":")
            if kind and identifier:
                evidence.append({"type": kind.strip(), "id": identifier.strip()})
        return self.member.currentData(), self.period.text().strip(), {
            "on_time_rate": self.on_time.value(),
            "first_pass_rate": self.first_pass.value(),
            "rework_rate": self.rework.value(),
            "collaboration_score": self.collaboration.value(),
            "complexity_score": self.complexity.value(),
            "business_contribution": self.contribution.value(),
            "customer_evaluation": {
                "score": self.customer_score.value(),
                "evaluator": self.customer_name.text().strip(),
                "comment": self.customer_comment.text().strip(),
            },
            "evidence": evidence,
        }


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
            "members": [],
            "skills": [],
            "capacity_demands": [],
            "collection_alerts": [],
            "security_audit": [],
            "access": {},
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
        self.collection_label = QLabel("")
        self.collection_label.setWordWrap(True)
        self.collection_label.setObjectName("OperationsCollectionAlert")
        root.addWidget(self.collection_label)
        self.capacity_label = QLabel("")
        self.capacity_label.setWordWrap(True)
        self.capacity_label.setObjectName("OperationsCapacityAlert")
        root.addWidget(self.capacity_label)

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
            "外包已付", "其他成本", "开票到期", "付款条款",
        ])
        self.project_table.itemSelectionChanged.connect(self._project_selected)
        project_layout.addWidget(self.project_table, 1)
        project_actions = QHBoxLayout()
        self.edit_economics_button = QPushButton("录入经营数据")
        self.edit_economics_button.setObjectName("GhostButton")
        self.edit_economics_button.clicked.connect(
            self._edit_selected_economics
        )
        self.skill_button = QPushButton("维护技能")
        self.skill_button.setObjectName("GhostButton")
        self.skill_button.clicked.connect(self._edit_skills)
        self.capacity_button = QPushButton("能力需求")
        self.capacity_button.setObjectName("GhostButton")
        self.capacity_button.clicked.connect(self._edit_capacity)
        project_actions.addWidget(self.edit_economics_button)
        project_actions.addWidget(self.skill_button)
        project_actions.addWidget(self.capacity_button)
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
        self.maintenance_table = self._table([
            "类型", "来源 ID", "对象", "摘要",
        ])
        self.maintenance_table.itemSelectionChanged.connect(
            self._maintenance_selected
        )
        capacity_layout.addWidget(self.maintenance_table, 1)
        splitter.addWidget(capacity_box)

        performance_box = QWidget()
        performance_layout = QVBoxLayout(performance_box)
        performance_layout.setContentsMargins(0, 0, 0, 0)
        performance_layout.setSpacing(5)
        performance_layout.addWidget(SectionTitle("绩效证据"))
        self.performance_table = self._table([
            "成员", "周期", "得分", "状态", "复核人说明", "来源 ID",
        ])
        self.performance_table.itemSelectionChanged.connect(
            self._performance_selected
        )
        performance_layout.addWidget(self.performance_table, 1)
        performance_actions = QHBoxLayout()
        self.evidence_button = QPushButton("新建绩效证据")
        self.evidence_button.setObjectName("GhostButton")
        self.evidence_button.clicked.connect(self._add_performance_evidence)
        self.review_button = QPushButton("复核绩效证据")
        self.review_button.setObjectName("GhostButton")
        self.review_button.clicked.connect(self._review_selected_performance)
        performance_actions.addWidget(self.evidence_button)
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

    def _access_flag(self, key, fallback=False):
        access = self.snapshot.get("access") if isinstance(self.snapshot, dict) else {}
        return bool((access or {}).get(key, fallback))

    def _can_manage_economics(self):
        return self._access_flag(
            "can_manage_economics",
            self._can("finance.manage", "projects.manage"),
        )

    def _can_review_performance(self):
        return self._access_flag(
            "can_manage_performance",
            self._can("people.manage", "tasks.grade", "company.manage"),
        )

    def _can_manage_skills(self):
        return self._access_flag(
            "can_manage_skills",
            self._can("people.manage"),
        )

    def _can_manage_capacity(self):
        return self._access_flag(
            "can_manage_capacity",
            self._can("projects.manage", "people.manage", "company.manage"),
        )

    def apply_account_session(self, session):
        changed = self.session is not session
        self.session = session
        if changed:
            self.refresh()

    def on_activated(self):
        self.refresh()

    def _can_view_operations(self):
        if self.window is not None and hasattr(self.window, "_effective_ui_mode"):
            if self.window._effective_ui_mode() != "advanced":
                return False
        return self._can(
            "company.manage", "projects.view_all", "projects.manage",
            "people.view_all", "people.manage", "worklogs.approve",
            "tasks.assign", "tasks.grade", "finance.view", "finance.manage",
            "reports.view", "audit.read", "rewards.manage", "leave.approve",
        )

    def refresh(self):
        if self.session is None or not self._can_view_operations():
            self.snapshot = {
                "projects": [],
                "capacity_gaps": [],
                "performance": [],
                "worklog_summary": {},
                "members": [],
                "skills": [],
                "capacity_demands": [],
                "collection_alerts": [],
                "security_audit": [],
                "access": {},
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
        if isinstance(data, dict) and data.get("ok") is False:
            self._load_failed(data.get("error") or "经营数据权限不足")
            return
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
            "members": [],
            "skills": [],
            "capacity_demands": [],
            "collection_alerts": [],
            "security_audit": [],
            "access": {},
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
                _money(item.get("outsourced_paid")),
                _money(item.get("other_cost")),
                item.get("invoice_due_date") or "—",
                item.get("payment_terms") or "—",
            ], item)
        access = self.snapshot.get("access")
        if not isinstance(access, dict):
            access = {}
        can_finance = self._access_flag(
            "can_finance", self._can("finance.view", "finance.manage")
        )
        for column in range(1, 14):
            self.project_table.setColumnHidden(column, not can_finance)

        alerts = self.snapshot.get("collection_alerts") or []
        if alerts:
            first = alerts[0]
            self.collection_label.setText(
                f"逾期回款预警 {len(alerts)} 项：{first.get('name') or '项目'} "
                f"逾期 {int(_number(first.get('overdue_days')))} 天，"
                f"待收 {_money(first.get('overdue_amount'))}。"
            )
            self.collection_label.setStyleSheet("color: var(--severe);")
        else:
            self.collection_label.setText(
                "没有逾期回款预警。" if can_finance else "当前权限不展示财务预警。"
            )
            self.collection_label.setStyleSheet("")

        can_capacity = self._access_flag(
            "can_capacity", self._can("people.view_all", "people.manage")
        )
        capacity_message = str(access.get("capacity_permission_message") or "")
        if access.get("capacity_requires_people_scope"):
            capacity_message = (
                "能力缺口需要人员查看范围；当前权限只显示项目经营数据。"
            )
        self.capacity_label.setText(
            "" if can_capacity else
            capacity_message or
            "能力缺口需要人员查看范围；当前权限只显示项目经营数据。"
        )
        self.capacity_table.setRowCount(0)
        if can_capacity:
            for item in self.snapshot.get("capacity_gaps") or []:
                self._put_row(self.capacity_table, [
                    item.get("skill") or "未命名技能",
                    _hours(item.get("required_hours")),
                    _hours(item.get("available_hours")),
                    _hours(item.get("gap_hours")),
                    f"{item.get('period_start') or '—'} 至 "
                    f"{item.get('period_end') or '—'}",
                    "缺口" if _number(item.get("gap_hours")) > 0 else "已覆盖",
                ], item)

        self.maintenance_table.setRowCount(0)
        for item in self.snapshot.get("capacity_demands") or []:
            self._put_row(self.maintenance_table, [
                "能力需求",
                item.get("source_id") or item.get("id") or "—",
                item.get("skill") or "技能",
                f"{_hours(item.get('required_hours'))} · "
                f"{item.get('needed_from') or '—'} 至 "
                f"{item.get('needed_until') or '—'}",
            ], dict(item, __kind="capacity"))
        for item in self.snapshot.get("skills") or []:
            self._put_row(self.maintenance_table, [
                "技能档案",
                item.get("source_id") or item.get("profile_id") or "—",
                f"{item.get('name') or '成员'} · {item.get('skill') or '技能'}",
                f"等级 {int(_number(item.get('level')))} · "
                f"每周 {_hours(item.get('available_hours'))}",
            ], dict(item, __kind="skill"))

        self.performance_table.setRowCount(0)
        for item in self.snapshot.get("performance") or []:
            self._put_row(self.performance_table, [
                item.get("name") or "成员",
                item.get("period") or "—",
                f"{_number(item.get('score')):.1f}",
                STATUS_LABELS.get(item.get("status"), item.get("status") or "草稿"),
                item.get("reviewer_note") or "—",
                item.get("source_id") or item.get("id") or "—",
            ], item)

        summary = self.snapshot.get("worklog_summary") or {}
        can_worklogs = self._access_flag("can_worklogs", True)
        self.worklog_label.setText(
            "当前权限不展示工时经营汇总。" if not can_worklogs else
            f"已批准工时 {_hours(summary.get('total_hours'))} · "
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
        project_editable = bool(
            project
            and self._can_manage_economics()
            and project.get("can_edit", True)
        )
        performance_reviewable = bool(
            performance
            and performance.get("status") != "reviewed"
            and self._can_review_performance()
            and performance.get("can_review", True)
        )
        self.edit_economics_button.setEnabled(project_editable)
        self.review_button.setEnabled(performance_reviewable)
        self.skill_button.setEnabled(self._can_manage_skills())
        self.capacity_button.setEnabled(self._can_manage_capacity())
        self.evidence_button.setEnabled(self._can_review_performance())

    def _project_selected(self):
        item = self._selected(self.project_table)
        if item:
            lines = [
                f"项目：{item.get('name') or '—'}",
                f"合同额：{_money(item.get('contract_amount'))}",
                f"已开票：{_money(item.get('invoiced_amount'))}",
                f"已回款：{_money(item.get('collected_amount'))}",
                f"外包承诺：{_money(item.get('outsourced_committed'))}",
                f"外包已付：{_money(item.get('outsourced_paid'))}",
                f"人力成本：{_money(item.get('labor_cost'))}",
                f"其他成本：{_money(item.get('other_cost'))}",
                f"预计完工成本：{_money(item.get('projected_completion_cost'))}",
                f"预计毛利：{_money(item.get('projected_margin'))}",
                f"预计毛利率：{_number(item.get('projected_margin_percent')):.1f}%",
                f"回款缺口：{_money(item.get('collection_gap'))}",
                f"开票到期日：{item.get('invoice_due_date') or '—'}",
                f"付款条款：{item.get('payment_terms') or '—'}",
                f"逾期天数：{int(_number(item.get('overdue_days')))}",
                f"逾期金额：{_money(item.get('overdue_amount'))}",
            ]
            self.detail_view.setPlainText("\n".join(lines))
        self._sync_actions()

    def _maintenance_selected(self):
        item = self._selected(self.maintenance_table)
        if not item:
            return
        lines = [
            f"类型：{item.get('__kind') or '记录'}",
            f"来源 ID：{item.get('source_id') or item.get('profile_id') or '—'}",
        ]
        if item.get("__kind") == "capacity":
            lines.extend([
                f"技能：{item.get('skill') or '—'}",
                f"需求工时：{_hours(item.get('required_hours'))}",
                f"周期：{item.get('needed_from') or '—'} 至 "
                f"{item.get('needed_until') or '—'}",
                f"项目：{item.get('project_name') or '—'}",
                f"说明：{item.get('note') or '—'}",
            ])
        else:
            lines.extend([
                f"成员：{item.get('name') or '—'}",
                f"技能：{item.get('skill') or '—'}",
                f"等级：{int(_number(item.get('level')))}/5",
                f"每周可用：{_hours(item.get('available_hours'))}",
                f"证书：{item.get('certification') or '—'}",
                f"有效期至：{item.get('valid_until') or '—'}",
            ])
        self.detail_view.setPlainText("\n".join(lines))

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
            entries = evidence
            if isinstance(entries, dict) and isinstance(entries.get("items"), list):
                entries = entries["items"]
            elif isinstance(entries, dict):
                entries = [entries]
            elif not isinstance(entries, list):
                entries = []
            details = item.get("evidence_details")
            if isinstance(details, list):
                for entry in details:
                    if isinstance(entry, dict):
                        evidence_lines.append(
                            f"· {entry.get('type') or '记录'} "
                            f"{entry.get('source_id') or entry.get('id') or ''}"
                            f" · {entry.get('label') or '—'}"
                            f" · {entry.get('status') or '—'}"
                        )
            else:
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
                "客户评价：",
                json.dumps(
                    item.get("customer_evaluation") or {},
                    ensure_ascii=False,
                    indent=2,
                ),
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

    def _edit_skills(self):
        if not self._can_manage_skills() or self.session is None:
            return
        selected = self._selected(self.maintenance_table) or {}
        existing = selected if selected.get("__kind") == "skill" else None
        dialog = SkillDialog(
            self.snapshot.get("members") or [], existing=existing, parent=self
        )
        if dialog.exec() == QDialog.DialogCode.Accepted:
            profile_id, skill, data = dialog.data()
            if profile_id:
                self._execute_skill(profile_id, skill, data)

    def _edit_capacity(self):
        if not self._can_manage_capacity() or self.session is None:
            return
        selected = self._selected(self.maintenance_table) or {}
        existing = selected if selected.get("__kind") == "capacity" else None
        dialog = CapacityDialog(
            self.snapshot.get("members") or [],
            self.snapshot.get("projects") or [],
            existing=existing,
            parent=self,
        )
        if dialog.exec() == QDialog.DialogCode.Accepted:
            demand_id = (existing or {}).get("id")
            self._execute_capacity(demand_id, dialog.data())

    def _add_performance_evidence(self):
        if not self._can_review_performance() or self.session is None:
            return
        selected = self._selected(self.performance_table)
        dialog = EvidenceDialog(
            self.snapshot.get("members") or [], existing=selected, parent=self
        )
        if dialog.exec() == QDialog.DialogCode.Accepted:
            profile_id, period, data = dialog.data()
            if profile_id:
                self._execute_evidence(profile_id, period, data)

    def _execute_skill(self, profile_id, skill, data):
        if self.session is None:
            return
        self._start_worker(
            lambda: CommunityClient().upsert_profile_skill(
                self.session, profile_id, skill, data
            ),
            self._mutation_done,
            self._action_failed,
        )

    def _execute_capacity(self, demand_id, data):
        if self.session is None:
            return
        self._start_worker(
            lambda: CommunityClient().upsert_capacity_demand(
                self.session, demand_id, data
            ),
            self._mutation_done,
            self._action_failed,
        )

    def _execute_evidence(self, profile_id, period, data):
        if self.session is None:
            return
        self._start_worker(
            lambda: CommunityClient().upsert_performance_evidence(
                self.session, profile_id, period, data
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

