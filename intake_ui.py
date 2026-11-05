"""Desktop work-intake page for Phase 4."""

from __future__ import annotations

import os
import tempfile
from datetime import date, timedelta

from PyQt6.QtCore import Qt
from PyQt6.QtGui import QPixmap
from PyQt6.QtWidgets import (
    QAbstractItemView,
    QApplication,
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QDoubleSpinBox,
    QFormLayout,
    QGroupBox,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPushButton,
    QSpinBox,
    QTableWidget,
    QTableWidgetItem,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from community_client import CommunityClient, CommunityError
from community_ui import CommunityWorker
from intake_rules import normalize_request_type
from widgets import SectionTitle, label, muted


TYPE_LABELS = {
    "customer": "客户需求",
    "sales": "销售机会",
    "improvement": "内部改进",
    "incident": "故障",
    "temporary": "临时事项",
}
STATUS_LABELS = {
    "submitted": "待分诊",
    "triage": "分诊中",
    "in_progress": "处理中",
    "resolved": "已解决",
    "closed": "已关闭",
    "merged": "已合并",
}


def _date(value):
    return str(value or "").replace("T", " ")[:16] or "—"


def _number(value):
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


class IntakePage(QWidget):
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
            "my_requests": [],
            "requests": [],
            "forms": [],
            "email_aliases": [],
            "members": [],
            "projects": [],
            "tasks": [],
            "settings": {},
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
        title_box.addWidget(label("工作入口", "KnowledgeTitle"))
        title_box.addWidget(muted(
            "快速记录、公开表单、分诊、重复合并和转入执行都在同一处完成。"
        ))
        header.addLayout(title_box, 1)
        self.refresh_button = QPushButton("刷新")
        self.refresh_button.setObjectName("GhostButton")
        self.refresh_button.clicked.connect(self.refresh)
        header.addWidget(self.refresh_button)
        root.addLayout(header)

        self.summary_label = QLabel("登录后加载工作入口。")
        self.summary_label.setWordWrap(True)
        root.addWidget(self.summary_label)
        self.status_label = QLabel("")
        self.status_label.setWordWrap(True)
        root.addWidget(self.status_label)

        self.quick_group = QGroupBox("快速记录")
        quick = QFormLayout(self.quick_group)
        self.quick_type = QComboBox()
        for key, text in TYPE_LABELS.items():
            self.quick_type.addItem(text, key)
        self.quick_title = QLineEdit()
        self.quick_title.setPlaceholderText("一句话说明要处理什么")
        self.quick_detail = QTextEdit()
        self.quick_detail.setPlaceholderText("补充背景、期望结果和截止时间")
        self.quick_detail.setMaximumHeight(90)
        quick.addRow("类型", self.quick_type)
        quick.addRow("标题", self.quick_title)
        quick.addRow("详情", self.quick_detail)
        scores = QHBoxLayout()
        self.business_score = self._score_spin("业务价值", scores)
        self.urgency_score = self._score_spin("紧急度", scores)
        self.risk_score = self._score_spin("风险", scores)
        self.dependency_score = self._score_spin("依赖影响", scores)
        self.effort_score = self._score_spin("投入成本", scores)
        quick.addRow("优先级因素", scores)
        quick_actions = QHBoxLayout()
        self.quick_submit = QPushButton("提交快速记录")
        self.quick_submit.setObjectName("PrimaryButton")
        self.quick_submit.clicked.connect(self._submit_quick)
        quick_actions.addWidget(self.quick_submit)
        quick_actions.addStretch()
        quick.addRow("", quick_actions)
        root.addWidget(self.quick_group)

        self.public_group = QGroupBox("公开入口")
        public_layout = QHBoxLayout(self.public_group)
        self.form_combo = QComboBox()
        self.form_combo.setMinimumWidth(240)
        public_layout.addWidget(self.form_combo, 1)
        self.create_form_button = QPushButton("新建公开表单")
        self.create_form_button.setObjectName("GhostButton")
        self.create_form_button.clicked.connect(self._create_form)
        public_layout.addWidget(self.create_form_button)
        self.settings_button = QPushButton("入口设置")
        self.settings_button.setObjectName("GhostButton")
        self.settings_button.clicked.connect(self._settings)
        public_layout.addWidget(self.settings_button)
        self.email_button = QPushButton("新建邮件入口")
        self.email_button.setObjectName("GhostButton")
        self.email_button.clicked.connect(self._create_email_alias)
        public_layout.addWidget(self.email_button)
        self.copy_link_button = QPushButton("复制链接")
        self.copy_link_button.setObjectName("GhostButton")
        self.copy_link_button.clicked.connect(self._copy_link)
        public_layout.addWidget(self.copy_link_button)
        self.qr_button = QPushButton("二维码")
        self.qr_button.setObjectName("GhostButton")
        self.qr_button.clicked.connect(self._show_qr)
        public_layout.addWidget(self.qr_button)
        root.addWidget(self.public_group)
        self.email_alias_label = QLabel("")
        self.email_alias_label.setWordWrap(True)
        root.addWidget(self.email_alias_label)

        self.management_group = QGroupBox("需求队列")
        board = QVBoxLayout(self.management_group)
        board.addWidget(SectionTitle("待分诊与处理中"))
        self.request_table = self._table([
            "编号", "类型", "标题", "状态", "优先级", "SLA", "负责人", "转化",
        ])
        self.request_table.itemSelectionChanged.connect(self._sync_actions)
        board.addWidget(self.request_table, 1)
        actions = QHBoxLayout()
        self.triage_button = QPushButton("分诊")
        self.convert_button = QPushButton("转项目/任务/售前")
        self.merge_button = QPushButton("合并重复")
        self.message_button = QPushButton("回复/备注")
        for button in (
            self.triage_button, self.convert_button,
            self.merge_button, self.message_button,
        ):
            button.setObjectName("GhostButton")
            button.setEnabled(False)
        self.triage_button.clicked.connect(self._triage)
        self.convert_button.clicked.connect(self._convert)
        self.merge_button.clicked.connect(self._merge)
        self.message_button.clicked.connect(self._message)
        actions.addWidget(self.triage_button)
        actions.addWidget(self.convert_button)
        actions.addWidget(self.merge_button)
        actions.addWidget(self.message_button)
        actions.addStretch()
        board.addLayout(actions)
        root.addWidget(self.management_group, 1)

        self.my_group = QGroupBox("我的需求")
        my_layout = QVBoxLayout(self.my_group)
        self.my_table = self._table(["编号", "类型", "标题", "状态", "优先级", "SLA"])
        my_layout.addWidget(self.my_table)
        root.addWidget(self.my_group, 1)

    def _score_spin(self, tooltip, layout):
        spin = QSpinBox()
        spin.setRange(0, 5)
        spin.setToolTip(tooltip)
        spin.setPrefix(tooltip[:2] + " ")
        layout.addWidget(spin)
        return spin

    def apply_account_session(self, session):
        self.session = session
        self.refresh()

    def on_activated(self):
        self.refresh()

    def refresh(self):
        if self.session is None:
            self.snapshot = self._empty_snapshot()
            self.render()
            self._set_status("登录后加载工作入口。")
            return
        if self._busy:
            return
        self._busy = True
        self.refresh_button.setEnabled(False)
        self._start_worker(self._load_data, self._loaded, self._load_failed)

    def _load_data(self):
        client = CommunityClient()
        my_data = client.my_intake_requests(self.session)
        board = {}
        try:
            board = client.intake_board(self.session)
        except CommunityError:
            board = {}
        return {"my": my_data, "board": board}

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
        data = data if isinstance(data, dict) else {}
        my = data.get("my") if isinstance(data.get("my"), dict) else {}
        board = data.get("board") if isinstance(data.get("board"), dict) else {}
        self.snapshot = {
            "my_requests": my.get("requests") or [],
            "requests": board.get("requests") or [],
            "forms": board.get("forms") or [],
            "email_aliases": board.get("email_aliases") or [],
            "members": board.get("members") or [],
            "projects": board.get("projects") or [],
            "tasks": board.get("tasks") or [],
            "settings": board.get("settings") or {},
            "access": board.get("access") or {},
        }
        self.render()
        self._set_status("工作入口已更新。")

    def _load_failed(self, message):
        self._busy = False
        self.refresh_button.setEnabled(True)
        self.snapshot = self._empty_snapshot()
        self.render()
        self._set_status(str(message), error=True)

    def render(self):
        requests = self.snapshot.get("requests") or []
        my_requests = self.snapshot.get("my_requests") or []
        management = bool(self.snapshot.get("access", {}).get("management"))
        self.management_group.setVisible(management)
        self.public_group.setVisible(management)
        self.email_alias_label.setVisible(management)
        pending = sum(1 for item in requests if item.get("status") == "submitted")
        overdue = sum(1 for item in requests if item.get("sla_overdue"))
        self.summary_label.setText(
            f"我的需求 {len(my_requests)} · 待分诊 {pending} · SLA 超时 {overdue}"
        )
        self.request_table.setRowCount(0)
        for item in requests:
            self._put_row(self.request_table, [
                item.get("request_no") or "—",
                TYPE_LABELS.get(item.get("request_type"), item.get("request_type") or "—"),
                item.get("title") or "—",
                STATUS_LABELS.get(item.get("status"), item.get("status") or "—"),
                int(_number(item.get("priority_score"))),
                _date(item.get("sla_due_at")),
                item.get("owner_name") or "—",
                item.get("converted_kind") or "—",
            ], item)
        self.my_table.setRowCount(0)
        for item in my_requests:
            self._put_row(self.my_table, [
                item.get("request_no") or "—",
                TYPE_LABELS.get(item.get("request_type"), item.get("request_type") or "—"),
                item.get("title") or "—",
                STATUS_LABELS.get(item.get("status"), item.get("status") or "—"),
                int(_number(item.get("priority_score"))),
                _date(item.get("sla_due_at")),
            ], item)
        self.form_combo.clear()
        for form in self.snapshot.get("forms") or []:
            label_text = form.get("name") or form.get("public_token") or "公开表单"
            self.form_combo.addItem(label_text, form)
        has_form = self.form_combo.count() > 0
        self.copy_link_button.setEnabled(has_form)
        self.qr_button.setEnabled(has_form)
        aliases = self.snapshot.get("email_aliases") or []
        self.email_alias_label.setText(
            "邮件入口：" + " · ".join(
                alias.get("email_address") or "" for alias in aliases
            ) if aliases else "尚未创建邮件入口。"
        )
        self._sync_actions()

    def _selected(self):
        row = self.request_table.currentRow()
        if row < 0:
            return {}
        item = self.request_table.item(row, 0)
        return item.data(Qt.ItemDataRole.UserRole) if item else {}

    def _selected_form(self):
        data = self.form_combo.currentData()
        return data if isinstance(data, dict) else {}

    def _sync_actions(self):
        selected = self._selected()
        enabled = bool(selected) and bool(
            self.snapshot.get('access', {}).get('management')
        )
        for button in (
            self.triage_button, self.convert_button,
            self.merge_button, self.message_button,
        ):
            button.setEnabled(enabled)

    def _set_status(self, text, error=False):
        self.status_label.setText(str(text or ""))
        self.status_label.setProperty("error", bool(error))
        self.status_label.style().unpolish(self.status_label)
        self.status_label.style().polish(self.status_label)

    def _action_done(self, data):
        if isinstance(data, dict) and data.get("ok") is False:
            self._set_status(data.get("error") or "操作没有权限", error=True)
            return
        self._set_status("操作成功。")
        self.refresh()

    def _action_failed(self, message):
        self._set_status(str(message), error=True)

    def _run(self, work):
        self._start_worker(work, self._action_done, self._action_failed)

    def _submit_quick(self):
        if self.session is None:
            return
        data = {
            "title": self.quick_title.text(),
            "detail": self.quick_detail.toPlainText(),
            "request_type": self.quick_type.currentData(),
            "source_type": "quick",
            "business_value": self.business_score.value(),
            "urgency": self.urgency_score.value(),
            "risk": self.risk_score.value(),
            "dependency_impact": self.dependency_score.value(),
            "effort": self.effort_score.value(),
        }
        try:
            from intake_rules import validate_submission
            validation = validate_submission(data, external=False)
            if not validation["valid"]:
                raise ValueError(validation["reason"])
        except ValueError as error:
            self._set_status(str(error), error=True)
            return
        self._run(lambda: CommunityClient().create_intake_request(
            self.session, data
        ))
        self.quick_title.clear()
        self.quick_detail.clear()

    def _settings(self):
        if self.session is None:
            return
        settings = self.snapshot.get("settings") or {}
        base_url, accepted = QInputDialog.getText(
            self, "入口设置", "公开表单站点地址",
            text=settings.get("public_form_base_url") or
            "https://example.com/project-recorder",
        )
        if not accepted:
            return
        email_domain, accepted = QInputDialog.getText(
            self, "入口设置", "收件域名",
            text=settings.get("email_domain") or
            "inbound.projectrecorder.local",
        )
        if not accepted:
            return
        self._run(lambda: CommunityClient().upsert_intake_settings(
            self.session, {
                "public_form_base_url": base_url.strip(),
                "email_domain": email_domain.strip(),
            }
        ))

    def _create_email_alias(self):
        if self.session is None:
            return
        label, accepted = QInputDialog.getText(
            self, "新建邮件入口", "入口名称", text="客户邮件"
        )
        if not accepted:
            return
        self._run(lambda: CommunityClient().create_intake_email_alias(
            self.session, label.strip()
        ))

    def _create_form(self):
        if self.session is None:
            return
        name, accepted = QInputDialog.getText(
            self, "新建公开表单", "表单名称", text="客户需求入口"
        )
        if not accepted:
            return
        self._run(lambda: CommunityClient().create_intake_form(
            self.session, {"name": name.strip() or "客户需求入口"}
        ))

    def _copy_link(self):
        form = self._selected_form()
        url = str(form.get("public_url") or "")
        if not url:
            self._set_status("还没有公开表单。", error=True)
            return
        QApplication.clipboard().setText(url)
        self._set_status("公开链接已复制。")

    def _show_qr(self):
        form = self._selected_form()
        url = str(form.get("public_url") or "")
        if not url:
            self._set_status("还没有公开表单。", error=True)
            return
        try:
            import qrcode
            image = qrcode.make(url)
            path = os.path.join(
                tempfile.gettempdir(), "project-recorder-intake-qr.png"
            )
            image.save(path)
        except Exception:
            QApplication.clipboard().setText(url)
            self._set_status("二维码组件不可用，链接已复制。", error=True)
            return
        dialog = QDialog(self)
        dialog.setWindowTitle("公开表单二维码")
        layout = QVBoxLayout(dialog)
        pixmap = QPixmap(path)
        picture = QLabel()
        picture.setPixmap(pixmap.scaledToWidth(320, Qt.TransformationMode.SmoothTransformation))
        layout.addWidget(picture)
        layout.addWidget(QLabel(url))
        layout.addWidget(QPushButton("关闭", clicked=dialog.accept))
        dialog.exec()

    def _triage(self):
        selected = self._selected()
        if not selected:
            return
        dialog = QDialog(self)
        dialog.setWindowTitle("分诊需求")
        layout = QFormLayout(dialog)
        owner = QComboBox()
        owner.addItem("未指定", "")
        for member in self.snapshot.get("members") or []:
            owner.addItem(member.get("name") or "成员", member.get("id") or "")
        request_type = QComboBox()
        for key, text in TYPE_LABELS.items():
            request_type.addItem(text, key)
        request_type.setCurrentIndex(max(request_type.findData(
            selected.get("request_type")), 0))
        status = QComboBox()
        status.addItem("分诊中", "triage")
        status.addItem("处理中", "in_progress")
        status.addItem("已解决", "resolved")
        priority = QDoubleSpinBox()
        priority.setRange(0, 100)
        priority.setValue(_number(selected.get("priority_score")))
        reason = QLineEdit()
        reason.setPlaceholderText("覆盖优先级时必须填写理由")
        layout.addRow("负责人", owner)
        layout.addRow("类型", request_type)
        layout.addRow("状态", status)
        layout.addRow("优先级覆盖", priority)
        layout.addRow("理由", reason)
        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok |
            QDialogButtonBox.StandardButton.Cancel
        )
        buttons.accepted.connect(dialog.accept)
        buttons.rejected.connect(dialog.reject)
        layout.addRow(buttons)
        if dialog.exec() != QDialog.DialogCode.Accepted:
            return
        original_priority = _number(selected.get("priority_score"))
        override = priority.value() if priority.value() != original_priority else None
        self._run(lambda: CommunityClient().triage_intake_request(
            self.session, selected.get("id"), owner.currentData() or None,
            request_type.currentData(), override,
            reason.text(), status.currentData(),
        ))

    def _convert(self):
        selected = self._selected()
        if not selected:
            return
        kind, accepted = QInputDialog.getItem(
            self, "转入执行", "转换类型", ["项目", "任务", "售前支持"], 0, False
        )
        if not accepted:
            return
        mapping = {"项目": "project", "任务": "task", "售前支持": "presales"}
        converted = mapping[kind]
        if converted == "project":
            name, accepted = QInputDialog.getText(
                self, "转为项目", "项目名称", text=selected.get("title") or ""
            )
            if not accepted:
                return
            data = {"name": name.strip(), "note": selected.get("detail") or ""}
        elif converted == "task":
            projects = self.snapshot.get("projects") or []
            members = self.snapshot.get("members") or []
            if not projects or not members:
                self._set_status("缺少项目或成员选项，先刷新。", error=True)
                return
            project_names = [p.get("name") or "项目" for p in projects]
            member_names = [m.get("name") or "成员" for m in members]
            project_name, accepted = QInputDialog.getItem(
                self, "转为任务", "项目", project_names, 0, False
            )
            if not accepted:
                return
            member_name, accepted = QInputDialog.getItem(
                self, "转为任务", "负责人", member_names, 0, False
            )
            if not accepted:
                return
            plan_date, accepted = QInputDialog.getText(
                self, "转为任务", "计划日期",
                text=(date.today() + timedelta(days=1)).isoformat(),
            )
            if not accepted:
                return
            data = {
                "title": selected.get("title") or "需求任务",
                "detail": selected.get("detail") or "",
                "project_id": projects[project_names.index(project_name)].get("id"),
                "employee_id": members[member_names.index(member_name)].get("id"),
                "plan_date": plan_date.strip(),
            }
        else:
            members = self.snapshot.get("members") or []
            if not members:
                self._set_status("缺少成员选项，先刷新。", error=True)
                return
            names = [m.get("name") or "成员" for m in members]
            owner, accepted = QInputDialog.getItem(
                self, "转为售前支持", "负责人", names, 0, False
            )
            if not accepted:
                return
            data = {"owner_id": members[names.index(owner)].get("id")}
        self._run(lambda: CommunityClient().convert_intake_request(
            self.session, selected.get("id"), converted, data
        ))

    def _merge(self):
        selected = self._selected()
        if not selected:
            return
        candidates = [
            row for row in self.snapshot.get("requests") or []
            if str(row.get("id")) != str(selected.get("id"))
            and row.get("status") != "merged"
        ]
        if not candidates:
            self._set_status("没有可合并的目标需求。", error=True)
            return
        labels = [
            f"{row.get('request_no')} · {row.get('title')}" for row in candidates
        ]
        target, accepted = QInputDialog.getItem(
            self, "合并重复", "目标需求", labels, 0, False
        )
        if not accepted:
            return
        note, accepted = QInputDialog.getText(
            self, "合并重复", "合并说明（可选）"
        )
        if not accepted:
            return
        target_row = candidates[labels.index(target)]
        self._run(lambda: CommunityClient().merge_intake_request(
            self.session, selected.get("id"), target_row.get("id"), note
        ))

    def _message(self):
        selected = self._selected()
        if not selected:
            return
        body, accepted = QInputDialog.getMultiLineText(
            self, "回复或备注", "内容"
        )
        if not accepted:
            return
        visibility, accepted = QInputDialog.getItem(
            self, "回复或备注", "可见范围", ["公开回复", "内部备注"], 0, False
        )
        if not accepted:
            return
        self._run(lambda: CommunityClient().add_intake_message(
            self.session, selected.get("id"), body, visibility == "公开回复"
        ))

    def shutdown(self):
        for worker in list(self.workers):
            try:
                worker.quit()
                worker.wait(500)
            except RuntimeError:
                pass
        self.workers.clear()
