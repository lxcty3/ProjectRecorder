"""知识星球 · 星球广场：所有成员共同看到、共同发布的社区页面。"""
import datetime
import json
import time

from PyQt6.QtCore import QThread, QTimer, Qt, pyqtSignal
from PyQt6.QtGui import QColor
from PyQt6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDialog, QFrame, QHBoxLayout,
    QInputDialog, QLabel, QLineEdit, QListWidget, QMessageBox, QPushButton,
    QScrollArea, QSizePolicy, QSpinBox, QSplitter, QTextEdit, QVBoxLayout,
    QWidget,
)

import theme
from community_client import (
    CommunityClient, CommunityError, CommunitySession, community_setup_sql,
)
from widgets import SectionTitle, label, muted

__all__ = ["CommunityPage", "CommunityLoginDialog"]

TOPIC_LABELS = ("分享", "提问", "经验", "灵感", "公告")
ROLE_LABELS = {"boss": "老板", "employee": "员工"}


def _friendly_time(value):
    text = str(value or "").strip()
    if not text:
        return ""
    try:
        parsed = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=datetime.timezone.utc)
        now = datetime.datetime.now(datetime.timezone.utc)
        seconds = max(0, int((now - parsed.astimezone(datetime.timezone.utc)).total_seconds()))
        if seconds < 60:
            return "刚刚"
        if seconds < 3600:
            return f"{seconds // 60} 分钟前"
        if seconds < 86400:
            return f"{seconds // 3600} 小时前"
        if seconds < 86400 * 7:
            return f"{seconds // 86400} 天前"
        return parsed.astimezone().strftime("%m月%d日 %H:%M")
    except (ValueError, TypeError, OverflowError):
        return text[:16].replace("T", " ")


class CommunityWorker(QThread):
    done = pyqtSignal(object)
    failed = pyqtSignal(str)

    def __init__(self, work, parent=None):
        super().__init__(parent)
        self._work = work

    def run(self):
        try:
            self.done.emit(self._work())
        except CommunityError as error:
            self.failed.emit(str(error))
        except Exception as error:  # noqa: BLE001 网络线程的错误必须回主线程
            self.failed.emit(f"社区请求出错：{type(error).__name__}: {error}")


class CommunityLoginDialog(QDialog):
    """用现有账号登录社区，不另建一套密码。"""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("登录知识星球社区")
        self.setMinimumWidth(460)
        self.session = None
        self._worker = None
        layout = QVBoxLayout(self)
        layout.setContentsMargins(24, 22, 24, 20)
        layout.setSpacing(11)
        layout.addWidget(label("登录后加入星球广场", "DialogTitle"))
        hint = muted(
            "这里使用你在手机版里的老板账号或员工号。"
            "所有成员会看到同一条社区消息流。"
        )
        hint.setWordWrap(True)
        layout.addWidget(hint)

        layout.addWidget(label("账号 / 员工号", "CommunityFieldLabel"))
        self.code_edit = QLineEdit()
        self.code_edit.setPlaceholderText("手机号或员工号")
        layout.addWidget(self.code_edit)
        layout.addWidget(label("密码", "CommunityFieldLabel"))
        self.password_edit = QLineEdit()
        self.password_edit.setEchoMode(QLineEdit.EchoMode.Password)
        self.password_edit.setPlaceholderText("登录密码")
        self.password_edit.returnPressed.connect(self._login)
        layout.addWidget(self.password_edit)

        self.error_label = QLabel("")
        self.error_label.setObjectName("CommunityErrorText")
        self.error_label.setWordWrap(True)
        self.error_label.setTextFormat(Qt.TextFormat.PlainText)
        self.error_label.hide()
        layout.addWidget(self.error_label)

        row = QHBoxLayout()
        row.addStretch()
        self.cancel_button = QPushButton("取消")
        self.cancel_button.setObjectName("GhostButton")
        self.cancel_button.clicked.connect(self.reject)
        row.addWidget(self.cancel_button)
        self.login_button = QPushButton("登录社区")
        self.login_button.setObjectName("PrimaryButton")
        self.login_button.clicked.connect(self._login)
        row.addWidget(self.login_button)
        layout.addLayout(row)

    def _login(self):
        if self._worker is not None and self._worker.isRunning():
            return
        code = self.code_edit.text().strip()
        password = self.password_edit.text()
        if not code or not password:
            self._show_error("账号和密码都要填。")
            return
        self.error_label.hide()
        self.login_button.setEnabled(False)
        self.cancel_button.setEnabled(False)
        self.login_button.setText("登录中…")
        self._worker = CommunityWorker(
            lambda: CommunityClient().login(code, password), self
        )
        self._worker.done.connect(self._on_done)
        self._worker.failed.connect(self._on_failed)
        self._worker.finished.connect(self._on_thread_finished)
        self._worker.start()

    def _on_done(self, session):
        self.session = session
        self.password_edit.clear()

    def _on_thread_finished(self):
        if self.session is not None:
            self.accept()

    def closeEvent(self, event):
        if self._worker is not None and self._worker.isRunning():
            self._show_error("正在登录，请稍候…")
            event.ignore()
            return
        super().closeEvent(event)

    def _on_failed(self, message):
        self.login_button.setEnabled(True)
        self.cancel_button.setEnabled(True)
        self.login_button.setText("登录社区")
        self._show_error(message)

    def _show_error(self, message):
        self.error_label.setText(message)
        self.error_label.show()

