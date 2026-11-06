from __future__ import annotations

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (
    QFrame, QHBoxLayout, QListWidget, QProgressBar, QPushButton,
    QVBoxLayout, QWidget,
)

from widgets import StatCard, label, muted


class TodayPage(QWidget):
    """The simple-mode landing page: today's work first, everything else later."""

    def __init__(self, window):
        super().__init__()
        self.window = window
        self.tasks = []
        self.account_user_id = ""

        root = QVBoxLayout(self)
        root.setContentsMargins(24, 20, 24, 18)
        root.setSpacing(10)
        root.addWidget(label("今天", "KnowledgeTitle"))
        root.addWidget(muted("和伙伴一起，把今天的事一件件完成。"))

        self.hud = QFrame()
        self.hud.setObjectName("GameHud")
        self.hud.setAttribute(Qt.WidgetAttribute.WA_StyledBackground, True)
        hud_root = QVBoxLayout(self.hud)
        hud_root.setContentsMargins(18, 15, 18, 14)
        hud_root.setSpacing(10)

        hud_top = QHBoxLayout()
        hud_top.setSpacing(13)
        self.hud_emblem = label("我", "GameEmblem")
        self.hud_emblem.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.hud_emblem.setFixedSize(54, 54)
        hud_top.addWidget(self.hud_emblem)

        hud_copy = QVBoxLayout()
        hud_copy.setSpacing(2)
        hud_copy.addWidget(label("今日冒险手账", "GameKicker"))
        self.hud_name = label("行动者，准备出发", "GameHudTitle")
        hud_copy.addWidget(self.hud_name)
        self.hud_status = label("先完成今天的事，再决定下一步。", "GameHudStatus")
        hud_copy.addWidget(self.hud_status)
        hud_top.addLayout(hud_copy, 1)

        hud_side = QVBoxLayout()
        hud_side.setSpacing(0)
        hud_side.setAlignment(Qt.AlignmentFlag.AlignRight)
        self.hud_rank = label("企业成员", "GameRank")
        self.hud_rank.setAlignment(Qt.AlignmentFlag.AlignRight)
        hud_side.addWidget(self.hud_rank)
        self.hud_points = label("0", "GamePoints")
        self.hud_points.setAlignment(Qt.AlignmentFlag.AlignRight)
        hud_side.addWidget(self.hud_points)
        hud_side.addWidget(label("可用积分", "GamePointsLabel"))
        hud_top.addLayout(hud_side)
        hud_root.addLayout(hud_top)

        progress_row = QHBoxLayout()
        progress_row.setSpacing(10)
        self.hud_progress = QProgressBar()
        self.hud_progress.setObjectName("MissionProgress")
        self.hud_progress.setRange(0, 100)
        self.hud_progress.setValue(0)
        self.hud_progress.setTextVisible(False)
        self.hud_progress.setFixedHeight(8)
        progress_row.addWidget(self.hud_progress, 1)
        self.hud_progress_text = label("0 / 0", "GameHudProgressText")
        progress_row.addWidget(self.hud_progress_text)
        hud_root.addLayout(progress_row)
        root.addWidget(self.hud)

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

        self.pool_label = muted("暂无积分池")
        root.addWidget(self.pool_label)
        self.ledger_list = QListWidget()
        self.ledger_list.setObjectName("TodayPointLedger")
        self.ledger_list.setMaximumHeight(150)
        root.addWidget(self.ledger_list)

        self.next_button = QPushButton("开始第一项任务")
        self.next_button.setObjectName("PrimaryButton")
        root.addWidget(self.next_button)

        self.render()

    def apply_account_session(self, session):
        next_user = str(session.user_id if session else "")
        if session is None or next_user != self.account_user_id:
            self.account_user_id = next_user
            self.tasks = []
            self.render()
        if session is None:
            return
        page = getattr(self.window, "employee_cloud_page", None)
        if page is not None and getattr(page, "session", None) is not session:
            page.apply_account_session(session)
        if page is not None and hasattr(page, "refresh"):
            page.refresh()
        self.refresh()

    def set_cloud_tasks(self, tasks):
        self.tasks = list(tasks or [])
        self.render()

    def refresh(self):
        self.render()

    @staticmethod
    def _is_done(task):
        if task.get("done") is True or task.get("completed") is True:
            return True
        status = str(task.get("status") or "").lower()
        return status in {"done", "completed", "已完成"}

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
        me = state.get("me") or {}
        session = getattr(self.window, "account_session", None)
        display_name = getattr(session, "name", "") if session else ""
        display_name = display_name or me.get("name") or "行动者"
        role_name = me.get("role_name") or "企业成员"
        remaining = max(0, total - done)
        self.hud_emblem.setText(str(display_name)[:1] or "我")
        self.hud_name.setText(
            f"{display_name}，今日行动已完成" if total and not remaining
            else f"{display_name}，准备出发"
        )
        self.hud_status.setText(
            "今天没有待办，去星球补充情报或规划下一步。"
            if not remaining else f"还有 {remaining} 个行动等你处理。"
        )
        self.hud_rank.setText(str(role_name))
        self.hud_progress.setValue(int(done * 100 / total) if total else 0)
        self.hud_progress_text.setText(f"{done} / {total}")

        point_state = state.get("point_state") or {}
        points = point_state.get("balance", 0)
        self.hud_points.setText(str(points))
        self.card_points.update_values(str(points), "分", "永久有效")
        pool = point_state.get("pool") or {}
        if pool:
            self.pool_label.setText(
                "本期积分池 {}：剩余 {} / {}，单次上限 {}".format(
                    pool.get("quarter") or "当前季度",
                    pool.get("remaining", 0), pool.get("total", 0),
                    pool.get("single_award_limit", 0),
                )
            )
        else:
            self.pool_label.setText("暂无积分池，董事会批准后会显示额度")
        self.ledger_list.clear()
        for entry in (point_state.get("ledger") or [])[:20]:
            amount = int(entry.get("amount") or 0)
            self.ledger_list.addItem(
                "{}  {}{}  {}".format(
                    str(entry.get("created_at") or "")[:16].replace("T", " "),
                    "+" if amount > 0 else "", amount,
                    entry.get("reason") or "积分变动",
                )
            )
        self.next_button.setEnabled(bool(self.tasks))
        self.next_button.setText(
            "今天已完成" if total and done == total else "开始第一项任务"
        )
