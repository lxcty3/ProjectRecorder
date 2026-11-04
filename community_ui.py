"""知识星球 · 星球广场：所有成员共同看到、共同发布的社区页面。"""
import datetime
import json
import time

from PyQt6.QtCore import QThread, QTimer, Qt, pyqtSignal
from PyQt6.QtGui import QColor
from PyQt6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QDialog, QFrame, QHBoxLayout, QLabel,
    QLineEdit, QMessageBox, QPushButton, QScrollArea, QSizePolicy, QSpinBox,
    QSplitter, QTextEdit, QVBoxLayout, QWidget,
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

    def __init__(self, post, is_mine=False, parent=None):
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
        identity.addWidget(label(
            f"{topic} · {_friendly_time(post.get('created_at'))}",
            "CommunityMeta",
        ))
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

class CommunityPage(QWidget):
    """共享社区：消息保存在 Supabase，所有成员看到同一份数据。"""

    REFRESH_MS = 12000

    def __init__(self, window):
        super().__init__()
        self.window = window
        self.client = CommunityClient()
        self.session = self._load_session()
        self.posts = []
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
        feed_head.addWidget(SectionTitle("全员消息"))
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

        side_layout.addWidget(SectionTitle("发到星球"))
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

    def _set_identity(self):
        logged = self.session is not None
        self.login_button.setVisible(not logged)
        self.logout_button.setVisible(logged)
        self.message_edit.setEnabled(logged)
        self.topic_box.setEnabled(logged)
        self.publish_button.setEnabled(logged)
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
            if "community.sql" in self._last_error:
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
            card = CommunityMessageCard(post, is_mine=is_mine)
            card.delete_requested.connect(self.delete_post)
            card.unlock_requested.connect(self.unlock_post)
            self.feed_layout.addWidget(card)
        self.feed_layout.addStretch()

    def _copy_setup_sql(self):
        sql = community_setup_sql()
        if not sql:
            QMessageBox.warning(
                self, "找不到安装脚本",
                "请打开项目里的 mobile/sql/community.sql 并手动复制。",
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

        def work():
            session = old_session
            if session.is_expired():
                session = self.client.refresh(session)
            return session, self.client.list_posts(session)

        self._spawn(
            work,
            lambda result: self._on_posts_loaded(*result),
            self._on_posts_failed,
        )

    def _on_posts_loaded(self, session, posts):
        self._busy = False
        self._last_refresh = time.time()
        self._last_error = ""
        self.session = session
        if hasattr(self.window, "account_session"):
            self.window.account_session = session
        self._save_session()
        self.posts = list(posts or [])
        self.feed_status.setText(f"{len(self.posts)} 条 · 刚刚更新")
        self._set_identity()
        self._render_feed()
        self.feed_scroll.verticalScrollBar().setValue(0)

    def _on_posts_failed(self, message):
        self._busy = False
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
        if self._busy:
            return
        self._busy = True
        topic = self.topic_box.currentText()
        self.publish_button.setEnabled(False)
        self.publish_button.setText("发送中…")
        old_session = self.session

        cost = self.unlock_cost.value()
        required = self.required_box.isChecked()

        def work():
            session = old_session
            if session.is_expired():
                session = self.client.refresh(session)
            self.client.publish(session, content, topic, cost, required)
            return session, self.client.list_posts(session)

        self._spawn(
            work,
            lambda result: self._on_published(*result),
            self._on_publish_failed,
        )

    def _on_published(self, session, posts):
        self._busy = False
        self.session = session
        if hasattr(self.window, "account_session"):
            self.window.account_session = session
        self._save_session()
        self.posts = list(posts or [])
        self.message_edit.clear()
        self.unlock_cost.setValue(0)
        self.required_box.setChecked(False)
        self.publish_button.setEnabled(True)
        self.publish_button.setText("发布消息")
        self._set_identity()
        self.feed_status.setText(f"{len(self.posts)} 条 · 刚刚更新")
        self._render_feed()
        self.feed_scroll.verticalScrollBar().setValue(0)
        if hasattr(self.window, "flash"):
            self.window.flash("消息已发布，所有成员都能看到")

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

        def work():
            session = old_session
            if session.is_expired():
                session = self.client.refresh(session)
            self.client.unlock_knowledge(session, post_id)
            return session, self.client.list_posts(session)

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

        def work():
            session = old_session
            if session.is_expired():
                session = self.client.refresh(session)
            self.client.delete_post(session, post_id)
            return session, self.client.list_posts(session)

        self._spawn(
            work,
            lambda result: self._on_published(*result),
            self._on_publish_failed,
        )