class CommunityMessageCard(QFrame):
    delete_requested = pyqtSignal(str)
    unlock_requested = pyqtSignal(str)
    like_requested = pyqtSignal(str)
    bookmark_requested = pyqtSignal(str)
    comments_requested = pyqtSignal(str)
    report_requested = pyqtSignal(str)
    moderation_requested = pyqtSignal(str)

    def __init__(self, post, is_mine=False, can_manage=False, parent=None):
        super().__init__(parent)
        self.post = dict(post)
        self.setObjectName("CommunityMessageCard")
        layout = QVBoxLayout(self)
        layout.setContentsMargins(15, 12, 15, 13)
        layout.setSpacing(7)

        head = QHBoxLayout()
        head.setSpacing(8)
        author = str(post.get("author_name") or "成员")
        avatar = QLabel(author[:1])
        avatar.setObjectName("CommunityAvatar")
        avatar.setAlignment(Qt.AlignmentFlag.AlignCenter)
        avatar.setFixedSize(34, 34)
        role = str(post.get("author_role") or "employee")
        color = "#7c93ad" if role == "boss" else "#8fa487"
        avatar.setStyleSheet(
            f"background-color: {color}; color: #ffffff; border-radius: 17px;"
            " font-weight: 700; font-size: 14px;"
        )
        head.addWidget(avatar)

        identity = QVBoxLayout()
        identity.setSpacing(1)
        name_row = QHBoxLayout()
        name_row.setSpacing(6)
        name_row.addWidget(label(author, "CommunityAuthor"))
        role_label = QLabel(ROLE_LABELS.get(role, "成员"))
        role_label.setObjectName("CommunityRolePill")
        name_row.addWidget(role_label)
        if is_mine:
            name_row.addWidget(label("我", "CommunityMinePill"))
        name_row.addStretch()
        identity.addLayout(name_row)
        topic = str(post.get("topic") or "分享")
        board_name = str(post.get("board_name") or "综合讨论")
        identity.addWidget(label(
            f"{board_name} · {topic} · {_friendly_time(post.get('created_at'))}",
            "CommunityMeta",
        ))
        tags = QHBoxLayout()
        tags.setSpacing(5)
        if post.get("pinned"):
            tags.addWidget(label("置顶", "CommunityStatePinned"))
        if post.get("featured"):
            tags.addWidget(label("精选", "CommunityStateFeatured"))
        if post.get("is_required"):
            tags.addWidget(label("必读", "CommunityStateRequired"))
        if int(post.get("unlock_cost") or 0) > 0:
            tags.addWidget(label(
                f"{int(post.get('unlock_cost'))} 积分", "CommunityStateCost"
            ))
        tags.addStretch()
        identity.addLayout(tags)
        head.addLayout(identity, 1)

        if is_mine:
            delete_button = QPushButton("删除")
            delete_button.setObjectName("CommunityDeleteButton")
            delete_button.clicked.connect(
                lambda: self.delete_requested.emit(str(self.post.get("id")))
            )
            head.addWidget(delete_button)
        layout.addLayout(head)

        locked = bool(post.get("locked"))
        body_text = str(post.get("preview") if locked else post.get("content") or "")
        if locked:
            body_text = "付费知识预览：{}...".format(body_text[:180])
        body = QLabel(body_text)
        body.setObjectName("CommunityMessageBody")
        body.setWordWrap(True)
        body.setTextFormat(Qt.TextFormat.PlainText)
        body.setTextInteractionFlags(
            Qt.TextInteractionFlag.TextSelectableByMouse
        )
        layout.addWidget(body)
        if locked:
            access = QHBoxLayout()
            cost = int(post.get("unlock_cost") or 0)
            access.addWidget(label(f"使用 {cost} 积分永久解锁", "CommunityMeta"))
            access.addStretch()
            unlock_button = QPushButton("解锁全文")
            unlock_button.setObjectName("PrimaryButton")
            unlock_button.clicked.connect(
                lambda: self.unlock_requested.emit(str(self.post.get("id")))
            )
            access.addWidget(unlock_button)
            layout.addLayout(access)

        actions = QHBoxLayout()
        actions.setSpacing(5)
        like_button = QPushButton(f"喜欢 {int(post.get('like_count') or 0)}")
        like_button.setObjectName("CommunityActionButton")
        like_button.setProperty("active", bool(post.get("liked")))
        like_button.clicked.connect(
            lambda: self.like_requested.emit(str(self.post.get("id")))
        )
        actions.addWidget(like_button)
        comments_button = QPushButton(f"评论 {int(post.get('comment_count') or 0)}")
        comments_button.setObjectName("CommunityActionButton")
        comments_button.clicked.connect(
            lambda: self.comments_requested.emit(str(self.post.get("id")))
        )
        actions.addWidget(comments_button)
        bookmark_button = QPushButton(
            "已收藏" if post.get("bookmarked") else "收藏"
        )
        bookmark_button.setObjectName("CommunityActionButton")
        bookmark_button.setProperty("active", bool(post.get("bookmarked")))
        bookmark_button.clicked.connect(
            lambda: self.bookmark_requested.emit(str(self.post.get("id")))
        )
        actions.addWidget(bookmark_button)
        report_button = QPushButton("举报")
        report_button.setObjectName("CommunityActionButton")
        report_button.clicked.connect(
            lambda: self.report_requested.emit(str(self.post.get("id")))
        )
        actions.addWidget(report_button)
        if can_manage:
            moderate_button = QPushButton("管理")
            moderate_button.setObjectName("CommunityActionButton")
            moderate_button.clicked.connect(
                lambda: self.moderation_requested.emit(str(self.post.get("id")))
            )
            actions.addWidget(moderate_button)
        actions.addStretch()
        layout.addLayout(actions)

