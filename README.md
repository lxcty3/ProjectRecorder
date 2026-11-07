# 项目记录器

给老板用的项目管理工具。核心不是「记录」，而是**主动告诉你哪里会出事，并且说清凭什么**。

一个窗口回答三个问题：

1. **现在总共什么情况？** —— 驾驶舱
2. **哪个项目要出事、凭什么这么说？** —— 项目详情 + 预测依据
3. **人都在忙什么、谁快撑不住了？** —— 员工负荷

## 运行

```bash
pip install -r requirements.txt
python main.py
```

Python 3.9 以上（建议 3.11 / 3.12）。界面用 PyQt6；项目、员工和工时数据仍存本机 SQLite。**知识星球社区是云端共享功能，需要联网并使用现有账号登录。**

### 电脑版与手机版账号统一

电脑端顶部新增“手机版账号”入口，直接复用手机版的 Supabase 账号：

- 老板账号和员工号都能登录。
- 登录状态同时用于顶部身份显示和知识星球社区。
- 桌面端只保存访问令牌与刷新令牌，不保存密码。
- 没登录时仍可使用本地项目、工时、预测和知识库；登录后社区自动同步。
- 退出账号不会删除任何本地项目数据。

## 九个页签

### 驾驶舱
所有项目一览。顶部四张指标卡（在管项目 / 需要处理 / 在岗员工 / 本周工时），下面一张表按风险排序。

**选中一行，下方直接给出这个项目的预测和依据**；双击进入详情。

### 知识星球

知识星球现在是一个**全员共享社区**，不再只是个人知识库。页面内有两个子页签：

#### 星球广场（共享）

- **所有人看到同一份消息流**：已登录的成员都能看到所有消息，也都能发布消息。
- **真实身份**：复用手机版 Supabase 账号，老板账号和员工号都能登录；作者姓名和角色由服务端写入，客户端不能冒充别人。
- **消息流**：支持分享、提问、经验、灵感、公告五类消息，最多 2000 字。
- **实时协作**：手机端使用 Supabase Realtime，桌面端每 12 秒自动同步；也可以手动刷新。
- **可删除自己的消息**：删除后所有成员都会看不到。
- **手机端入口**：员工和老板底部导航都新增了「星球」。

第一次使用前，管理员需要把 [`mobile/sql/community.sql`](mobile/sql/community.sql) 整个文件粘贴到 Supabase SQL Editor 运行一次。该脚本会创建社区表、权限策略和发帖/删除函数。



组织创始人与股权规则由 [`mobile/sql/organization-founders-v1.sql`](mobile/sql/organization-founders-v1.sql) 安装。它增加创始人邀请、首次分股、原始股份 1.1 投票权重、股权表决、股份转让、员工持股池、解散表决和活动组织切换；现有企业所有者会迁移为创始人。

公司改名和「添加公司成员」由 [`mobile/sql/organization-management-v1.sql`](mobile/sql/organization-management-v1.sql) 安装。它提供受 `company.manage` / `governance.manage` 权限保护的组织改名与成员添加 RPC；客户端仍然不能直接写治理表。

阶段一的「主公司 + 成员邀请」由 [`mobile/sql/phase1-primary-company-member-invites-v1.sql`](mobile/sql/phase1-primary-company-member-invites-v1.sql) 安装。它为已有成员自动补主公司，加入新公司不会退出原公司，普通成员必须接受邀请后才生效。

「我的公司」页面由 [`mobile/sql/phase1-my-companies-v1.sql`](mobile/sql/phase1-my-companies-v1.sql) 安装。可查看主公司、其他成员关系和当前成员目录；普通成员只看到公开角色信息，管理身份才看到账号、邮箱、成员状态和持股信息。

今日工作台固定为四个板块：今日焦点、待我处理、正在工作、公司动态，每块最多显示三条。应用版本信息来自 `mobile/version.json`，更新检查读取仓库根目录的 `latest.json`，只提示下载，不自动安装。

v2.1 社区底座是在旧社区表上的增量升级。安装完 `community.sql` 后，再运行 [`mobile/sql/community-forum-v1.sql`](mobile/sql/community-forum-v1.sql)。它会增加板块、评论、点赞、收藏、举报、关注、通知、搜索、分页、板块管理和社区数据统计；旧帖子会自动迁入「综合讨论」，旧 RPC 继续保留以便回滚。

社区作者头像和主公司职业由 [`mobile/sql/community-author-cards-v1.sql`](mobile/sql/community-author-cards-v1.sql) 提供。帖子与评论显示作者设置的社区头像，并优先显示主公司的最高职级职业。

#### 我的知识库（本地）

把个人散落的经验、直觉、失败和客户反馈，做成一张会生长的认知地图。

