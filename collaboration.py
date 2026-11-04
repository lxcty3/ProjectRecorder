"""Desktop collaboration center: cloud tasks, grading, rewards and leave."""
import datetime
import json
import time

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (
    QAbstractItemView, QComboBox, QDialog, QDialogButtonBox, QDoubleSpinBox, QFormLayout,
    QHBoxLayout, QInputDialog, QLabel, QLineEdit, QMessageBox, QPushButton,
    QTableWidget, QTableWidgetItem, QTabWidget, QTextEdit, QVBoxLayout, QWidget,
)

from cloud_integration import CloudIntegrationClient
from community_client import CommunityClient
from community_ui import CommunityWorker
from widgets import SectionTitle, StatCard, label, muted

__all__ = [
    "CollaborationPage",
    "CollaborationTaskDialog",
    "EmployeeCloudPage",
    "cloud_tasks_for_user",
]


def cloud_tasks_for_user(snapshot, user_id):
    """Return one user's tasks with completion derived from real task logs."""
    snapshot = snapshot if isinstance(snapshot, dict) else {}
    user_text = str(user_id or "")
    finished_task_ids = {
        str(log.get("task_id"))
        for log in snapshot.get("task_logs") or []
        if str(log.get("employee_id") or "") == user_text
        and log.get("task_id")
        and (log.get("finished_at") or log.get("finish_date"))
    }
    tasks = []
    for row in snapshot.get("tasks") or []:
        if str(row.get("employee_id") or "") != user_text:
            continue
        task = dict(row)
        status = str(task.get("status") or "").strip().lower()
        task["completed"] = bool(
            task.get("completed") is True
            or task.get("done") is True
            or status in {"done", "completed", "已完成"}
            or str(task.get("id")) in finished_task_ids
        )
        tasks.append(task)
    return tasks


class CollaborationTaskDialog(QDialog):
    def __init__(self, parent, snapshot):
        super().__init__(parent)
        self.snapshot = snapshot
        self.data = None
        self.setWindowTitle("派发云端任务")
        self.setMinimumWidth(540)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(22, 20, 22, 18)
        layout.setSpacing(11)
        layout.addWidget(label("派发任务到手机", "DialogTitle"))
        hint = muted("任务会立即进入员工的手机任务列表，并保存项目与步骤的真实关联。")
        hint.setWordWrap(True)
        layout.addWidget(hint)

        form = QFormLayout()
        form.setSpacing(10)
        self.employee_box = QComboBox()
        for profile in snapshot.get("profiles", []):
            if profile.get("role") == "employee":
                self.employee_box.addItem(
                    f"{profile.get('name')}（{profile.get('code')}）", profile.get("id")
                )
        self.project_box = QComboBox()
        self.project_box.addItem("不关联项目", None)
        for project in snapshot.get("projects", []):
            self.project_box.addItem(project.get("name", "项目"), project.get("id"))
        self.step_box = QComboBox()
        self.project_box.currentIndexChanged.connect(self._reload_steps)
        self.title_edit = QLineEdit()
        self.title_edit.setPlaceholderText("员工要完成什么")
        self.detail_edit = QTextEdit()
        self.detail_edit.setMinimumHeight(100)
        self.detail_edit.setPlaceholderText("验收标准、注意事项、交付物")
        self.date_edit = QLineEdit(datetime.date.today().isoformat())
        self.hours_box = QDoubleSpinBox()
        self.hours_box.setRange(0, 24)
        self.hours_box.setDecimals(1)
        self.hours_box.setValue(4)
        form.addRow("员工", self.employee_box)
        form.addRow("项目", self.project_box)
        form.addRow("步骤", self.step_box)
        form.addRow("任务标题 *", self.title_edit)
        form.addRow("任务说明", self.detail_edit)
        form.addRow("计划日期", self.date_edit)
        form.addRow("预估工时", self.hours_box)
        layout.addLayout(form)
        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save
            | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.button(QDialogButtonBox.StandardButton.Save).setText("派发")
        buttons.button(QDialogButtonBox.StandardButton.Cancel).setText("取消")
        buttons.accepted.connect(self._save)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)
        self._reload_steps()

    def _reload_steps(self):
        project_id = self.project_box.currentData()
        self.step_box.clear()
        self.step_box.addItem("不指定步骤", None)
        if project_id:
            for step in self.snapshot.get("project_steps", []):
                if step.get("project_id") == project_id:
                    self.step_box.addItem(step.get("name", "步骤"), step.get("id"))

    def _save(self):
        title = self.title_edit.text().strip()
        if not title:
            QMessageBox.warning(self, "缺少标题", "请填写任务标题。")
            return
        if self.employee_box.currentData() is None:
            QMessageBox.warning(self, "没有员工", "团队里还没有可派任务的员工账号。")
            return
        try:
            datetime.date.fromisoformat(self.date_edit.text().strip())
        except ValueError:
            QMessageBox.warning(self, "日期错误", "计划日期请使用 YYYY-MM-DD。")
            return
        self.data = {
            "employee_id": self.employee_box.currentData(),
            "project_id": self.project_box.currentData(),
            "step_id": self.step_box.currentData(),
            "title": title,
            "detail": self.detail_edit.toPlainText().strip(),
            "plan_date": self.date_edit.text().strip(),
            "est_hours": self.hours_box.value(),
        }
        self.accept()


