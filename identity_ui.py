"""Enterprise identity and shareholder voting page for the desktop app."""
import datetime
import time

from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtWidgets import (
    QAbstractItemView,
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPushButton,
    QSpinBox,
    QTableWidget,
    QTableWidgetItem,
    QTabWidget,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from community_client import CommunityClient
from community_ui import CommunityWorker
from role_templates_ui import RoleTemplatePage
from widgets import SectionTitle, StatCard, label, muted

__all__ = [
    "IdentityPage", "RoleMotionDialog", "BoardPointPage",
    "PointPoolMotionDialog", "AwardPointsDialog",
]

ROLE_LABELS = {
    "chairperson": "董事长",
    "director": "董事",
    "supervisor": "监事",
    "ceo": "首席执行官",
    "vice_president": "副总裁",
    "department_manager": "部门经理",
    "project_manager": "项目经理",
    "team_lead": "组长",
    "finance": "财务",
    "hr": "人力资源",
    "auditor": "审计",
    "employee": "员工",
}

ROLE_DESCRIPTIONS = {
    "chairperson": "领导董事会，统筹企业治理与经营",
    "director": "参与战略决策，监督经营管理",
    "supervisor": "独立监督经营、财务与合规",
    "ceo": "负责日常经营并向董事会汇报",
    "vice_president": "负责一个业务板块或职能体系",
    "department_manager": "负责部门人员、交付与协作",
    "project_manager": "负责项目交付和任务分配",
    "team_lead": "带领小组执行并审核工作",
    "finance": "管理预算、成本和财务控制",
    "hr": "管理人员资料与组织关系",
    "auditor": "只读查看经营、财务与审计信息",
    "employee": "执行分配任务并参与社区",
}

PERMISSION_LABELS = {
    "identity.view": "查看企业身份",
    "identity.propose": "发起任免提案",
    "identity.vote": "按股份投票",
    "identity.manage_shares": "调整股份",
    "company.manage": "管理企业",
    "projects.view_all": "查看全部项目",
    "projects.manage": "管理项目",
    "people.view_all": "查看全部成员",
    "people.manage": "管理成员",
    "worklogs.approve": "审核工时",
    "tasks.assign": "分配任务",
    "tasks.grade": "任务评级",
    "rewards.manage": "管理奖励",
    "leave.approve": "审批请假",
    "finance.view": "查看财务",
    "finance.manage": "管理财务",
    "reports.view": "查看经营报表",
    "audit.read": "查看审计信息",
    "community.post": "发布社区消息",
}

STATUS_LABELS = {
    "open": "投票中",
    "passed": "已通过",
    "rejected": "未通过",
    "cancelled": "已取消",
}


def role_label(key):
    return ROLE_LABELS.get(str(key or ""), str(key or "员工"))


def role_description(key):
    return ROLE_DESCRIPTIONS.get(str(key or ""), "")


def permission_list(permissions):
    return "、".join(PERMISSION_LABELS.get(p, p) for p in permissions or [])


class RoleMotionDialog(QDialog):
    """Create an appointment or removal proposal."""

    def __init__(self, parent, snapshot, target_profile_id=None):
        super().__init__(parent)
        self.snapshot = snapshot or {}
        self.data = None
        self.setWindowTitle("发起身份任免提案")
        self.setMinimumWidth(520)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(22, 20, 22, 18)
        layout.setSpacing(12)
        layout.addWidget(label("股东任免提案", "DialogTitle"))
        hint = muted(
            "提案发出后由持股股东按股份比例投票。默认出席率达到 50%，"
            "且赞成票超过有效投票的 50%，任免才会生效。"
        )
        hint.setWordWrap(True)
        layout.addWidget(hint)

        form = QFormLayout()
        form.setSpacing(10)
        self.target_box = QComboBox()
        for member in self.snapshot.get("members", []):
            if member.get("status") != "active":
                continue
            text = "{}（{}）".format(
                member.get("name") or "成员", role_label(member.get("role_key"))
            )
            self.target_box.addItem(text, member.get("profile_id"))
        if target_profile_id:
            index = self.target_box.findData(target_profile_id)
            if index >= 0:
                self.target_box.setCurrentIndex(index)

        self.kind_box = QComboBox()
        self.kind_box.addItem("任命 / 调整身份", "appointment")
        self.kind_box.addItem("免去当前身份", "removal")
        self.role_box = QComboBox()
        for role in self.snapshot.get("roles", []):
            if role.get("key") == "employee":
                continue
            self.role_box.addItem(
                "{} — {}".format(role_label(role.get("key")), role_description(role.get("key")) or role.get("description") or ""),
                role.get("key"),
            )
        self.department_edit = QLineEdit()
        self.department_edit.setPlaceholderText("例如：产品研发部")
        self.title_edit = QLineEdit()
        self.title_edit.setPlaceholderText("例如：研发负责人")
        self.reason_edit = QTextEdit()
        self.reason_edit.setMinimumHeight(90)
        self.reason_edit.setPlaceholderText("说明为什么需要这项任免，股东投票时会看到")
        self.days_box = QSpinBox()
        self.days_box.setRange(1, 14)
        self.days_box.setValue(3)
        self.days_box.setSuffix(" 天")
        self.conflict_box = QCheckBox(
            "\u6211\u4e0e\u8be5\u4e8b\u9879\u5b58\u5728\u5229\u76ca"
            "\u5173\u7cfb\uff0c\u5df2\u4e3b\u52a8\u62ab\u9732"
        )

        form.addRow("成员", self.target_box)
        form.addRow("事项", self.kind_box)
        form.addRow("拟任身份", self.role_box)
        form.addRow("部门", self.department_edit)
        form.addRow("职务名称", self.title_edit)
        form.addRow("提案原因", self.reason_edit)
        form.addRow("投票期", self.days_box)
        form.addRow("\u5229\u76ca\u51b2\u7a81", self.conflict_box)
        layout.addLayout(form)

        self.kind_box.currentIndexChanged.connect(self._sync_kind)
        self.role_box.currentIndexChanged.connect(self._sync_days)
        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save
            | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.button(QDialogButtonBox.StandardButton.Save).setText("发起提案")
        buttons.button(QDialogButtonBox.StandardButton.Cancel).setText("取消")
        buttons.accepted.connect(self._save)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)
        self._sync_kind()
        self._sync_days()

    def _sync_days(self):
        major_roles = {
            "chairperson", "director", "supervisor", "ceo",
            "finance", "identity_admin",
        }
        self.days_box.setValue(
            5 if self.role_box.currentData() in major_roles else 3
        )

    def _sync_kind(self):
        appointment = self.kind_box.currentData() == "appointment"
        for widget in (
            self.role_box,
            self.department_edit,
            self.title_edit,
        ):
            widget.setEnabled(appointment)

    def _save(self):
        if self.target_box.currentData() is None:
            QMessageBox.warning(self, "没有成员", "企业里还没有可任免的成员。")
            return
        kind = self.kind_box.currentData()
        role_key = self.role_box.currentData() if kind == "appointment" else None
        if kind == "appointment" and not role_key:
            QMessageBox.warning(self, "缺少身份", "请选择拟任身份。")
            return
        self.data = {
            "target_profile_id": self.target_box.currentData(),
            "kind": kind,
            "role_key": role_key or "employee",
            "department": self.department_edit.text().strip(),
            "title": self.title_edit.text().strip(),
            "reason": self.reason_edit.toPlainText().strip(),
            "days": self.days_box.value(),
            "conflict_disclosed": self.conflict_box.isChecked(),
        }
        self.accept()