- **四个认知区域**：实际知识（已验证）、关联知识（跨项目连接）、潜在知识（直觉与假设）、原始知识（刚记下的种子）。
- **知识引力图**：共同标签会自动形成「同频」关系，也可以手动建立启发、支撑、反例等关系；点星体即可查看详情。
- **显性/隐性冰山**：一眼看出哪些知识已经说清、哪些还沉在水面下。
- **反思机制**：每次反思单独留痕，用问题推动知识从「知道」走向「能迁移、能验证」。
- **完整 CRUD**：支持记录、编辑、删除、搜索、按区域筛选、关联项目与回看日期。快捷键 `Ctrl+K` 可直接记录一条知识。

### 协作中心

桌面端新增云端协作页，和手机端共用同一套 Supabase 业务数据：

- 派发任务到员工手机，并关联项目、步骤、计划和预估工时。
- 查看完成情况并按 S/A/B/C 评级。
- 审核手工补录工时。
- 管理奖励兑换审批和请假审批。
- 点击“同步云端”时自动把桌面项目、步骤和知识库映射到云 UUID。

员工账号登录桌面端默认使用简单模式，只显示“今日”和知识星球，不显示预算、团队风险和老板数据；具备管理、财务、审计或治理权限后可在桌面顶部切换高级模式。

### 经营决策中心

高级模式默认进入“经营决策中心”，把跨项目、跨模块的影响集中成一条处理队列：

- **入口权限**：只有具备管理、财务、审计或治理能力的身份可进入高级模式和决策中心；简单模式员工看不到入口。
- **决策队列**：按交付影响天数、涉及金额、风险等级和等待时间排序；每条决策展示来源证据、负责人、截止时间和处理状态。
- **统一审批**：请假、工时、费用、采购、奖励、任务延期和身份事项进入同一个审批收件箱。
- **证据下钻**：决策和审批带有结构化来源记录，可追到任务、工时、审批、任务延期或身份治理事项。
- **幂等与审计**：批准、拒绝、退回补充、取消、确认、分派、延期和关闭都要求幂等键，并由服务端写入审批事件和企业审计。
- **授权边界**：不同审批类型校验不同权限；严重/高风险或金额达到 5 万元的审批要求高管身份。身份事项沿用股东权重投票，不由普通审批绕过。
- **真实动作**：桌面和手机按钮只在服务端返回对应 `actions` 能力时显示；没有数据时显示空状态，不用假数据填充。
- **数据库边界**：决策和审批表启用 RLS，直接表权限收回，客户端只可调用 `get_decision_center`、`act_on_decision` 和 `act_on_approval` 三个 SECURITY DEFINER RPC。

### 企业身份与股东投票

电脑端「企业身份」页和手机端「治理」页读取同一套 Supabase 企业数据。当前已实现：

- **企业身份细分**：董事长、董事、监事、首席执行官、副总裁、部门经理、项目经理、组长、财务、人力资源、审计、员工。
- **服务端权限**：资源、动作、范围、限制条件四个维度的权限随身份模板版本保存；客户端只按服务端返回的能力展示入口。
- **身份模板**：可以复制模板，并在桌面端编辑四维权限、名称和条件。普通改动立即生成新版本；包含高风险权限的改动会转为重大股东表决，通过后才生成新版本。
- **临时兼任**：仅 CEO 或企业所有者可设置，最长 7 天，必须填写原因并写入审计；高风险权限不能通过临时兼任授予。
- **股东会**：持股且在册的成员可发起任免、股份调整和身份模板变更提案。提案创建时锁定在册股东股份快照，投票期间不能直接改动股份。
- **表决规则**：普通事项默认 3 天，要求 50% 股份出席且赞成票超过有效投票 50%；重大事项默认 5 天，要求全体股份三分之二以上赞成。当事人可投票，但为自己提案时必须披露利益冲突。
- **董事会**：董事一名董事一票，积分池等经营事项需过半董事出席且出席董事过半赞成。
- **积分池与积分**：董事会按季度批准积分池；董事长只能在剩余额度和单次上限内、凭证据向其他成员发分，不能给自己发分。积分发放后永久有效。
- **积分结转**：发起新积分池议案时可显式选择上一积分池 ID；获批后上一池剩余积分会计入新池总额和剩余额度。
- **知识解锁**：发布者可设置解锁积分或设为必读。锁定内容通过 RLS 安全预览列表被发现，成员可用永久积分解锁全文。
- **简单模式**：普通成员默认进入“今天”，看到云端员工任务、积分余额、积分池和积分明细；不返回或展示股份、股东投票和董事会记录。
- **高级模式**：只有管理、财务、审计或治理权限才能切换，普通员工仅有的 `identity.view` 不再赋予高级入口。服务端在 `set_enterprise_ui_mode` 再次校验。
- **模式记忆**：服务端返回并保存 `preferred_mode`；桌面和手机切换后跨设备生效，权限撤销后自动回退到简单模式。
- **审计留痕**：提案、投票、股份变更、模板变更、临时兼任、积分池和积分发放均写入企业审计表。

