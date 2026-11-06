"""项目记录器 —— 老板视图

一个窗口回答三个问题：
  1. 现在总共什么情况？（驾驶舱）
  2. 哪个项目要出事、凭什么这么说？（项目详情 + 预测依据）
  3. 人都在忙什么、谁快撑不住了？（员工负荷）

设计沿用「墨读」：中性灰骨架 + 粉红强调 + 灰紫说明文字，
分析面板式的信息组织，以及「每条结论都给出依据」的表达方式。

快捷键   Ctrl+N 新建项目   Ctrl+R 刷新   Ctrl+E 导出   F1 说明
"""
import datetime
import os
import sys

from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtGui import QAction, QColor, QFont, QIcon, QKeySequence
from PyQt6.QtWidgets import (
    QAbstractItemView, QApplication, QButtonGroup, QComboBox, QDialog,
    QDialogButtonBox, QDoubleSpinBox, QFileDialog, QFormLayout, QFrame,
    QHBoxLayout, QHeaderView, QInputDialog, QLabel, QLineEdit, QListWidget,
    QListWidgetItem, QMainWindow, QMenu, QMessageBox, QPushButton,
    QScrollArea, QSizePolicy, QSpinBox, QSplitter, QStyle,
    QStyledItemDelegate, QTableWidget, QTableWidgetItem, QTabWidget,
    QTextEdit, QToolButton, QVBoxLayout, QWidget,
)

import metrics
import rules
import theme
from chart import BarChart, LoadChart
from db import ASSIGN_STATUS, PRIORITY, PROJECT_STATUS, Store
from community_client import CommunityClient, CommunitySession
from community_ui import CommunityLoginDialog, CommunityWorker
from identity_rules import PermissionGrant, can_use_advanced_mode
from collaboration import CollaborationPage, EmployeeCloudPage
from detail import ImportDialog, ProjectDialog, SubmitWindow
from knowledge_planet import KnowledgePlanetPage
from identity_ui import IdentityPage, role_label
from today_ui import TodayPage
from decision_ui import DecisionCenterPage
from operations_ui import OperationsPage
from execution_ui import ExecutionPage
from intake_ui import IntakePage
from metrics import budget_usage, load_ratio, num, sum_hours
from server import DEFAULT_PORT, SubmitServer
from timer_ui import SessionListDialog, TimerBar
from widgets import (
    Badge, ChatBubble, HairLine, LevelDot, SectionTitle, StatCard,
    SuggestionChips, fmt_hours, fmt_money, label, level_color, muted,
)

APP_NAME = "项目记录器"
APP_SUBTITLE = "和伙伴一起，把每个项目变成一段可回看的冒险"
VERSION = "2.0"

LEVEL_ORDER = ["严重", "风险", "关注", "健康"]


def resource_path(*parts):
    """源码运行和 PyInstaller 打包后都能找到资源"""
    base = getattr(sys, "_MEIPASS", None)
    if not base:
        base = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(base, *parts)


def styled(widget):
    """纯 QWidget 要显式开启样式表背景，style.qss 里的背景与边框才会生效"""
    widget.setAttribute(Qt.WidgetAttribute.WA_StyledBackground, True)
    return widget


# ====================================================================== 驾驶舱
class DashboardPage(QWidget):
    """多项目总览：一眼看出哪个要出事"""

    def __init__(self, window):
        super().__init__()
        self.window = window
        self.rows = []

        root = QVBoxLayout(self)
        root.setContentsMargins(18, 16, 18, 14)
        root.setSpacing(14)

        # ---- 顶部四张卡 ----
        cards = QHBoxLayout()
        cards.setSpacing(12)
        self.card_projects = StatCard("在管项目", "0", "个", "含已交付")
        self.card_risk = StatCard("需要处理", "0", "个", "风险 + 严重")
        self.card_people = StatCard("在岗员工", "0", "人", "近 7 天有工时")
        self.card_hours = StatCard("本周工时", "0", "小时", "全员合计")
        for card in (self.card_projects, self.card_risk,
                     self.card_people, self.card_hours):
            card.setSizePolicy(QSizePolicy.Policy.Expanding,
                               QSizePolicy.Policy.Fixed)
            cards.addWidget(card)
        root.addLayout(cards)

        # ---- 筛选行 ----
        tools = QHBoxLayout()
        tools.setSpacing(8)
        tools.addWidget(SectionTitle("项目一览"))
        tools.addStretch()

        self.filter_box = QLineEdit()
        self.filter_box.setPlaceholderText("搜索项目 / 负责人 / 客户")
        self.filter_box.setFixedWidth(220)
        self.filter_box.textChanged.connect(self.refresh)
        tools.addWidget(self.filter_box)
        root.addLayout(tools)

        # ---- 项目表 ----
        self.table = QTableWidget(0, 9)
        self.table.setHorizontalHeaderLabels([
            "项目", "负责人", "状态", "风险", "进度",
            "剩余天数", "预算使用", "投入工时", "人数",
        ])
        self.table.verticalHeader().setVisible(False)
        self.table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.table.setShowGrid(False)
        self.table.setAlternatingRowColors(False)
        self.table.setSortingEnabled(True)
        self.table.itemDoubleClicked.connect(self._open_project)
        self.table.itemSelectionChanged.connect(self._on_select)
        header = self.table.horizontalHeader()
        header.setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        for column in range(1, 9):
            header.setSectionResizeMode(column, QHeaderView.ResizeMode.ResizeToContents)
        root.addWidget(self.table, 1)

        # ---- 选中项目的结论 ----
        self.advice = AdviceBox()
        root.addWidget(self.advice)

    # ---------- 刷新 ----------
    def refresh(self):
        keyword = self.filter_box.text().strip().lower()
        self.rows = rules.load_summary(self.window.store)
        if keyword:
            self.rows = [
                row for row in self.rows
                if keyword in (row["name"] or "").lower()
                or keyword in (row["owner"] or "").lower()
                or keyword in (row["client"] or "").lower()
            ]
        self._fill_table()
        self._fill_cards()

    def _fill_cards(self):
        all_rows = rules.load_summary(self.window.store)
        active = [row for row in all_rows if row["status"] != "已交付"]
        risks = [row for row in all_rows if row["level"] in ("风险", "严重")]
        self.card_projects.update_values(len(all_rows), "个",
                                         f"其中进行中 {len(active)} 个")
        self.card_risk.update_values(
            len(risks), "个",
            "有项目需要介入" if risks else "暂无高风险项目",
            color=level_color("风险") if risks else None,
        )

        today = datetime.date.today()
        week_ago = (today - datetime.timedelta(days=6)).isoformat()
        hours_rows = self.window.store.hours_by_employee(week_ago, today.isoformat())
        busy = [row for row in hours_rows if num(row["hours"]) > 0]
        total = sum_hours(hours_rows)
        self.card_people.update_values(len(busy), "人",
                                       f"共 {len(hours_rows)} 人在岗")
        self.card_hours.update_values(f"{total:,.0f}", "小时", "最近 7 天")

    def _fill_table(self):
        self.table.setSortingEnabled(False)
        self.table.setRowCount(len(self.rows))
        for index, row in enumerate(self.rows):
            self._fill_row(index, row)
        self.table.setSortingEnabled(True)

    def _fill_row(self, index, row):
        level = row["level"]
        cells = [
            (row["name"], None),
            (row["owner"] or "—", None),
            (row["status"], None),
            (level, level_color(level)),
            (f"{row['progress'] or 0}%", None),
            (self._days_left_text(row), None),
            (self._budget_text(row), None),
            (fmt_hours(row["hours"]), None),
            (f"{row['people']} 人", None),
        ]
        for column, (text, color) in enumerate(cells):
            item = QTableWidgetItem(str(text))
            if column in (4, 5, 6, 7, 8):
                item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
            if column == 3:
                item.setForeground(QColor(level_color(level)))
                font = item.font()
                font.setBold(True)
                item.setFont(font)
            if color and column != 3:
                item.setForeground(QColor(color))
            # 数据挂在第一列上，供双击时定位项目
            if column == 0:
                item.setData(Qt.ItemDataRole.UserRole, row["id"])
            self.table.setItem(index, column, item)

    @staticmethod
    def _days_left_text(row):
        days = row["days_left"]
        if days is None:
            return "—"
        days = int(days)
        if row["status"] == "已交付":
            return "已交付"
        if days < 0:
            return f"超期 {abs(days)} 天"
        return f"{days} 天"

    @staticmethod
    def _budget_text(row):
        """预算使用百分比。

        这里原先直接写 `cost / budget`，**没有除零保护**——
        只要有一个项目预算填 0，整个驾驶舱就会崩。
        现在统一走 metrics.budget_usage()，没设预算返回「—」。
        """
        usage = budget_usage(row)
        if not usage["has_budget"]:
            return "—"
        return f"{usage['used_ratio'] * 100:.0f}%"

    # ---------- 交互 ----------
    def _open_project(self, item):
        row = self.table.row(item)
        if 0 <= row < len(self.rows):
            self.window.open_project(self.rows[row]["id"])

    def _on_select(self):
        rows = {index.row() for index in self.table.selectedIndexes()}
        if not rows:
            return
        row_index = rows.pop()
        if 0 <= row_index < len(self.rows):
            project_id = self.rows[row_index]["id"]
            result = rules.predict(self.window.store, project_id)
            self.advice.show_result(result)

    def selected_project_id(self):
        rows = {index.row() for index in self.table.selectedIndexes()}
        if not rows:
            return None
        row_index = rows.pop()
        if 0 <= row_index < len(self.rows):
            return self.rows[row_index]["id"]
        return None


# ================================================================== 结论面板
class AdviceBox(QFrame):
    """预测结论：一句话结论 + 逐条依据 + 建议动作。

    这是整个软件的核心表达方式——不给你一个分数，给你理由。
    """

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("AdviceBox")
        layout = QVBoxLayout(self)
        layout.setContentsMargins(18, 14, 18, 14)
        layout.setSpacing(6)

        self.headline = label("选中一个项目，这里会给出预测和依据", "AdviceHeadline")
        self.headline.setWordWrap(True)
        layout.addWidget(self.headline)

        self.body = QLabel("")
        self.body.setObjectName("AdviceReason")
        self.body.setWordWrap(True)
        self.body.setTextFormat(Qt.TextFormat.PlainText)
        layout.addWidget(self.body)

        self.actions = QLabel("")
        self.actions.setObjectName("AdviceAction")
        self.actions.setWordWrap(True)
        layout.addWidget(self.actions)

    def show_result(self, result):
        if not result:
            self.headline.setText("选中一个项目，这里会给出预测和依据")
            self.body.setText("")
            self.actions.setText("")
            return
        self.headline.setText(f"【{result['level']}】{result['headline']}")

        lines = []
        for reason in result["reasons"]:
            detail = reason.get("detail", "")
            lines.append(f"· {reason['text']}" + (f"　（{detail}）" if detail else ""))
        self.body.setText("\n".join(lines))

        if result["actions"]:
            self.actions.setText(
                "建议：\n" + "\n".join(f"· {action}" for action in result["actions"])
            )
        else:
            self.actions.setText("")


