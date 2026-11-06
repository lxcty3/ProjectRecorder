"""Organization founding, share lots and equity motions for the desktop app."""

from __future__ import annotations

import datetime
import time

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import (
    QAbstractItemView, QComboBox, QHBoxLayout, QInputDialog, QLabel,
    QMessageBox, QPushButton, QTableWidget, QTableWidgetItem, QTextEdit,
    QVBoxLayout, QWidget,
)

from community_client import CommunityClient
from community_ui import CommunityWorker
from widgets import SectionTitle

__all__ = ["OrganizationFoundationPage"]


class OrganizationFoundationPage(QWidget):
    def __init__(self, identity_page):
        super().__init__()
        self.identity_page = identity_page
        self.window = identity_page.window
        self.client = CommunityClient()
        self.state = {}
        self.busy = False
        self._workers = []
        self._build()

    @staticmethod
    def _table(headers):
        table = QTableWidget(0, len(headers))
        table.setHorizontalHeaderLabels(headers)
        table.verticalHeader().setVisible(False)
        table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        table.setSelectionMode(QAbstractItemView.SelectionMode.SingleSelection)
        table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        table.setShowGrid(False)
        table.horizontalHeader().setStretchLastSection(True)
        return table

    def _build(self):
        root = QVBoxLayout(self)
        root.setContentsMargins(4, 8, 4, 4)
        root.setSpacing(9)
        head = QHBoxLayout()
        head.addWidget(SectionTitle("组织与股权"))
        head.addStretch()
        self.org_combo = QComboBox()
        self.org_combo.setMinimumWidth(180)
        head.addWidget(self.org_combo)
        self.switch_button = QPushButton("切换")
        self.switch_button.setObjectName("GhostButton")
        self.switch_button.clicked.connect(self.switch_organization)
        head.addWidget(self.switch_button)
        self.refresh_button = QPushButton("刷新")
        self.refresh_button.setObjectName("GhostButton")
        self.refresh_button.clicked.connect(lambda: self.refresh(force=True))
        head.addWidget(self.refresh_button)
        root.addLayout(head)
        self.summary = QLabel("登录后加载组织与股权")
        self.summary.setObjectName("CommunityProfileName")
        self.summary.setWordWrap(True)
        root.addWidget(self.summary)

        actions = QHBoxLayout()
        for text, name, slot in (
            ("创建组织", "PrimaryButton", self.create_organization),
            ("邀请创始人", "GhostButton", self.invite_founder),
            ("发起首次分股", "GhostButton", self.propose_initial_split),
            ("股份转让", "GhostButton", self.create_transfer),
            ("员工持股池", "GhostButton", self.create_employee_pool),
            ("发起解散", "GhostButton", self.propose_dissolution),
        ):
            button = QPushButton(text)
            button.setObjectName(name)
            button.clicked.connect(slot)
            setattr(self, name + "_" + str(len(actions)), button)
            actions.addWidget(button)
        actions.addStretch()
        root.addLayout(actions)
        self.create_button = actions.itemAt(0).widget()
        self.invite_button = actions.itemAt(1).widget()
        self.split_button = actions.itemAt(2).widget()
        self.transfer_button = actions.itemAt(3).widget()
        self.pool_button = actions.itemAt(4).widget()
        self.dissolve_button = actions.itemAt(5).widget()

        body = QHBoxLayout()
        left = QVBoxLayout()
        left.addWidget(SectionTitle("创始人与股本"))
        self.founders_text = QTextEdit()
        self.founders_text.setReadOnly(True)
        self.founders_text.setMinimumHeight(150)
        left.addWidget(self.founders_text)
        self.lots_text = QTextEdit()
        self.lots_text.setReadOnly(True)
        self.lots_text.setMinimumHeight(150)
        left.addWidget(self.lots_text)
        right = QVBoxLayout()
        right.addWidget(SectionTitle("股权表决"))
        self.motion_table = self._table(["事项", "规则", "状态", "赞成", "反对", "票数"])
        right.addWidget(self.motion_table, 1)
        motion_actions = QHBoxLayout()
        self.yes_button = QPushButton("赞成")
        self.yes_button.setObjectName("PrimaryButton")
        self.yes_button.clicked.connect(lambda: self.vote("yes"))
        self.no_button = QPushButton("反对")
        self.no_button.setObjectName("GhostButton")
        self.no_button.clicked.connect(lambda: self.vote("no"))
        self.abstain_button = QPushButton("弃权")
        self.abstain_button.setObjectName("GhostButton")
        self.abstain_button.clicked.connect(lambda: self.vote("abstain"))
        self.grant_button = QPushButton("授予员工激励")
        self.grant_button.setObjectName("GhostButton")
        self.grant_button.clicked.connect(self.grant_employee_equity)
        for button in (self.yes_button, self.no_button, self.abstain_button):
            motion_actions.addWidget(button)
        motion_actions.addStretch()
        motion_actions.addWidget(self.grant_button)
        right.addLayout(motion_actions)
        body.addLayout(left, 1)
        body.addLayout(right, 1)
        root.addLayout(body, 1)

    def _session(self):
        session = self.identity_page.session
        if session is None or session.is_expired():
            session = self.identity_page._client_session()
        return session

    def _spawn(self, work, done, failed=None):
        worker = CommunityWorker(work, self)
        self._workers.append(worker)

        def cleanup():
            if worker in self._workers:
                self._workers.remove(worker)
            worker.deleteLater()

        worker.done.connect(done)
        worker.failed.connect(failed or self._failed)
        worker.finished.connect(cleanup)
        worker.start()

    def _failed(self, message):
        self.busy = False
        QMessageBox.warning(self, "组织操作失败", str(message))

    def refresh(self, force=True):
        if self.busy or self.identity_page.session is None:
            return
        self.busy = True
        old_session = self.identity_page.session

        def work():
            session = old_session
            if session.is_expired():
                session = self.client.refresh(session)
            return session, self.client.organization_state(session)

        def done(result):
            session, state = result
            self.busy = False
            self.identity_page.session = session
            self.window.account_session = session
            self.window.window_settings_set("community_session", session.to_dict())
            self.state = state if isinstance(state, dict) else {}
            self.render()

        self._spawn(work, done)

    def _run_action(self, action, success):
        if self.busy:
            return
        self.busy = True
        old_session = self.identity_page.session

        def work():
            session = old_session
            if session.is_expired():
                session = self.client.refresh(session)
            action(session)
            return session, self.client.organization_state(session)

        def done(result):
            session, state = result
            self.busy = False
            self.identity_page.session = session
            self.window.account_session = session
            self.window.window_settings_set("community_session", session.to_dict())
            self.state = state if isinstance(state, dict) else {}
            self.render()
            if hasattr(self.window, "flash"):
                self.window.flash(success, 3500)

        self._spawn(work, done)

    def render(self):
        state = self.state or {}
        organizations = state.get("organizations") or []
        self.org_combo.blockSignals(True)
        self.org_combo.clear()
        for org in organizations:
            self.org_combo.addItem(org.get("name") or "Organization", org.get("id"))
        active = (state.get("organization") or {}).get("id")
        if active:
            index = self.org_combo.findData(active)
            if index >= 0:
                self.org_combo.setCurrentIndex(index)
        self.org_combo.blockSignals(False)
        org = state.get("organization")
        me = state.get("me") or {}
        if not org:
            self.summary.setText(
                "当前没有组织。创建单人组织会立即成为临时董事长；"
                "多人组织需要邀请全部创始人并完成首次分股。"
            )
            self.founders_text.clear()
            self.lots_text.clear()
            self.motion_table.setRowCount(0)
            for button in (
                self.invite_button, self.split_button, self.transfer_button,
                self.pool_button, self.dissolve_button, self.grant_button,
            ):
                button.setEnabled(False)
            return
        founders = state.get("founders") or []
        self.summary.setText(
            "{} · {} · 总股份 {} 单位 · 加权投票权 {} · 创始人 {} 人".format(
                org.get("name") or "Organization",
                org.get("foundation_status") or "unknown",
                state.get("total_units", 0), state.get("voting_units", 0),
                len([item for item in founders if item.get("status") == "active"]),
            )
        )
        self.founders_text.setPlainText("\n".join(
            "{} · {} · {} · {}".format(
                item.get("name") or "Member",
                item.get("role_key") or "employee",
                "Founder" if item.get("is_original") else "Member",
                item.get("status") or "active",
            ) for item in founders
        ) or "No founders")
        lots = state.get("share_lots") or []
        self.lots_text.setPlainText("\n".join(
            "{} · {} · {} units · voting x{}".format(
                item.get("owner_name") or "Employee pool",
                item.get("share_class") or "share",
                item.get("units") or 0, item.get("voting_weight") or 0,
            ) for item in lots
        ) or "Equity has not been split")
        motions = state.get("motions") or []
        self.motion_table.setRowCount(len(motions))
        for row, motion in enumerate(motions):
            values = [
                motion.get("kind") or "",
                motion.get("required_rule") or "",
                motion.get("status") or "",
                motion.get("yes_units") or 0,
                motion.get("no_units") or 0,
                motion.get("vote_count") or 0,
            ]
            for column, value in enumerate(values):
                item = QTableWidgetItem(str(value))
                if column == 0:
                    item.setData(Qt.ItemDataRole.UserRole, motion)
                self.motion_table.setItem(row, column, item)
        founding = org.get("foundation_status") == "founding"
        can_manage = bool(me.get("can_manage"))
        self.invite_button.setEnabled(founding and can_manage)
        self.split_button.setEnabled(founding and can_manage)
        self.transfer_button.setEnabled(not founding and bool(lots))
        self.pool_button.setEnabled(not founding and can_manage)
        self.dissolve_button.setEnabled(not founding)
        self.grant_button.setEnabled(bool(state.get("employee_pool")) and can_manage)

    def create_organization(self):
        name, ok = QInputDialog.getText(self, "Create organization", "Organization name:")
        if not ok or not name.strip():
            return
        codes, ok = QInputDialog.getText(
            self, "Co-founders", "Founder codes, comma separated (optional):"
        )
        if not ok:
            return
        founder_codes = [item.strip() for item in codes.split(",") if item.strip()]
        self._run_action(
            lambda session: self.client.create_organization(session, name, founder_codes),
            "Organization created",
        )

    def invite_founder(self):
        org = (self.state or {}).get("organization") or {}
        code, ok = QInputDialog.getText(self, "Invite founder", "Employee code or name:")
        if not ok or not code.strip():
            return
        self._run_action(
            lambda session: self.client.invite_organization_founder(
                session, org.get("id"), code.strip()
            ),
            "Founder invitation sent",
        )

    def switch_organization(self):
        enterprise_id = self.org_combo.currentData()
        if not enterprise_id:
            return

        def action(session):
            data = self.client.set_active_organization(session, enterprise_id)
            if data.get("owner_profile_id"):
                session.profile["boss_id"] = data["owner_profile_id"]
            return data

        self._run_action(action, "Active organization switched")

    def propose_initial_split(self):
        founders = [item for item in (self.state.get("founders") or [])
                    if item.get("status") == "active"]
        if not founders:
            return
        units = round(100.0 / len(founders), 4)
        allocations = [
            {"profile_id": item.get("profile_id"), "units": units}
            for item in founders
        ]
        allocations[-1]["units"] += 100.0 - sum(item["units"] for item in allocations)
        closes = (datetime.datetime.now(datetime.timezone.utc)
                  + datetime.timedelta(days=3)).isoformat()
        self._run_action(
            lambda session: self.client.propose_initial_split(
                session, allocations, "Initial equity split", closes
            ),
            "Initial split motion created",
        )

    def _selected_motion(self):
        rows = self.motion_table.selectionModel().selectedRows()
        if not rows:
            return None
        item = self.motion_table.item(rows[0].row(), 0)
        return item.data(Qt.ItemDataRole.UserRole) if item else None

    def vote(self, choice):
        motion = self._selected_motion()
        if not motion:
            QMessageBox.information(self, "Select a motion", "Select an equity motion first.")
            return
        self._run_action(
            lambda session: self.client.cast_equity_vote(
                session, motion.get("id"), choice
            ),
            "Equity vote recorded",
        )

    def create_transfer(self):
        session = self.identity_page.session
        lots = [item for item in (self.state.get("share_lots") or [])
                if str(item.get("owner_profile_id")) == str(session.user_id)]
        members = [item for item in (self.state.get("members") or [])
                   if str(item.get("profile_id")) != str(session.user_id)]
        if not lots or not members:
            QMessageBox.information(self, "Transfer unavailable",
                                    "No transferable share lot or buyer.")
            return
        lot_labels = [f"{item.get('share_class')} · {item.get('units')} units"
                      for item in lots]
        member_labels = [f"{item.get('name')} ({item.get('code')})" for item in members]
        lot_label, ok = QInputDialog.getItem(
            self, "Share transfer", "Share lot:", lot_labels, 0, False
        )
        if not ok:
            return
        buyer_label, ok = QInputDialog.getItem(
            self, "Share transfer", "Buyer:", member_labels, 0, False
        )
        if not ok:
            return
        units, ok = QInputDialog.getDouble(
            self, "Share transfer", "Units:", 1, 0.0001, 999999, 4
        )
        if not ok:
            return
        price, ok = QInputDialog.getDouble(
            self, "Share transfer", "Price:", 0, 0, 999999999, 2
        )
        if not ok:
            return
        payload = {
            "lot_id": lots[lot_labels.index(lot_label)].get("id"),
            "buyer_profile_id": members[member_labels.index(buyer_label)].get("profile_id"),
            "units": units,
            "price": price,
        }
        closes = (datetime.datetime.now(datetime.timezone.utc)
                  + datetime.timedelta(days=3)).isoformat()
        self._run_action(
            lambda session: self.client.create_equity_motion(
                session, "share_transfer", payload, "Share transfer", closes
            ),
            "Share transfer motion created",
        )

    def create_employee_pool(self):
        units, ok = QInputDialog.getDouble(
            self, "Employee pool", "Pool units:", 5, 0.0001, 999999, 4
        )
        if not ok:
            return
        closes = (datetime.datetime.now(datetime.timezone.utc)
                  + datetime.timedelta(days=3)).isoformat()
        self._run_action(
            lambda session: self.client.create_equity_motion(
                session, "employee_pool", {"units": units},
                "Employee equity pool", closes
            ),
            "Employee pool motion created",
        )

    def propose_dissolution(self):
        reason, ok = QInputDialog.getText(self, "Dissolution", "Reason:")
        if not ok or not reason.strip():
            return
        closes = (datetime.datetime.now(datetime.timezone.utc)
                  + datetime.timedelta(days=7)).isoformat()
        self._run_action(
            lambda session: self.client.create_equity_motion(
                session, "dissolution", {"reason": reason}, reason, closes
            ),
            "Dissolution motion created",
        )

    def grant_employee_equity(self):
        members = [item for item in (self.state.get("members") or [])
                   if item.get("status") == "active"]
        if not members:
            return
        labels = [f"{item.get('name')} ({item.get('code')})" for item in members]
        selected, ok = QInputDialog.getItem(
            self, "Employee equity", "Member:", labels, 0, False
        )
        if not ok:
            return
        units, ok = QInputDialog.getDouble(
            self, "Employee equity", "Units:", 1, 0.0001, 999999, 4
        )
        if not ok:
            return
        member = members[labels.index(selected)]
        self._run_action(
            lambda session: self.client.grant_employee_equity(
                session, member.get("profile_id"), units,
                datetime.datetime.now(datetime.timezone.utc).isoformat(),
            ),
            "Employee equity granted",
        )