class IdentityPage(QWidget):
    """Shared governance view: members, capabilities and weighted motions."""

    def __init__(self, window):
        super().__init__()
        self.window = window
        self.session = None
        self.snapshot = {}
        self.workers = []
        self.busy = False
        self._last_refresh = 0
        self._build()

        self.timer = QTimer(self)
        self.timer.setInterval(20000)
        self.timer.timeout.connect(self._auto_refresh)
        self.timer.start()

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

    def _build(self):
        root = QVBoxLayout(self)
        root.setContentsMargins(18, 14, 18, 12)
        root.setSpacing(11)

        hero = QHBoxLayout()
        title = QVBoxLayout()
        title.setSpacing(1)
        title.addWidget(label("企业身份", "KnowledgeTitle"))
        title.addWidget(label(
            "股东按持股比例投票任免；身份决定可见范围和可执行操作",
            "KnowledgeSubtitle",
        ))
        hero.addLayout(title)
        hero.addStretch()
        self.identity_label = label("尚未登录", "CommunityIdentity")
        hero.addWidget(self.identity_label)
        self.refresh_button = QPushButton("刷新")
        self.refresh_button.setObjectName("GhostButton")
        self.refresh_button.clicked.connect(self.refresh)
        hero.addWidget(self.refresh_button)
        root.addLayout(hero)

        cards = QHBoxLayout()
        cards.setSpacing(10)
        self.card_role = StatCard("我的身份", "—", "", "由股东投票任免")
        self.card_shares = StatCard("股份权重", "0", "%", "用于计算投票效力")
        self.card_open = StatCard("进行中提案", "0", "项", "待股东表决")
        self.card_members = StatCard("在册成员", "0", "人", "含股东与员工")
        for card in (
            self.card_role,
            self.card_shares,
            self.card_open,
            self.card_members,
        ):
            cards.addWidget(card)
        root.addLayout(cards)

        self.tabs = QTabWidget()
        self.tabs.setObjectName("InnerTabs")

        member_page = QWidget()
        member_layout = QVBoxLayout(member_page)
        member_layout.setContentsMargins(0, 6, 0, 0)
        member_layout.setSpacing(8)
        member_head = QHBoxLayout()
        member_head.addWidget(SectionTitle("成员与企业身份"))
        member_head.addStretch()
        self.propose_button = QPushButton("发起任免提案")
        self.propose_button.setObjectName("PrimaryButton")
        self.propose_button.clicked.connect(self._propose)
        member_head.addWidget(self.propose_button)
        self.share_button = QPushButton("发起股份提案")
        self.share_button.setObjectName("GhostButton")
        self.share_button.clicked.connect(self._edit_shares)
        member_head.addWidget(self.share_button)
        member_layout.addLayout(member_head)
        self.member_table = self._make_table(
            ["成员", "企业身份", "部门 / 职务", "股份", "状态"]
        )
        self.member_table.itemSelectionChanged.connect(self._update_actions)
        self.member_table.doubleClicked.connect(lambda _: self._propose())
        member_layout.addWidget(self.member_table, 1)
        self.member_hint = muted("选择成员可发起任免或调整股份。")
        self.member_hint.setWordWrap(True)
        member_layout.addWidget(self.member_hint)
        self.tabs.addTab(member_page, "成员与身份")

        motion_page = QWidget()
        motion_layout = QVBoxLayout(motion_page)
        motion_layout.setContentsMargins(0, 6, 0, 0)
        motion_layout.setSpacing(8)
        motion_head = QHBoxLayout()
        motion_head.addWidget(SectionTitle("股东表决"))
        motion_head.addStretch()
        self.yes_button = QPushButton("赞成")
        self.yes_button.setObjectName("PrimaryButton")
        self.yes_button.clicked.connect(lambda: self._vote("yes"))
        self.no_button = QPushButton("反对")
        self.no_button.setObjectName("GhostButton")
        self.no_button.clicked.connect(lambda: self._vote("no"))
        self.abstain_button = QPushButton("弃权")
        self.abstain_button.setObjectName("GhostButton")
        self.abstain_button.clicked.connect(lambda: self._vote("abstain"))
        self.close_button = QPushButton("截止并计票")
        self.close_button.setObjectName("GhostButton")
        self.close_button.clicked.connect(self._close_vote)
        self.cancel_button = QPushButton("撤回提案")
        self.cancel_button.setObjectName("DangerButton")
        self.cancel_button.clicked.connect(self._cancel_vote)
        for button in (
            self.yes_button,
            self.no_button,
            self.abstain_button,
            self.close_button,
            self.cancel_button,
        ):
            motion_head.addWidget(button)
        motion_layout.addLayout(motion_head)
        self.motion_table = self._make_table(
            ["事项", "对象", "发起人", "股份票结果", "状态 / 截止"]
        )
        self.motion_table.itemSelectionChanged.connect(self._update_actions)
        motion_layout.addWidget(self.motion_table, 1)
        self.rule_label = muted(
            "出席率 = 已投票股份 / 全部有效股份；赞成率只按赞成与反对股份计算，"
            "弃权计入出席但不计入赞成。"
        )
        self.rule_label.setWordWrap(True)
        motion_layout.addWidget(self.rule_label)
        self.tabs.addTab(motion_page, "任免投票")

        role_page = QWidget()
        role_layout = QVBoxLayout(role_page)
        role_layout.setContentsMargins(0, 6, 0, 0)
        role_layout.setSpacing(8)
        role_layout.addWidget(SectionTitle("企业身份与权限目录"))
        self.role_text = QTextEdit()
        self.role_text.setReadOnly(True)
        self.role_text.setPlaceholderText("登录后加载企业身份目录")
        role_layout.addWidget(self.role_text, 1)
        self.tabs.addTab(role_page, "身份权限")

        self.role_template_page = RoleTemplatePage(self.window)
        self.tabs.addTab(self.role_template_page, "身份模板")

        self.board_point_page = BoardPointPage(self.window)
        self.tabs.addTab(self.board_point_page, "董事会与积分")

        root.addWidget(self.tabs, 1)
        self.status_label = label("登录后加载企业身份", "CommunityFeedStatus")
        root.addWidget(self.status_label)
        self._update_actions()

    def apply_account_session(self, session):
        changed = (
            self.session is not session
            or (self.session and session and self.session.user_id != session.user_id)
        )
        if self.session and session and self.session.user_id != session.user_id:
            self.snapshot = {}
        self.session = session
        self.role_template_page.apply_account_session(session)
        if hasattr(self, "board_point_page"):
            self.board_point_page.apply_account_session(session)
        if session is None:
            self.snapshot = {}
            self.identity_label.setText("尚未登录")
            self.status_label.setText("登录后可查看企业身份")
            self._render()
        elif changed or not self.snapshot:
            self.refresh()

    def on_activated(self):
        if self.session is not None:
            self.refresh(force=False)

    def shutdown(self):
        self.timer.stop()
        workers = list(self.workers)
        if hasattr(self, "board_point_page"):
            workers.extend(self.board_point_page.workers)
        for worker in workers:
            if worker.isRunning():
                worker.wait(12000)

    def _auto_refresh(self):
        if self.isVisible() and self.session is not None:
            self.refresh(force=False)

    def _client_session(self):
        session = self.session
        if session and session.is_expired():
            return CommunityClient().refresh(session)
        return session

    def _run(self, work, on_done, busy_text="处理中…"):
        if self.busy or self.session is None:
            return
        self.busy = True
        self.refresh_button.setEnabled(False)
        self.status_label.setText(busy_text)
        worker = CommunityWorker(work)
        self.workers.append(worker)

        def cleanup():
            self.busy = False
            self.refresh_button.setEnabled(True)
            if worker in self.workers:
                self.workers.remove(worker)
            worker.deleteLater()

        def failed(message):
            self.status_label.setText(message)
            QMessageBox.warning(self, "企业身份请求失败", message)

        worker.done.connect(on_done)
        worker.failed.connect(failed)
        worker.finished.connect(cleanup)
        worker.start()

    def refresh(self, force=True):
        if self.session is None:
            self._render()
            return
        if not force and time.time() - self._last_refresh < 8:
            return

        def work():
            session = self._client_session()
            client = CommunityClient()
            state = client.identity_state(session)
            templates = client.role_templates(session)
            return state, templates, session

        def done(result):
            state, templates, session = result
            if session is not self.session:
                self.session = session
                self.window.account_session = session
                self.window.window_settings_set(
                    "community_session", session.to_dict()
                )
            self.snapshot = state if isinstance(state, dict) else {}
            if not templates:
                templates = self.snapshot.get("templates", [])
            self.role_template_page.snapshot = {"templates": templates}
            self.role_template_page.render()
            self._last_refresh = time.time()
            if hasattr(self.window, "apply_identity_state"):
                self.window.apply_identity_state(self.snapshot)
            self._render()
            self.status_label.setText("已同步企业身份")

        self._run(work, done, "正在加载企业身份…")

    def _render(self):
        state = self.snapshot or {}
        me = state.get("me") or {}
        members = state.get("members") or []
        motions = state.get("motions") or []
        roles = state.get("roles") or []
        enterprise = state.get("enterprise") or {}

        if me:
            shares = float(me.get("share_percent") or 0)
            self.identity_label.setText(
                "{} · {} · {:.2f}%".format(
                    me.get("name") or "成员",
                    role_label(me.get("role_key")),
                    shares,
                )
            )
            self.card_role.update_values(
                role_label(me.get("role_key")), "",
                enterprise.get("name") or "企业身份",
            )
            self.card_shares.update_values(
                "{:.2f}".format(shares), "%",
                "股东" if me.get("is_shareholder") else "非股东",
            )
        else:
            self.identity_label.setText("尚未登录")
            self.card_role.update_values("—", "", "登录后加载")
            self.card_shares.update_values("0", "%", "登录后加载")

        open_count = sum(1 for motion in motions if motion.get("status") == "open")
        self.card_open.update_values(str(open_count), "项", "待股东表决")
        self.card_members.update_values(
            str(sum(1 for member in members if member.get("status") == "active")),
            "人",
            "{} 名股东".format(
                sum(1 for member in members if member.get("is_shareholder"))
            ),
        )

        self.member_table.setRowCount(0)
        for member in members:
            row = self.member_table.rowCount()
            self.member_table.insertRow(row)
            name = member.get("name") or "成员"
            if member.get("is_owner"):
                name += "（所有者）"
            values = [
                name,
                role_label(member.get("role_key")),
                " / ".join(
                    part for part in (
                        member.get("department"), member.get("title")
                    ) if part
                ) or "—",
                "{:.2f}%".format(float(member.get("share_percent") or 0))
                if member.get("is_shareholder") else "—",
                "在册" if member.get("status") == "active" else "停用",
            ]
            for column, text in enumerate(values):
                item = QTableWidgetItem(str(text))
                if column == 0:
                    item.setData(Qt.ItemDataRole.UserRole, member)
                self.member_table.setItem(row, column, item)
        self.member_table.resizeColumnsToContents()

        self.motion_table.setRowCount(0)
        for motion in motions:
            row = self.motion_table.rowCount()
            self.motion_table.insertRow(row)
            kind = {
                "appointment": "任命 / 调整",
                "removal": "免职",
                "share_change": "股份调整",
                "template_change": "身份模板变更",
            }.get(motion.get("kind"), motion.get("kind") or "事项")
            target = motion.get("target_name") or "企业"
            if motion.get("kind") == "share_change":
                target += " · 目标 {:.4f} 股".format(
                    float((motion.get("payload") or {}).get("shares") or 0)
                )
            elif motion.get("kind") == "template_change":
                target += " · " + str((motion.get("payload") or {}).get("template_key") or "模板")
            if motion.get("proposed_role_key"):
                target += " → " + role_label(motion.get("proposed_role_key"))
            result = "赞成 {:.2f}% · 出席 {:.2f}%".format(
                float(motion.get("yes_percent") or 0),
                float(motion.get("turnout_percent") or 0),
            )
            deadline = str(motion.get("closes_at") or "")[:16].replace("T", " ")
            status = STATUS_LABELS.get(motion.get("status"), motion.get("status") or "—")
            if motion.get("conflict_disclosed"):
                status += " · 已披露利益冲突"
            if motion.get("status") == "open":
                status += " · 截止 " + deadline
            else:
                status += " · " + (motion.get("decision_reason") or "")
            values = [
                kind,
                target,
                motion.get("proposer_name") or "—",
                result,
                status,
            ]
            for column, text in enumerate(values):
                item = QTableWidgetItem(str(text))
                if column == 0:
                    item.setData(Qt.ItemDataRole.UserRole, motion)
                self.motion_table.setItem(row, column, item)
        self.motion_table.resizeColumnsToContents()

        role_lines = []
        for role in roles:
            permissions = permission_list(role.get("permissions"))
            role_lines.append(
                "{}\n{}\n权限：{}\n".format(
                    role_label(role.get("key")),
                    role_description(role.get("key")) or role.get("description") or "",
                    permissions or "无",
                )
            )
        self.role_text.setPlainText("\n".join(role_lines))
        self.role_template_page.snapshot["members"] = members
        self.role_template_page.render()
        if hasattr(self, "board_point_page"):
            self.board_point_page.apply_snapshot(state)

        me_permissions = me.get("permissions") or []
        self.propose_button.setEnabled("identity.propose" in me_permissions)
        self.share_button.setEnabled("identity.manage_shares" in me_permissions)
        self._update_actions()

    def _selected_member(self):
        rows = self.member_table.selectionModel().selectedRows()
        if not rows:
            return None
        item = self.member_table.item(rows[0].row(), 0)
        return item.data(Qt.ItemDataRole.UserRole) if item else None

    def _selected_motion(self):
        rows = self.motion_table.selectionModel().selectedRows()
        if not rows:
            return None
        item = self.motion_table.item(rows[0].row(), 0)
        return item.data(Qt.ItemDataRole.UserRole) if item else None

    def _update_actions(self):
        me = (self.snapshot or {}).get("me") or {}
        permissions = me.get("permissions") or []
        motion = self._selected_motion()
        can_vote = bool(
            motion
            and motion.get("status") == "open"
            and motion.get("can_vote")
            and "identity.vote" in permissions
        )
        for button in (self.yes_button, self.no_button, self.abstain_button):
            button.setEnabled(can_vote)
        is_open = bool(motion and motion.get("status") == "open")
        self.close_button.setEnabled(is_open)
        self.cancel_button.setEnabled(
            is_open
            and (
                me.get("profile_id") == motion.get("proposer_profile_id")
                or me.get("is_owner")
            )
        )
        member = self._selected_member()
        self.share_button.setEnabled(
            bool(member and "identity.manage_shares" in permissions)
        )
        self.propose_button.setEnabled(
            bool(member and "identity.propose" in permissions)
        )

    def _run_action(self, action, success_text):
        def work():
            session = self._client_session()
            result = action(session)
            return result, CommunityClient().identity_state(session), session

        def done(result):
            _, state, session = result
            if session is not self.session:
                self.session = session
                self.window.account_session = session
                self.window.window_settings_set(
                    "community_session", session.to_dict()
                )
            self.snapshot = state if isinstance(state, dict) else {}
            self._last_refresh = time.time()
            if hasattr(self.window, "apply_identity_state"):
                self.window.apply_identity_state(self.snapshot)
            self._render()
            self.status_label.setText(success_text)
            self.window.flash(success_text, 3600)

        self._run(work, done, "正在提交…")

    def _propose(self):
        member = self._selected_member()
        if not member:
            QMessageBox.information(self, "先选成员", "请先在成员表里选择一个人。")
            return
        dialog = RoleMotionDialog(self, self.snapshot, member.get("profile_id"))
        if dialog.exec() != QDialog.DialogCode.Accepted or not dialog.data:
            return
        data = dialog.data
        self._run_action(
            lambda session: CommunityClient().propose_role_change(
                session,
                data["target_profile_id"],
                data["kind"],
                data["role_key"],
                data["department"],
                data["title"],
                data["reason"],
                data["days"],
                conflict_disclosed=data["conflict_disclosed"],
            ),
            "任免提案已发起，等待股东投票",
        )

    def _vote(self, choice):
        motion = self._selected_motion()
        if not motion:
            return
        self._run_action(
            lambda session: CommunityClient().cast_role_vote(
                session, motion.get("id"), choice
            ),
            "投票已提交",
        )

    def _close_vote(self):
        motion = self._selected_motion()
        if not motion:
            return
        answer = QMessageBox.question(
            self,
            "截止投票",
            "只有投票期结束或全部股东已投票时才能计票。现在继续吗？",
        )
        if answer != QMessageBox.StandardButton.Yes:
            return
        self._run_action(
            lambda session: CommunityClient().close_role_vote(
                session, motion.get("id")
            ),
            "投票已计票",
        )

    def _cancel_vote(self):
        motion = self._selected_motion()
        if not motion:
            return
        answer = QMessageBox.question(self, "撤回提案", "确定撤回这项任免提案吗？")
        if answer != QMessageBox.StandardButton.Yes:
            return
        self._run_action(
            lambda session: CommunityClient().cancel_role_vote(
                session, motion.get("id")
            ),
            "提案已撤回",
        )

    def _edit_shares(self):
        member = self._selected_member()
        if not member:
            return
        from PyQt6.QtWidgets import QInputDialog

        current = float(member.get("shares") or 0)
        shares, ok = QInputDialog.getDouble(
            self,
            "发起股份调整提案",
            "拟调整后的股份权重（将提交重大股东表决）：",
            current,
            0,
            1000000000,
            4,
        )
        if not ok:
            return
        reason, ok = QInputDialog.getText(
            self,
            "股份调整提案",
            "调整原因（股东投票时会看到）：",
        )
        if not ok or not reason.strip():
            QMessageBox.warning(self, "缺少原因", "股份调整必须填写原因。")
            return
        conflict = QMessageBox.question(
            self,
            "利益冲突披露",
            "你是否与该股份调整存在利益关系？",
        ) == QMessageBox.StandardButton.Yes
        self._run_action(
            lambda session: CommunityClient().propose_share_change(
                session, member.get("profile_id"), shares, reason.strip(),
                conflict_disclosed=conflict,
            ),
            "股份调整已提交重大股东表决",
        )