# ====================================================================== 主窗口
class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.store = Store()

        # 局域网提交服务。先建好对象不启动——要不要开由用户决定，
        # 默默监听端口是不礼貌的，也会被防火墙拦下来还不知道为什么。
        self.server = SubmitServer(self.store, on_submit=None)
        self.server.bridge.submitted.connect(self._on_remote_submit)

        # 底部提示几秒后自动还原，先建好定时器，避免 flash() 用到未创建的属性
        self._flash_timer = QTimer(self)
        self._flash_timer.setSingleShot(True)
        self._flash_timer.timeout.connect(self._restore_hint)

        # 电脑版与手机版共用同一套 Supabase 账号。登录状态只保存令牌，
        # 不保存密码；没有登录时仍可继续使用本地项目数据。
        self.account_session = self._load_account_session()
        self.identity_state = {}

        self.setWindowTitle(APP_NAME)
        self.setWindowIcon(QIcon(resource_path("assets", "app_icon.ico")))
        self.setMinimumSize(1080, 680)
        self._build_menu()
        self._build_ui()
        self._restore_state()
        self._refresh_account_ui()
        self.refresh_all()

    def _on_remote_submit(self, who, message):
        """员工通过网页提交后自动刷新界面。

        这个函数由 Qt 信号触发，所以**运行在主线程**——
        服务线程不能直接碰控件，那样会随机崩溃。
        """
        self.refresh_all()
        self.flash(f"{who} 通过网页提交了工时", 4000)

    # ---------- 菜单 ----------
    def _build_menu(self):
        bar = self.menuBar()
        bar.setNativeMenuBar(False)

        file_menu = bar.addMenu("文件(&F)")
        act_new = QAction("新建项目", self)
        act_new.setShortcut("Ctrl+N")
        act_new.triggered.connect(self.new_project)
        file_menu.addAction(act_new)
        self.act_new = act_new
        act_knowledge = QAction("记录一条知识", self)
        act_knowledge.setShortcut("Ctrl+K")
        act_knowledge.triggered.connect(self.new_knowledge)
        file_menu.addAction(act_knowledge)
        file_menu.addSeparator()
        act_export = QAction("导出全部数据…", self)
        act_export.setShortcut("Ctrl+E")
        act_export.triggered.connect(self.export_data)
        file_menu.addAction(act_export)
        self.act_export = act_export
        file_menu.addSeparator()
        act_quit = QAction("退出", self)
        act_quit.setShortcut(QKeySequence.StandardKey.Quit)
        act_quit.triggered.connect(self.close)
        file_menu.addAction(act_quit)

        # 员工提交：老板开服务，员工用浏览器填
        self.menu_submit = bar.addMenu("员工提交(&S)")
        act_export_mine = QAction("导出我的工时…", self)
        act_export_mine.triggered.connect(self.export_my_hours)
        self.menu_submit.addAction(act_export_mine)
        act_import = QAction("导入员工提交…", self)
        act_import.setShortcut("Ctrl+I")
        act_import.triggered.connect(self.import_submissions)
        self.menu_submit.addAction(act_import)
        self.act_import = act_import
        act_snapshot = QAction("导出手机快照…", self)
        act_snapshot.setToolTip(
            "导出一份完整数据，发到手机上用「手机版」打开查看"
        )
        act_snapshot.triggered.connect(self.export_mobile_snapshot)
        self.menu_submit.addAction(act_snapshot)
        self.act_snapshot = act_snapshot
        self.menu_submit.addSeparator()
        act_server = QAction("开启局域网服务", self)
        act_server.setCheckable(True)
        act_server.triggered.connect(self.toggle_server)
        self.menu_submit.addAction(act_server)
        self.act_server = act_server
        act_show_url = QAction("显示服务地址…", self)
        act_show_url.triggered.connect(self.show_server_url)
        self.menu_submit.addAction(act_show_url)
        self.act_show_url = act_show_url
        act_port = QAction("设置服务端口…", self)
        act_port.triggered.connect(self.change_server_port)
        self.menu_submit.addAction(act_port)
        self.act_port = act_port
        self.menu_submit.addSeparator()
        act_sessions = QAction("查看计时明细…", self)
        act_sessions.triggered.connect(self.show_sessions)
        self.menu_submit.addAction(act_sessions)
        self.act_sessions = act_sessions
        self.management_actions = [
            (self.act_new, "projects.manage"),
            (self.act_export, "data.export_all"),
            (self.act_import, "worklogs.approve"),
            (self.act_snapshot, "data.export_all"),
            (self.act_server, "company.manage"),
            (self.act_show_url, "company.manage"),
            (self.act_port, "company.manage"),
            (self.act_sessions, "worklogs.approve"),
        ]

        account_menu = bar.addMenu("账号(&A)")
        self.act_account_login = QAction("登录手机版账号…", self)
        self.act_account_login.triggered.connect(self.login_account)
        account_menu.addAction(self.act_account_login)
        self.act_account_logout = QAction("退出账号", self)
        self.act_account_logout.triggered.connect(self.logout_account)
        account_menu.addAction(self.act_account_logout)

        view_menu = bar.addMenu("视图(&V)")
        act_refresh = QAction("刷新", self)
        act_refresh.setShortcut("Ctrl+R")
        act_refresh.triggered.connect(self.refresh_all)
        view_menu.addAction(act_refresh)
        view_menu.addSeparator()

        self.theme_actions = {}
        theme_menu = view_menu.addMenu("主题")
        from PyQt6.QtGui import QActionGroup
        group = QActionGroup(self)
        group.setExclusive(True)
        for key, text in (("light", "浅色"), ("dark", "深色")):
            action = QAction(text, self)
            action.setCheckable(True)
            action.triggered.connect(lambda _, k=key: self.change_theme(k))
            group.addAction(action)
            theme_menu.addAction(action)
            self.theme_actions[key] = action

        help_menu = bar.addMenu("帮助(&H)")
        act_help = QAction("使用说明", self)
        act_help.setShortcut("F1")
        act_help.triggered.connect(self.show_help)
        help_menu.addAction(act_help)
        act_about = QAction("关于", self)
        act_about.triggered.connect(self.show_about)
        help_menu.addAction(act_about)

    # ---------- 界面 ----------
    def _build_ui(self):
        central = QWidget()
        central.setObjectName("Root")
        styled(central)
        self.setCentralWidget(central)
        outer = QVBoxLayout(central)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(0)

        # ---- 顶栏 ----
        toolbar = QWidget()
        toolbar.setObjectName("ToolBar")
        styled(toolbar)
        top = QHBoxLayout(toolbar)
        top.setContentsMargins(18, 10, 18, 10)
        top.setSpacing(10)
        top.addWidget(label("冒险手账", "ToolMode"))
        top.addWidget(label(APP_NAME, "ToolTitle"))
        top.addWidget(label(APP_SUBTITLE, "ToolMeta"))
        top.addStretch()

        self.mode_button = QPushButton("切换到高级模式")
        self.mode_button.setObjectName("GhostButton")
        self.mode_button.setVisible(False)
        self.mode_button.clicked.connect(self._toggle_ui_mode)
        top.addWidget(self.mode_button)

        self.account_button = QPushButton("登录手机版账号")
        self.account_button.setObjectName("AccountButton")
        self.account_button.setToolTip(
            "电脑版与手机版使用同一个老板账号或员工号；登录一次即可同步社区身份"
        )
        self.account_button.clicked.connect(self._account_button_clicked)
        top.addWidget(self.account_button)

        self.risk_badge = Badge("", theme.palette()["fg_dim"])
        self.risk_badge.setVisible(False)
        top.addWidget(self.risk_badge)

        new_button = QPushButton("新建项目")
        new_button.setObjectName("PrimaryButton")
        new_button.clicked.connect(self.new_project)
        top.addWidget(new_button)
        self.new_project_button = new_button
        self.management_actions.append((new_button, "projects.manage"))
        outer.addWidget(toolbar)

        # ---- 主选项卡 ----
        self.tabs = QTabWidget()
        self.tabs.setObjectName("RootTabs")
        self.tabs.tabBar().setUsesScrollButtons(True)
        self.tabs.tabBar().setExpanding(True)
        self.today_page = TodayPage(self)
        self.today_tab = self.tabs.addTab(self.today_page, "◇ 今日")
        self.decision_page = DecisionCenterPage(self)
        self.decision_tab = self.tabs.addTab(self.decision_page, "⚖ 决策")
        self.operations_page = OperationsPage(self)
        self.operations_tab = self.tabs.addTab(self.operations_page, "◫ 经营")
        self.execution_page = ExecutionPage(self)
        self.execution_tab = self.tabs.addTab(self.execution_page, "⚔ 执行")
        self.intake_page = IntakePage(self)
        self.intake_tab = self.tabs.addTab(self.intake_page, "↗ 入口")
        self.dashboard = DashboardPage(self)
        self.tabs.addTab(self.dashboard, "◈ 驾驶舱")
        self.knowledge_page = KnowledgePlanetPage(self)
        self.tabs.addTab(self.knowledge_page, "✦ 星球")
        self.collaboration_page = CollaborationPage(self)
        self.tabs.addTab(self.collaboration_page, "◎ 协作")
        self.identity_page = IdentityPage(self)
        self.identity_tab = self.tabs.addTab(self.identity_page, "⚑ 身份")
        self.employee_cloud_page = EmployeeCloudPage(self)
        self.employee_cloud_tab = self.tabs.addTab(self.employee_cloud_page, "◉ 任务")
        self.tabs.setTabVisible(self.employee_cloud_tab, False)
        self.assistant_page = AssistantPage(self)
        self.tabs.addTab(self.assistant_page, "✦ 助手")
        self.employee_page = EmployeePage(self)
        self.tabs.addTab(self.employee_page, "人 员工")
        self.staffing_page = StaffingPage(self)
        self.tabs.addTab(self.staffing_page, "→ 分配")
        self.tabs.currentChanged.connect(self._on_tab_changed)
        outer.addWidget(self.tabs, 1)

        # ---- 计时条：常驻在选项卡下方 ----
        # 放这里而不是塞进某个页签——计时器只有唾手可得才会被真正使用。
        # 藏起来的话，员工干完活才想起来「忘了开」，整套设计就白做了。
        self.timer_bar = TimerBar(self)
        outer.addWidget(self.timer_bar)

        # ---- 状态栏 ----
        status = QWidget()
        status.setObjectName("StatusBar")
        styled(status)
        bottom = QHBoxLayout(status)
        bottom.setContentsMargins(18, 7, 18, 7)
        bottom.setSpacing(12)
        self.status_left = label("", "StatusFile")
        self.status_note = label("", "StatusMeta")
        self.status_hint = label(
            "Ctrl+N 新建    Ctrl+K 知识    Ctrl+R 刷新    Ctrl+E 导出    F1 说明",
            "StatusHint"
        )
        bottom.addWidget(self.status_left)
        bottom.addWidget(self.status_note)
        bottom.addStretch()
        bottom.addWidget(self.status_hint)
        outer.addWidget(status)

    # ---------- 统一账号 ----------
    def _load_account_session(self):
        raw = self._settings_get("community_session", {})
        if isinstance(raw, dict):
            return CommunitySession.from_dict(raw)
        return None

    def _identity_me(self):
        return (self.identity_state or {}).get("me") or {}

    def _has_identity_permission(self, *permissions):
        """Use fine-grained enterprise capabilities once identity state loads."""
        session = self.account_session
        if session is None:
            return True
        me = self._identity_me()
        granted = me.get("permissions")
        if isinstance(granted, list):
            return any(permission in granted for permission in permissions)
        # Before the identity RPC finishes, preserve the legacy owner experience.
        return session.role == "boss"

    def _management_action_allowed(self, permission):
        if self.account_session is None:
            return True
        return bool(
            self._effective_ui_mode() == "advanced"
            and self._has_identity_permission(permission)
        )

    def _ensure_management_action(self, permission):
        if self._management_action_allowed(permission):
            return True
        self.flash(
            "当前为简单模式或没有该管理权限，操作已阻止。",
            4200,
        )
        return False

    def _refresh_management_actions(self):
        for action, permission in getattr(self, "management_actions", []):
            action.setEnabled(self._management_action_allowed(permission))

    def _management_view(self):
        return self._has_identity_permission(
            "company.manage", "projects.view_all", "projects.manage",
            "people.view_all", "people.manage", "reports.view",
            "tasks.assign", "finance.view", "audit.read",
        )

    def _execution_view(self):
        return self._has_identity_permission(
            "company.manage", "projects.manage", "people.manage",
            "tasks.assign", "tasks.grade",
        )

    def _advanced_mode_allowed(self):
        """Advanced controls require management, finance, audit or governance authority."""
        if self.account_session is None:
            return False
        me = self._identity_me()
        permissions = me.get("permissions")
        if isinstance(permissions, list):
            return can_use_advanced_mode(
                [PermissionGrant(str(key)) for key in permissions]
            )
        # Preserve the legacy owner experience until the identity RPC resolves.
        return self.account_session.role == "boss"

    def _effective_ui_mode(self):
        """Return the persisted mode, but never trust it beyond current permissions."""
        if not self._advanced_mode_allowed():
            return "simple"
        preferred = str(self._identity_me().get("preferred_mode") or "simple")
        return "advanced" if preferred == "advanced" else "simple"

    def apply_identity_state(self, state):
        self.identity_state = state if isinstance(state, dict) else {}
        me = self._identity_me()
        if me and self.account_session is not None:
            self.account_session.profile["enterprise_role"] = me.get("role_key")
            self.account_session.profile["enterprise_role_name"] = me.get("role_name")
            self.account_session.profile["enterprise_permissions"] = me.get("permissions") or []
        self._refresh_account_ui()
        if (hasattr(self, "operations_page")
                and (self._effective_ui_mode() != "advanced" or not self._management_view())):
            self.operations_page.refresh()
        if (hasattr(self, "execution_page")
                and (self._effective_ui_mode() != "advanced" or not self._execution_view())):
            self.execution_page.refresh()
        self.intake_page.refresh()

    def _account_role_label(self):
        me = self._identity_me()
        if me.get("role_key"):
            return role_label(me.get("role_key"))
        if self.account_session is None:
            return "未登录"
        return "老板" if self.account_session.role == "boss" else "员工"

    def _refresh_account_ui(self):
        session = self.account_session
        logged = session is not None
        if hasattr(self, "account_button"):
            if logged:
                role = self._account_role_label()
                self.account_button.setText(f"{session.name} · {role}")
                self.account_button.setToolTip(
                    f"账号 {session.profile.get('code') or session.name}\n"
                    f"企业身份：{role}\n"
                    "电脑版与手机版共用此账号"
                )
            else:
                self.account_button.setText("登录手机版账号")
                self.account_button.setToolTip(
                    "使用手机版同一个老板账号或员工号登录"
                )
        if hasattr(self, "tabs"):
            mode = self._effective_ui_mode()
            advanced = mode == "advanced"
            management = bool(session and self._management_view())
            execution_view = bool(session and self._execution_view())
            employee_tasks = bool(session and not management and advanced)

            self.tabs.setTabVisible(self.today_tab, not advanced)
            self.tabs.setTabVisible(self.decision_tab, advanced and management)
            self.tabs.setTabVisible(self.operations_tab, advanced and management)
            self.tabs.setTabVisible(self.execution_tab, advanced and execution_view)
            self.tabs.setTabVisible(self.intake_tab, logged)
            if self.decision_page.session is not session:
                self.decision_page.apply_account_session(session)
            if self.operations_page.session is not session:
                self.operations_page.apply_account_session(session)
            if self.execution_page.session is not session:
                self.execution_page.apply_account_session(session)
            if self.intake_page.session is not session:
                self.intake_page.apply_account_session(session)
            self.tabs.setTabVisible(
                self.tabs.indexOf(self.knowledge_page), logged
            )
            for widget in (self.dashboard, self.collaboration_page,
                           self.assistant_page, self.employee_page,
                           self.staffing_page):
                self.tabs.setTabVisible(self.tabs.indexOf(widget), advanced)
            if hasattr(self, "identity_page"):
                self.tabs.setTabVisible(self.identity_tab, advanced)
                if self.identity_page.session is not session:
                    self.identity_page.apply_account_session(session)
            if hasattr(self, "employee_cloud_page"):
                self.tabs.setTabVisible(self.employee_cloud_tab, employee_tasks)
                self.employee_cloud_page.apply_account_session(
                    session if employee_tasks else None
                )
            if advanced and management:
                self.tabs.setCurrentWidget(self.decision_page)
            elif advanced:
                self.tabs.setCurrentWidget(self.dashboard)
            else:
                self.tabs.setCurrentWidget(self.today_page)
            self.today_page.apply_account_session(session)

        if hasattr(self, "mode_button"):
            self.mode_button.setVisible(logged and self._advanced_mode_allowed())
            self.mode_button.setText(
                "切换到简单模式"
                if self._effective_ui_mode() == "advanced"
                else "切换到高级模式"
            )

        if hasattr(self, "act_account_login"):
            self.act_account_login.setText(
                "切换手机版账号…" if logged else "登录手机版账号…"
            )
        if hasattr(self, "act_account_logout"):
            self.act_account_logout.setEnabled(logged)
        self._refresh_management_actions()

    def _toggle_ui_mode(self):
        if self.account_session is None:
            return
        target = "simple" if self._effective_ui_mode() == "advanced" else "advanced"
        if target == "advanced" and not self._advanced_mode_allowed():
            self.flash("当前身份没有高级模式权限", 3600)
            return
        worker = CommunityWorker(
            lambda: CommunityClient().set_ui_mode(self.account_session, target),
            self,
        )
        self._mode_worker = worker

        def done(result):
            mode = str((result or {}).get("mode") or target)
            self.identity_state.setdefault("me", {})["preferred_mode"] = mode
            self._refresh_account_ui()
            self.flash(
                "已切换到高级模式" if mode == "advanced" else "已回到简单模式",
                3000,
            )

        worker.done.connect(done)
        worker.failed.connect(lambda message: self.flash(str(message), 5000))
        worker.finished.connect(worker.deleteLater)
        worker.start()

    def _account_button_clicked(self):
        if self.account_session is None:
            self.login_account()
            return
        menu = QMenu(self)
        show_action = menu.addAction("查看当前账号")
        switch_action = menu.addAction("切换账号…")
        menu.addSeparator()
        logout_action = menu.addAction("退出账号")
        chosen = menu.exec(
            self.account_button.mapToGlobal(
                self.account_button.rect().bottomLeft()
            )
        )
        if chosen is show_action:
            session = self.account_session
            role = self._account_role_label()
            QMessageBox.information(
                self, "当前账号",
                f"姓名：{session.name}\n"
                f"身份：{role}\n"
                f"登录名：{session.profile.get('code') or '—'}\n\n"
                "电脑版与手机版共用这个账号。退出账号不会删除本地项目数据。",
            )
        elif chosen is switch_action:
            self.login_account()
        elif chosen is logout_action:
            self.logout_account()

    def login_account(self):
        dialog = CommunityLoginDialog(self)
        if dialog.exec() == QDialog.DialogCode.Accepted and dialog.session:
            self.set_account_session(dialog.session)
            self.apply_identity_state({})
            role = "老板" if dialog.session.role == "boss" else "员工"
            self.flash(f"已连接手机版账号：{dialog.session.name}（{role}）", 4200)

    def set_account_session(self, session):
        old_user = self.account_session.user_id if self.account_session else ""
        new_user = session.user_id if session else ""
        if old_user != new_user:
            self.identity_state = {}
        self.account_session = session
        self.window_settings_set(
            "community_session", session.to_dict() if session else {}
        )
        self._refresh_account_ui()
        if hasattr(self, "knowledge_page"):
            self.knowledge_page.community_page.apply_account_session(session)
        if hasattr(self, "collaboration_page"):
            self.collaboration_page.apply_account_session(session)
        if hasattr(self, "identity_page"):
            self.identity_page.apply_account_session(session)
        if hasattr(self, "decision_page"):
            self.decision_page.apply_account_session(session)
        if hasattr(self, "operations_page"):
            self.operations_page.apply_account_session(session)
        if hasattr(self, "execution_page"):
            self.execution_page.apply_account_session(session)
        if hasattr(self, "intake_page"):
            self.intake_page.apply_account_session(session)
        if hasattr(self, "today_page"):
            self.today_page.apply_account_session(session)
        if hasattr(self, "employee_cloud_page"):
            self.employee_cloud_page.apply_account_session(
                session if session and session.role == "employee" else None
            )

    def account_session_expired(self):
        self.set_account_session(None)
        self.flash("手机版账号登录已过期，请重新登录")

    def logout_account(self, confirm=True):
        if confirm:
            answer = QMessageBox.question(
                self, "退出账号",
                "退出后知识社区会隐藏，但本地项目、员工和工时数据不会被删除。\n"
                "确定退出账号吗？",
            )
            if answer != QMessageBox.StandardButton.Yes:
                return
        self.set_account_session(None)
        self.flash("已退出手机版账号，本地数据仍在")

    # ---------- 数据操作 ----------
    def refresh_all(self):
        self.today_page.refresh()
        self.decision_page.refresh()
        self.operations_page.refresh()
        self.execution_page.refresh()
        self.intake_page.refresh()
        self.dashboard.refresh()
        self.knowledge_page.refresh()
        self.employee_page.refresh()
        self.staffing_page.refresh()
        # 计时条也要刷：它自己的下拉里有项目和员工，
        # 别处新建了项目 / 加了员工之后这里必须跟着更新，
        # 否则计时条里选不到刚建的东西——之前漏了这一步。
        self.timer_bar.refresh_sources()
        self._refresh_status()

    def _refresh_status(self):
        self.status_left.setText(
            f"数据库：{self.store.path}"
        )
        rows = rules.load_summary(self.store)
        bad = [row for row in rows if row["level"] in ("风险", "严重")]
        self.status_note.setText(
            f"{len(rows)} 个项目 · {len(bad)} 个需要处理" if bad
            else f"{len(rows)} 个项目 · 暂无高风险"
        )
        if bad:
            self.risk_badge.set_level("风险")
            self.risk_badge.setText(f"{len(bad)} 个需处理")
            self.risk_badge.setVisible(True)
        else:
            self.risk_badge.setVisible(False)

    def open_project(self, project_id):
        dialog = ProjectDialog(self, project_id)
        dialog.exec()
        self.refresh_all()

    def new_project(self):
        if not self._ensure_management_action("projects.manage"):
            return
        dialog = ProjectDialog(self, None)
        if dialog.exec():
            self.refresh_all()

    def new_knowledge(self):
        self.tabs.setCurrentWidget(self.knowledge_page)
        self.knowledge_page.open_add()

    def _on_tab_changed(self, index):
        """切到知识星球时重算关联，保证别处新增项目后立即能选。"""
        if self.tabs.widget(index) is self.today_page:
            self.today_page.refresh()
        elif self.tabs.widget(index) is self.knowledge_page:
            self.knowledge_page.refresh()
        elif self.tabs.widget(index) is self.collaboration_page:
            self.collaboration_page.on_activated()
        elif self.tabs.widget(index) is self.employee_cloud_page:
            self.employee_cloud_page.refresh()
        elif hasattr(self, "identity_page") and self.tabs.widget(index) is self.identity_page:
            self.identity_page.on_activated()
        elif hasattr(self, "decision_page") and self.tabs.widget(index) is self.decision_page:
            self.decision_page.on_activated()
        elif hasattr(self, "operations_page") and self.tabs.widget(index) is self.operations_page:
            self.operations_page.on_activated()
        elif hasattr(self, "execution_page") and self.tabs.widget(index) is self.execution_page:
            self.execution_page.on_activated()
        elif hasattr(self, "intake_page") and self.tabs.widget(index) is self.intake_page:
            self.intake_page.on_activated()

    def export_data(self):
        if not self._ensure_management_action("data.export_all"):
            return
        import export
        path, _ = QFileDialog.getSaveFileName(
            self, "导出全部数据", "项目数据.xlsx", "Excel (*.xlsx);;CSV (*.csv)"
        )
        if not path:
            return
        try:
            count = export.export_all(self.store, path)
            self.flash(f"已导出 {count} 张表到 {os.path.basename(path)}")
        except Exception as error:
            QMessageBox.warning(self, "导出失败", str(error))

    def change_theme(self, name):
        """切换主题。

        全局样式表一换，自绘控件（四种图表、对话气泡）会收到
        StyleChange 事件并自己重画——它们继承/实现了
        ThemedWidget 或在自己的 changeEvent 里处理了。
        所以这里不需要挨个去刷。
        """
        theme.set_theme(name)
        app = QApplication.instance()
        if app is not None:
            app.setStyleSheet(load_stylesheet_text())
        for action_name, action in self.theme_actions.items():
            action.setChecked(action_name == name)
        self.refresh_all()
        # 计时条的颜色是按状态设的，让它自己按新配色重算一遍
        if hasattr(self, "timer_bar"):
            self.timer_bar.refresh()
        self.window_settings_set("theme", name)

    def flash(self, text, milliseconds=2600):
        self.status_hint.setText(text)
        self._flash_timer.start(milliseconds)

    def _restore_hint(self):
        prefix = "提交服务已开启　|　" if self.server.running else ""
        self.status_hint.setText(
            prefix + "Ctrl+N 新建    Ctrl+K 知识    Ctrl+R 刷新    Ctrl+E 导出    F1 说明"
        )

    # ---------- 员工提交 ----------
    def export_my_hours(self):
        """员工给自己导出工时文件。"""
        dialog = SubmitWindow(self)
        # 接着上次选的人
        saved = self._settings_get("submit_employee")
        if saved is not None:
            index = dialog.f_employee.findData(saved)
            if index >= 0:
                dialog.f_employee.setCurrentIndex(index)
        dialog.exec()
        self.refresh_all()

    def import_submissions(self):
        """老板导入员工发来的文件，可以一次选多个。"""
        if not self._ensure_management_action("worklogs.approve"):
            return
        paths, _ = QFileDialog.getOpenFileNames(
            self, "选择员工发来的工时文件", os.path.expanduser("~"),
            "工时文件 (*.json);;所有文件 (*)",
        )
        if not paths:
            return
        ImportDialog(self, paths).exec()
        self.refresh_all()

    def export_mobile_snapshot(self):
        """导出完整快照给手机版用。

        手机上跑不了 SQLite，所以数据得整个带过去。
        导出的是**只读镜像**——手机上做的改动通过「员工工时文件」回传，
        走的是已有的导入去重流程，不会覆盖电脑上的数据。
        """
        if not self._ensure_management_action("data.export_all"):
            return
        import submit

        if not self.store.projects():
            QMessageBox.information(
                self, "还没有数据",
                "先建一个项目再导出，否则手机上打开是空的。",
            )
            return

        default = os.path.join(os.path.expanduser("~"), "Desktop",
                               submit.snapshot_filename())
        path, _ = QFileDialog.getSaveFileName(
            self, "导出手机快照", default, "快照文件 (*.json)"
        )
        if not path:
            return
        if not path.lower().endswith(".json"):
            path += ".json"

        data, error = submit.write_snapshot(self.store, path)
        if data is None:
            QMessageBox.warning(self, "导出失败", error)
            return

        QMessageBox.information(
            self, "导出完成",
            f"已保存到：\n{path}\n\n"
            f"含 {len(data['projects'])} 个项目、"
            f"{len(data['employees'])} 名员工、"
            f"{len(data['worklogs'])} 条工时。\n\n"
            "把文件发到手机，用手机版 App 导入即可查看。\n"
            "手机是只读镜像；在手机上记的工时会导回文件，"
            "再由你在电脑上「导入员工提交」收进来，不会覆盖这边的数据。"
        )
        self.flash("已导出手机快照")

    def show_sessions(self):
        """看计时明细：时长和起止时间对不对得上，一眼能查。"""
        if not self._ensure_management_action("worklogs.approve"):
            return
        employee_id = self.timer_bar.f_employee.currentData()
        if employee_id is None:
            QMessageBox.information(self, "还没有人", "先在「员工与工时」里加一个员工。")
            return
        today = datetime.date.today()
        SessionListDialog(
            self, self.store, employee_id,
            (today - datetime.timedelta(days=30)).isoformat(), today.isoformat(),
        ).exec()

    # ---------- 局域网服务 ----------
    def toggle_server(self):
        """开 / 关提交服务。菜单项是 checkable 的，状态跟着实际结果走。"""
        if not self._ensure_management_action("company.manage"):
            return
        if self.server.running:
            self.server.stop()
            self.act_server.setChecked(False)
            self.act_server.setText("开启提交服务")
            self.flash("提交服务已关闭")
            return

        ok, message = self.server.start()
        if not ok:
            self.act_server.setChecked(False)
            QMessageBox.warning(self, "开启失败", message)
            return
        self.act_server.setChecked(True)
        self.act_server.setText("关闭提交服务")
        self.flash("提交服务已开启，点「显示提交地址」看网址")
        self.show_server_url()

    def show_server_url(self):
        """把网址显示出来，方便复制发给员工。"""
        if not self._ensure_management_action("company.manage"):
            return
        if not self.server.running:
            QMessageBox.information(
                self, "提交服务未开启",
                "先在「员工提交」菜单里点「开启提交服务」。",
            )
            return
        url = self.server.url()
        box = QMessageBox(self)
        box.setWindowTitle("员工提交地址")
        box.setText(
            "把这行地址发给员工，他们在浏览器里打开就能提交：\n\n"
            f"{url}\n\n"
            "员工不需要安装任何东西。\n"
            "需要你和员工在同一个局域网（同一个 WiFi 或同一根网线）。"
        )
        # 加个复制按钮，省得手抄一长串地址
        copy = box.addButton("复制地址", QMessageBox.ButtonRole.ActionRole)
        box.addButton("关闭", QMessageBox.ButtonRole.RejectRole)
        box.exec()
        if box.clickedButton() is copy:
            QApplication.clipboard().setText(url)
            self.flash("地址已复制")

    def change_server_port(self):
        """换端口。原端口被占用时用得上。"""
        if not self._ensure_management_action("company.manage"):
            return
        was_running = self.server.running
        if was_running:
            self.server.stop()
            self.act_server.setChecked(False)
            self.act_server.setText("开启提交服务")

        current = self.server.port
        value, ok = QInputDialog.getInt(
            self, "设置端口",
            "员工提交服务的端口号（1024~65535）：\n"
            "一般不用改。如果开启时提示端口被占用，换个数字试试。",
            current, 1024, 65535, 1,
        )
        if not ok:
            return
        self.server.port = value
        self.window_settings_set("server_port", value)
        if was_running:
            # 之前是开着的，用新端口重新开
            self.toggle_server()
        else:
            self.flash(f"端口已设为 {value}")

    def show_help(self):
        QMessageBox.information(
            self, "使用说明",
            "驾驶舱：所有项目一览，双击一行进入详情。\n"
            "　　　　选中一行，下方会给出这个项目的预测和依据。\n\n"
            "项目详情：步骤、能力与资源评估、指标趋势曲线、预测全文。\n\n"
            "员工与工时：录工时、看每个人的负荷。\n"
            "任务分配：把员工挂到项目的某一步上，计划工时和实际工时对比。\n\n"
            "员工提交：在「员工提交」菜单里开启服务，把网址发给员工，\n"
            "　　　　　他们用浏览器填工时、勾完成，你这边会自动刷新。\n\n"
            "预测全部由本机规则算出，不联网、不上传，"
            "每条结论都能追溯到具体数字。",
        )

    def show_about(self):
        QMessageBox.about(
            self, f"关于 {APP_NAME}",
            f"<b>{APP_NAME}</b> {VERSION}<br>{APP_SUBTITLE}<br><br>"
            "项目、员工和工时数据默认存在本机。<br>"
            "电脑版与手机版共用一套 Supabase 账号；"
            "登录后可同步知识星球社区。<br>"
            "预测由本地规则引擎计算，可复现、可追溯。",
        )

    # ---------- 窗口设置 ----------
    def _settings_path(self):
        from db import DB_DIR
        return os.path.join(DB_DIR, "settings.json")

    def window_settings_set(self, key, value):
        import json
        path = self._settings_path()
        data = {}
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            data = {}
        data[key] = value
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=1)
        except OSError:
            pass

    def _settings_get(self, key, default=None):
        """读一个设置项。读不到就返回默认值，不抛异常。"""
        import json
        try:
            with open(self._settings_path(), "r", encoding="utf-8") as f:
                return json.load(f).get(key, default)
        except (OSError, ValueError):
            return default

    def _restore_state(self):
        import json
        path = self._settings_path()
        theme_name = "light"
        port = DEFAULT_PORT
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            theme_name = str(data.get("theme", "light"))
            port = int(data.get("server_port", DEFAULT_PORT) or DEFAULT_PORT)
        except (OSError, ValueError, TypeError):
            pass
        theme.set_theme(theme_name)
        for action_name, action in self.theme_actions.items():
            action.setChecked(action_name == theme_name)
        # 端口沿用上次设置；服务本身不自动开启
        if 1024 <= port <= 65535:
            self.server.port = port
        self.resize(1180, 760)

    def closeEvent(self, event):
        # 先停社区网络线程和局域网服务，再关库：
        # 否则后台线程可能正拿着已经关掉的控件或连接继续工作。
        if hasattr(self, "knowledge_page"):
            self.knowledge_page.community_page.shutdown()
        if hasattr(self, "collaboration_page"):
            self.collaboration_page.shutdown()
        if hasattr(self, "identity_page"):
            self.identity_page.shutdown()
        if hasattr(self, "employee_cloud_page"):
            self.employee_cloud_page.shutdown()
        if hasattr(self, "operations_page"):
            self.operations_page.shutdown()
        if hasattr(self, "execution_page"):
            self.execution_page.shutdown()
        if hasattr(self, "intake_page"):
            self.intake_page.shutdown()
        if self.server.running:
            self.server.stop()
        self.store.close()
        super().closeEvent(event)