class CollaborationPage(QWidget):
    def __init__(self, window):
        super().__init__()
        self.window = window
        self.session = getattr(window, "account_session", None)
        self.snapshot = {}
        self.workers = []
        self.busy = False
        self._build()

    def _build(self):
        root = QVBoxLayout(self)
        root.setContentsMargins(18, 14, 18, 12)
        root.setSpacing(11)
        hero = QHBoxLayout()
        title = QVBoxLayout()
        title.setSpacing(1)
        title.addWidget(label("协作中心", "KnowledgeTitle"))
        title.addWidget(label(
            "桌面端派任务、评级和审批；手机端执行并同步结果",
            "KnowledgeSubtitle",
        ))
        hero.addLayout(title)
        hero.addStretch()
        self.identity = label("尚未登录", "CommunityIdentity")
        hero.addWidget(self.identity)
        self.refresh_button = QPushButton("同步云端")
        self.refresh_button.setObjectName("GhostButton")
        self.refresh_button.clicked.connect(self.refresh)
        hero.addWidget(self.refresh_button)
        root.addLayout(hero)

        cards = QHBoxLayout()
        cards.setSpacing(10)
        self.card_tasks = StatCard("进行中任务", "0", "个", "云端任务")
        self.card_grading = StatCard("待评级", "0", "个", "完成任务后待处理")
        self.card_worklogs = StatCard("待审工时", "0", "条", "手工补录等待确认")
        self.card_approvals = StatCard("待审批", "0", "项", "奖励 + 请假")
        for card in (self.card_tasks, self.card_grading,
                     self.card_worklogs, self.card_approvals):
            cards.addWidget(card)
        root.addLayout(cards)

        toolbar = QHBoxLayout()
        self.new_task_button = QPushButton("派发任务")
        self.new_task_button.setObjectName("PrimaryButton")
        self.new_task_button.clicked.connect(self._new_task)
        toolbar.addWidget(self.new_task_button)
        self.grade_button = QPushButton("给选中任务评级")
        self.grade_button.setObjectName("GhostButton")
        self.grade_button.clicked.connect(self._grade_selected)
        toolbar.addWidget(self.grade_button)
        toolbar.addStretch()
        self.status_label = label("登录后同步", "CommunityFeedStatus")
        toolbar.addWidget(self.status_label)
        root.addLayout(toolbar)

        self.tabs = QTabWidget()
        self.tabs.setObjectName("InnerTabs")
        self.task_table = self._make_table([
            "员工", "任务", "计划日期", "状态", "评级", "源点", "项目"
        ])
        self.tabs.addTab(self.task_table, "任务与评级")
        self.worklog_table = self._make_table([
            "员工", "日期", "工时", "内容", "来源", "状态"
        ])
        self.tabs.addTab(self.worklog_table, "工时结算")
        self.reward_table = self._make_table([
            "员工", "奖励", "源点", "申请时间", "状态"
        ])
        self.tabs.addTab(self.reward_table, "奖励兑换")
        self.leave_table = self._make_table([
            "员工", "开始", "结束", "天数", "原因", "状态"
        ])
        self.tabs.addTab(self.leave_table, "请假审批")
        root.addWidget(self.tabs, 1)

        actions = QHBoxLayout()
        self.approve_worklog_button = QPushButton("确认选中工时")
        self.approve_worklog_button.setObjectName("GhostButton")
        self.approve_worklog_button.clicked.connect(self._approve_worklog)
        actions.addWidget(self.approve_worklog_button)
        self.redeem_button = QPushButton("批准/拒绝兑换")
        self.redeem_button.setObjectName("GhostButton")
        self.redeem_button.clicked.connect(self._decide_redemption)
        actions.addWidget(self.redeem_button)
        self.leave_button = QPushButton("批准/拒绝请假")
        self.leave_button.setObjectName("GhostButton")
        self.leave_button.clicked.connect(self._decide_leave)
        actions.addWidget(self.leave_button)
        actions.addStretch()
        root.addLayout(actions)

    @staticmethod
    def _make_table(headers):
        table = QTableWidget(0, len(headers))
        table.setHorizontalHeaderLabels(headers)
        table.verticalHeader().setVisible(False)
        table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        table.setShowGrid(False)
        table.horizontalHeader().setStretchLastSection(True)
        table.setAlternatingRowColors(False)
        return table

    def apply_account_session(self, session):
        self.session = session
        if session is None:
            self.snapshot = {}
            self.status_label.setText("尚未登录")
            self._render()
        elif self.isVisible():
            self.refresh()

    def on_activated(self):
        if self.session is not None:
            self.refresh()

    def shutdown(self):
        for worker in list(self.workers):
            if worker.isRunning():
                worker.wait(12000)

    def _client_session(self):
        session = self.session
        if session and session.is_expired():
            session = CommunityClient().refresh(session)
            self.session = session
            if hasattr(self.window, "account_session"):
                self.window.account_session = session
                self.window.window_settings_set("community_session", session.to_dict())
        return session

    def _run(self, work, done):
        if self.busy:
            return
        self.busy = True
        self.refresh_button.setEnabled(False)
        self.status_label.setText("同步中…")
        worker = CommunityWorker(work, self)
        self.workers.append(worker)

        def cleanup():
            self.busy = False
            self.refresh_button.setEnabled(True)
            if worker in self.workers:
                self.workers.remove(worker)
            worker.deleteLater()

        worker.done.connect(done)
        worker.failed.connect(self._failed)
        worker.finished.connect(cleanup)
        worker.start()

    def refresh(self):
        if self.session is None:
            self.status_label.setText("请先登录手机版账号")
            return

        def work():
            session = self._client_session()
            snapshot = CloudIntegrationClient(session).sync_all(self.window.store)
            return session, snapshot

        self._run(work, self._loaded)

    def _loaded(self, result):
        self.session, self.snapshot = result
        self.status_label.setText("云端已同步")
        self._render()

    def _failed(self, message):
        self.status_label.setText("同步失败")
        QMessageBox.warning(self, "协作中心", message)

    def _render(self):
        if self.session is None:
            self.identity.setText("尚未登录")
            for table in (self.task_table, self.worklog_table,
                          self.reward_table, self.leave_table):
                table.setRowCount(0)
            return
        role = "老板" if self.session.role == "boss" else "员工"
        self.identity.setText(f"{self.session.name} · {role}")
        profiles = {row.get("id"): row for row in self.snapshot.get("profiles", [])}
        self._fill_tasks(profiles)
        self._fill_worklogs(profiles)
        self._fill_redemptions(profiles)
        self._fill_leaves(profiles)
        tasks = self.snapshot.get("tasks", [])
        pending_grade = sum(1 for row in tasks if not row.get("grade")
                            and row.get("accept_status") != "rejected")
        pending_logs = sum(1 for row in self.snapshot.get("worklogs", [])
                           if row.get("approval_status") == "pending")
        pending_redeem = sum(1 for row in self.snapshot.get("redemptions", [])
                             if row.get("status") == "pending")
        pending_leave = sum(1 for row in self.snapshot.get("leave_requests", [])
                            if row.get("status") == "pending")
        self.card_tasks.update_values(len(tasks), "个", "云端任务")
        self.card_grading.update_values(pending_grade, "个", "等待老板评级")
        self.card_worklogs.update_values(pending_logs, "条", "手工补录等待确认")
        self.card_approvals.update_values(
            pending_redeem + pending_leave, "项", "奖励 + 请假"
        )
    @staticmethod
    def _name(profiles, profile_id):
        row = profiles.get(profile_id) or {}
        return row.get("name") or row.get("code") or "成员"

    @staticmethod
    def _set_row(table, index, values):
        for column, value in enumerate(values):
            item = QTableWidgetItem("" if value is None else str(value))
            if column > 0:
                item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
            table.setItem(index, column, item)

    def _fill_tasks(self, profiles):
        tasks = self.snapshot.get("tasks", [])
        projects = {row.get("id"): row.get("name", "")
                    for row in self.snapshot.get("projects", [])}
        self.task_table.setRowCount(len(tasks))
        for index, task in enumerate(tasks):
            values = [
                self._name(profiles, task.get("employee_id")),
                task.get("title") or "",
                task.get("plan_date") or "",
                task.get("accept_status") or "pending",
                task.get("grade") or "待评级",
                task.get("merit_awarded") or 0,
                projects.get(task.get("project_id"), ""),
            ]
            self._set_row(self.task_table, index, values)
            self.task_table.item(index, 0).setData(
                Qt.ItemDataRole.UserRole, task.get("id")
            )

    def _fill_worklogs(self, profiles):
        rows = [row for row in self.snapshot.get("worklogs", [])
                if row.get("approval_status") == "pending"]
        self.worklog_table.setRowCount(len(rows))
        for index, row in enumerate(rows):
            self._set_row(self.worklog_table, index, [
                self._name(profiles, row.get("employee_id")),
                row.get("work_date") or "",
                f"{float(row.get('hours') or 0):g}",
                (row.get("content") or "")[:40],
                row.get("source") or "",
                row.get("approval_status") or "",
            ])
            self.worklog_table.item(index, 0).setData(
                Qt.ItemDataRole.UserRole, row.get("id")
            )

    def _fill_redemptions(self, profiles):
        rows = self.snapshot.get("redemptions", [])
        self.reward_table.setRowCount(len(rows))
        for index, row in enumerate(rows):
            self._set_row(self.reward_table, index, [
                self._name(profiles, row.get("profile_id")),
                row.get("title") or "",
                row.get("cost") or 0,
                str(row.get("created_at") or "")[:16].replace("T", " "),
                row.get("status") or "",
            ])
            self.reward_table.item(index, 0).setData(
                Qt.ItemDataRole.UserRole, row.get("id")
            )

    def _fill_leaves(self, profiles):
        rows = self.snapshot.get("leave_requests", [])
        self.leave_table.setRowCount(len(rows))
        for index, row in enumerate(rows):
            self._set_row(self.leave_table, index, [
                self._name(profiles, row.get("profile_id")),
                row.get("from_date") or "",
                row.get("to_date") or "",
                row.get("days") or 0,
                (row.get("reason") or "")[:40],
                row.get("status") or "",
            ])
            self.leave_table.item(index, 0).setData(
                Qt.ItemDataRole.UserRole, row.get("id")
            )

    @staticmethod
    def _selected_id(table):
        row = table.currentRow()
        if row < 0 or table.item(row, 0) is None:
            return None
        return table.item(row, 0).data(Qt.ItemDataRole.UserRole)

    def _new_task(self):
        if self.session is None:
            QMessageBox.information(self, "先登录", "请先登录手机版账号。")
            return
        dialog = CollaborationTaskDialog(self, self.snapshot)
        if dialog.exec() != QDialog.DialogCode.Accepted or not dialog.data:
            return

        def work():
            session = self._client_session()
            CloudIntegrationClient(session).create_task(dialog.data)
            return session, CloudIntegrationClient(session).sync_all(self.window.store)

        self._run(work, self._loaded)

    def _grade_selected(self):
        task_id = self._selected_id(self.task_table)
        if not task_id:
            QMessageBox.information(self, "先选任务", "请选择一条任务。")
            return
        grade, ok = QInputDialog.getItem(
            self, "任务评级", "选择评级：", ["S", "A", "B", "C"], 1, False
        )
        if not ok:
            return

        def work():
            session = self._client_session()
            client = CloudIntegrationClient(session)
            client.grade_task(task_id, grade)
            return session, client.sync_all(self.window.store)

        self._run(work, self._loaded)

    def _approve_worklog(self):
        worklog_id = self._selected_id(self.worklog_table)
        if not worklog_id:
            QMessageBox.information(self, "先选工时", "请选择一条待审工时。")
            return

        def work():
            session = self._client_session()
            client = CloudIntegrationClient(session)
            client.approve_worklog(worklog_id)
            return session, client.sync_all(self.window.store)

        self._run(work, self._loaded)

    def _decide_redemption(self):
        redemption_id = self._selected_id(self.reward_table)
        if not redemption_id:
            QMessageBox.information(self, "先选申请", "请选择一条兑换申请。")
            return
        answer = QMessageBox.question(
            self, "兑换审批", "批准这次兑换吗？选择“否”会拒绝申请。"
        )
        approved = answer == QMessageBox.StandardButton.Yes

        def work():
            session = self._client_session()
            client = CloudIntegrationClient(session)
            client.decide_redemption(redemption_id, approved)
            return session, client.sync_all(self.window.store)

        self._run(work, self._loaded)

    def _decide_leave(self):
        leave_id = self._selected_id(self.leave_table)
        if not leave_id:
            QMessageBox.information(self, "先选请假", "请选择一条请假申请。")
            return
        answer = QMessageBox.question(
            self, "请假审批", "批准这条请假吗？选择“否”会拒绝申请。"
        )
        approved = answer == QMessageBox.StandardButton.Yes

        def work():
            session = self._client_session()
            client = CloudIntegrationClient(session)
            client.decide_leave(leave_id, approved)
            return session, client.sync_all(self.window.store)

        self._run(work, self._loaded)
