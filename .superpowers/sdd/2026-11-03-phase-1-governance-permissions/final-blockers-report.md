# Phase 1 Final Blockers Report

- Date: 2026-11-04
- Worktree: `C:\Users\34590\Documents\Codex\2026-10-31\d-xianmugual-projectrecorder-main\work\ProjectRecorder-target`
- Branch: `main`
- Status: PASS
- Push/sync to D: not performed

## Commits

1. `37f971b` `fix: resolve phase 1 final review blockers`
2. This report commit (see `git log -1 --oneline`).
3. `cf1a821` `fix: close phase 1 regression gaps`

## Blockers Fixed

1. Paid knowledge RLS boundary
   - Removed direct `USING (true)` reads from `mobile/sql/community.sql` and `mobile/sql/install-unified.sql`.
   - Added a SECURITY DEFINER readability helper and a least-privilege `authenticated` grant.
   - `enterprise-governance-v2.sql` replaces the policy with the unlock-aware helper, so authors, required posts, free posts, and permanent unlocks remain readable while locked bodies stay hidden.
   - Mobile and desktop feeds continue through `list_knowledge_posts`; desktop uses `CommunityClient.list_posts()`.

2. Template clone/update motion contract
   - Clone payloads now carry `operation = clone` plus `source_template_id`.
   - Passed clone motions create the new template and version-1 permissions during `_identity_apply_template_change_motion`.
   - Update motions carry `operation = update` plus `template_id`.
   - Clone/update RPCs accept reason, duration, and conflict disclosure. High-risk motions preserve the operator-entered reason and disclosure instead of generating an undisclosed title.
   - Desktop clone dialog now collects name, key, reason, and conflict disclosure; the permission editor's reason and disclosure are passed through on update.

3. Desktop Today completion and account isolation
   - Completion now comes from explicit completion status or real `task_logs`; `accept_status = accepted` is no longer treated as done.
   - Today clears visible tasks immediately when the account user changes and when the employee task refresh fails.
   - Employee task rows show completed state before acceptance status.

4. Simple-mode action enforcement
   - New Project, Export All Data, import submissions, mobile snapshot export, server controls, and session-detail actions are disabled by QAction/button state in simple mode.
   - Direct method calls are guarded as well, with a clear status message when the mode or permission is absent.
   - Empty loaded permission lists no longer fall back to legacy boss access.

5. Full point ledger and evidence validation
   - `get_point_state()` now returns the complete enterprise ledger to board directors, chairpersons, and auditors with `audit.read`, while ordinary members still receive only their own rows.
   - Ledger rows include recipient ID/name and the response exposes `can_read_full_ledger` and `ledger_scope`.
   - Desktop and mobile point views display recipient-aware ledger rows.
   - `award_points()` now validates evidence against an existing, allowed business record: acceptance task logs, collaboration worklogs, or knowledge records owned by the recipient.
   - Arbitrary or cross-user evidence UUIDs are rejected.

6. Test dependencies and rollout notes
   - Added `requirements-test.txt` with `pglast` and `psycopg2-binary`.
   - README documents opt-in PostgreSQL integration tests, the disposable database requirement, CI secret handling, migration order, and cleanup behavior.
   - Integration tests remain opt-in through `PROJECT_RECORDER_TEST_DATABASE_URL`; the suite uses the documented dependency and is ready for a live disposable database.

## Verification

- Full unittest discovery:
  - `130` tests run
  - `OK`
  - `18` PostgreSQL integration tests skipped because no disposable DB URL was provided
- `python check.py`:
  - All self-checks passed
- `node build-www.js`:
  - 14 source files + 18 avatar assets copied
- `node selfcheck.js`:
  - 12 syntax files passed
  - 182 logic checks passed
- pglast:
  - `enterprise-governance-v2.sql`, `community.sql`, `enterprise-identity.sql`, and `install-unified.sql` parse
  - All checked SQL files are ASCII
- Capacitor:
  - `npx cap sync android` completed successfully
- `git diff --check`:
  - Clean

## Final Regression Follow-up

Commit `cf1a821` closes four regressions found after the first final-blocker pass:

1. Desktop Today now publishes `cloud_tasks_for_user()` results from `collaboration._loaded()`, so accepted tasks with task logs render as complete.
2. Logged-out local use is no longer treated as simple mode: management actions and shortcuts are enabled when `account_session is None`; logged-in users still require advanced mode and the specific permission.
3. `install-unified.sql` now declares `unlock_cost` and `is_required` in the table definition and adds them idempotently before the RLS policy/function references. Its community publish RPC now accepts and stores those fields.
4. `get_point_state()` and the mobile board ledger no longer truncate authorized ledger history at 100/30 rows. The integration contract inserts more than 100 rows and verifies board, auditor, and member responses are complete.

Follow-up verification:

- Full unittest discovery: `134` tests, `OK`, `18` PostgreSQL integration tests skipped for missing DB URL
- `python check.py`: passed
- `node build-www.js`: passed
- `node selfcheck.js`: 12 files + 182 logic checks passed
- pglast/ASCII checks: all four SQL files passed
- `npx cap sync android`: passed
- `git diff --check`: clean

## Concerns

- PostgreSQL integration tests were not executed locally because no live disposable database URL was available. Static SQL contracts and the full Python/JavaScript suites pass, but production rollout should run `tests.test_enterprise_governance_integration` against a disposable Supabase/PostgreSQL database first.
- The template RPC signatures changed. Deploy the updated SQL, desktop client, and mobile web bundle together; do not leave an old client calling the removed three-argument/three-parameter signatures.
- Apply the SQL in this order: `enterprise-identity.sql`, `community.sql`, then `enterprise-governance-v2.sql`. `install-unified.sql` is not a substitute for the phase-one governance migration.
- No push or sync to D was performed.

## Files of Interest

- `mobile/sql/community.sql`
- `mobile/sql/enterprise-governance-v2.sql`
- `mobile/sql/install-unified.sql`
- `main.py`
- `collaboration.py`
- `today_ui.py`
- `role_templates_ui.py`
- `identity_ui.py`
- `community_client.py`
- `mobile/identity.js`
- `mobile/www/identity.js`
- `tests/test_phase1_final_blockers.py`
- `tests/test_enterprise_governance_integration.py`
- `requirements-test.txt`