# ==================================================================== 小助手
class AssistantPage(QWidget):
    """小助手：用自然语言问项目情况。

    引擎是 rules.ask()，纯关键词匹配，不联网。
    所以这一页不是「聊天玩具」——它每一句回答都来自真实查询，
    答不上来会直接说能问什么，不会编。
    """

    def __init__(self, window):
        super().__init__()
        self.window = window
        self._history = []      # 记住问答，供「导出对话」用

        root = QVBoxLayout(self)
        root.setContentsMargins(18, 16, 18, 14)
        root.setSpacing(10)

        head = QHBoxLayout()
        head.addWidget(SectionTitle("问项目情况"))
        head.addStretch()
        export = QToolButton()
        export.setObjectName("TextButton")
        export.setText("导出对话")
        export.setToolTip("把这次问答存成文本，方便贴给别人或存档")
        export.clicked.connect(self._export)
        head.addWidget(export)
        clear = QToolButton()
        clear.setObjectName("TextButton")
        clear.setText("清空对话")
        clear.clicked.connect(self.clear)
        head.addWidget(clear)
        root.addLayout(head)

        # ---- 主动发现：不用提问，直接让它看一遍 ----
        scan_row = QHBoxLayout()
        scan_row.setSpacing(8)
        scan_row.addWidget(label("主动发现", "PanelHeading"))
        for text, question, tip in (
            ("比一比", "比一比",
             "横向比较：哪个项目投入大产出小、谁被摊到太多项目上"),
            ("找矛盾", "找矛盾",
             "逻辑检查：状态填错、顺序乱了、工时对不上分配"),
            ("全部看一遍", "帮我看看有什么问题",
             "两组都跑，把它们发现的问题一次列出来"),
        ):
            button = QToolButton()
            button.setObjectName("TextButton")
            button.setText(text)
            button.setToolTip(tip)
            button.clicked.connect(lambda _, q=question: self.ask_now(q))
            scan_row.addWidget(button)
        scan_row.addStretch()
        root.addLayout(scan_row)

        # ---- 对话区 ----
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setFrameShape(QScrollArea.Shape.NoFrame)
        self.scroll.setObjectName("ChatArea")
        self.scroll.setStyleSheet(
            f"#ChatArea {{ background-color: {theme.palette()['bg_read']};"
            f" border: 1px solid {theme.palette()['line']};"
            f" border-radius: 10px; }}"
        )
        holder = QWidget()
        holder.setObjectName("ChatHolder")
        holder.setStyleSheet("background: transparent;")
        self.chat_layout = QVBoxLayout(holder)
        self.chat_layout.setContentsMargins(14, 14, 14, 14)
        self.chat_layout.setSpacing(10)
        self.chat_layout.addStretch()
        self.scroll.setWidget(holder)
        root.addWidget(self.scroll, 1)

        # ---- 建议问题 ----
        self.chips = SuggestionChips(rules.SUGGESTIONS, self.ask_now)
        root.addWidget(self.chips)

        # ---- 输入行 ----
        row = QHBoxLayout()
        row.setSpacing(8)
        self.input = QLineEdit()
        self.input.setPlaceholderText(
            "问点什么，例如「智慧园区二期怎么样」「李工最近做了什么」"
        )
        self.input.returnPressed.connect(self._submit)
        row.addWidget(self.input, 1)
        send = QPushButton("发送")
        send.setObjectName("PrimaryButton")
        send.clicked.connect(self._submit)
        row.addWidget(send)
        root.addLayout(row)

        self.say(
            "我是本地小助手，不联网。\n"
            "能回答下面这些问题，也可以在左边点「比一比」「找矛盾」"
            "让我主动看一遍——那不需要你事先知道要问什么。\n"
            "回答里每个数字都来自你库里的真实数据。",
            is_user=False,
        )

    # ------------------------------------------------------------ 对话
    def say(self, text, is_user):
        bubble = ChatBubble(text, is_user)
        if is_user:
            self.chat_layout.addWidget(bubble)
        else:
            row = QHBoxLayout()
            row.addWidget(bubble, 4)
            row.addStretch(1)
            container = QWidget()
            container.setStyleSheet("background: transparent;")
            container.setLayout(row)
            self.chat_layout.addWidget(container)
        self._history.append((is_user, text))
        # 滚到底，否则新回答在视野外
        QTimer.singleShot(30, self._scroll_to_bottom)

    def _scroll_to_bottom(self):
        bar = self.scroll.verticalScrollBar()
        bar.setValue(bar.maximum())

    def _submit(self):
        question = self.input.text().strip()
        if not question:
            return
        self.input.clear()
        self.ask_now(question)

    def ask_now(self, question):
        """问一句并显示回答。建议按钮也走这里。"""
        self.say(question, is_user=True)
        try:
            answer = rules.ask(self.window.store, question)
        except Exception as error:
            answer = f"查询时出错：{type(error).__name__}: {error}"
        self.say(answer, is_user=False)
        self.window.flash("已回答")

    def clear(self):
        while self.chat_layout.count() > 1:
            item = self.chat_layout.takeAt(0)
            widget = item.widget()
            if widget is not None:
                widget.deleteLater()
        self._history.clear()
        self.say("对话已清空。下面这几类问题我都能答：", is_user=False)

    def _export(self):
        """把这次问答存成文本"""
        if not self._history:
            self.window.flash("还没有问答可以导出")
            return
        default = f"小助手问答_{datetime.date.today().isoformat()}.txt"
        path, _ = QFileDialog.getSaveFileName(
            self, "导出对话", default, "文本文件 (*.txt)"
        )
        if not path:
            return
        try:
            count = rules.export_conversation(self.window.store, self._history, path)
            self.window.flash(f"已导出 {count} 条问答到 {os.path.basename(path)}")
        except OSError as error:
            QMessageBox.warning(self, "导出失败", str(error))

    # 主窗口刷新时更新建议问题：固定列表 + 根据当前数据的紧急提示
    def refresh(self):
        try:
            urgent = rules.urgent_suggestions(self.window.store)
        except Exception:
            urgent = []
        self.chips.set_suggestions(list(rules.SUGGESTIONS) + urgent)