### 股东大会、月度会议和请假记录

在现有企业身份与治理能力之上，新增独立的股东大会议程：

- **月度例行会议**：系统自动为当前月份建立一次例行股东大会，默认安排在本月最后一天 18:00（上海时区）；每月最多一场有效例行会议。
- **临时股东大会**：持股股东可以发起临时会议，但必须填写特殊原因；本月只能存在一场有效临时会议。
- **同意门槛**：临时会议的召集需要超过半数在册股东按人数同意，不按股份权重计算。发起人自动投赞成票。
- **出席登记**：股东可以登记出席、缺席或请假；登记前必须输入当前登录账号的员工号或老板号完成身份验证，请假还必须填写原因。
- **会议纪要**：企业所有者、董事长或具备治理管理权限的身份可以结束会议并记录纪要。
- **审计与权限**：会议、召集投票、出席和请假均由 SECURITY DEFINER RPC 写入企业审计；客户端不能直接写表。
- **桌面和手机入口**：电脑端位于「企业身份 → 股东大会」，手机端位于「更多 → 治理 → 股东大会」。

股东大会升级顺序：

```text
mobile/sql/enterprise-identity.sql
mobile/sql/enterprise-governance-v2.sql
mobile/sql/shareholder-meetings-v1.sql
mobile/sql/shareholder-meeting-verification-v1.sql
```

`install-unified.sql` 末尾包含受前置条件保护的股东大会区块。首次部署后打开治理页，系统会自动建立当前月例行会议。

阶段一升级顺序：

部署时，在现有数据库脚本之后按以下顺序运行：

```text
1. mobile/sql/enterprise-identity.sql
2. mobile/sql/community.sql
3. mobile/sql/enterprise-governance-v2.sql
```

`community.sql` 必须先于治理扩展，因为付费知识字段、列表 RPC 和解锁 RLS 依赖社区表。`install-unified.sql` 不包含阶段一治理扩展，`enterprise-governance-v2.sql` 必须单独执行。

桌面端和手机端共享同一套治理数据。直接修改股份的旧 RPC 已只保留为内部/初始化权限，普通客户端不能再调用；股份和模板高风险改动必须经过股东表决。

阶段 2A 部署顺序：

在阶段一治理扩展和任务延期脚本之后运行决策中心迁移：

```text
mobile/sql/enterprise-identity.sql
mobile/sql/community.sql
mobile/sql/community-forum-v1.sql
mobile/sql/organization-founders-v1.sql
mobile/sql/organization-management-v1.sql
mobile/sql/phase1-primary-company-member-invites-v1.sql
mobile/sql/phase1-my-companies-v1.sql
mobile/sql/platform-stability-v1.sql
mobile/sql/enterprise-governance-v2.sql
mobile/sql/task-accept-extension.sql
mobile/sql/decision-approvals-v1.sql
```

`decision-approvals-v1.sql` 会建立 `decision_items`、`approval_requests` 及事件表，并把现有请假、工时、奖励兑换、任务延期和身份任免数据同步进统一审批。脚本纯 ASCII、可重复执行；业务表只通过 SECURITY DEFINER RPC 读写，直接表权限对客户端收回。

`install-unified.sql` 末尾包含一个受前置条件保护的 Phase 2A 区块：基础统一安装时如果阶段一或任务延期表还不存在，会跳过并输出提示；完成前置迁移后重新执行统一安装脚本即可应用。独立部署时仍以 `mobile/sql/decision-approvals-v1.sql` 为准。

### 经营分析、工时经营标签、能力与绩效证据

Phase 2B 在经营决策中心之后增加管理经营分析，并把执行记录与经营结果对齐：