class EmployeeCloudPage(QWidget):
    """Restricted desktop view for employee accounts."""

    def __init__(self, window):
        super().__init__()
        self.window = window
        self.session = getattr(window, "account_session", None)
        self.snapshot = {}
        self.workers = []
        root = QVBoxLayout(self)
        root.setContentsMargins(22, 18, 22, 16)
        root.setSpacing(12)
        head = QHBoxLayout()
        title = QVBoxLayout()
        title.addWidget(label("我的云端任务", "KnowledgeTitle"))
        title.addWidget(label(
            "员工电脑端只显示自己的任务、计时和社区，不显示预算与团队风险",
            "KnowledgeSubtitle",
        ))
        head.addLayout(title)
        head.addStretch()
        self.status = label("尚未登录", "CommunityFeedStatus")
        head.addWidget(self.status)
        self.refresh_button = QPushButton("刷新")
        self.refresh_button.setObjectName("GhostButton")
        self.refresh_button.clicked.connect(self.refresh)
        head.addWidget(self.refresh_button)
        root.addLayout(head)

        self.table = QTableWidget(0, 5)
        self.table.setHorizontalHeaderLabels(["任务", "日期", "状态", "预估工时", "评级"])
        self.table.verticalHeader().setVisible(False)
        self.table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.horizontalHeader().setStretchLastSection(True)
        root.addWidget(self.table, 1)

        actions = QHBoxLayout()
        self.timer_label = label("未开始计时", "CommunityProfileName")
        actions.addWidget(self.timer_label)
        actions.addStretch()
        self.start_button = QPushButton("开始选中任务")
        self.start_button.setObjectName("PrimaryButton")
        self.start_button.clicked.connect(self._start)
        actions.addWidget(self.start_button)
        self.stop_button = QPushButton("收工并提交工时")
        self.stop_button.setObjectName("GhostButton")
        self.stop_button.clicked.connect(self._stop)
        actions.addWidget(self.stop_button)
        root.addLayout(actions)

    def apply_account_session(self, session):
        previous_user = str(getattr(self, "account_user_id", "") or "")
        next_user = str(session.user_id if session else "")
        if previous_user != next_user:
            self.account_user_id = next_user
            self.snapshot = {}
            self.table.setRowCount(0)
            self._publish_tasks([])
            self.status.setText(
                f"{session.name} · 员工" if session else "尚未登录"
            )
        self.session = session
        if session and self.isVisible():
            self.refresh()

    def _publish_tasks(self, tasks):
        if self.window is not None and hasattr(self.window, "today_page"):
            self.window.today_page.set_cloud_tasks(tasks)

    def _refresh_failed(self, message):
        self.snapshot = {}
        self.table.setRowCount(0)
        self._publish_tasks([])
        self.status.setText("刷新失败，已清空旧账号任务")
        QMessageBox.warning(self, "我的任务", str(message))

    def shutdown(self):
        for worker in list(self.workers):
            if worker.isRunning():
                worker.wait(12000)

    def refresh(self):
        if self.session is None:
            return

        def work():
            client = CloudIntegrationClient(self.session)
            us = client.snapshot()
            return us

        self._run(work, self._loaded)

    def _run(self, work, done):
        worker = CommunityWorker(work, self)
        self.workers.append(worker)

        def cleanup():
            if worker in self.workers:
                self.workers.remove(worker)
            worker.deleteLater()

        worker.done.connect(done)
        worker.failed.connect(self._refresh_failed)
        worker.finished.connect(cleanup)
        worker.start()

    def _loaded(self, snapshot):
        self.snapshot = snapshot
        tasks = cloud_tasks_for_user(
            snapshot, self.session.user_id if self.session else ""
        )
        if self.window is not None and hasattr(self.window, "today_page"):
            self.window.today_page.set_cloud_tasks(tasks)
        self.table.setRowCount(len(tasks))
        for index, task in enumerate(tasks):
            values = [
                task.get("title") or "",
                task.get("plan_date") or "",
                "已完成" if task.get("completed") else (task.get("accept_status") or ""),
                task.get("est_hours") or 0,
                task.get("grade") or "待评级",
            ]
            for column, value in enumerate(values):
                item = QTableWidgetItem(str(value))
                if column > 0:
                    item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
                if column == 0:
                    item.setData(Qt.ItemDataRole.UserRole, task.get("id"))
                self.table.setItem(index, column, item)
        open_session = next(
            (row for row in snapshot.get("work_sessions", [])
             if row.get("profile_id") == self.session.user_id
             and not row.get("ended_at")),
            None,
        )
        self.timer_label.setText(
            "正在计时 · 可直接收工" if open_session else "未开始计时"
        )
        self.status.setText("云端已同步")

    def _selected_task(self):
        row = self.table.currentRow()
        if row < 0 or self.table.item(row, 0) is None:
            return None
        return self.table.item(row, 0).data(Qt.ItemDataRole.UserRole)

    def _start(self):
        task_id = self._selected_task()
        if task_id is None:
            QMessageBox.information(self, "先选任务", "请先选择一条任务。")
            return

        def work():
            CloudIntegrationClient(self.session).start_work(task_id)
            return CloudIntegrationClient(self.session).snapshot()

        self._run(work, self._loaded)

    def _stop(self):
        def work():
            CloudIntegrationClient(self.session).end_work()
            return CloudIntegrationClient(self.session).snapshot()

        self._run(work, self._loaded)