# ================================================================== 员工与工时
class EmployeePage(QWidget):
    """左边员工名单和负荷，右边录工时、看工时明细。

    负荷率是这一页的核心：光看「谁干得多」没意义，
    要看「他相对自己的周工时基准干到了几成」。
    """

    def __init__(self, window):
        super().__init__()
        self.window = window
        self.rows = []

        root = QVBoxLayout(self)
        root.setContentsMargins(18, 16, 18, 14)
        root.setSpacing(12)

        # 时间范围
        head = QHBoxLayout()
        head.setSpacing(6)
        head.addWidget(SectionTitle("员工与工时"))
        head.addStretch()
        self.range_group = QButtonGroup(self)
        self.range_group.setExclusive(True)
        for index, (text, days) in enumerate((("近 7 天", 7), ("近 30 天", 30), ("近 90 天", 90))):
            button = QToolButton()
            button.setObjectName("ScopeButton")
            button.setText(text)
            button.setCheckable(True)
            button.setChecked(index == 0)
            button.setProperty("days", days)
            self.range_group.addButton(button, index)
            head.addWidget(button)
        self.range_group.idClicked.connect(lambda _: self.refresh())
        root.addLayout(head)

        splitter = QSplitter(Qt.Orientation.Horizontal)
        splitter.setChildrenCollapsible(False)
        splitter.setHandleWidth(5)

        # ---- 左：员工负荷 ----
        left = QWidget()
        left.setObjectName("SidePanel")
        styled(left)
        left_layout = QVBoxLayout(left)
        left_layout.setContentsMargins(12, 12, 10, 12)
        left_layout.setSpacing(8)
        left_layout.addWidget(label("负荷", "PanelHeading"))

        self.load_chart = LoadChart()
        self.load_chart.set_empty("选一个时间范围后显示负荷")
        self.load_chart.setMinimumHeight(120)
        left_layout.addWidget(self.load_chart)

        self.emp_list = QListWidget()
        self.emp_list.setWordWrap(True)
        self.emp_list.currentRowChanged.connect(self._on_employee_changed)
        left_layout.addWidget(self.emp_list, 1)

        buttons = QHBoxLayout()
        add = QToolButton()
        add.setObjectName("TextButton")
        add.setText("新增员工")
        add.clicked.connect(self._add_employee)
        buttons.addWidget(add)
        edit = QToolButton()
        edit.setObjectName("TextButton")
        edit.setText("编辑")
        edit.clicked.connect(self._edit_employee)
        buttons.addWidget(edit)
        buttons.addStretch()
        left_layout.addLayout(buttons)
        splitter.addWidget(left)

        # ---- 右：工时 ----
        right = QWidget()
        right_layout = QVBoxLayout(right)
        right_layout.setContentsMargins(10, 0, 0, 0)
        right_layout.setSpacing(10)

        tool_row = QHBoxLayout()
        tool_row.addWidget(label("工时记录", "PanelHeading"))
        tool_row.addStretch()
        log = QPushButton("录入工时")
        log.setObjectName("PrimaryButton")
        log.clicked.connect(self._add_worklog)
        tool_row.addWidget(log)
        # 编辑只在老板端提供——员工不能改自己的计时结果
        edit = QPushButton("编辑选中")
        edit.setObjectName("GhostButton")
        edit.setToolTip("改小时数、项目、日期。员工的计时结果不该由他自己改，"
                        "所以这个入口只在老板端有。")
        edit.clicked.connect(self._edit_worklog)
        tool_row.addWidget(edit)
        remove = QPushButton("删除选中")
        remove.setObjectName("DangerButton")
        remove.clicked.connect(self._delete_worklog)
        tool_row.addWidget(remove)
        right_layout.addLayout(tool_row)

        self.work_table = QTableWidget(0, 5)
        self.work_table.setHorizontalHeaderLabels(["日期", "员工", "项目", "工时", "内容"])
        self.work_table.verticalHeader().setVisible(False)
        self.work_table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.work_table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.work_table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.work_table.setShowGrid(False)
        header = self.work_table.horizontalHeader()
        header.setSectionResizeMode(4, QHeaderView.ResizeMode.Stretch)
        for column in (0, 1, 2, 3):
            header.setSectionResizeMode(column, QHeaderView.ResizeMode.ResizeToContents)
        right_layout.addWidget(self.work_table, 1)

        self.work_hint = muted("")
        right_layout.addWidget(self.work_hint)
        splitter.addWidget(right)

        splitter.setStretchFactor(0, 0)
        splitter.setStretchFactor(1, 1)
        splitter.setSizes([300, 780])
        root.addWidget(splitter, 1)

    # ---------- 数据 ----------
    def _days(self):
        button = self.range_group.checkedButton()
        return int(button.property("days")) if button else 7

    def _range(self):
        today = datetime.date.today()
        return ((today - datetime.timedelta(days=self._days() - 1)).isoformat(),
                today.isoformat())

    def refresh(self):
        date_from, date_to = self._range()
        self.rows = [dict(row) for row in
                     self.window.store.hours_by_employee(date_from, date_to)]
        self._fill_employees()
        self._fill_worklogs()
        self._sync_title()

    def _fill_employees(self):
        current = self.emp_list.currentRow()
        self.emp_list.blockSignals(True)
        self.emp_list.clear()
        for row in self.rows:
            hours = num(row["hours"])
            ratio = load_ratio(hours, row["weekly_hours"], self._days())
            entry = QListWidgetItem(
                f"{row['name']}　{hours:.1f} 小时\n"
                f"负荷 {ratio * 100:.0f}%"
                + ("　← 超了" if ratio > 1 else "")
            )
            entry.setData(Qt.ItemDataRole.UserRole, row)
            if ratio > 1:
                entry.setForeground(QColor(level_color("风险")))
            self.emp_list.addItem(entry)
        self.emp_list.blockSignals(False)
        if 0 <= current < self.emp_list.count():
            self.emp_list.setCurrentRow(current)
        elif self.emp_list.count():
            self.emp_list.setCurrentRow(0)

        self._fill_load_chart()

    def _fill_load_chart(self):
        """负荷条形图。按负荷从高到低排——最该关注的排在最上面。"""
        days = self._days()
        rows = []
        for row in self.rows:
            rows.append({
                "name": row["name"],
                "hours": num(row["hours"]),
                "ratio": load_ratio(num(row["hours"]), row["weekly_hours"], days),
            })
        rows.sort(key=lambda item: -item["ratio"])
        self.load_chart.set_rows(rows)
        # 高度跟着人数走，人少时不留一大片空白
        height = self.load_chart.sizeHint().height()
        self.load_chart.setFixedHeight(min(max(height, 120), 260))

    def _sync_title(self):
        date_from, date_to = self._range()
        total = sum_hours(self.rows)
        self.window.status_note.setText(
            f"{date_from} ~ {date_to} · 合计 {total:,.1f} 小时"
        )

    def _fill_worklogs(self):
        row_index = self.emp_list.currentRow()
        employee_id = None
        if 0 <= row_index < len(self.rows):
            employee_id = self.rows[row_index]["id"]
        date_from, date_to = self._range()
        logs = self.window.store.worklogs(
            employee_id=employee_id, date_from=date_from, date_to=date_to
        )
        self.work_table.setRowCount(len(logs))
        for index, log in enumerate(logs):
            values = [log["work_date"], log["employee_name"] or "",
                      log["project_name"] or "非项目",
                      f"{float(log['hours']):.1f}", log["content"] or ""]
            for column, text in enumerate(values):
                item = QTableWidgetItem(text)
                if column in (0, 3):
                    item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
                if column == 0:
                    item.setData(Qt.ItemDataRole.UserRole, log["id"])
                self.work_table.setItem(index, column, item)

        if employee_id is None:
            self.work_hint.setText("左侧选一个人，这里只看他的工时。")
        else:
            total = sum(float(log["hours"]) for log in logs)
            self.work_hint.setText(f"这个人这段时间共 {len(logs)} 条、{total:.1f} 小时。")

    def _on_employee_changed(self, _row):
        self._fill_worklogs()

    # ---------- 操作 ----------
    def _add_employee(self):
        dialog = EmployeeDialog(self)
        if dialog.exec() == QDialog.DialogCode.Accepted:
            self.window.store.add_employee(dialog.values())
            self.refresh()
            self.window.flash("已新增员工")

    def _edit_employee(self):
        index = self.emp_list.currentRow()
        if not 0 <= index < len(self.rows):
            return
        employee = dict(self.window.store.employee(self.rows[index]["id"]))
        dialog = EmployeeDialog(self, employee)
        if dialog.exec() == QDialog.DialogCode.Accepted:
            self.window.store.update_employee(employee["id"], dialog.values())
            self.refresh()

    def _add_worklog(self):
        index = self.emp_list.currentRow()
        default_employee = self.rows[index]["id"] if 0 <= index < len(self.rows) else None
        dialog = WorklogDialog(self, default_employee)
        if dialog.exec() != QDialog.DialogCode.Accepted:
            return
        values = dialog.values()

        # 库里已经有一条一模一样的？提醒一下，但**照常让你加**——
        # 上午下午各干 4 小时、备注写一样，是真实存在的两条记录。
        # 数据库不该替人判断，只该把情况说清楚。
        twin = self.window.store.find_duplicate_worklog(values)
        if twin is not None:
            where = twin["project_name"] or "非项目"
            answer = QMessageBox.question(
                self, "可能重复了",
                "已经有一条一样的记录：\n\n"
                f"　{twin['work_date']}　{twin['employee_name']}　{where}　"
                f"{float(twin['hours']):g} 小时\n"
                f"　{twin['content'] or '（没有说明）'}\n\n"
                "如果确实是两段分开的工作，就继续添加。\n"
                "如果只是手滑点重了，点「取消」。",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.No,
            )
            if answer != QMessageBox.StandardButton.Yes:
                return

        self.window.store.add_worklog(values, dedupe=False)
        self.refresh()
        self.window.dashboard.refresh()
        self.window.flash("已记录工时")

    def _delete_worklog(self):
        row = self.work_table.currentRow()
        if row < 0:
            QMessageBox.information(self, "未选中", "先选中一条工时记录。")
            return
        worklog_id = self.work_table.item(row, 0).data(Qt.ItemDataRole.UserRole)
        if QMessageBox.question(
            self, "删除工时", "确定删除这条工时记录？",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
        ) == QMessageBox.StandardButton.Yes:
            self.window.store.delete_worklog(worklog_id)
            self.refresh()
            self.window.dashboard.refresh()

    def _edit_worklog(self):
        """改一条工时。

        **只有老板端有这个入口。** 员工的计时结果不该能被他自己改——
        小时数一旦可编辑，防篡改就没有意义了。
        员工记错了就在员工端删除重记，或者走「补录」。
        """
        row = self.work_table.currentRow()
        if row < 0:
            QMessageBox.information(self, "未选中", "先选中一条工时记录。")
            return
        worklog_id = self.work_table.item(row, 0).data(Qt.ItemDataRole.UserRole)
        worklog = self.window.store.one(
            "SELECT * FROM worklog WHERE id = ?", (worklog_id,)
        )
        if worklog is None:
            QMessageBox.information(self, "记录已不存在", "可能刚被删掉了，刷新一下。")
            return

        dialog = EditWorklogDialog(self, dict(worklog))
        if dialog.exec() != QDialog.DialogCode.Accepted:
            return
        values = dialog.values()

        # 改完可能和另一条撞指纹（同一个人同一天同样的项目、工时和说明）。
        # 两条一模一样的记录本身就没有意义，所以不硬留下，
        # 而是让人选删哪一条——这比「保留两条」干净得多。
        conflict = self.window.store.worklog_conflict(worklog_id, values)
        if conflict is not None:
            where = conflict["project_name"] or "非项目"
            box = QMessageBox(self)
            box.setWindowTitle("和另一条记录重复")
            box.setText(
                "改完之后和这条记录一模一样了：\n\n"
                f"　{conflict['work_date']}　{conflict['employee_name']}　"
                f"{where}　{float(conflict['hours']):g} 小时\n"
                f"　{conflict['content'] or '（没有说明）'}\n\n"
                "两条一样的记录没有意义，选一条留下、另一条删掉。"
            )
            keep_other = box.addButton("保留原来那条（删掉这次改的）",
                                       QMessageBox.ButtonRole.DestructiveRole)
            keep_this = box.addButton("保留改后的（删掉原来那条）",
                                      QMessageBox.ButtonRole.AcceptRole)
            box.addButton("取消", QMessageBox.ButtonRole.RejectRole)
            box.exec()
            clicked = box.clickedButton()
            if clicked is keep_other:
                self.window.store.delete_worklog(worklog_id)
                self.refresh()
                self.window.dashboard.refresh()
                self.window.flash("已删除重复的一条")
                return
            if clicked is keep_this:
                self.window.store.delete_worklog(conflict["id"])
                # 删掉旧的之后就不冲突了，正常写入
            else:
                return

        self.window.store.update_worklog(worklog_id, values)
        self.refresh()
        self.window.dashboard.refresh()
        self.window.flash("已修改这条工时")