- **入口权限**：桌面端「经营分析」和手机端「经营摘要」只在高级模式且具备管理身份时显示；简单模式不拉取也不缓存经营数据，权限撤销时客户端立即清空 `DB.operations`。
- **四维权限**：Phase 2B RPC 继续使用身份模板的 scope 与 conditions。`project_ids` 限制项目经理只能读写指定项目，`profile_ids` / `department` 限制人员与绩效范围，`amount_limit` 逐个校验合同、开票、回款和各类成本字段；看板会按财务、人员、绩效和工时权限过滤字段。跨企业项目写入会先写入安全审计再返回拒绝。技能编辑即使修改自己，也必须具备显式 `people.manage` 与对应人员范围。
- **项目经营口径**：合同额、已开票、已回款、应付/已付外包、人力成本、其他成本、预计完工成本、预计毛利、毛利率、开票到期日、付款条款和回款缺口均由服务端聚合。逾期未收会自动生成回款预警并写入 Phase 2A 决策队列。
- **工时经营标签**：工时支持可计费、加班、项目/售前/内部、返工、等待和出差。新增字段都有兼容默认值；本地手工工时通过独立迁移队列预留云 UUID、上传工时并消除数字 ID 的永久等待，随后再同步经营维度。手机团队页可直接编辑云端工时的经营标签。
- **能力缺口**：技能记录包含等级、证书、可用时间和有效期；未来 2-4 周需求与可用时间形成可下钻的能力缺口。能力缺口要求人员查看范围；只有项目权限的管理者会看到权限说明，而不是把全部需求误报为短缺。桌面和手机管理视图提供真实的技能维护与能力需求维护入口，并显示来源 ID。
- **绩效证据**：准时率、一次通过率、返工、协作、复杂度、经营贡献和结构化客户评价组成证据记录。来源必须是属于该员工的任务、工时或审批记录；绩效分包含复杂度与经营贡献。员工可以查看自己的依据并提交说明，有权限的管理者才能复核。
- **绩效边界**：绩效分数只依据交付和质量证据计算，不直接决定工资或晋升；简单模式不会展示跨人员经营或绩效对比，知识星球也不承载这些敏感数据。
- **数据库边界**：经营、技能、需求、绩效和工时标签表启用 RLS，直接表权限收回；成功写入进入企业审计，越权尝试进入独立的 `operations_security_audit`，避免异常回滚吞掉安全事件。工时汇总只统计已批准工时。

阶段 2B 部署顺序：

```text
mobile/sql/enterprise-identity.sql
mobile/sql/community.sql
mobile/sql/enterprise-governance-v2.sql
mobile/sql/task-accept-extension.sql
mobile/sql/decision-approvals-v1.sql
mobile/sql/execution-tracking-v1.sql
mobile/sql/operations-economics-v1.sql
mobile/sql/work-intake-v1.sql
```

`decision-approvals-v1.sql` 会建立 `decision_items`、`approval_requests` 及事件表，并把现有请假、工时、奖励兑换、任务延期和身份任免数据同步进统一审批。脚本纯 ASCII、可重复执行；业务表只通过 SECURITY DEFINER RPC 读写，直接表权限对客户端收回。

`install-unified.sql` 末尾包含受前置条件保护的 Phase 2A、Phase 3 和 Phase 2B 区块：基础统一安装时如果阶段一、任务延期、决策中心或执行追踪表还不存在，会跳过并输出提示；完成前置迁移后重新执行统一安装脚本即可应用。独立部署时仍以 `mobile/sql/decision-approvals-v1.sql`、`mobile/sql/execution-tracking-v1.sql` 和 `mobile/sql/operations-economics-v1.sql` 为准。

### 执行追踪、验收、依赖、交接与变更

Phase 3 建立可追踪的执行闭环，并作为经营绩效聚合的验收数据源；部署时应先于经营分析迁移：

- **验收闭环**：任务提交时必须填写验收标准和交付证据，并指定独立验收人。状态只允许待验收、返工和已验收；只有已验收是最终完成，提交人不能自行验收。
- **依赖影响**：任务支持前后置依赖和依赖间隔。服务端拒绝循环依赖，并按最长累计路径计算下游延迟天数、预计日期和责任人，供桌面和手机下钻。
- **交接确认**：交接物、发起人、接收人和部门都会记录。交接必须由接收方确认或拒绝，发起人不能代确认。
- **变更控制**：变更申请记录 `decision_items` 范围、原因、紧急程度，以及工期、成本、资源和风险影响。未批准的变更不会覆盖原计划或项目日期、预算、任务计划；高影响或跨部门变更进入 Phase 2A 决策队列。
- **审计与权限**：`task_acceptance`、`task_dependencies`、`task_handoffs`、`change_requests` 和审计表启用 RLS，直接表写入收回。成功操作写入 `execution_audit` 和企业审计，越权尝试写入 `execution_security_audit`。
- **客户端入口**：桌面「执行追踪」只在高级管理模式显示；手机所有已登录成员都可进入，但服务端只返回本人任务、本人交接和授权管理范围。所有按钮均调用真实 RPC。

阶段 3 部署顺序：

```text
mobile/sql/enterprise-identity.sql
mobile/sql/community.sql
mobile/sql/enterprise-governance-v2.sql
mobile/sql/task-accept-extension.sql
mobile/sql/decision-approvals-v1.sql
mobile/sql/execution-tracking-v1.sql
mobile/sql/operations-economics-v1.sql
```

