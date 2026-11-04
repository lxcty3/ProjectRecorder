"""Desktop role-template catalog, permission editor, and assignment UI."""
import json

from PyQt6.QtCore import QDateTime, Qt
from PyQt6.QtWidgets import (
    QAbstractItemView, QCheckBox, QComboBox, QDateTimeEdit, QDialog,
    QDialogButtonBox, QFormLayout, QHBoxLayout, QLineEdit,
    QMessageBox, QPushButton, QTableWidget, QTableWidgetItem, QTextEdit,
    QVBoxLayout, QWidget,
)

from community_client import CommunityClient, CommunityError
from widgets import SectionTitle, label, muted

__all__ = [
    "PermissionEditorDialog",
    "RoleAssignmentDialog",
    "RoleTemplatePage",
]

SCOPES = ("self", "team", "department", "project", "company")


class PermissionEditorDialog(QDialog):
    """Edit a template using resource/action/scope/conditions dimensions."""

    def __init__(self, parent=None, template=None):
        super().__init__(parent)
        self.template = dict(template or {})
        self.data = None
        self.setWindowTitle("编辑身份模板")
        self.setMinimumSize(860, 580)
        root = QVBoxLayout(self)
        root.setContentsMargins(20, 18, 20, 16)
        root.setSpacing(10)
        root.addWidget(label("四维权限编辑器", "DialogTitle"))
        root.addWidget(muted(
            "每一行定义资源、动作、范围与限制条件。高风险权限保存后会转为重大股东表决。"
        ))

        form = QFormLayout()
        self.name_edit = QLineEdit(str(self.template.get("name") or ""))
        form.addRow("身份名称", self.name_edit)
        root.addLayout(form)

        self.table = QTableWidget(0, 6)
        self.table.setHorizontalHeaderLabels(
            ["权限键", "资源", "动作", "范围", "条件 JSON", "高风险"]
        )
        self.table.verticalHeader().setVisible(False)
        self.table.setSelectionBehavior(
            QAbstractItemView.SelectionBehavior.SelectRows
        )
        self.table.setSelectionMode(
            QAbstractItemView.SelectionMode.SingleSelection
        )
        self.table.horizontalHeader().setStretchLastSection(True)
        root.addWidget(self.table, 1)

        row = QHBoxLayout()
        add_button = QPushButton("添加权限")
        add_button.setObjectName("GhostButton")
        add_button.clicked.connect(self._add_row)
        row.addWidget(add_button)
        remove_button = QPushButton("删除选中")
        remove_button.setObjectName("DangerButton")
        remove_button.clicked.connect(self._remove_row)
        row.addWidget(remove_button)
        row.addStretch()
        root.addLayout(row)

        self.reason_edit = QTextEdit()
        self.reason_edit.setMaximumHeight(76)
        self.reason_edit.setPlaceholderText("说明本次权限调整原因")
        root.addWidget(self.reason_edit)
        self.conflict_box = QCheckBox("我与该事项存在利益关系，已主动披露")
        root.addWidget(self.conflict_box)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save
            | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.button(QDialogButtonBox.StandardButton.Save).setText("保存")
        buttons.button(QDialogButtonBox.StandardButton.Cancel).setText("取消")
        buttons.accepted.connect(self._save)
        buttons.rejected.connect(self.reject)
        root.addWidget(buttons)

        for permission in self.template.get("permission_details") or []:
            self._add_row(permission)
        if not self.table.rowCount():
            for key in self.template.get("permissions") or []:
                self._add_row({"permission_key": key})

    def _add_row(self, permission=None):
        permission = dict(permission or {})
        key = str(permission.get("permission_key") or permission.get("key") or "")
        resource, _, action = key.partition(".")
        row = self.table.rowCount()
        self.table.insertRow(row)
        values = [
            key,
            permission.get("resource") or resource,
            permission.get("action") or action,
            permission.get("scope") or "self",
            json.dumps(permission.get("conditions") or {}, ensure_ascii=False),
        ]
        for column, value in enumerate(values):
            self.table.setItem(row, column, QTableWidgetItem(str(value)))
        high_risk = QTableWidgetItem()
        high_risk.setFlags(
            Qt.ItemFlag.ItemIsEnabled
            | Qt.ItemFlag.ItemIsSelectable
            | Qt.ItemFlag.ItemIsUserCheckable
        )
        high_risk.setCheckState(
            Qt.CheckState.Checked if permission.get("high_risk")
            else Qt.CheckState.Unchecked
        )
        self.table.setItem(row, 5, high_risk)

    def _remove_row(self):
        row = self.table.currentRow()
        if row >= 0:
            self.table.removeRow(row)

    def _save(self):
        name = self.name_edit.text().strip()
        if not name:
            QMessageBox.warning(self, "缺少名称", "身份名称不能为空。")
            return
        permissions = []
        for row in range(self.table.rowCount()):
            def value(column):
                item = self.table.item(row, column)
                return item.text().strip() if item else ""

            key = value(0)
            if not key:
                continue
            conditions_text = value(4) or "{}"
            try:
                conditions = json.loads(conditions_text)
            except ValueError:
                QMessageBox.warning(
                    self, "条件格式错误",
                    f"第 {row + 1} 行条件必须是 JSON 对象。",
                )
                return
            if not isinstance(conditions, dict):
                QMessageBox.warning(
                    self, "条件格式错误",
                    f"第 {row + 1} 行条件必须是 JSON 对象。",
                )
                return
            scope = value(3) or "self"
            if scope not in SCOPES:
                QMessageBox.warning(
                    self, "范围错误", f"第 {row + 1} 行范围无效。"
                )
                return
            resource = value(1) or key.partition(".")[0]
            action = value(2) or key.partition(".")[2]
            high_risk_item = self.table.item(row, 5)
            permissions.append({
                "permission_key": key,
                "resource": resource,
                "action": action,
                "scope": scope,
                "conditions": conditions,
                "high_risk": bool(
                    high_risk_item
                    and high_risk_item.checkState() == Qt.CheckState.Checked
                ),
            })
        reason = self.reason_edit.toPlainText().strip()
        if not reason:
            QMessageBox.warning(self, "缺少原因", "请填写本次调整原因。")
            return
        self.data = {
            "name": name,
            "permissions": permissions,
            "reason": reason,
            "conflict_disclosed": self.conflict_box.isChecked(),
        }
        self.accept()