# ================================================================== 任务分配
class StaffingPage(QWidget):
    """把员工挂到项目的某一步上。

    计划工时登记在这张表里，实际工时在「员工与工时」里录，
    两边一对比就知道谁被压了活。
    """

    def __init__(self, window):
        super().__init__()
        self.window = window

        root = QVBoxLayout(self)
        root.setContentsMargins(18, 16, 18, 14)
        root.setSpacing(12)

        head = QHBoxLayout()
        head.addWidget(SectionTitle("计划 vs 实际"))
        head.addStretch()
        self.chart_hint = muted("")
        head.addWidget(self.chart_hint)
        root.addLayout(head)

        # 双组柱状图：每根柱子旁边并排一根「实际」，
        # 高出来的那截就是估算偏差
        self.chart = BarChart()
        self.chart.set_empty("新增任务分配后，这里对比计划工时和实际工时")
        self.chart.setMinimumHeight(210)
        root.addWidget(self.chart)

        head = QHBoxLayout()
        head.addWidget(SectionTitle("任务分配"))
        head.addStretch()
        add = QPushButton("新增分配")
        add.setObjectName("PrimaryButton")
        add.clicked.connect(self._add)
        head.addWidget(add)
        remove = QPushButton("删除选中")
        remove.setObjectName("DangerButton")
        remove.clicked.connect(self._delete)
        head.addWidget(remove)
        root.addLayout(head)

        self.table = QTableWidget(0, 8)
        self.table.setHorizontalHeaderLabels([
            "项目", "步骤", "员工", "任务角色",
            "计划工时", "实际工时", "截止", "状态",
        ])
        self.table.verticalHeader().setVisible(False)
        self.table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        self.table.setShowGrid(False)
        self.table.setSortingEnabled(True)
        header = self.table.horizontalHeader()
        header.setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        for column in (1, 2, 3, 4, 5, 6, 7):
            header.setSectionResizeMode(column, QHeaderView.ResizeMode.ResizeToContents)
        root.addWidget(self.table, 1)

        self.hint = muted("")
        root.addWidget(self.hint)

    def refresh(self):
        rows = [dict(row) for row in self.window.store.assignments()]
        # 每条分配的实际工时：按员工 + 项目 + 步骤把工时聚起来
        actual = metrics.aggregate_hours(self.window.store.worklogs())

        self.table.setSortingEnabled(False)
        self.table.setRowCount(len(rows))
        over = 0
        for index, row in enumerate(rows):
            key = (row["employee_id"], row["project_id"], row["step_id"])
            used = actual.get(key, 0.0)
            planned = num(row["planned_hours"])
            ratio = metrics.safe_div(used, planned)
            if planned > 0 and ratio > 1.0:
                over += 1
            values = [
                row["project_name"] or "—", row["step_name"] or "—",
                row["employee_name"] or "—", row["role_in_task"] or "—",
                f"{planned:.1f}", f"{used:.1f}",
                row["due_date"] or "—", row["status"],
            ]
            for column, text in enumerate(values):
                item = QTableWidgetItem(text)
                if column in (4, 5, 6, 7):
                    item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
                if column == 5 and planned > 0 and ratio > 1.0:
                    item.setForeground(QColor(level_color("风险")))
                    item.setToolTip(f"已超出计划 {ratio * 100 - 100:.0f}%")
                if column == 0:
                    item.setData(Qt.ItemDataRole.UserRole, row["id"])
                self.table.setItem(index, column, item)
        self.table.setSortingEnabled(True)

        if over:
            self.hint.setText(
                f"有 {over} 条分配的实际工时已经超出计划——这些任务的时间估算偏乐观，"
                "或者有人在硬扛。"
            )
        else:
            self.hint.setText(
                "「计划工时」是你当初估的量，「实际工时」是从工时记录里算出来的。"
            )
        self._draw_chart(rows, actual)

    def _draw_chart(self, rows, actual):
        """按人汇总计划与实际工时，画成并排柱状图。

        按人而不是按条：一个人挂了 5 条任务的话，
        按条画会有 5 根柱子，看不出「这个人整体被压了多少」。
        """
        by_person = {}
        for row in rows:
            key = (row["employee_id"], row["employee_name"] or "未指定")
            bucket = by_person.setdefault(key, {"planned": 0.0, "used": 0.0})
            bucket["planned"] += num(row["planned_hours"])
            hit = actual.get((row["employee_id"], row["project_id"], row["step_id"]))
            bucket["used"] += hit or 0.0

        bars = []
        for (_employee_id, name), bucket in sorted(
            by_person.items(), key=lambda item: -item[1]["planned"]
        ):
            bars.append({
                "label": name,
                "values": [bucket["planned"], bucket["used"]],
            })
        self.chart.set_bars(bars, group_names=["计划", "实际"])

        if not bars:
            self.chart_hint.setText("还没有分配，先去「任务分配」加一条。")
            return
        total_planned = sum(b["values"][0] for b in bars)
        total_used = sum(b["values"][1] for b in bars)
        if total_planned <= 0:
            self.chart_hint.setText("分配还没填计划工时，对比不出来。")
        else:
            deviation = (total_used / total_planned - 1) * 100
            if deviation > 5:
                self.chart_hint.setText(
                    f"整体比计划多用 {deviation:.0f}% 工时——时间估算系统性偏乐观。"
                )
            elif deviation < -5:
                self.chart_hint.setText(
                    f"整体比计划少用 {abs(deviation):.0f}% 工时——估算留了余量。"
                )
            else:
                self.chart_hint.setText("整体和计划基本吻合，估算挺准。")

    def _add(self):
        dialog = AssignmentDialog(self)
        if dialog.exec() == QDialog.DialogCode.Accepted:
            self.window.store.add_assignment(dialog.values())
            self.refresh()
            self.window.dashboard.refresh()
            self.window.flash("已新增分配")

    def _delete(self):
        row = self.table.currentRow()
        if row < 0:
            QMessageBox.information(self, "未选中", "先选中一条分配。")
            return
        assignment_id = self.table.item(row, 0).data(Qt.ItemDataRole.UserRole)
        if QMessageBox.question(
            self, "删除分配", "确定删除这条任务分配？",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
        ) == QMessageBox.StandardButton.Yes:
            self.window.store.delete_assignment(assignment_id)
            self.refresh()
            self.window.dashboard.refresh()


