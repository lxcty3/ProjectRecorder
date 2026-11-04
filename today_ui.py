from __future__ import annotations

from PyQt6.QtWidgets import QHBoxLayout, QListWidget, QPushButton, QVBoxLayout, QWidget

from widgets import StatCard, label, muted


class TodayPage(QWidget):
    """The simple-mode landing page: today's work first, everything else later."""

    def __init__(self, window):
        super().__init__()
        self.window = window
        self.tasks = []

        root = QVBoxLayout(self)
        root.setContentsMargins(24, 20, 24, 18)
        root.setSpacing(10)
        root.addWidget(label("今天", "KnowledgeTitle"))
        root.addWidget(muted("先完成今天的事，再决定下一步。"))

        cards = QHBoxLayout()
        cards.setSpacing(12)
        self.card_done = StatCard("今日完成", "0/0", "", "任务完成情况")
        self.card_points = StatCard("当前积分", "0", "分", "永久有效")
        self.card_streak = StatCard("连续完成", "0", "天", "每天一小步")
        cards.addWidget(self.card_done)
        cards.addWidget(self.card_points)
        cards.addWidget(self.card_streak)
        root.addLayout(cards)

        self.task_list = QListWidget()
        self.task_list.setObjectName("TodayTaskList")
        root.addWidget(self.task_list, 1)

        self.next_button = QPushButton("开始第一项任务")
        self.next_button.setObjectName("PrimaryButton")
        root.addWidget(self.next_button)

        self.render()

    def apply_account_session(self, session):
        self.refresh()

    def refresh(self):
        self.render()

    @staticmethod
    def _is_done(task):
        if task.get("done") is True or task.get("completed") is True:
            return True
        status = str(task.get("accept_status") or task.get("status") or "").lower()
        return status in {"done", "completed", "accepted", "已完成"}

    def render(self):
        self.task_list.clear()
        for task in self.tasks or []:
            title = task.get("title") or "任务"
            due = task.get("due") or task.get("plan_date") or "—"
            suffix = " · 已完成" if self._is_done(task) else ""
            self.task_list.addItem(f"{title}  截止 {due}{suffix}")

        total = len(self.tasks or [])
        done = sum(1 for task in (self.tasks or []) if self._is_done(task))
        self.card_done.update_values(f"{done}/{total}", "", "任务完成情况")

        state = getattr(self.window, "identity_state", {}) or {}
        points = (state.get("point_state") or {}).get("balance", 0)
        self.card_points.update_values(str(points), "分", "永久有效")
        self.next_button.setEnabled(bool(self.tasks))
        self.next_button.setText(
            "今天已完成" if total and done == total else "开始第一项任务"
        )