class TemplateCloneDialog(QDialog):
    """Collect clone identity fields and the motion disclosure."""

    def __init__(self, parent=None, template=None):
        super().__init__(parent)
        template = dict(template or {})
        self.data = None
        self.setWindowTitle("复制身份模板")
        self.setMinimumWidth(520)
        root = QVBoxLayout(self)
        root.setContentsMargins(20, 18, 20, 16)
        root.setSpacing(10)
        root.addWidget(label("复制身份模板", "DialogTitle"))
        root.addWidget(muted(
            "高权限模板复制会提交重大股东会表决；原因和利益冲突披露会原样展示给投票人。"
        ))
        form = QFormLayout()
        self.name_edit = QLineEdit("{} 副本".format(template.get("name") or "身份"))
        self.key_edit = QLineEdit("{}_copy".format(template.get("key") or "role"))
        form.addRow("模板名称", self.name_edit)
        form.addRow("唯一 key", self.key_edit)
        root.addLayout(form)
        self.reason_edit = QTextEdit()
        self.reason_edit.setMaximumHeight(90)
        self.reason_edit.setPlaceholderText("说明为什么需要复制这个身份模板")
        root.addWidget(self.reason_edit)
        self.conflict_box = QCheckBox("如存在利益冲突，我已主动披露")
        root.addWidget(self.conflict_box)
        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save
            | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.button(QDialogButtonBox.StandardButton.Save).setText("提交")
        buttons.button(QDialogButtonBox.StandardButton.Cancel).setText("取消")
        buttons.accepted.connect(self._save)
        buttons.rejected.connect(self.reject)
        root.addWidget(buttons)

    def _save(self):
        name = self.name_edit.text().strip()
        key = self.key_edit.text().strip()
        reason = self.reason_edit.toPlainText().strip()
        if not name or not key:
            QMessageBox.warning(self, "缺少信息", "模板名称和唯一 key 都不能为空。")
            return
        if not reason:
            QMessageBox.warning(self, "缺少原因", "请填写本次模板复制的原因。")
            return
        self.data = {
            "name": name,
            "key": key,
            "reason": reason,
            "conflict_disclosed": self.conflict_box.isChecked(),
        }
        self.accept()