`install-unified.sql` 末尾按要求先执行 Phase 3、再执行依赖 `task_acceptance` 的 Phase 2B 区块；决策中心和执行追踪基础表未就绪时会跳过并输出提示。独立部署仍以 `mobile/sql/execution-tracking-v1.sql` 为准。执行追踪集成测试位于 `tests.test_execution_integration`，使用 `PROJECT_RECORDER_TEST_DATABASE_URL` 指向一次性测试库。


### 工作入口、公开需求与分诊

Phase 4 把电脑和手机上的临时事项统一成可追踪需求：

- **快速记录**：电脑「工作入口」和手机「需求」页都可以直接记录类型、标题、详情和五项优先级因素。优先级由服务端计算，返回逐项分值和总分；管理者覆盖排序必须填写理由。
- **公开表单与二维码**：管理端可新建 `intake.html?token=...` 公开入口，复制链接或显示二维码。外部提交者只看到公司名称、表单名称、允许类型和自己的申请编号。
- **邮件入口**：管理端可创建 `intake+随机令牌@配置域名` 地址，邮件网关把发件人、主题和正文转发到 `ingest_intake_email`。地址令牌和发送频率都由服务端校验。
- **分诊与 SLA**：故障 2 小时、客户/销售/临时事项 1 天、内部改进 3 天。超时未分诊会自动升级给企业负责人并进入待分诊队列；可调用 `intake_escalate_sla` 或配置定时任务执行。
- **重复需求**：提交时返回相似度提示；管理端可查看候选、合并重复。合并写入 `merged_into_id`、双向关联并复制全部沟通记录，原始需求和提出人不会被删除。
- **外部沟通隔离**：公开回复进入公开消息流，`get_public_intake_status` 同时校验申请编号和邮箱；内部备注只对管理端可见，外部状态接口不会返回内部字段。
- **转入执行**：需求可转项目、转任务或售前支持，保留 `linked_project_id`、`linked_task_id` 和转换事件；转换不会丢失来源、提出人、验收线索和沟通记录。
- **安全边界**：公开表单启用服务端限流、邮箱校验和同意确认；所有业务表启用 RLS，直接写入被收回，成功和越权操作分别进入企业审计与 `intake_security_audit`。

Phase 4 部署顺序：

```text
mobile/sql/enterprise-identity.sql
mobile/sql/community.sql
mobile/sql/enterprise-governance-v2.sql
mobile/sql/task-accept-extension.sql
mobile/sql/decision-approvals-v1.sql
mobile/sql/execution-tracking-v1.sql
mobile/sql/operations-economics-v1.sql
mobile/sql/work-intake-v1.sql
```

`install-unified.sql` 末尾包含受前置条件保护的 Phase 4 区块。公开静态页为 `mobile/intake.html`，手机管理页加载 `mobile/intake.js`，二维码组件为 `mobile/vendor/qrcode.min.js`。邮件网关需把收到的邮件转发给 `ingest_intake_email`，实际发信由 `intake_notifications` 出站队列处理。

### 统一云端部署

已有手机数据库升级时，先备份，再把以下脚本按现有部署顺序运行：

```text
mobile/sql/unified-platform.sql
```

然后登录主老板账号 `19155037002`，执行迁移预览：

```powershell
python cloud_migration.py --dry-run
```

确认预览报告后执行：

```powershell
python cloud_migration.py --apply
```

迁移会先把本地 SQLite 备份到 `~/ProjectRecorder/backups/`，再同步项目、步骤、员工映射和个人知识库。

### 小助手
用中文问项目情况。两种问法：

**点建议按钮** —— 底部两排。固定那排是「助手会什么」，**动态那排是「你现在该关心什么」**（有阻塞任务、有人超负荷、有项目超预算时才出现，并且带着具体数字）。

**直接打字** —— 支持 11 类问题：

| 问题 | 回答 |
| --- | --- |
| 现在什么情况 | 整体概况 + 该先看哪个项目 |
| 哪个项目有风险 | 列出需要介入的 |
| 谁最忙 / 谁超负荷 | 负荷排行，超标的点名 |
| 谁闲下来了 | 没记工时的人 |
| 预算要紧吗 / 哪些超预算了 | 各项目占用比例 |
| 有多少人在岗 | 人力规模 + 投入总量 |
| 哪些任务卡住了 | 所有「已阻塞」步骤 |
| 「项目名」怎么样 | 该项目的完整预测 |
| 「人名」最近做了什么 | 工时明细 + 负荷率 |

**还可以让它主动发现**（顶部「比一比 / 找矛盾 / 全部看一遍」）——见下面「主动发现」。

**导出对话**：把这次问答存成文本，方便贴给别人。

### 员工与工时
左边员工负荷列表，右边工时明细。时间范围可切 7 / 30 / 90 天。