# ================================================================== 子对话框
def resolve_store(parent):
    """从对话框的 parent 上拿到数据库。

    这个函数存在的原因是：这些对话框有两种调用方——

      · 页面里的按钮（EmployeePage、StaffingPage）→ parent 是**页面**，
        页面上有 `.window` 指向主窗口；
      · 计时条、员工导出窗口 → parent 直接就是**主窗口**。

    两种都写死 `parent.window.store` 的话，第二种会
    AttributeError: 'MainWindow' object has no attribute 'window'。
    计时条上的「补录」按钮就踩过这个坑。

    所以这里两种都认：有 .store 就用，没有就顺着 .window 找。
    """
    store = getattr(parent, "store", None)
    if store is not None:
        return store
    window = getattr(parent, "window", None)
    if window is not None:
        return window.store
    raise RuntimeError(
        f"拿不到数据库：{type(parent).__name__} 既没有 .store 也没有 .window"
    )


class EmployeeDialog(QDialog):
    def __init__(self, parent, employee=None):
        super().__init__(parent)
        employee = dict(employee or {})
        self.setWindowTitle("编辑员工" if employee else "新增员工")
        self.setMinimumWidth(400)

        layout = QVBoxLayout(self)
        form = QFormLayout()
        form.setSpacing(10)
        self.f_name = QLineEdit(employee.get("name", ""))
        self.f_role = QLineEdit(employee.get("role", ""))
        self.f_level = QLineEdit(employee.get("level", ""))
        self.f_weekly = QDoubleSpinBox()
        self.f_weekly.setRange(0, 168)
        self.f_weekly.setDecimals(1)
        self.f_weekly.setValue(float(employee.get("weekly_hours", 40) or 40))
        self.f_hired = QLineEdit(employee.get("hired_date", ""))
        self.f_hired.setPlaceholderText("YYYY-MM-DD")
        self.f_active = QComboBox()
        self.f_active.addItems(["在职", "离职"])
        self.f_active.setCurrentIndex(0 if employee.get("active", 1) else 1)
        self.f_note = QLineEdit(employee.get("note", ""))

        form.addRow("姓名", self.f_name)
        form.addRow("岗位", self.f_role)
        form.addRow("职级", self.f_level)
        form.addRow("周工时基准", self.f_weekly)
        form.addRow("入职日期", self.f_hired)
        form.addRow("状态", self.f_active)
        form.addRow("备注", self.f_note)
        layout.addLayout(form)

        hint = label("周工时基准用来算负荷率：这个人是 40 小时制的，还是兼职 20 小时。",
                     "DialogHint")
        hint.setWordWrap(True)
        layout.addWidget(hint)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.button(QDialogButtonBox.StandardButton.Ok).setText("确定")
        buttons.button(QDialogButtonBox.StandardButton.Cancel).setText("取消")
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def values(self):
        return {
            "name": self.f_name.text().strip(),
            "role": self.f_role.text().strip(),
            "level": self.f_level.text().strip(),
            "weekly_hours": self.f_weekly.value(),
            "hired_date": self.f_hired.text().strip(),
            "active": 0 if self.f_active.currentIndex() == 1 else 1,
            "note": self.f_note.text().strip(),
        }


