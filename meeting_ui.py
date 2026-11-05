"""Desktop shareholder meeting page."""

from __future__ import annotations

import calendar
from datetime import datetime

from PyQt6.QtCore import QDateTime, Qt
from PyQt6.QtWidgets import (
    QAbstractItemView,
    QComboBox,
    QDateTimeEdit,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QLineEdit,
    QPushButton,
    QTableWidget,
    QTableWidgetItem,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from community_client import CommunityClient
from community_ui import CommunityWorker
from widgets import SectionTitle, label, muted


TYPE_LABELS = {"regular": "月度例行", "special": "临时会议"}
STATUS_LABELS = {
    "pending_approval": "等股东同意",
    "scheduled": "待召开",
    "approved": "已同意",
    "completed": "已完成",
    "cancelled": "已取消",
    "rejected": "未通过",
}
ATTENDANCE_LABELS = {
    "pending": "未登记", "attending": "出席", "absent": "缺席", "leave": "请假",
}


def _date(value):
    return str(value or "").replace("T", " ")[:16] or "—"


class ShareholderMeetingPage(QWidget):
    def __init__(self, window):
        super().__init__()
        self.window = window
        self.session = None
        self.snapshot = {}
        self.workers = []
        self.busy = False
        self._build()

    @staticmethod
    def _empty_snapshot():
        return {"meetings": [], "shareholders": [], "access": {}, "month_status": "missing"}

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

    def _build(self):
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 6, 0, 0)
        root.setSpacing(8)
        header = QHBoxLayout()
        header.addWidget(SectionTitle("股东大会"))
        header.addStretch()
        self.refresh_button = QPushButton("刷新")
        self.refresh_button.setObjectName("GhostButton")
        self.refresh_button.clicked.connect(self.refresh)
        header.addWidget(self.refresh_button)
        root.addLayout(header)
        self.month_label = muted("每月自动建立一次例行股东大会；临时会议需超过半数股东同意。")
        self.month_label.setWordWrap(True)
        root.addWidget(self.month_label)
        self.meeting_table = self._table([
            "类型", "标题", "召开时间", "状态", "召集同意", "出席/请假",
        ])
        self.meeting_table.itemSelectionChanged.connect(self._sync_actions)
        root.addWidget(self.meeting_table, 1)
        actions = QHBoxLayout()
        self.initiate_button = QPushButton("发起临时股东大会")
        self.initiate_button.setObjectName("PrimaryButton")
        self.initiate_button.clicked.connect(self._initiate)
        self.yes_button = QPushButton("同意召集")
        self.no_button = QPushButton("反对召集")
        self.abstain_button = QPushButton("弃权")
        self.attend_button = QPushButton("出席")
        self.leave_button = QPushButton("请假")
        self.absent_button = QPushButton("缺席")
        self.complete_button = QPushButton("结束并记录纪要")
        for button in (
            self.yes_button, self.no_button, self.abstain_button,
            self.attend_button, self.leave_button, self.absent_button,
            self.complete_button,
        ):
            button.setObjectName("GhostButton")
            button.setEnabled(False)
        self.yes_button.clicked.connect(lambda: self._vote("yes"))
        self.no_button.clicked.connect(lambda: self._vote("no"))
        self.abstain_button.clicked.connect(lambda: self._vote("abstain"))
        self.attend_button.clicked.connect(lambda: self._attendance("attending"))
        self.leave_button.clicked.connect(lambda: self._attendance("leave"))
        self.absent_button.clicked.connect(lambda: self._attendance("absent"))
        self.complete_button.clicked.connect(self._complete)
        actions.addWidget(self.initiate_button)
        for button in (
            self.yes_button, self.no_button, self.abstain_button,
            self.attend_button, self.leave_button, self.absent_button,
            self.complete_button,
        ):
            actions.addWidget(button)
        actions.addStretch()
        root.addLayout(actions)
        self.detail_label = QLabel("")
        self.detail_label.setWordWrap(True)
        root.addWidget(self.detail_label)
        self.status_label = QLabel("登录后加载股东大会。")
        self.status_label.setWordWrap(True)
        root.addWidget(self.status_label)
        self._sync_actions()

    def apply_account_session(self, session):
        self.session = session
        self.refresh()

    def on_activated(self):
        self.refresh()

    def refresh(self):
        if self.session is None:
            self.snapshot = self._empty_snapshot()
            self.render()
            self.status_label.setText("登录后加载股东大会。")
            return
        if self.busy:
            return
        self.busy = True
        self.refresh_button.setEnabled(False)
        worker = CommunityWorker(
            lambda: CommunityClient().shareholder_meetings(self.session), self
        )
        worker.done.connect(self._loaded)
        worker.failed.connect(self._failed)
        worker.finished.connect(worker.deleteLater)
        worker.finished.connect(
            lambda: self.workers.remove(worker) if worker in self.workers else None
        )
        self.workers.append(worker)
        worker.start()

    def _loaded(self, data):
        self.busy = False
        self.refresh_button.setEnabled(True)
        if isinstance(data, dict) and data.get("ok") is False:
            self._failed(data.get("error") or "股东大会权限不足")
            return
        self.snapshot = data if isinstance(data, dict) else self._empty_snapshot()
        self.render()
        self.status_label.setText("股东大会数据已更新。")

    def _failed(self, message):
        self.busy = False
        self.refresh_button.setEnabled(True)
        self.snapshot = self._empty_snapshot()
        self.render()
        self.status_label.setText(str(message))

    def render(self):
        meetings = self.snapshot.get("meetings") or []
        access = self.snapshot.get("access") or {}
        month_status = self.snapshot.get("month_status") or "missing"
        month_labels = {
            "missing": "本月例行股东大会尚未建立",
            "scheduled": "本月例行股东大会待召开",
            "approved": "本月例行股东大会已同意",
            "completed": "本月例行股东大会已完成",
        }
        total = int(self.snapshot.get("total_shareholders") or 0)
        pending = int(self.snapshot.get("special_pending") or 0)
        self.month_label.setText(
            f"{month_labels.get(month_status, month_status)} · 股东 {total} 人 · 待表决临时会议 {pending} 项"
        )
        self.initiate_button.setEnabled(bool(access.get("can_initiate_special")))
        self.meeting_table.setRowCount(0)
        for meeting in meetings:
            row = self.meeting_table.rowCount()
            self.meeting_table.insertRow(row)
            attendance = meeting.get("attendance") or []
            leave_count = sum(1 for item in attendance if item.get("status") == "leave")
            present_count = sum(1 for item in attendance if item.get("status") == "attending")
            values = [
                TYPE_LABELS.get(meeting.get("meeting_type"), meeting.get("meeting_type") or "—"),
                meeting.get("title") or "—",
                _date(meeting.get("scheduled_at")),
                STATUS_LABELS.get(meeting.get("status"), meeting.get("status") or "—"),
                f"{meeting.get('yes_count', 0)}/{meeting.get('eligible_count', 0)}",
                f"出席 {present_count} · 请假 {leave_count}",
            ]
            for column, value in enumerate(values):
                item = QTableWidgetItem(str(value))
                if column == 0:
                    item.setData(Qt.ItemDataRole.UserRole, meeting)
                self.meeting_table.setItem(row, column, item)
        self._sync_actions()

    def _selected(self):
        row = self.meeting_table.currentRow()
        if row < 0:
            return {}
        item = self.meeting_table.item(row, 0)
        return item.data(Qt.ItemDataRole.UserRole) if item else {}

    def _sync_actions(self):
        selected = self._selected()
        actions = selected.get("actions") or {}
        for button, key in (
            (self.yes_button, "vote"), (self.no_button, "vote"),
            (self.abstain_button, "vote"), (self.attend_button, "attend"),
            (self.leave_button, "attend"), (self.absent_button, "attend"),
            (self.complete_button, "complete"),
        ):
            button.setEnabled(bool(selected and actions.get(key)))
        attendance = selected.get("attendance") or []
        leave_rows = [item for item in attendance if item.get("status") == "leave"]
        if not selected:
            self.detail_label.setText("选择一条会议记录查看请假和出席情况。")
        else:
            leave_text = "；".join(
                f"{item.get('name') or '股东'}：{item.get('note') or '未填写原因'}"
                for item in leave_rows
            ) or "无请假记录"
            self.detail_label.setText(f"请假记录：{leave_text}")

    def _activate(self, work):
        worker = CommunityWorker(work, self)
        worker.done.connect(self._action_done)
        worker.failed.connect(lambda message: self.status_label.setText(str(message)))
        worker.finished.connect(worker.deleteLater)
        worker.finished.connect(
            lambda: self.workers.remove(worker) if worker in self.workers else None
        )
        self.workers.append(worker)
        worker.start()

    def _action_done(self, data):
        if isinstance(data, dict) and data.get("ok") is False:
            self.status_label.setText(data.get("error") or "操作没有权限")
            return
        self.status_label.setText("操作成功。")
        self.refresh()

    def _initiate(self):
        if self.session is None:
            return
        dialog = QDialog(self)
        dialog.setWindowTitle("发起临时股东大会")
        form = QFormLayout(dialog)
        title = QLineEdit()
        title.setPlaceholderText("会议标题")
        agenda = QTextEdit()
        agenda.setPlaceholderText("需要股东审议的事项")
        agenda.setMaximumHeight(100)
        reason = QTextEdit()
        reason.setPlaceholderText("为什么必须在本月增加一次会议")
        reason.setMaximumHeight(90)
        now = datetime.now()
        last_day = calendar.monthrange(now.year, now.month)[1]
        day = min(now.day + 1, last_day)
        scheduled = QDateTimeEdit(QDateTime(datetime(now.year, now.month, day, 18, 0)))
        scheduled.setDisplayFormat("yyyy-MM-dd HH:mm")
        form.addRow("标题", title)
        form.addRow("议程", agenda)
        form.addRow("召开时间", scheduled)
        form.addRow("特殊原因", reason)
        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok |
            QDialogButtonBox.StandardButton.Cancel
        )
        buttons.accepted.connect(dialog.accept)
        buttons.rejected.connect(dialog.reject)
        form.addRow(buttons)
        if dialog.exec() != QDialog.DialogCode.Accepted:
            return
        self._activate(lambda: CommunityClient().initiate_shareholder_meeting(
            self.session, title.text(), agenda.toPlainText(),
            scheduled.dateTime().toPyDateTime().astimezone().isoformat(),
            reason.toPlainText(),
        ))

    def _vote(self, choice):
        selected = self._selected()
        if not selected:
            return
        self._activate(lambda: CommunityClient().vote_shareholder_meeting(
            self.session, selected.get("id"), choice
        ))

    def _attendance(self, status):
        selected = self._selected()
        if not selected:
            return
        note = ""
        if status == "leave":
            note, accepted = QInputDialog.getMultiLineText(
                self, "登记请假", "请假原因"
            )
            if not accepted or not note.strip():
                return
        self._activate(lambda: CommunityClient().record_shareholder_meeting_attendance(
            self.session, selected.get("id"), status, note
        ))

    def _complete(self):
        selected = self._selected()
        if not selected:
            return
        minutes, accepted = QInputDialog.getMultiLineText(
            self, "结束股东大会", "会议纪要"
        )
        if not accepted or not minutes.strip():
            return
        self._activate(lambda: CommunityClient().complete_shareholder_meeting(
            self.session, selected.get("id"), minutes
        ))

    def shutdown(self):
        for worker in list(self.workers):
            if worker.isRunning():
                worker.wait(5000)
        self.workers.clear()