**负荷率 = 这段时间的工时 ÷ 同期应出工时**（周工时基准 × 周数）。光看「谁干得多」没意义，要看相对他自己的基准干到了几成。

### 任务分配
把员工挂到项目的某一步上。**计划工时**登记在这里，**实际工时**从工时记录算出来，两边对比就知道谁被压了活。

实际超出计划的会标红，上方还有一张「计划 vs 实际」并排柱状图，
以及一句整体判断（例如「整体比计划多用 23% 工时——时间估算系统性偏乐观」）。

## 员工提交工时

两种方式，**按你的实际情况选一种**：

| 方式 | 需要什么 | 适合 |
| --- | --- | --- |
| **文件交换** | 员工装程序 | **员工不在同一地点**、网络隔离、不想开端口 |
| **局域网服务** | 员工用浏览器 | 员工和你在同一网段，且网络允许设备互访 |

原理一样：员工报的工时进入同一个数据库，所有负荷分析和预测都基于它。

### 方式一：文件交换（不依赖任何网络）

**员工端**：

```powershell
项目记录器.exe --submit
```

（或者在完整界面里点「员工提交 → 导出我的工时…」）

选自己 → 选时间段 → 「导出并保存…」，得到一个文件：

```
工时_王强_2026-09-01_到_2026-09-30.json
```

把这个文件**微信、邮件、U 盘**发给老板都行。员工电脑上还没有记录时，窗口里有「补记一条工时」可以先补上。

**老板端**：「员工提交 → 导入员工提交…」（`Ctrl+I`），**可以一次选多个文件**。

导入前会先列出每个文件是谁的、有多少条让你确认；导入后给一份报告：

```
本次新增 47 条工时，跳过已存在 12 条。

王强：新增 23 条，已存在跳过 6 条
（新建员工 李工）李工：新增 24 条
· 这些项目在你的库里不存在，相关记录没有导入：新零售中台
  要么先在驾驶舱建好同名项目再导一次，
  要么确认员工是不是写错了项目名。
```

几条重要的设计：

- **重复导入是安全的**。每条记录带一个指纹（员工+项目+日期+工时+说明），导入时按指纹跳过已存在的。**同一个文件导多少次结果都一样**——员工多发几次、你手滑导两遍，都不会变成两份记录。
- **按名字匹配**。员工电脑上的数据库和你的是两套，id 必然不同，所以文件里存的是名字。
- **项目必须你这边先建好**。员工报了一个你还没建过的项目名，那些记录**不会导入**，而是报出来让你确认——**不会自动建一个重名项目**。
- **员工可以自动建**。名单里没有这个人时会自动加上（并在报告里明确告知），因为「人来了就该有」。
- **坏文件会被挡住并说明原因**：不是本程序的文件、版本比程序新、内容损坏、没说清是谁提交的。

**顺带支持云同步盘**：把员工的导出目录指到 OneDrive / 坚果云 / 群晖的同步文件夹里，文件就自动送到你那边，不用手动转发。

### 方式二：局域网服务

老板端：「员工提交 → 开启局域网服务」，再点「显示服务地址」拿到网址，例如：

```
http://192.168.1.7:8765/
```

发给员工，**他们用浏览器打开就能填**，不需要安装任何东西。老板这边会**自动刷新**。

**这一步不需要互联网**——只要员工和你在同一个 WiFi 或同一根网线。但有两个前提：

- **防火墙要放行**。第一次开启时 Windows 会弹窗问「是否允许访问网络」，**必须点「允许」**。没弹窗但连不上，就去「Windows Defender 防火墙 → 允许应用通过防火墙」里手动勾上「专用网络」。
- **网络不能隔离设备**。有些公司 WiFi 开了 AP 隔离（同一 WiFi 下设备互不相通），那样这条走不通，改用方式一。

端口默认 8765，被占用了可以在「设置服务端口」里换。

**这个服务没有任何认证**——同一局域网内、知道地址的人都能提交。这是有意的：员工名单在公司内部本来就不是秘密，加密码会让「今天忘带密码」变成不交工时的理由；而自己写的登录框比没有认证更危险，会给人虚假的安全感。**真要更强的隔离，应该在网络层做**（VLAN、只开特定端口、内网 ACL）。

服务端会**独立重新校验**所有输入，不信任浏览器端：工时必须 0~24 小时、不能填未来日期、项目必须存在且未交付、**勾选完成时只允许改所选项目里的步骤**（防止改前端越权改别的项目）。

## 预测是怎么算的

**本地规则引擎，不是大模型。** 每条结论都带依据链：

