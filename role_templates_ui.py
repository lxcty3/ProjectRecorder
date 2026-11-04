"""Desktop role-template catalog and cloning page."""
from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (
    QAbstractItemView,
    QHBoxLayout,
    QInputDialog,
    QMessageBox,
    QPushButton,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from community_client import CommunityClient, CommunityError
from widgets import SectionTitle, muted

__all__ = ["RoleTemplatePage"]


class RoleTemplatePage(QWidget):
    """Show reusable identity templates and clone one into a custom role."""

    def __init__(self, window):
        super().__init__()
        self.window = window
        self.session = None
        self.snapshot = {"templates": []}
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 6, 0, 0)
        root.setSpacing(8)

        head = QHBoxLayout()
        head.addWidget(SectionTitle("身份模板"))
        head.addStretch()
        self.clone_button = QPushButton("复制选中身份")
        self.clone_button.setObjectName("PrimaryButton")
        self.clone_button.setEnabled(False)
        self.clone_button.clicked.connect(self._clone_selected)
        head.addWidget(self.clone_button)
        root.addLayout(head)

        self.table = QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(["身份", "名称", "版本", "权限数"])
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
            "复制身份后可继续配置四维权限；高风险权限必须提交股东表决。"
        ))

    def apply_account_session(self, session):
        self.session = session
        if session is None:
            self.snapshot = {"templates": []}
            self.render()
        self._update_actions()

    def refresh(self):
        if self.session is None:
            self.snapshot = {"templates": []}
            self.render()
            return
        try:
            templates = CommunityClient().role_templates(self.session)
        except CommunityError as error:
            if self.window is not None and hasattr(self.window, "flash"):
                self.window.flash(str(error), 5000)
            return
        self.snapshot = {"templates": templates}
        self.render()

    def render(self):
        self.table.setRowCount(0)
        for template in self.snapshot.get("templates", []):
            row = self.table.rowCount()
            self.table.insertRow(row)
            values = [
                template.get("key", ""),
                template.get("name", ""),
                str(template.get("current_version", "")),
                str(len(template.get("permissions", []))),
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

    def _update_actions(self):
        template = self._selected_template()
        self.clone_button.setEnabled(
            bool(self.session and template and template.get("id"))
        )

    def _clone_selected(self):
        template = self._selected_template()
        if not template or self.session is None:
            return
        default_name = "{}副本".format(template.get("name") or "身份")
        name, accepted = QInputDialog.getText(
            self, "复制身份模板", "新身份名称：", text=default_name
        )
        if not accepted or not name.strip():
            return
        key, accepted = QInputDialog.getText(
            self, "复制身份模板", "新身份标识（唯一英文 key）：",
            text="{}_copy".format(template.get("key") or "role"),
        )
        if not accepted or not key.strip():
            return
        try:
            CommunityClient().clone_role_template(
                self.session, template.get("id"), key.strip(), name.strip()
            )
        except CommunityError as error:
            QMessageBox.warning(self, "复制身份失败", str(error))
            return
        self.refresh()
        if self.window is not None and hasattr(self.window, "flash"):
            self.window.flash("身份模板已复制", 3600)
