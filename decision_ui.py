"""Desktop decision center for Phase 2A."""

from __future__ import annotations

import datetime
import json

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (
    QAbstractItemView,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QMessageBox,
    QPushButton,
    QSplitter,
    QTableWidget,
    QTableWidgetItem,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from community_client import CommunityClient
from community_ui import CommunityWorker
from widgets import SectionTitle, label, muted


RISK_LABELS = {
    "severe": "严重",
    "risk": "风险",
    "attention": "关注",
    "healthy": "健康",
}
KIND_LABELS = {
    "leave": "请假",
    "worklog": "工时",
    "expense": "费用",
    "purchase": "采购",
    "reward": "奖励",
    "task_extension": "任务延期",
    "identity_motion": "身份事项",
}
STATUS_LABELS = {
    "open": "待处理",
    "acknowledged": "已确认",
    "assigned": "已分派",
    "deferred": "已延期",
    "resolved": "已解决",
    "dismissed": "已关闭",
    "pending": "待审批",
    "approved": "已批准",
    "rejected": "已拒绝",
    "returned": "退回补充",
    "cancelled": "已取消",
}


def _short_time(value):
    text = str(value or "").strip()
    if not text:
        return "—"
    try:
        parsed = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
        return parsed.astimezone().strftime("%Y-%m-%d %H:%M")
    except (TypeError, ValueError, OverflowError):
        return text[:16].replace("T", " ")


def _money(value):
    try:
        return f"¥{float(value or 0):,.2f}"
    except (TypeError, ValueError):
        return "¥0.00"


def _evidence_text(item, fallback_title=""):
    lines = [fallback_title or str(item.get("title") or "")]
    detail = str(item.get("detail") or "").strip()
    if detail:
        lines.extend(["", detail])
    lines.extend([
        "",
        f"风险：{RISK_LABELS.get(str(item.get('risk') or ''), item.get('risk') or '健康')}",
        f"影响：{int(item.get('impact_days') or 0)} 天 / {_money(item.get('impact_amount', item.get('amount', 0)))}",
        f"负责人：{item.get('owner_name') or '未指派'}",
        f"截止：{_short_time(item.get('due_at'))}",
    ])
    evidence = item.get("evidence")
    if evidence:
        lines.extend(["", "来源证据："])
        entries = evidence if isinstance(evidence, list) else [evidence]
        for entry in entries:
            if isinstance(entry, dict):
                source_type = entry.get("type") or entry.get("source_type") or "记录"
                source_id = entry.get("id") or entry.get("source_id") or ""
                extras = " · ".join(
                    f"{key}={value}"
                    for key, value in entry.items()
                    if key not in {"type", "source_type", "id", "source_id"}
                    and value not in (None, "", [], {})
                )
                lines.append(
                    f"· {source_type} {source_id}"
                    + (f"（{extras}）" if extras else "")
                )
            else:
                lines.append(f"· {json.dumps(entry, ensure_ascii=False)}")
    else:
        lines.extend(["", "来源证据：暂无结构化证据"])
    return "\n".join(lines)


class DecisionCenterPage(QWidget):
    """Read and act on the server-owned decision/approval queues."""

    def __init__(self, window):
        super().__init__()
        self.window = window
        self.session = None
        self.snapshot = {"decisions": [], "approvals": [], "members": []}
        self.workers = []
        self._busy = False

        root = QVBoxLayout(self)
        root.setContentsMargins(18, 16, 18, 14)
        root.setSpacing(10)

        header = QHBoxLayout()
        title_box = QVBoxLayout()
        title_box.setSpacing(2)
        title_box.addWidget(label("经营决策中心", "KnowledgeTitle"))
        title_box.addWidget(muted(
            "先处理影响交付、金额和等待时间最大的事项；所有操作由服务端校验并审计。"
        ))
        header.addLayout(title_box, 1)
        self.refresh_button = QPushButton("刷新")
        self.refresh_button.setObjectName("GhostButton")
        self.refresh_button.clicked.connect(self.refresh)
        header.addWidget(self.refresh_button)
        root.addLayout(header)

        splitter = QSplitter(Qt.Orientation.Horizontal)
        splitter.setChildrenCollapsible(False)
        root.addWidget(splitter, 1)

        left = QWidget()
        left_layout = QVBoxLayout(left)
        left_layout.setContentsMargins(0, 0, 8, 0)
        left_layout.setSpacing(7)
        left_layout.addWidget(SectionTitle("决策队列"))
        self.decision_table = self._table([
            "风险", "事项", "影响", "负责人", "截止", "状态",
        ])
        self.decision_table.itemSelectionChanged.connect(self._decision_selected)
        left_layout.addWidget(self.decision_table, 1)
        decision_actions = QHBoxLayout()
        decision_actions.setSpacing(6)
        self.decision_action_buttons = {}
        for key, text in (
            ("acknowledge", "确认"),
            ("assign", "分派"),
            ("defer", "延期"),
            ("resolve", "解决"),
            ("dismiss", "关闭"),
        ):
            button = QPushButton(text)
            button.setObjectName("GhostButton")
            button.clicked.connect(
                lambda _, action=key: self._invoke_decision_action(action)
            )
            button.setEnabled(False)
            self.decision_action_buttons[key] = button
            decision_actions.addWidget(button)
        decision_actions.addStretch()
        left_layout.addLayout(decision_actions)

        left_layout.addWidget(SectionTitle("统一审批"))
        self.approval_table = self._table([
            "类型", "事项", "金额", "影响", "申请人", "截止", "状态",
        ])
        self.approval_table.itemSelectionChanged.connect(
            self._approval_selected
        )
        left_layout.addWidget(self.approval_table, 1)
        approval_actions = QHBoxLayout()
        approval_actions.setSpacing(6)
        self.approval_action_buttons = {}
        for key, text in (
            ("approve", "批准"),
            ("reject", "拒绝"),
            ("return", "退回补充"),
            ("cancel", "取消"),
        ):
            button = QPushButton(text)
            button.setObjectName("GhostButton")
            button.clicked.connect(
                lambda _, action=key: self._invoke_approval_action(action)
            )
            button.setEnabled(False)
            self.approval_action_buttons[key] = button
            approval_actions.addWidget(button)
        approval_actions.addStretch()
        left_layout.addLayout(approval_actions)
        splitter.addWidget(left)

        right = QWidget()
        right_layout = QVBoxLayout(right)
        right_layout.setContentsMargins(8, 0, 0, 0)
        right_layout.setSpacing(7)
        right_layout.addWidget(SectionTitle("证据与影响"))
        self.detail_view = QTextEdit()
        self.detail_view.setReadOnly(True)
        self.detail_view.setObjectName("DecisionEvidence")
        self.detail_view.setPlaceholderText(
            "选择一条决策或审批，查看来源证据、影响、负责人和截止时间。"
        )
        right_layout.addWidget(self.detail_view, 1)
        self.status_label = QLabel("")
        self.status_label.setWordWrap(True)
        self.status_label.setObjectName("DecisionStatus")
        right_layout.addWidget(self.status_label)
        splitter.addWidget(right)
        splitter.setSizes([430, 720])

    @staticmethod
    def _table(headers):
        table = QTableWidget(0, len(headers))
        table.setHorizontalHeaderLabels(headers)
        table.verticalHeader().setVisible(False)
        table.setSelectionBehavior(
            QAbstractItemView.SelectionBehavior.SelectRows
        )
        table.setSelectionMode(
            QAbstractItemView.SelectionMode.SingleSelection
        )
        table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        table.horizontalHeader().setStretchLastSection(True)
        return table

    @staticmethod
    def _put_row(table, values, item):
        row = table.rowCount()
        table.insertRow(row)
        for column, text in enumerate(values):
            cell = QTableWidgetItem(str(text))
            if column == 0:
                cell.setData(Qt.ItemDataRole.UserRole, item)
            table.setItem(row, column, cell)

    def apply_account_session(self, session):
        changed = self.session is not session
        self.session = session
        if changed:
            self.refresh()

    def on_activated(self):
        self.refresh()

    def refresh(self):
        if self.session is None:
            self.snapshot = {"decisions": [], "approvals": [], "members": []}
            self.render()
            self._set_status("登录管理账号后加载经营决策。")
            return
        self.refresh_button.setEnabled(False)
        self._start_worker(
            lambda: CommunityClient().decision_center(self.session),
            self._loaded,
            self._load_failed,
        )

    def _start_worker(self, work, done=None, failed=None):
        worker = CommunityWorker(work, self)
        worker.done.connect(done or self._action_done)
        worker.failed.connect(failed or self._action_failed)
        worker.finished.connect(worker.deleteLater)
        worker.finished.connect(
            lambda: self.workers.remove(worker) if worker in self.workers else None
        )
        self.workers.append(worker)
        worker.start()

    def _loaded(self, data):
        self.refresh_button.setEnabled(True)
        self.snapshot = data if isinstance(data, dict) else {}
        self.render()
        count = len(self.snapshot.get("decisions") or []) + len(
            self.snapshot.get("approvals") or []
        )
        self._set_status(f"队列已更新：{count} 项待处理。")

    def _load_failed(self, message):
        self.refresh_button.setEnabled(True)
        self.snapshot = {"decisions": [], "approvals": [], "members": []}
        self.render()
        self._set_status(str(message), error=True)
        self._flash(str(message), 5000)

    def render(self):
        self.decision_table.setRowCount(0)
        decisions = self.snapshot.get("decisions") or []
        for item in decisions:
            self._put_row(self.decision_table, [
                RISK_LABELS.get(str(item.get("risk") or ""), item.get("risk") or "健康"),
                item.get("title") or "决策",
                f"{int(item.get('impact_days') or 0)} 天 / "
                f"{_money(item.get('impact_amount'))}",
                item.get("owner_name") or "未指派",
                _short_time(item.get("due_at")),
                STATUS_LABELS.get(item.get("status"), item.get("status") or ""),
            ], item)

        self.approval_table.setRowCount(0)
        approvals = self.snapshot.get("approvals") or []
        for item in approvals:
            self._put_row(self.approval_table, [
                KIND_LABELS.get(item.get("kind"), item.get("kind") or ""),
                item.get("title") or "审批",
                _money(item.get("amount")),
                f"{int(item.get('impact_days') or 0)} 天",
                item.get("requester_name") or "—",
                _short_time(item.get("due_at")),
                STATUS_LABELS.get(item.get("status"), item.get("status") or ""),
            ], item)

        self._sync_action_buttons()
        if decisions:
            self.decision_table.selectRow(0)
        elif approvals:
            self.approval_table.selectRow(0)
        else:
            self.detail_view.clear()

    def _selected(self, table):
        row = table.currentRow()
        if row < 0:
            return None
        cell = table.item(row, 0)
        data = cell.data(Qt.ItemDataRole.UserRole) if cell else None
        return data if isinstance(data, dict) else None

    def _current_decision(self):
        return self._selected(self.decision_table)

    def _current_approval(self):
        return self._selected(self.approval_table)

    def _decision_selected(self):
        item = self._current_decision()
        if item:
            self.detail_view.setPlainText(_evidence_text(item, "决策证据"))
        self._sync_action_buttons()

    def _approval_selected(self):
        item = self._current_approval()
        if item:
            text = _evidence_text(item, "审批证据")
            text += (
                f"\n\n审批类型：{KIND_LABELS.get(item.get('kind'), item.get('kind') or '')}"
                f"\n申请人：{item.get('requester_name') or '—'}"
                f"\n审批金额：{_money(item.get('amount'))}"
            )
            self.detail_view.setPlainText(text)
        self._sync_action_buttons()

    def _sync_action_buttons(self):
        decision = self._current_decision()
        actions = (decision or {}).get("actions") or {}
        for key, button in self.decision_action_buttons.items():
            button.setEnabled(bool(decision and actions.get(key) and not self._busy))
        approval = self._current_approval()
        actions = (approval or {}).get("actions") or {}
        identity_motion = bool(
            approval and approval.get("kind") == "identity_motion"
        )
        self.approval_action_buttons["approve"].setText(
            "赞成" if identity_motion else "批准"
        )
        self.approval_action_buttons["reject"].setText(
            "反对" if identity_motion else "拒绝"
        )
        for key, button in self.approval_action_buttons.items():
            button.setEnabled(bool(approval and actions.get(key) and not self._busy))

    def _invoke_decision_action(self, action):
        item = self._current_decision()
        if not item:
            return
        owner_id = None
        note = ""
        if action == "assigned":
            members = self.snapshot.get("members") or []
            if not members:
                self._set_status("没有可分派的在职成员。", error=True)
                return
            names = [str(member.get("name") or member.get("id")) for member in members]
            name, accepted = QInputDialog.getItem(
                self, "分派决策", "负责人", names, 0, False
            )
            if not accepted:
                return
            owner_id = members[names.index(name)].get("id")
        elif action in ("deferred", "resolved", "dismissed"):
            note, accepted = QInputDialog.getMultiLineText(
                self,
                "填写说明",
                "原因 / 处理结果" + ("（必填）" if action != "resolved" else ""),
            )
            if not accepted:
                return
            if action in ("deferred", "dismissed") and not note.strip():
                self._set_status("延期或关闭必须填写原因。", error=True)
                return
        self._execute_decision(item, action, owner_id=owner_id, note=note)

    def _invoke_approval_action(self, action):
        item = self._current_approval()
        if not item:
            return
        if action in ("rejected", "returned"):
            note, accepted = QInputDialog.getMultiLineText(
                self, "审批说明", "说明（必填）"
            )
            if not accepted or not note.strip():
                return
        else:
            note, accepted = QInputDialog.getMultiLineText(
                self, "审批说明", "说明（可选）"
            )
            if not accepted:
                return
        if action == "cancelled":
            answer = QMessageBox.question(
                self, "取消审批", "确定取消这条待审批事项吗？"
            )
            if answer != QMessageBox.StandardButton.Yes:
                return
        if item.get("kind") == "identity_motion" and action in (
            "approved", "rejected",
        ):
            answer = QMessageBox.question(
                self, "治理表决",
                "身份事项按股东持股权重表决。此操作会记录你的赞成或反对票，"
                "最终结果仍由治理规则计算。\n\n继续投票吗？",
            )
            if answer != QMessageBox.StandardButton.Yes:
                return
        if (str(item.get("risk")) in ("severe", "risk")
                or float(item.get("amount") or 0) >= 50000):
            answer = QMessageBox.warning(
                self, "高风险审批",
                "这是高风险或高金额审批，服务端会校验高管权限。继续吗？",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            )
            if answer != QMessageBox.StandardButton.Yes:
                return
        self._execute_approval(item, action, note)

    def _execute_decision(self, item, action, owner_id=None, note=""):
        if self.session is None or not item.get("id"):
            return
        self._set_busy(True)
        client = CommunityClient()
        key = client.new_idempotency_key("decision")

        def work():
            return client.act_on_decision(
                self.session,
                decision_id=item["id"],
                action=action,
                owner_id=owner_id,
                note=note,
                idempotency_key=key,
            )

        self._start_worker(work, self._action_done, self._action_failed)

    def _execute_approval(self, item, action, note=""):
        if self.session is None or not item.get("id"):
            return
        self._set_busy(True)
        client = CommunityClient()
        key = client.new_idempotency_key("approval")

        def work():
            return client.act_on_approval(
                self.session,
                approval_id=item["id"],
                action=action,
                note=note,
                idempotency_key=key,
            )

        self._start_worker(work, self._action_done, self._action_failed)

    def _set_busy(self, busy):
        self._busy = bool(busy)
        self.refresh_button.setEnabled(not self._busy)
        self._sync_action_buttons()
        if self._busy:
            self._set_status("正在提交，重复点击不会重复生效。")

    def _action_done(self, result):
        self._set_busy(False)
        duplicate = bool((result or {}).get("duplicate")) if isinstance(
            result, dict
        ) else False
        self._set_status("操作已生效。" if not duplicate else "重复请求已安全忽略。")
        self.refresh()

    def _action_failed(self, message):
        self._set_busy(False)
        self._set_status(str(message), error=True)
        self._flash(str(message), 5000)

    def _set_status(self, text, error=False):
        self.status_label.setText(str(text or ""))
        self.status_label.setProperty("error", bool(error))
        self.status_label.style().unpolish(self.status_label)
        self.status_label.style().polish(self.status_label)

    def _flash(self, message, timeout=5000):
        if self.window is not None and hasattr(self.window, "flash"):
            self.window.flash(str(message), timeout)