```
【严重】按当前速度，预计 2026年04月18日 才能收尾，比计划晚 27 天

· 预计延期 27 天　（已过 60 天完成 35%，按此速度还需约 111 天，而计划只剩 20 天）
· 时间用掉 75%，进度只有 35%　（落后 40 个百分点）
· 2 个步骤处于「已阻塞」　（接口联调、灰度发布）
· 计划工时超出可用产能 38%　（计划 210 小时，3 人剩余产能约 152 小时）
· 预算已用掉 88%　（预算 80.0 万，已花 70.0 万，剩余 10.0 万）

建议：
· 先解开阻塞——阻塞不解决，加人也没用
· 要么砍范围，要么加人，否则只能靠加班顶
```

覆盖 8 类判断：交付时间外推、时间与进度错位、过期步骤、阻塞步骤、人力负荷、预算占用、能力/资源加权分、工时停滞。

**为什么不用大模型**：管理工具的价值在于**可复现、可追责**。同一个项目算两次结果必须一样，老板追问「凭什么」时每个数字都能追到出处。这些是规则引擎能做而生成式模型做不到的。

## 主动发现

不用你提问，点「比一比」或「找矛盾」就让它自己看一遍。两类共 8 条判据：

**横向比较**
- 投入最大、推进最慢的项目（跨两个维度交叉看，单看成本或单看进度都发现不了）
- 谁超出同期应出工时
- 一个人挂在 3 个以上项目（切换成本会吃掉产能）
- 阻塞超过 3 天的步骤
- 低职级的人负责关键步骤

**逻辑矛盾**
- 步骤顺序矛盾（第二步完成了但第一步没有）
- 工时没有归属（记了工时但没分配到人）
- 空转的分配（计划了工时、开始超过 14 天、实际是 0）

每条都带**数字依据 + 建议动作**。自检会强制验证这两样——没有数字的「洞察」就是废话。

## 快捷键

| 按键 | 作用 |
| --- | --- |
| `Ctrl+N` | 新建项目 |
| `Ctrl+K` | 记录一条知识 |
| `Ctrl+I` | 导入员工提交 |
| `Ctrl+R` | 刷新 |
| `Ctrl+E` | 导出全部数据 |
| `F1` | 使用说明 |

## 数据

存在 `~/ProjectRecorder/projects.db`（即 `C:\Users\你的用户名\ProjectRecorder\projects.db`）。

**和程序放在哪无关**——换 exe 位置、重装都不会丢数据。但**换台电脑登录不同用户就是全新的空库**。

导出：「文件 → 导出全部数据」，可选 Excel（`.xlsx`，需要 openpyxl）或 CSV（不需要额外依赖，会生成 11 个文件）。

清空：`python clear_data.py`（会先列出内容再问确认）。

## 文件说明

```
ProjectRecorder/
├── main.py           入口：主窗口、驾驶舱、小助手、员工、分配
├── detail.py         项目详情（五个页签）+ 子对话框 + 导出/导入工时窗口
├── knowledge_planet.py 知识星球：星图、冰山、录入、关联、反思
├── db.py             全部数据库读写；界面层不写一行 SQL
├── metrics.py        公共计算：负荷率、预算占用、日期、数值兜底
├── rules.py          预测引擎、小助手问答、主动发现
├── submit.py         员工提交：导出/导入工时文件、去重指纹
├── server.py         局域网提交服务
├── server_pages.py   员工在浏览器里看到的页面
├── chart.py          QPainter 手绘折线图、柱状图、时间轴、负荷图
├── widgets.py        徽标、指标卡、对话气泡、流式布局
├── theme.py          浅色 / 深色调色板
├── style.qss         界面样式模板（颜色写成 $token）
├── export.py         导出 11 张表到 Excel / CSV
├── schema.sql        建表脚本（打包必须带上）
├── check.py          自检：py check.py
├── build.py          打包：py build.py
├── clear_data.py     清空数据库
├── preview.html      配色预览（浏览器直接打开）
└── requirements.txt  依赖
```

## 配色

清冷的蓝灰骨架 + 低饱和石青强调，风险四色（健康 / 关注 / 风险 / 严重）全部降饱和，避免一屏红黄绿像交通灯。

改配色**只需要动 `theme.py`** —— `style.qss` 里写的是 `$bg_win` 这样的 token，运行时替换。加一套主题就是再加一个字典。

想看效果不用启动程序：**双击 `preview.html`**。

## 打包成 exe

```powershell
py -m pip install pyinstaller
py check.py                  # 先确认没问题
py build.py --onefile --clean
```

产物：`dist\项目记录器.exe`。

`build.py` 已经处理好了：`schema.sql`（**漏了会启动即崩**）、`style.qss`、`README.md`、`preview.html` 和应用图标一起打进去；排掉 tkinter / matplotlib / numpy 和一堆用不到的 PyQt6 子模块。

打包后注意事项：