class WorklogDialog(QDialog):
    def __init__(self, parent, default_employee=None):
        super().__init__(parent)
        # parent 可能是页面，也可能直接是主窗口——两种都认
        self.store = resolve_store(parent)
        self.setWindowTitle("录入工时")
        self.setMinimumWidth(440)

        layout = QVBoxLayout(self)
        form = QFormLayout()
        form.setSpacing(10)

        self.f_date = QLineEdit(datetime.date.today().isoformat())
        self.f_date.setPlaceholderText("YYYY-MM-DD")

        self.f_employee = QComboBox()
        for row in self.store.employees(only_active=True):
            self.f_employee.addItem(row["name"], row["id"])
        if default_employee:
            index = self.f_employee.findData(default_employee)
            if index >= 0:
                self.f_employee.setCurrentIndex(index)

        self.f_project = QComboBox()
        self.f_project.addItem("（非项目事务）", None)
        for row in self.store.projects():
            self.f_project.addItem(row["name"], row["id"])
        self.f_project.currentIndexChanged.connect(self._reload_steps)

        self.f_step = QComboBox()
        self.f_step.addItem("（不指定步骤）", None)

        self.f_hours = QDoubleSpinBox()
        self.f_hours.setRange(0, 24)
        self.f_hours.setDecimals(1)
        self.f_hours.setSingleStep(0.5)
        self.f_hours.setValue(8)

        self.f_content = QLineEdit()
        self.f_content.setPlaceholderText("干了什么")

        form.addRow("日期", self.f_date)
        form.addRow("员工", self.f_employee)
        form.addRow("项目", self.f_project)
        form.addRow("步骤", self.f_step)
        form.addRow("工时", self.f_hours)
        form.addRow("内容", self.f_content)
        layout.addLayout(form)
        self._reload_steps()

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.button(QDialogButtonBox.StandardButton.Ok).setText("确定")
        buttons.button(QDialogButtonBox.StandardButton.Cancel).setText("取消")
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _reload_steps(self):
        self.f_step.clear()
        self.f_step.addItem("（不指定步骤）", None)
        project_id = self.f_project.currentData()
        if project_id:
            for row in self.store.steps(project_id):
                self.f_step.addItem(row["name"], row["id"])

    def values(self):
        return {
            "employee_id": self.f_employee.currentData(),
            "project_id": self.f_project.currentData(),
            "step_id": self.f_step.currentData(),
            "work_date": self.f_date.text().strip(),
            "hours": self.f_hours.value(),
            "content": self.f_content.text().strip(),
        }