class RoleAssignmentDialog(QDialog):
    """Assign a secondary role for no more than seven days."""

    def __init__(self, parent=None, members=None, templates=None):
        super().__init__(parent)
        self.data = None
        self.setWindowTitle("临时角色指派")
        self.setMinimumWidth(520)
        root = QVBoxLayout(self)
        root.setContentsMargins(20, 18, 20, 16)
        root.setSpacing(10)
        root.addWidget(label("临时角色指派", "DialogTitle"))
        root.addWidget(muted(
            "临时兼任最长 7 天，必须填写原因，仅 CEO 或企业所有者可提交。"
        ))

        form = QFormLayout()
        self.member_box = QComboBox()
        for member in members or []:
            if member.get("status") != "active":
                continue
            self.member_box.addItem(
                "{} · {}".format(
                    member.get("name") or "成员",
                    member.get("role_name") or member.get("role_key") or "",
                ),
                member.get("profile_id"),
            )
        self.template_box = QComboBox()
        for template in templates or []:
            self.template_box.addItem(
                template.get("name") or template.get("key") or "身份",
                template.get("id"),
            )
        self.ends_at = QDateTimeEdit(QDateTime.currentDateTime().addDays(7))
        self.ends_at.setCalendarPopup(True)
        self.ends_at.setDisplayFormat("yyyy-MM-dd HH:mm")
        self.ends_at.setMaximumDateTime(QDateTime.currentDateTime().addDays(7))
        self.reason_edit = QTextEdit()
        self.reason_edit.setMaximumHeight(90)
        self.reason_edit.setPlaceholderText("说明为什么需要这次临时兼任")
        form.addRow("成员", self.member_box)
        form.addRow("临时身份", self.template_box)
        form.addRow("失效时间", self.ends_at)
        form.addRow("原因", self.reason_edit)
        root.addLayout(form)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save
            | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.button(QDialogButtonBox.StandardButton.Save).setText("指派")
        buttons.button(QDialogButtonBox.StandardButton.Cancel).setText("取消")
        buttons.accepted.connect(self._save)
        buttons.rejected.connect(self.reject)
        root.addWidget(buttons)

    def _save(self):
        reason = self.reason_edit.toPlainText().strip()
        if not reason:
            QMessageBox.warning(self, "缺少原因", "临时兼任必须填写原因。")
            return
        ends_at = self.ends_at.dateTime()
        if ends_at > QDateTime.currentDateTime().addDays(7):
            QMessageBox.warning(self, "期限过长", "临时兼任不能超过 7 天。")
            return
        if not self.member_box.currentData() or not self.template_box.currentData():
            QMessageBox.warning(self, "缺少数据", "请选择成员和临时身份。")
            return
        self.data = {
            "profile_id": self.member_box.currentData(),
            "template_id": self.template_box.currentData(),
            "ends_at": ends_at.toUTC().toString(Qt.DateFormat.ISODate),
            "reason": reason,
        }
        self.accept()