class PointPoolMotionDialog(QDialog):
    """Create a board point-pool motion."""

    def __init__(self, parent=None, point_state=None):
        super().__init__(parent)
        self.data = None
        self.setWindowTitle("发起积分池议案")
        self.setMinimumWidth(520)
        root = QVBoxLayout(self)
        root.setContentsMargins(20, 18, 20, 16)
        root.setSpacing(10)
        root.addWidget(label("董事会积分池议案", "DialogTitle"))
        root.addWidget(muted(
            "积分池按季度审批，董事长只能在剩余额度内发放；未选结转的余额默认关闭。"
        ))
        form = QFormLayout()
        quarter = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-Q") + str(
            (datetime.datetime.now(datetime.timezone.utc).month - 1) // 3 + 1
        )
        self.title_edit = QLineEdit(f"{quarter} 积分池")
        self.quarter_edit = QLineEdit(quarter)
        self.total_spin = QSpinBox()
        self.total_spin.setRange(1, 100000000)
        self.total_spin.setValue(1000)
        self.limit_spin = QSpinBox()
        self.limit_spin.setRange(1, 100000000)
        self.limit_spin.setValue(100)
        self.carry_edit = QLineEdit()
        self.carry_edit.setPlaceholderText("可选：上一积分池 UUID")
        pool = (point_state or {}).get("pool") or {}
        if pool.get("id"):
            self.carry_edit.setPlaceholderText(
                f"可选：{pool.get('quarter') or ''} {pool.get('id')}"
            )
        self.conflict_box = QCheckBox("我与该议案存在利益关系，已主动披露")
        form.addRow("议案标题", self.title_edit)
        form.addRow("季度", self.quarter_edit)
        form.addRow("新增额度", self.total_spin)
        form.addRow("单次上限", self.limit_spin)
        form.addRow("结转来源", self.carry_edit)
        form.addRow("利益冲突", self.conflict_box)
        root.addLayout(form)
        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save
            | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.button(QDialogButtonBox.StandardButton.Save).setText("提交董事会")
        buttons.button(QDialogButtonBox.StandardButton.Cancel).setText("取消")
        buttons.accepted.connect(self._save)
        buttons.rejected.connect(self.reject)
        root.addWidget(buttons)

    def _save(self):
        title = self.title_edit.text().strip()
        quarter = self.quarter_edit.text().strip().upper()
        if not title or not quarter:
            QMessageBox.warning(self, "缺少内容", "议案标题和季度不能为空。")
            return
        payload = {
            "quarter": quarter,
            "total_amount": self.total_spin.value(),
            "single_award_limit": self.limit_spin.value(),
        }
        carry = self.carry_edit.text().strip()
        if carry:
            payload["carry_from"] = carry
        self.data = {
            "title": title,
            "kind": "point_pool",
            "payload": payload,
            "conflict_disclosed": self.conflict_box.isChecked(),
        }
        self.accept()