class EditWorklogDialog(QDialog):
    """改一条工时。**只有老板端会开这个窗口。**

    员工的计时结果不该能被他自己改——小时数一旦可编辑，
    防篡改就没有意义了。员工记错了就在员工端删除重记。

    改小时数时会明确提醒一次：计时记录的小时数是从计时器来的，
    改它等于推翻了计时结论。
    """

    def __init__(self, parent, worklog):
        super().__init__(parent)
        self.store = resolve_store(parent)
        self.window = getattr(parent, "window", parent)
        self.worklog = dict(worklog)
        self.setWindowTitle("修改工时")
        self.setMinimumWidth(460)

        layout = QVBoxLayout(self)

        # 说明来源，让老板知道自己在改什么
        source = self.worklog.get("source") or "manual"
        if source == "timer":
            origin = label(
                "这条是员工用计时器记的。改小时数等于修改计时结论，"
                "改之前建议先想想是不是该让他重新解释一下。",
                "DialogHint",
            )
        else:
            origin = label("这条是手工补录的。", "DialogHint")
        origin.setWordWrap(True)
        layout.addWidget(origin)

        form = QFormLayout()
        form.setSpacing(10)

        self.f_employee = QComboBox()
        for row in self.store.employees():
            self.f_employee.addItem(row["name"], row["id"])
        _select_data(self.f_employee, self.worklog["employee_id"])

        self.f_project = QComboBox()
        self.f_project.addItem("（非项目事务）", None)
        for row in self.store.projects():
            self.f_project.addItem(row["name"], row["id"])
        _select_data(self.f_project, self.worklog["project_id"])
        self.f_project.currentIndexChanged.connect(self._reload_steps)

        self.f_step = QComboBox()
        self.f_date = QLineEdit(self.worklog["work_date"] or "")
        self.f_date.setPlaceholderText("YYYY-MM-DD")
        self.f_hours = QDoubleSpinBox()
        self.f_hours.setRange(0.1, 24)
        self.f_hours.setDecimals(2)
        self.f_hours.setSingleStep(0.25)
        self.f_hours.setValue(num(self.worklog["hours"]))
        self.f_content = QLineEdit(self.worklog["content"] or "")

        form.addRow("员工", self.f_employee)
        form.addRow("项目", self.f_project)
        form.addRow("步骤", self.f_step)
        form.addRow("日期", self.f_date)
        form.addRow("工时", self.f_hours)
        form.addRow("内容", self.f_content)
        layout.addLayout(form)

        self._reload_steps()
        _select_data(self.f_step, self.worklog["step_id"])

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.button(QDialogButtonBox.StandardButton.Ok).setText("保存")
        buttons.button(QDialogButtonBox.StandardButton.Cancel).setText("取消")
        buttons.accepted.connect(self._confirm)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _reload_steps(self):
        project_id = self.f_project.currentData()
        self.f_step.clear()
        self.f_step.addItem("（不指定步骤）", None)
        if project_id:
            for row in self.store.steps(project_id):
                self.f_step.addItem(row["name"], row["id"])

    def _confirm(self):
        """改小时数时多问一句——那是计时结论，不该顺手改掉。"""
        original = num(self.worklog["hours"])
        changed = self.f_hours.value()
        if (self.worklog.get("source") == "timer"
                and abs(changed - original) > 0.001):
            answer = QMessageBox.question(
                self, "改动计时结果",
                f"小时数从 {original:g} 改成 {changed:g}。\n\n"
                "这条是计时器记的，改了之后就没有计时证据了。确定保存吗？",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.No,
            )
            if answer != QMessageBox.StandardButton.Yes:
                return
        self.accept()

    def values(self):
        return {
            "employee_id": self.f_employee.currentData(),
            "project_id": self.f_project.currentData(),
            "step_id": self.f_step.currentData(),
            "work_date": self.f_date.text().strip(),
            "hours": self.f_hours.value(),
            "content": self.f_content.text().strip(),
        }


def _select_data(combo, value):
    """把下拉选到指定值。找不到就保持不动。"""
    index = combo.findData(value)
    if index >= 0:
        combo.setCurrentIndex(index)


class AssignmentDialog(QDialog):
    def __init__(self, parent):
        super().__init__(parent)
        self.store = resolve_store(parent)
        self.setWindowTitle("新增任务分配")
        self.setMinimumWidth(460)

        layout = QVBoxLayout(self)
        form = QFormLayout()
        form.setSpacing(10)

        self.f_project = QComboBox()
        for row in self.store.projects():
            self.f_project.addItem(row["name"], row["id"])
        self.f_project.currentIndexChanged.connect(self._reload_steps)

        self.f_step = QComboBox()
        self.f_step.addItem("（不指定步骤）", None)

        self.f_employee = QComboBox()
        for row in self.store.employees(only_active=True):
            self.f_employee.addItem(f"{row['name']}（{row['role'] or '未填岗位'}）", row["id"])

        self.f_role = QLineEdit()
        self.f_role.setPlaceholderText("他在这步里负责什么")
        self.f_planned = QDoubleSpinBox()
        self.f_planned.setRange(0, 5000)
        self.f_planned.setDecimals(1)
        self.f_planned.setValue(20)
        self.f_start = QLineEdit(datetime.date.today().isoformat())
        self.f_start.setPlaceholderText("YYYY-MM-DD")
        self.f_due = QLineEdit()
        self.f_due.setPlaceholderText("YYYY-MM-DD")
        self.f_status = QComboBox()
        self.f_status.addItems(ASSIGN_STATUS)

        form.addRow("项目", self.f_project)
        form.addRow("步骤", self.f_step)
        form.addRow("员工", self.f_employee)
        form.addRow("任务角色", self.f_role)
        form.addRow("计划工时", self.f_planned)
        form.addRow("开始日期", self.f_start)
        form.addRow("截止日期", self.f_due)
        form.addRow("状态", self.f_status)
        layout.addLayout(form)
        self._reload_steps()

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.button(QDialogButtonBox.StandardButton.Ok).setText("确定")
        buttons.button(QDialogButtonBox.StandardButton.Cancel).setText("取消")
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _reload_steps(self):
        self.f_step.clear()
        self.f_step.addItem("（不指定步骤）", None)
        project_id = self.f_project.currentData()
        if project_id:
            for row in self.store.steps(project_id):
                self.f_step.addItem(row["name"], row["id"])

    def values(self):
        return {
            "project_id": self.f_project.currentData(),
            "step_id": self.f_step.currentData(),
            "employee_id": self.f_employee.currentData(),
            "role_in_task": self.f_role.text().strip(),
            "planned_hours": self.f_planned.value(),
            "start_date": self.f_start.text().strip(),
            "due_date": self.f_due.text().strip(),
            "status": self.f_status.currentText(),
        }


# ------------------------------------------------------------------- 启动
def load_stylesheet_text():
    try:
        with open(resource_path("style.qss"), "r", encoding="utf-8") as f:
            return theme.render_stylesheet(f.read())
    except OSError:
        return ""


def main():
    app = QApplication(sys.argv)
    app.setApplicationName(APP_NAME)
    app.setApplicationDisplayName(APP_NAME)
    app.setWindowIcon(QIcon(resource_path("assets", "app_icon.ico")))
    app.setFont(QFont("Microsoft YaHei UI", 10))
    app.setStyleSheet(load_stylesheet_text())

    # --submit：员工模式。直接开导出窗口，不显示老板那套界面。
    # 员工不需要看项目、预算、预测，给他一个干净的窗口就行。
    if "--submit" in sys.argv:
        window = MainWindow()
        dialog = SubmitWindow(window)
        saved = window._settings_get("submit_employee")
        if saved is not None:
            index = dialog.f_employee.findData(saved)
            if index >= 0:
                dialog.f_employee.setCurrentIndex(index)
        dialog.exec()
        window.store.close()
        return 0

    window = MainWindow()
    window.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