class RoleTemplatePage(QWidget):
    """Show reusable identity templates with edit and temporary assignment UI."""

    def __init__(self, window):
        super().__init__()
        self.window = window
        self.session = None
        self.snapshot = {"templates": [], "members": []}
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 6, 0, 0)
        root.setSpacing(8)

        head = QHBoxLayout()
        head.addWidget(SectionTitle("身份模板"))
        head.addStretch()
        self.clone_button = QPushButton("复制身份")
        self.clone_button.setObjectName("GhostButton")
        self.clone_button.setEnabled(False)
        self.clone_button.clicked.connect(self._clone_selected)
        head.addWidget(self.clone_button)
        self.edit_button = QPushButton("编辑四维权限")
        self.edit_button.setObjectName("PrimaryButton")
        self.edit_button.setEnabled(False)
        self.edit_button.clicked.connect(self._edit_selected)
        head.addWidget(self.edit_button)
        self.assign_button = QPushButton("临时指派")
        self.assign_button.setObjectName("GhostButton")
        self.assign_button.setEnabled(False)
        self.assign_button.clicked.connect(self._assign_selected)
        head.addWidget(self.assign_button)
        root.addLayout(head)

        self.table = QTableWidget(0, 5)
        self.table.setHorizontalHeaderLabels(
            ["身份", "名称", "版本", "权限数", "高风险"]
        )
        self.table.verticalHeader().setVisible(False)
        self.table.setSelectionBehavior(
            QAbstractItemView.SelectionBehavior.SelectRows
        )
        self.table.setSelectionMode(
            QAbstractItemView.SelectionMode.SingleSelection
        )
        self.table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setShowGrid(False)
        self.table.horizontalHeader().setStretchLastSection(True)
        self.table.itemSelectionChanged.connect(self._update_actions)
        root.addWidget(self.table, 1)
        root.addWidget(muted(
            "复制或编辑身份后可配置资源、动作、范围、条件；高风险改动会转为重大股东表决。"
        ))

    def apply_account_session(self, session):
        self.session = session
        if session is None:
            self.snapshot = {"templates": [], "members": []}
            self.render()
        self._update_actions()

    def refresh(self):
        if self.session is None:
            self.snapshot = {"templates": [], "members": []}
            self.render()
            return
        try:
            templates = CommunityClient().role_templates(self.session)
        except CommunityError as error:
            if self.window is not None and hasattr(self.window, "flash"):
                self.window.flash(str(error), 5000)
            return
        self.snapshot["templates"] = templates
        self.render()

    def render(self):
        self.table.setRowCount(0)
        for template in self.snapshot.get("templates", []):
            row = self.table.rowCount()
            self.table.insertRow(row)
            details = template.get("permission_details") or []
            high_risk = any(item.get("high_risk") for item in details)
            values = [
                template.get("key", ""),
                template.get("name", ""),
                str(template.get("current_version", "")),
                str(len(template.get("permissions", []))),
                "是" if high_risk else "否",
            ]
            for column, text in enumerate(values):
                item = QTableWidgetItem(str(text))
                if column == 0:
                    item.setData(Qt.ItemDataRole.UserRole, template)
                self.table.setItem(row, column, item)
        self.table.resizeColumnsToContents()
        self._update_actions()

    def _selected_template(self):
        rows = self.table.selectionModel().selectedRows()
        if not rows:
            return None
        item = self.table.item(rows[0].row(), 0)
        return item.data(Qt.ItemDataRole.UserRole) if item else None

    def _identity_me(self):
        state = getattr(self.window, "identity_state", {}) if self.window else {}
        return (state or {}).get("me") or {}

    def _can_assign(self):
        return bool(self._identity_me().get("can_manage_assignments"))

    def _can_manage_templates(self):
        return "identity.manage_templates" in (
            self._identity_me().get("permissions") or []
        )

    def _update_actions(self):
        template = self._selected_template()
        selected = bool(self.session and template and template.get("id"))
        self.clone_button.setEnabled(selected and self._can_manage_templates())
        self.edit_button.setEnabled(selected and self._can_manage_templates())
        self.assign_button.setEnabled(selected and self._can_assign())

    def _clone_selected(self):
        template = self._selected_template()
        if not template or self.session is None:
            return
        dialog = TemplateCloneDialog(self, template)
        if dialog.exec() != QDialog.DialogCode.Accepted or not dialog.data:
            return
        data = dialog.data
        try:
            result = CommunityClient().clone_role_template(
                self.session, template.get("id"), data["key"], data["name"],
                data["reason"], conflict_disclosed=data["conflict_disclosed"],
            )
        except CommunityError as error:
            QMessageBox.warning(self, "复制模板失败", str(error))
            return
        if result.get("motion_required"):
            QMessageBox.information(
                self, "已提交股东会",
                f"高权限模板复制已提交重大股东会表决，议案 {result.get('motion_id')}。",
            )
        self.refresh()
        if self.window is not None and hasattr(self.window, "flash"):
            self.window.flash("复制模板已提交", 3600)

    def _edit_selected(self):
        template = self._selected_template()
        if not template or self.session is None:
            return
        dialog = PermissionEditorDialog(self, template)
        if dialog.exec() != QDialog.DialogCode.Accepted or not dialog.data:
            return
        data = dialog.data
        try:
            result = CommunityClient().update_role_template(
                self.session, template.get("id"), data["name"],
                data["permissions"], data["reason"],
                conflict_disclosed=data["conflict_disclosed"],
            )
        except CommunityError as error:
            QMessageBox.warning(self, "保存身份失败", str(error))
            return
        if result.get("motion_required"):
            QMessageBox.information(
                self, "已提交股东表决",
                f"高风险权限已提交重大股东表决（提案 {result.get('motion_id')}）。",
            )
        self.refresh()
        if self.window is not None and hasattr(self.window, "flash"):
            self.window.flash("身份权限已保存或提交表决", 3600)

    def _assign_selected(self):
        template = self._selected_template()
        if not template or self.session is None:
            return
        state = getattr(self.window, "identity_state", {}) if self.window else {}
        me = (state or {}).get("me") or {}
        members = [
            member for member in self.snapshot.get("members", [])
            if str(member.get("profile_id")) != str(me.get("profile_id"))
        ]
        dialog = RoleAssignmentDialog(
            self, members, self.snapshot.get("templates", [])
        )
        if dialog.exec() != QDialog.DialogCode.Accepted or not dialog.data:
            return
        data = dialog.data
        try:
            CommunityClient().set_role_assignment(
                self.session, data["profile_id"], data["template_id"],
                data["ends_at"], data["reason"],
            )
        except CommunityError as error:
            QMessageBox.warning(self, "指派失败", str(error))
            return
        self.refresh()
        if self.window is not None and hasattr(self.window, "flash"):
            self.window.flash("临时身份已指派", 3600)