class AwardPointsDialog(QDialog):
    """Chairperson award form with evidence and permanent-point context."""

    def __init__(self, parent=None, members=None):
        super().__init__(parent)
        self.data = None
        self.setWindowTitle("董事长发放积分")
        self.setMinimumWidth(520)
        root = QVBoxLayout(self)
        root.setContentsMargins(20, 18, 20, 16)
        root.setSpacing(10)
        root.addWidget(label("按证据发放积分", "DialogTitle"))
        form = QFormLayout()
        self.member_box = QComboBox()
        for member in members or []:
            if member.get("status") == "active":
                self.member_box.addItem(
                    f"{member.get('name') or '成员'} · {member.get('role_name') or ''}",
                    member.get("profile_id"),
                )
        self.amount_spin = QSpinBox()
        self.amount_spin.setRange(1, 100000000)
        self.amount_spin.setValue(10)
        self.evidence_box = QComboBox()
        self.evidence_box.addItems(["acceptance", "collaboration", "knowledge"])
        self.evidence_edit = QLineEdit()
        self.evidence_edit.setPlaceholderText("验收、协作或知识记录的 UUID")
        self.reason_edit = QTextEdit()
        self.reason_edit.setMaximumHeight(90)
        self.reason_edit.setPlaceholderText("说明发放依据")
        form.addRow("成员", self.member_box)
        form.addRow("积分", self.amount_spin)
        form.addRow("证据类型", self.evidence_box)
        form.addRow("证据 ID", self.evidence_edit)
        form.addRow("原因", self.reason_edit)
        root.addLayout(form)
        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save
            | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.button(QDialogButtonBox.StandardButton.Save).setText("发放")
        buttons.button(QDialogButtonBox.StandardButton.Cancel).setText("取消")
        buttons.accepted.connect(self._save)
        buttons.rejected.connect(self.reject)
        root.addWidget(buttons)

    def _save(self):
        evidence_id = self.evidence_edit.text().strip()
        reason = self.reason_edit.toPlainText().strip()
        if not self.member_box.currentData() or not evidence_id or not reason:
            QMessageBox.warning(self, "缺少内容", "成员、证据 ID 和原因都必须填写。")
            return
        self.data = {
            "profile_id": self.member_box.currentData(),
            "amount": self.amount_spin.value(),
            "evidence_type": self.evidence_box.currentText(),
            "evidence_id": evidence_id,
            "reason": reason,
        }
        self.accept()