class CommunityPage(QWidget):
    """共享社区：消息保存在 Supabase，所有成员看到同一份数据。"""

    REFRESH_MS = 12000

    def __init__(self, window):
        super().__init__()
        self.window = window
        self.client = CommunityClient()
        self.session = self._load_session()
        self.posts = []
        self.boards = []
        self.current_board = ""
        self.search_text = ""
        self.bookmarked_only = False
        self.can_manage = False
        self._workers = []
        self._busy = False
        self._last_refresh = 0.0
        self._last_error = ""
        self._build()
        self._set_identity()
        self._render_feed()
        self.timer = QTimer(self)
        self.timer.setInterval(self.REFRESH_MS)
        self.timer.timeout.connect(self._auto_refresh)
        self.timer.start()

    def _build(self):
        root = QVBoxLayout(self)
        root.setContentsMargins(10, 10, 10, 8)
        root.setSpacing(11)

        hero = QHBoxLayout()
        hero.setSpacing(9)
        title_block = QVBoxLayout()
        title_block.setSpacing(1)
        title_block.addWidget(label("星球广场", "KnowledgeTitle"))
        title_block.addWidget(label(
            "所有成员共享的消息流：提问、分享经验、发出想法，彼此都能看见",
            "KnowledgeSubtitle",
        ))
        hero.addLayout(title_block)
        hero.addStretch()
        self.identity_label = label("尚未登录", "CommunityIdentity")
        hero.addWidget(self.identity_label)
        self.notifications_button = QPushButton("通知")
        self.notifications_button.setObjectName("GhostButton")
        self.notifications_button.clicked.connect(self.open_notifications)
        hero.addWidget(self.notifications_button)
        self.boards_button = QPushButton("板块")
        self.boards_button.setObjectName("GhostButton")
        self.boards_button.clicked.connect(self.open_board_manager)
        hero.addWidget(self.boards_button)
        self.refresh_button = QPushButton("刷新")
        self.refresh_button.setObjectName("GhostButton")
        self.refresh_button.clicked.connect(lambda: self.refresh_posts(force=True))
        hero.addWidget(self.refresh_button)
        self.login_button = QPushButton("登录社区")
        self.login_button.setObjectName("PrimaryButton")
        self.login_button.clicked.connect(self.open_login)
        hero.addWidget(self.login_button)
        self.logout_button = QPushButton("退出")
        self.logout_button.setObjectName("GhostButton")
        self.logout_button.clicked.connect(self.logout)
        hero.addWidget(self.logout_button)
        root.addLayout(hero)

        splitter = QSplitter(Qt.Orientation.Horizontal)
        splitter.setChildrenCollapsible(False)
        splitter.setHandleWidth(7)

        feed_panel = QFrame()
        feed_panel.setObjectName("CommunityFeedPanel")
        feed_layout = QVBoxLayout(feed_panel)
        feed_layout.setContentsMargins(15, 13, 15, 13)
        feed_layout.setSpacing(8)
        feed_head = QHBoxLayout()
        feed_head.addWidget(SectionTitle("板块讨论"))
        feed_head.addWidget(self._make_board_filter())
        self.search_edit = QLineEdit()
        self.search_edit.setPlaceholderText("搜索帖子")
        self.search_edit.setFixedWidth(150)
        self.search_edit.returnPressed.connect(
            lambda: self.refresh_posts(force=True)
        )
        feed_head.addWidget(self.search_edit)
        self.search_button = QPushButton("搜索")
        self.search_button.setObjectName("GhostButton")
        self.search_button.clicked.connect(lambda: self.refresh_posts(force=True))
        feed_head.addWidget(self.search_button)
        self.bookmark_button = QPushButton("收藏")
        self.bookmark_button.setObjectName("GhostButton")
        self.bookmark_button.setCheckable(True)
        self.bookmark_button.toggled.connect(
            lambda checked: self._set_bookmark_filter(checked)
        )
        feed_head.addWidget(self.bookmark_button)
        feed_head.addStretch()
        self.feed_status = label("登录后加载", "CommunityFeedStatus")
        feed_head.addWidget(self.feed_status)
        feed_layout.addLayout(feed_head)

        self.feed_scroll = QScrollArea()
        self.feed_scroll.setObjectName("CommunityFeedScroll")
        self.feed_scroll.setWidgetResizable(True)
        self.feed_scroll.setHorizontalScrollBarPolicy(
            Qt.ScrollBarPolicy.ScrollBarAlwaysOff
        )
        self.feed_widget = QWidget()
        self.feed_widget.setObjectName("CommunityFeedContent")
        self.feed_layout = QVBoxLayout(self.feed_widget)
        self.feed_layout.setContentsMargins(2, 2, 2, 2)
        self.feed_layout.setSpacing(9)
        self.feed_scroll.setWidget(self.feed_widget)
        feed_layout.addWidget(self.feed_scroll, 1)
        splitter.addWidget(feed_panel)

        side = QFrame()
        side.setObjectName("CommunitySidePanel")
        side.setMinimumWidth(300)
        side_layout = QVBoxLayout(side)
        side_layout.setContentsMargins(16, 14, 16, 14)
        side_layout.setSpacing(9)
        side_layout.addWidget(SectionTitle("我的身份"))
        self.profile_name = label("尚未登录", "CommunityProfileName")
        self.profile_name.setWordWrap(True)
        side_layout.addWidget(self.profile_name)
        self.profile_role = label("登录后即可发消息", "CommunityProfileRole")
        self.profile_role.setWordWrap(True)
        side_layout.addWidget(self.profile_role)

        side_layout.addWidget(SectionTitle("发布讨论"))
        side_layout.addWidget(label("发布到板块", "CommunityFieldLabel"))
        self.board_box = QComboBox()
        self.board_box.currentIndexChanged.connect(self._board_compose_changed)
        side_layout.addWidget(self.board_box)
        self.topic_box = QComboBox()
        self.topic_box.addItems(TOPIC_LABELS)
        side_layout.addWidget(self.topic_box)
        self.message_edit = QTextEdit()
        self.message_edit.setPlaceholderText(
            "写一条所有成员都能看到的消息。\n"
            "可以提问、分享经验、同步一个判断或发出一条灵感。"
        )
        self.message_edit.setMinimumHeight(155)
        self.message_edit.setTabChangesFocus(True)
        self.message_edit.textChanged.connect(self._update_char_count)
        side_layout.addWidget(self.message_edit)
        access_row = QHBoxLayout()
        access_row.addWidget(label("解锁积分", "CommunityFieldLabel"))
        self.unlock_cost = QSpinBox()
        self.unlock_cost.setRange(0, 100000000)
        self.unlock_cost.setValue(0)
        access_row.addWidget(self.unlock_cost)
        self.required_box = QCheckBox("设为必读")
        access_row.addWidget(self.required_box)
        side_layout.addLayout(access_row)
        admin_row = QHBoxLayout()
        self.pinned_box = QCheckBox("置顶")
        self.featured_box = QCheckBox("精选")
        admin_row.addWidget(self.pinned_box)
        admin_row.addWidget(self.featured_box)
        admin_row.addStretch()
        side_layout.addLayout(admin_row)
        row = QHBoxLayout()
        self.char_label = label("0 / 2000", "CommunityCharCount")
        row.addWidget(self.char_label)
        row.addStretch()
        self.publish_button = QPushButton("发布消息")
        self.publish_button.setObjectName("PrimaryButton")
        self.publish_button.clicked.connect(self.publish)
        row.addWidget(self.publish_button)
        side_layout.addLayout(row)

        self.compose_hint = QLabel(
            "社区消息对全部成员可见。请尊重他人，不发密码、密钥和隐私信息。"
        )
        self.compose_hint.setObjectName("CommunityHint")
        self.compose_hint.setWordWrap(True)
        side_layout.addWidget(self.compose_hint)
        side_layout.addWidget(SectionTitle("社区是什么"))
        rule = QLabel(
            "每个人看到同一份消息流。\n"
            "提问不必等到想清楚，经验也不必等到完美。\n"
            "一条消息可以被所有人补充、反驳或带到项目里继续验证。"
        )
        rule.setObjectName("CommunityRule")
        rule.setWordWrap(True)
        side_layout.addWidget(rule)
        side_layout.addStretch()
        splitter.addWidget(side)

        splitter.setStretchFactor(0, 1)
        splitter.setStretchFactor(1, 0)
        splitter.setSizes([800, 330])
        root.addWidget(splitter, 1)

    def _update_char_count(self):
        count = len(self.message_edit.toPlainText())
        self.char_label.setText(f"{count} / 2000")
        self.char_label.setStyleSheet("color: #b06a5a;" if count > 2000 else "")

    def _load_session(self):
        existing = getattr(self.window, "account_session", None)
        if existing is not None:
            return existing
        raw = None
        if hasattr(self.window, "_settings_get"):
            raw = self.window._settings_get("community_session")
        if isinstance(raw, dict):
            return CommunitySession.from_dict(raw)
        if isinstance(raw, str) and raw.strip():
            try:
                return CommunitySession.from_dict(json.loads(raw))
            except ValueError:
                return None
        return None

    def _save_session(self):
        if not hasattr(self.window, "window_settings_set"):
            return
        value = self.session.to_dict() if self.session else {}
        self.window.window_settings_set("community_session", value)

    def apply_account_session(self, session):
        """主窗口统一账号状态变化后，同步社区页面。"""
        self.session = session
        self.posts = [] if session is None else self.posts
        self._last_error = ""
        self._set_identity()
        self._render_feed()
        if session is not None and self.isVisible():
            self.refresh_posts(force=True)

    def _make_board_filter(self):
        self.board_filter = QComboBox()
        self.board_filter.addItem("全部板块", "")
        self.board_filter.setMinimumWidth(125)
        self.board_filter.currentIndexChanged.connect(
            self._board_filter_changed
        )
        return self.board_filter

    def _populate_boards(self):
        current = str(self.current_board or "")
        self.board_filter.blockSignals(True)
        self.board_filter.clear()
        self.board_filter.addItem("全部板块", "")
        for board in self.boards:
            self.board_filter.addItem(
                f"{board.get('icon') or '*'} {board.get('name') or '板块'}",
                str(board.get("id") or ""),
            )
        index = self.board_filter.findData(current)
        self.board_filter.setCurrentIndex(max(0, index))
        self.board_filter.blockSignals(False)

        compose_current = self.board_box.currentData() if self.board_box.count() else ""
        self.board_box.blockSignals(True)
        self.board_box.clear()
        for board in self.boards:
            if board.get("allow_posts"):
                self.board_box.addItem(
                    f"{board.get('icon') or '*'} {board.get('name') or '板块'}",
                    str(board.get("id") or ""),
                )
        if compose_current:
            compose_index = self.board_box.findData(compose_current)
            if compose_index >= 0:
                self.board_box.setCurrentIndex(compose_index)
        self.board_box.blockSignals(False)

    def _board_filter_changed(self):
        self.current_board = str(self.board_filter.currentData() or "")
        self.refresh_posts(force=True)

    def _board_compose_changed(self):
        if self.board_box.currentData():
            self.current_board = str(self.board_box.currentData())
            self._populate_boards()

    def _set_bookmark_filter(self, checked):
        self.bookmarked_only = bool(checked)
        self.refresh_posts(force=True)

    def _set_identity(self):
        logged = self.session is not None
        self.login_button.setVisible(not logged)
        self.logout_button.setVisible(logged)
        self.message_edit.setEnabled(logged)
        self.topic_box.setEnabled(logged)
        self.board_box.setEnabled(logged)
        self.publish_button.setEnabled(logged)
        self.search_edit.setEnabled(logged)
        self.search_button.setEnabled(logged)
        self.bookmark_button.setEnabled(logged)
        self.notifications_button.setEnabled(logged)
        self.pinned_box.setVisible(logged and self.can_manage)
        self.featured_box.setVisible(logged and self.can_manage)
        self.boards_button.setVisible(logged and self.can_manage)
        if logged:
            self.identity_label.setText(f"{self.session.name} · 已登录")
            self.profile_name.setText(self.session.name)
            self.profile_role.setText(
                f"{ROLE_LABELS.get(self.session.role, '成员')} · 可以发布社区消息"
            )
        else:
            self.identity_label.setText("尚未登录")
            self.profile_name.setText("尚未登录")
            self.profile_role.setText("登录后即可看到全部成员的消息并发布")
        self._update_char_count()

    def _clear_feed(self):
        while self.feed_layout.count():
            item = self.feed_layout.takeAt(0)
            widget = item.widget()
            if widget is not None:
                # deleteLater() 要等事件循环，登录切换的同一帧里新旧空状态
                # 会短暂叠在一起。先解除父子关系，立即从界面移除。
                widget.hide()
                widget.setParent(None)
                widget.deleteLater()

    def _empty_card(self, title, body):
        card = QFrame()
        card.setObjectName("CommunityEmptyCard")
        layout = QVBoxLayout(card)
        layout.setContentsMargins(20, 24, 20, 24)
        layout.setSpacing(6)
        title_label = label(title, "CommunityEmptyTitle")
        title_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(title_label)
        body_label = QLabel(body)
        body_label.setObjectName("CommunityEmptyBody")
        body_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        body_label.setWordWrap(True)
        layout.addWidget(body_label)
        return card

    def _render_feed(self):
        self._clear_feed()
        if self.session is None:
            self.feed_layout.addWidget(self._empty_card(
                "登录后进入星球广场",
                "社区消息对所有成员可见。登录你的账号后，就能看到大家发的消息，也能发布自己的消息。",
            ))
            self.feed_layout.addStretch()
            self.feed_status.setText("尚未登录")
            return
        if self._last_error and not self.posts:
            self.feed_layout.addWidget(self._empty_card(
                "社区暂时没有加载出来", self._last_error
            ))
            if ("community.sql" in self._last_error
                    or "community-forum-v1.sql" in self._last_error):
                setup_button = QPushButton("复制安装 SQL")
                setup_button.setObjectName("GhostButton")
                setup_button.clicked.connect(self._copy_setup_sql)
                self.feed_layout.addWidget(
                    setup_button, 0, Qt.AlignmentFlag.AlignHCenter
                )
            self.feed_layout.addStretch()
            return
        if not self.posts:
            if self._busy:
                title = "正在加载"
                text = "正在从星球同步消息…"
            else:
                title = "这里还很安静"
                text = "还没有人发消息。你可以成为第一个，把此刻的问题或经验发到星球上。"
            self.feed_layout.addWidget(self._empty_card(title, text))
            self.feed_layout.addStretch()
            return

        for post in self.posts:
            is_mine = bool(
                self.session and post.get("author_id") == self.session.user_id
            )
            card = CommunityMessageCard(
                post, is_mine=is_mine, can_manage=self.can_manage
            )
            card.delete_requested.connect(self.delete_post)
            card.unlock_requested.connect(self.unlock_post)
            card.like_requested.connect(self.toggle_like)
            card.bookmark_requested.connect(self.toggle_bookmark)
            card.comments_requested.connect(self.open_comments)
            card.report_requested.connect(self.report_post)
            card.moderation_requested.connect(self.open_moderation)
            self.feed_layout.addWidget(card)
        self.feed_layout.addStretch()

    def _copy_setup_sql(self):
        sql = community_setup_sql()
        if not sql:
            QMessageBox.warning(
                self, "找不到安装脚本",
                "请打开项目里的 mobile/sql/community-forum-v1.sql 并手动复制。",
            )
            return
        QApplication.clipboard().setText(sql)
        QMessageBox.information(
            self, "安装 SQL 已复制",
            "到 Supabase → SQL Editor 新建查询，粘贴并运行。\n"
            "运行完成后回到这里点「刷新」。",
        )

    def _spawn(self, work, on_done, on_error):
        worker = CommunityWorker(work, self)
        self._workers.append(worker)

        def cleanup():
            if worker in self._workers:
                self._workers.remove(worker)
            worker.deleteLater()

        worker.done.connect(on_done)
        worker.failed.connect(on_error)
        worker.finished.connect(cleanup)
        worker.start()

    def _auto_refresh(self):
        if self.isVisible() and self.session is not None:
            self.refresh_posts(force=False)

    def on_activated(self):
        if self.session is not None:
            self.refresh_posts(force=False)

    def shutdown(self):
        """窗口关闭前让网络线程结束，避免 QThread 随控件一起销毁。"""
        self.timer.stop()
        for worker in list(self._workers):
            if worker.isRunning():
                worker.wait(12000)

    def _refresh_after(self, session, board_id=None, search="", bookmarked=False):
        return (
            session,
            self.client.boards(session),
            self.client.list_posts_v2(
                session, board_id=board_id, search=search, limit=50,
                bookmarked=bookmarked,
            ),
        )

    def toggle_like(self, post_id):
        if self.session is None or self._busy:
            return
        self._busy = True
        old_session = self.session
        board_id = self.current_board or None
        search = self.search_edit.text().strip()
        bookmarked = bool(self.bookmark_button.isChecked())

        def work():
            session = old_session
            if session.is_expired():
                session = self.client.refresh(session)
            self.client.toggle_like(session, post_id)
            return self._refresh_after(session, board_id, search, bookmarked)

        self._spawn(
            work, lambda result: self._on_posts_loaded(*result),
            self._on_publish_failed,
        )

    def toggle_bookmark(self, post_id):
        if self.session is None or self._busy:
            return
        self._busy = True
        old_session = self.session
        board_id = self.current_board or None
        search = self.search_edit.text().strip()
        bookmarked = bool(self.bookmark_button.isChecked())

        def work():
            session = old_session
            if session.is_expired():
                session = self.client.refresh(session)
            self.client.toggle_bookmark(session, post_id)
            return self._refresh_after(session, board_id, search, bookmarked)

        self._spawn(
            work, lambda result: self._on_posts_loaded(*result),
            self._on_publish_failed,
        )

    def report_post(self, post_id):
        if self.session is None:
            return
        reason, ok = QInputDialog.getText(
            self, "举报内容", "举报原因（例如：垃圾内容、攻击、隐私泄露）："
        )
        if not ok or not reason.strip():
            return
        if self._busy:
            return
        self._busy = True
        old_session = self.session

        def work():
            session = old_session
            if session.is_expired():
                session = self.client.refresh(session)
            self.client.report_content(session, post_id=post_id, reason=reason)
            return session

        def done(session):
            self._busy = False
            self.session = session
            QMessageBox.information(self, "举报已提交", "管理员会处理这条举报。")

        self._spawn(work, done, self._on_publish_failed)

    def open_comments(self, post_id):
        if self.session is None or self._busy:
            return
        self._busy = True
        old_session = self.session

        def work():
            session = old_session
            if session.is_expired():
                session = self.client.refresh(session)
            return session, self.client.post_detail(session, post_id)

        self._spawn(
            work,
            lambda result: self._show_comments(post_id, *result),
            self._on_publish_failed,
        )

    def _show_comments(self, post_id, session, data):
        self._busy = False
        self.session = session
        post = (data or {}).get("post") or {}
        comments = (data or {}).get("comments") or []
        dialog = QDialog(self)
        dialog.setWindowTitle("评论 · " + str(post.get("author_name") or "帖子"))
        dialog.setMinimumSize(560, 480)
        layout = QVBoxLayout(dialog)
        layout.setContentsMargins(18, 16, 18, 16)
        layout.setSpacing(9)
        layout.addWidget(label(str(post.get("preview") or ""), "CommunityMessageBody"))
        comment_list = QListWidget()
        for item in comments:
            comment_list.addItem(
                "{}  {}：{}".format(
                    _friendly_time(item.get("created_at")),
                    item.get("author_name") or "成员",
                    item.get("body") or "",
                )
            )
        layout.addWidget(comment_list, 1)
        editor = QTextEdit()
        editor.setPlaceholderText("写下你的回复…")
        editor.setMinimumHeight(80)
        layout.addWidget(editor)
        buttons = QHBoxLayout()
        buttons.addStretch()
        close_button = QPushButton("关闭")
        close_button.setObjectName("GhostButton")
        close_button.clicked.connect(dialog.accept)
        buttons.addWidget(close_button)
        send_button = QPushButton("发送评论")
        send_button.setObjectName("PrimaryButton")
        buttons.addWidget(send_button)
        layout.addLayout(buttons)

        def send():
            body = editor.toPlainText().strip()
            if not body:
                return
            send_button.setEnabled(False)
            old_session = self.session

            def work():
                session = old_session
                if session.is_expired():
                    session = self.client.refresh(session)
                self.client.add_comment(session, post_id, body)
                return session

            def done(new_session):
                self.session = new_session
                send_button.setEnabled(True)
                editor.clear()
                comment_list.addItem(
                    "刚刚  {}：{}".format(self.session.name, body)
                )
                item = next(
                    (row for row in self.posts
                     if str(row.get("id")) == str(post_id)), None
                )
                if item:
                    item["comment_count"] = int(item.get("comment_count") or 0) + 1
                self._render_feed()

            self._spawn(work, done, self._on_publish_failed)

        send_button.clicked.connect(send)
        dialog.exec()

    def open_moderation(self, post_id):
        if not self.can_manage or self._busy:
            return
        post = next(
            (row for row in self.posts if str(row.get("id")) == str(post_id)),
            {},
        )
        dialog = QDialog(self)
        dialog.setWindowTitle("管理内容")
        dialog.setMinimumWidth(420)
        layout = QVBoxLayout(dialog)
        pinned = QCheckBox("置顶")
        pinned.setChecked(bool(post.get("pinned")))
        featured = QCheckBox("设为精选")
        featured.setChecked(bool(post.get("featured")))
        deleted = QCheckBox("隐藏这条内容")
        layout.addWidget(pinned)
        layout.addWidget(featured)
        layout.addWidget(deleted)
        row = QHBoxLayout()
        row.addStretch()
        cancel = QPushButton("取消")
        cancel.setObjectName("GhostButton")
        cancel.clicked.connect(dialog.reject)
        row.addWidget(cancel)
        save = QPushButton("保存")
        save.setObjectName("PrimaryButton")
        row.addWidget(save)
        layout.addLayout(row)

        def commit():
            old_session = self.session
            board_id = self.current_board or None
            search = self.search_edit.text().strip()
            bookmarked = bool(self.bookmark_button.isChecked())

            def work():
                session = old_session
                if session.is_expired():
                    session = self.client.refresh(session)
                self.client.moderate_post(
                    session, post_id, pinned=pinned.isChecked(),
                    featured=featured.isChecked(),
                    deleted=deleted.isChecked(),
                )
                return self._refresh_after(session, board_id, search, bookmarked)

            def done(result):
                dialog.accept()
                self._on_posts_loaded(*result)

            self._spawn(work, done, self._on_publish_failed)

        save.clicked.connect(commit)
        dialog.exec()

    def open_notifications(self):
        if self.session is None or self._busy:
            return
        self._busy = True
        old_session = self.session

        def work():
            session = old_session
            if session.is_expired():
                session = self.client.refresh(session)
            return session, self.client.notifications(session, limit=50)

        def done(result):
            self._busy = False
            session, data = result
            self.session = session
            dialog = QDialog(self)
            dialog.setWindowTitle("社区通知")
            dialog.setMinimumSize(520, 420)
            layout = QVBoxLayout(dialog)
            listing = QListWidget()
            for item in (data or {}).get("notifications") or []:
                listing.addItem(
                    "{}  {}  {}".format(
                        "" if item.get("read_at") else "●",
                        item.get("title") or "社区通知",
                        _friendly_time(item.get("created_at")),
                    )
                )
            layout.addWidget(listing, 1)
            row = QHBoxLayout()
            row.addStretch()
            read_all = QPushButton("全部标为已读")
            read_all.setObjectName("GhostButton")
            close = QPushButton("关闭")
            close.setObjectName("PrimaryButton")
            close.clicked.connect(dialog.accept)
            row.addWidget(read_all)
            row.addWidget(close)
            layout.addLayout(row)

            def mark_all():
                try:
                    self.client.mark_notifications_read(session)
                    self.refresh_posts(force=True)
                    dialog.accept()
                except Exception as error:
                    QMessageBox.warning(dialog, "操作失败", str(error))

            read_all.clicked.connect(mark_all)
            dialog.exec()

        self._spawn(work, done, self._on_publish_failed)

    def open_board_manager(self):
        if not self.can_manage or self.session is None:
            return
        dialog = QDialog(self)
        dialog.setWindowTitle("管理社区板块")
        dialog.setMinimumSize(520, 500)
        layout = QVBoxLayout(dialog)
        board_box = QComboBox()
        board_box.addItem("新建板块", "")
        for board in self.boards:
            if board.get("can_edit"):
                board_box.addItem(str(board.get("name") or "板块"), str(board.get("id")))
        layout.addWidget(board_box)
        name = QLineEdit()
        slug = QLineEdit()
        desc = QTextEdit()
        desc.setMinimumHeight(80)
        visibility = QComboBox()
        visibility.addItem("公开", "public")
        visibility.addItem("按权限", "restricted")
        permissions = QLineEdit()
        permissions.setPlaceholderText("例如 finance.view,audit.read")
        layout.addWidget(label("板块名称", "CommunityFieldLabel"))
        layout.addWidget(name)
        layout.addWidget(label("板块短名", "CommunityFieldLabel"))
        layout.addWidget(slug)
        layout.addWidget(label("说明", "CommunityFieldLabel"))
        layout.addWidget(desc)
        layout.addWidget(label("可见范围", "CommunityFieldLabel"))
        layout.addWidget(visibility)
        layout.addWidget(label("所需权限（逗号分隔）", "CommunityFieldLabel"))
        layout.addWidget(permissions)

        def load_board(_index=None):
            board = next(
                (row for row in self.boards
                 if str(row.get("id") or "") == str(board_box.currentData() or "")),
                None,
            )
            name.setText(str((board or {}).get("name") or ""))
            slug.setText(str((board or {}).get("slug") or ""))
            slug.setEnabled(not bool(board))
            desc.setPlainText(str((board or {}).get("description") or ""))
            visibility.setCurrentIndex(
                visibility.findData(str((board or {}).get("visibility") or "public"))
            )
            permissions.setText(",".join((board or {}).get("required_permissions") or []))

        board_box.currentIndexChanged.connect(load_board)
        load_board()
        row = QHBoxLayout()
        stats_button = QPushButton("社区数据")
        stats_button.setObjectName("GhostButton")
        cancel = QPushButton("关闭")
        cancel.setObjectName("GhostButton")
        cancel.clicked.connect(dialog.reject)
        save = QPushButton("保存板块")
        save.setObjectName("PrimaryButton")
        row.addWidget(stats_button)
        row.addStretch()
        row.addWidget(cancel)
        row.addWidget(save)
        layout.addLayout(row)

        def save_board():
            selected = str(board_box.currentData() or "")
            perms = [item.strip() for item in permissions.text().split(",") if item.strip()]
            old_session = self.session

            def work():
                session = old_session
                if session.is_expired():
                    session = self.client.refresh(session)
                if selected:
                    result = self.client.update_board(
                        session, selected, name.text(), desc.toPlainText(),
                        visibility.currentData(), perms, "*", False,
                    )
                else:
                    result = self.client.create_board(
                        session, name.text(), slug.text(), desc.toPlainText(),
                        visibility.currentData(), perms, "*",
                    )
                return session, result

            def done(result):
                session, _payload = result
                self.session = session
                dialog.accept()
                self.refresh_posts(force=True)
                if hasattr(self.window, "flash"):
                    self.window.flash("社区板块已保存")

            self._spawn(work, done, self._on_publish_failed)

        def show_stats():
            old_session = self.session

            def work():
                session = old_session
                if session.is_expired():
                    session = self.client.refresh(session)
                return self.client.admin_stats(session)

            def done(data):
                QMessageBox.information(
                    dialog, "社区数据",
                    json.dumps(data.get("stats") or {}, ensure_ascii=False, indent=2),
                )

            self._spawn(work, done, self._on_publish_failed)

        save.clicked.connect(save_board)
        stats_button.clicked.connect(show_stats)
        dialog.exec()

    def refresh_posts(self, force=True):
        if self.session is None:
            self._render_feed()
            return
        if self._busy:
            return
        now = time.time()
        if not force and now - self._last_refresh < 6:
            return
        self._busy = True
        self._last_error = ""
        self.feed_status.setText("同步中…")
        old_session = self.session

        board_id = str(self.current_board or "") or None
        search = self.search_edit.text().strip()
        bookmarked = bool(self.bookmark_button.isChecked())

        def work():
            session = old_session
            if session.is_expired():
                session = self.client.refresh(session)
            boards = self.client.boards(session)
            posts = self.client.list_posts_v2(
                session, board_id=board_id, search=search,
                limit=50, bookmarked=bookmarked,
            )
            return session, boards, posts

        self._spawn(
            work,
            lambda result: self._on_posts_loaded(*result),
            self._on_posts_failed,
        )

    def _on_posts_loaded(self, session, board_data, post_data):
        self._busy = False
        self._last_refresh = time.time()
        self._last_error = ""
        self.session = session
        if hasattr(self.window, "account_session"):
            self.window.account_session = session
        self._save_session()
        board_data = board_data if isinstance(board_data, dict) else {}
        post_data = post_data if isinstance(post_data, dict) else {}
        self.boards = list(board_data.get("boards") or [])
        self.can_manage = bool(
            (board_data.get("access") or {}).get("can_manage")
        )
        self.posts = list(post_data.get("posts") or [])
        self._populate_boards()
        self.notifications_button.setText(
            f"通知 {int(board_data.get('unread_count') or 0)}"
        )
        self.boards_button.setVisible(self.can_manage)
        self.pinned_box.setVisible(self.can_manage)
        self.featured_box.setVisible(self.can_manage)
        self.feed_status.setText(f"{len(self.posts)} 条 · 刚刚更新")
        self._set_identity()
        self._render_feed()
        self.feed_scroll.verticalScrollBar().setValue(0)

    def _on_posts_failed(self, message):
        self._busy = False
        message = str(message or "")
        if (("get_community_boards" in message
             or "list_community_posts_v2" in message
             or "community_boards" in message)
                and any(marker in message.lower()
                        for marker in ("does not exist", "could not find",
                                       "not found"))):
            message = ("社区 v2.1 数据尚未安装。请在 Supabase SQL Editor 运行 "
                       "mobile/sql/community-forum-v1.sql，然后点刷新。")
        self._last_error = message
        if "重新登录" in message:
            if hasattr(self.window, "account_session_expired"):
                self.window.account_session_expired()
            self.session = None
            self.posts = []
            self._save_session()
            self._set_identity()
            self._render_feed()
            self.feed_status.setText("登录已过期，请重新登录")
            return
        self.feed_status.setText("加载失败")
        self._render_feed()

    def open_login(self):
        dialog = CommunityLoginDialog(self.window)
        if dialog.exec() == QDialog.DialogCode.Accepted and dialog.session:
            if hasattr(self.window, "set_account_session"):
                self.window.set_account_session(dialog.session)
            else:
                self.session = dialog.session
                self._save_session()
                self._last_error = ""
                self._set_identity()
                self.refresh_posts(force=True)
            if hasattr(self.window, "flash"):
                self.window.flash(f"{self.session.name} 已加入星球广场")

    def logout(self):
        answer = QMessageBox.question(
            self, "退出社区",
            "退出后社区消息会从本机隐藏，下次登录还能看到。\n确定退出吗？",
        )
        if answer != QMessageBox.StandardButton.Yes:
            return
        if hasattr(self.window, "logout_account"):
            self.window.logout_account(confirm=False)
        else:
            self.session = None
            self.posts = []
            self._last_error = ""
            self._save_session()
            self._set_identity()
            self._render_feed()

    def publish(self):
        if self.session is None:
            self.open_login()
            return
        content = self.message_edit.toPlainText().strip()
        if not content:
            QMessageBox.information(self, "还没写内容", "先写一条消息再发布。")
            self.message_edit.setFocus()
            return
        if len(content) > 2000:
            QMessageBox.information(self, "消息太长", "请控制在 2000 字以内。")
            return
        board_id = str(self.board_box.currentData() or "")
        if not board_id:
            QMessageBox.information(self, "先选板块", "请选择要发布到的板块。")
            return
        if self._busy:
            return
        self._busy = True
        topic = self.topic_box.currentText()
        self.publish_button.setEnabled(False)
        self.publish_button.setText("发送中…")
        old_session = self.session
        cost = self.unlock_cost.value()
        required = self.required_box.isChecked()
        pinned = bool(self.pinned_box.isChecked() and self.can_manage)
        featured = bool(self.featured_box.isChecked() and self.can_manage)
        search = self.search_edit.text().strip()
        bookmarked = bool(self.bookmark_button.isChecked())

        def work():
            session = old_session
            if session.is_expired():
                session = self.client.refresh(session)
            result = self.client.publish_v2(
                session, content, board_id=board_id, topic=topic,
                unlock_cost=cost, is_required=required,
            )
            post_id = (result or {}).get("id")
            if post_id and (pinned or featured):
                self.client.moderate_post(
                    session, post_id, pinned=pinned, featured=featured
                )
            boards = self.client.boards(session)
            posts = self.client.list_posts_v2(
                session, board_id=board_id or None, search=search,
                limit=50, bookmarked=bookmarked,
            )
            return session, boards, posts

        self._spawn(
            work,
            lambda result: self._on_published(*result),
            self._on_publish_failed,
        )

    def _on_published(self, session, board_data, post_data):
        self._busy = False
        self.message_edit.clear()
        self.unlock_cost.setValue(0)
        self.required_box.setChecked(False)
        self.pinned_box.setChecked(False)
        self.featured_box.setChecked(False)
        self.publish_button.setEnabled(True)
        self.publish_button.setText("发布消息")
        self._on_posts_loaded(session, board_data, post_data)
        if hasattr(self.window, "flash"):
            self.window.flash("讨论已发布到板块")

    def _on_publish_failed(self, message):
        self._busy = False
        self.publish_button.setEnabled(True)
        self.publish_button.setText("发布消息")
        self._last_error = message
        if "重新登录" in message:
            if hasattr(self.window, "account_session_expired"):
                self.window.account_session_expired()
            self.session = None
            self._save_session()
            self._set_identity()
            self._render_feed()
            self.feed_status.setText("登录已过期，请重新登录")
        else:
            self.feed_status.setText("发布失败")
            self._render_feed()
        QMessageBox.warning(self, "发布失败", message)

    def unlock_post(self, post_id):
        if self.session is None:
            self.open_login()
            return
        post = next(
            (item for item in self.posts if str(item.get("id")) == str(post_id)),
            None,
        )
        cost = int((post or {}).get("unlock_cost") or 0)
        if QMessageBox.question(
            self, "永久解锁知识",
            f"使用 {cost} 积分解锁这篇知识？解锁后可永久查看。",
        ) != QMessageBox.StandardButton.Yes:
            return
        if self._busy:
            return
        self._busy = True
        old_session = self.session
        board_id = self.current_board or None
        search = self.search_edit.text().strip()
        bookmarked = bool(self.bookmark_button.isChecked())

        def work():
            session = old_session
            if session.is_expired():
                session = self.client.refresh(session)
            self.client.unlock_knowledge(session, post_id)
            return self._refresh_after(session, board_id, search, bookmarked)

        self._spawn(
            work,
            lambda result: self._on_published(*result),
            self._on_publish_failed,
        )

    def delete_post(self, post_id):
        if self.session is None:
            return
        answer = QMessageBox.question(
            self, "删除消息", "确定从社区删除这条消息吗？所有成员都将看不到它。"
        )
        if answer != QMessageBox.StandardButton.Yes:
            return
        if self._busy:
            return
        self._busy = True
        old_session = self.session
        board_id = self.current_board or None
        search = self.search_edit.text().strip()
        bookmarked = bool(self.bookmark_button.isChecked())

        def work():
            session = old_session
            if session.is_expired():
                session = self.client.refresh(session)
            self.client.delete_post(session, post_id)
            return self._refresh_after(session, board_id, search, bookmarked)

        self._spawn(
            work,
            lambda result: self._on_published(*result),
            self._on_publish_failed,
        )