- **数据仍在 `~/ProjectRecorder/`**，不在 exe 旁边
- **`--windowed` 藏了报错**：双击没反应就用命令行跑，报错会显示出来
- **体积约 60–90 MB**，PyQt6 本身就占地方
- **发给别人要压成 zip**：微信 / QQ 对 `.exe` 拦截很凶

```powershell
Compress-Archive -Path dist\项目记录器.exe `
                 -DestinationPath dist\项目记录器.zip -Force
```

对方第一次运行会看到 Windows SmartScreen 警告，点「更多信息」→「仍要运行」（程序没买代码签名证书，不是病毒）。

## PostgreSQL 集成测试（opt-in）

普通单元测试不会连接数据库。需要验证 RLS、RPC、股份投票、积分和知识解锁时，使用一次性 PostgreSQL/Supabase 测试库：

```powershell
python -m pip install -r requirements-test.txt
$env:PROJECT_RECORDER_TEST_DATABASE_URL = 'postgresql://postgres:postgres@127.0.0.1:5432/project_recorder_test'
python -m unittest tests.test_enterprise_governance_integration -v
python -m unittest tests.test_decision_integration -v
python -m unittest tests.test_execution_integration -v
python -m unittest tests.test_operations_integration -v
python -m unittest tests.test_intake_integration -v
python -m unittest tests.test_meeting_integration -v
```

运行前按以下顺序在测试库执行：

```text
mobile/sql/setup-tables.sql
mobile/sql/migrate-notify.sql
mobile/sql/work-session.sql
mobile/sql/merit-ledger.sql
mobile/sql/rewards-leave.sql
mobile/sql/unified-platform.sql
mobile/sql/enterprise-identity.sql
mobile/sql/community.sql
mobile/sql/enterprise-governance-v2.sql
mobile/sql/task-accept-extension.sql
mobile/sql/decision-approvals-v1.sql
mobile/sql/execution-tracking-v1.sql
mobile/sql/operations-economics-v1.sql
mobile/sql/work-intake-v1.sql
mobile/sql/shareholder-meetings-v1.sql
mobile/sql/shareholder-meeting-verification-v1.sql
```

决策中心集成测试位于 `tests.test_decision_integration`，覆盖审批回写、幂等重复请求、事件/审计记录和越权拒绝。
经营集成测试位于 `tests.test_operations_integration`，覆盖经营聚合、逐字段金额上限、跨企业项目拒绝审计、技能自助编辑权限、项目-only 能力权限、工时标签、员工证据说明、经理复核和审计。执行追踪集成测试位于 `tests.test_execution_integration`，会实际执行 PL/pgSQL 函数体，覆盖看板全部分区、验收/评级/积分门禁、返工重开、权限只读、中文风险与紧急度归一化、决策双写同步、可选依赖、绩效聚合、接收方交接、变更不改计划及直接表写入拒绝。

注意：

- `PROJECT_RECORDER_TEST_DATABASE_URL` 未设置或未安装 `psycopg2-binary` 时，集成测试会自动跳过，不影响普通 `unittest`。
- CI 中把该变量保存为受保护的 secret，指向临时数据库；不要让测试连接生产库。
- 集成测试需要 `authenticated`、`anon`、`auth.uid()`、`auth.users`、`pgcrypto` 和 Supabase RLS 环境；普通本地 PostgreSQL 需先创建这些角色/函数与 schema，再按上方顺序执行迁移。仅有 `pglast` 不能验证 PL/pgSQL 函数体，因此发布前必须让该 opt-in 套件实际调用 RPC。
- 测试大多在事务中回滚；并发发分测试会提交隔离夹具并在 `finally` 中清理，因此必须使用一次性数据库。
- 发布前应先让 opt-in 集成测试在一次性数据库实际执行全部 RPC，再执行 `python check.py`、`node build-www.js`、`node selfcheck.js`、SQL `pglast` 解析和 `npx cap sync android`。

## 自检

```powershell
py check.py
```

跑六项，都不需要启动界面：

1. **语法检查** —— 所有 .py 编译一遍
2. **未定义名字** —— 用 ast 静态扫描「用了但没导入 / 没定义」的名字
3. **资源检查** —— schema.sql 等打包必需的文件在不在
4. **数据层** —— 内存库跑一遍完整读写
5. **预测引擎** —— 验证结论、依据、等级
6. **小助手** —— 空库和有数据的库各问 22 个问题；**动态建议必须真能被回答**（不能是死按钮）
7. **洞察引擎** —— **干净数据上不误报**，问题数据上八类判据全触发
8. **导出** —— 真导出 11 张 CSV 并逐个确认文件存在（含知识星球）

界面出问题时先跑它，能分清是「数据算错了」还是「界面画错了」。