class BoardPointPage(QWidget):
    """Board motions, chair awards, and permanent point history."""

    def __init__(self, window):
        super().__init__()
        self.window = window
        self.session = None
        self.snapshot = {}
        self.workers = []
        root = QVBoxLayout(self)
        root.setContentsMargins(0, 6, 0, 0)
        root.setSpacing(8)
        head = QHBoxLayout()
        head.addWidget(SectionTitle("董事会与积分"))
        head.addStretch()
        self.new_button = QPushButton("发起积分池议案")
        self.new_button.setObjectName("PrimaryButton")
        self.new_button.clicked.connect(self._create_motion)
        head.addWidget(self.new_button)
        self.yes_button = QPushButton("赞成")
        self.yes_button.setObjectName("GhostButton")
        self.yes_button.clicked.connect(lambda: self._vote("yes"))
        head.addWidget(self.yes_button)
        self.no_button = QPushButton("反对")
        self.no_button.setObjectName("GhostButton")
        self.no_button.clicked.connect(lambda: self._vote("no"))
        head.addWidget(self.no_button)
        self.abstain_button = QPushButton("弃权")
        self.abstain_button.setObjectName("GhostButton")
        self.abstain_button.clicked.connect(lambda: self._vote("abstain"))
        head.addWidget(self.abstain_button)
        self.finalize_button = QPushButton("截止并计票")
        self.finalize_button.setObjectName("GhostButton")
        self.finalize_button.clicked.connect(self._finalize)
        head.addWidget(self.finalize_button)
        root.addLayout(head)

        self.motion_table = QTableWidget(0, 6)
        self.motion_table.setHorizontalHeaderLabels(
            ["议案", "类型", "董事票数", "利益冲突", "状态", "发起人"]
        )
        self._style_table(self.motion_table)
        self.motion_table.itemSelectionChanged.connect(self._update_actions)
        root.addWidget(self.motion_table, 2)

        cards = QHBoxLayout()
        self.balance_card = StatCard("我的积分", "0", "分", "永久有效")
        self.pool_card = StatCard("本期积分池", "0", "分", "董事会审批")
        self.remaining_card = StatCard("剩余额度", "0", "分", "董事长发放")
        cards.addWidget(self.balance_card)
        cards.addWidget(self.pool_card)
        cards.addWidget(self.remaining_card)
        root.addLayout(cards)

        award_row = QHBoxLayout()
        award_row.addWidget(SectionTitle("积分发放与历史"))
        award_row.addStretch()
        self.award_button = QPushButton("董事长发放积分")
        self.award_button.setObjectName("PrimaryButton")
        self.award_button.clicked.connect(self._award)
        award_row.addWidget(self.award_button)
        root.addLayout(award_row)
        self.ledger_table = QTableWidget(0, 6)
        self.ledger_table.setHorizontalHeaderLabels(
            ["时间", "成员", "变动", "类型", "原因", "操作人"]
        )
        self._style_table(self.ledger_table)
        root.addWidget(self.ledger_table, 2)
        self.status = muted("登录后加载董事会与积分台账")
        root.addWidget(self.status)
        self._update_actions()

    @staticmethod
    def _style_table(table):
        table.verticalHeader().setVisible(False)
        table.setSelectionBehavior(
            QAbstractItemView.SelectionBehavior.SelectRows
        )
        table.setSelectionMode(
            QAbstractItemView.SelectionMode.SingleSelection
        )
        table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        table.setShowGrid(False)
        table.horizontalHeader().setStretchLastSection(True)

    def apply_account_session(self, session):
        self.session = session
        if session is None:
            self.snapshot = {}
            self.render()
        self._update_actions()

    def apply_snapshot(self, snapshot):
        self.snapshot = snapshot if isinstance(snapshot, dict) else {}
        self.render()

    def _selected_motion(self):
        rows = self.motion_table.selectionModel().selectedRows()
        if not rows:
            return None
        item = self.motion_table.item(rows[0].row(), 0)
        return item.data(Qt.ItemDataRole.UserRole) if item else None

    def render(self):
        me = (self.snapshot or {}).get("me") or {}
        points = (self.snapshot or {}).get("point_state") or {}
        pool = points.get("pool") or {}
        self.balance_card.update_values(str(points.get("balance", 0)), "分", "永久有效")
        self.pool_card.update_values(str(pool.get("total", 0)), "分", pool.get("quarter", "暂无积分池"))
        self.remaining_card.update_values(str(pool.get("remaining", 0)), "分", "董事长发放")

        motions = (self.snapshot or {}).get("board_motions") or []
        self.motion_table.setRowCount(0)
        for motion in motions:
            row = self.motion_table.rowCount()
            self.motion_table.insertRow(row)
            votes = "赞成 {} / 出席 {}".format(
                motion.get("yes_count", 0), motion.get("cast_count", 0)
            )
            values = [
                motion.get("title") or "董事会事项",
                "积分池" if motion.get("kind") == "point_pool" else (motion.get("kind") or ""),
                votes,
                "已披露" if motion.get("conflict_disclosed") else "未披露",
                STATUS_LABELS.get(motion.get("status"), motion.get("status") or ""),
                motion.get("proposer_name") or "—",
            ]
            for column, text in enumerate(values):
                item = QTableWidgetItem(str(text))
                if column == 0:
                    item.setData(Qt.ItemDataRole.UserRole, motion)
                self.motion_table.setItem(row, column, item)
        self.motion_table.resizeColumnsToContents()

        ledger = points.get("ledger") or []
        self.ledger_table.setRowCount(0)
        for entry in ledger:
            row = self.ledger_table.rowCount()
            self.ledger_table.insertRow(row)
            values = [
                str(entry.get("created_at") or "")[:16].replace("T", " "),
                entry.get("profile_name") or "成员",
                ("+" if int(entry.get("amount") or 0) > 0 else "") + str(entry.get("amount") or 0),
                entry.get("entry_type") or "",
                entry.get("reason") or "",
                entry.get("actor_name") or "系统",
            ]
            for column, text in enumerate(values):
                self.ledger_table.setItem(row, column, QTableWidgetItem(str(text)))
        self.ledger_table.resizeColumnsToContents()
        if points.get("can_read_full_ledger"):
            self.status.setText("董事会、审计和董事长可查看完整企业积分台账。")
        else:
            self.status.setText("当前身份只可查看自己的积分台账。")
        self._update_actions()

    def _update_actions(self):
        me = (self.snapshot or {}).get("me") or {}
        motion = self._selected_motion()
        board = bool(me.get("is_board_director"))
        self.new_button.setEnabled(board)
        can_vote = bool(board and motion and motion.get("can_vote"))
        for button in (self.yes_button, self.no_button, self.abstain_button):
            button.setEnabled(can_vote)
        self.finalize_button.setEnabled(bool(board and motion and motion.get("can_finalize")))
        self.award_button.setEnabled(bool(me.get("is_chairperson")))

    def _run(self, work, success_text):
        worker = CommunityWorker(work, self)
        self.workers.append(worker)
        def done(_):
            self.status.setText(success_text)
            if self.window is not None and hasattr(self.window, "identity_page"):
                self.window.identity_page.refresh(True)
        def cleanup():
            if worker in self.workers:
                self.workers.remove(worker)
            worker.deleteLater()
        worker.done.connect(done)
        worker.failed.connect(
            lambda message: QMessageBox.warning(self, "治理操作失败", message)
        )
        worker.finished.connect(cleanup)
        worker.start()

    def _create_motion(self):
        if self.session is None:
            return
        dialog = PointPoolMotionDialog(
            self, (self.snapshot or {}).get("point_state") or {}
        )
        if dialog.exec() != QDialog.DialogCode.Accepted or not dialog.data:
            return
        data = dialog.data
        self._run(
            lambda: CommunityClient().create_board_motion(
                self.session, data["title"], data["kind"], data["payload"],
                conflict_disclosed=data["conflict_disclosed"],
            ),
            "积分池议案已提交董事会",
        )

    def _vote(self, choice):
        motion = self._selected_motion()
        if not motion or self.session is None:
            return
        self._run(
            lambda: CommunityClient().cast_board_vote(
                self.session, motion.get("id"), choice
            ),
            "董事会投票已提交",
        )

    def _finalize(self):
        motion = self._selected_motion()
        if not motion or self.session is None:
            return
        self._run(
            lambda: CommunityClient().finalize_board_motion(
                self.session, motion.get("id")
            ),
            "董事会表决已计票",
        )

    def _award(self):
        if self.session is None:
            return
        me = (self.snapshot or {}).get("me") or {}
        members = [
            member for member in (self.snapshot or {}).get("members", [])
            if str(member.get("profile_id")) != str(me.get("profile_id"))
        ]
        dialog = AwardPointsDialog(self, members)
        if dialog.exec() != QDialog.DialogCode.Accepted or not dialog.data:
            return
        data = dialog.data
        self._run(
            lambda: CommunityClient().award_points(
                self.session, data["profile_id"], data["amount"],
                data["evidence_type"], data["evidence_id"], data["reason"],
            ),
            "积分已发放并写入永久台账",
        )
