# E10 产品收敛契约（R01 · #79 · 冻结版 2026-11-10）

本文件是 E10 后续 issue（R02–R13）的冻结契约。它回答三件事：配置怎么收敛成「简报」、每个决策的默认值是什么、界面用哪一套状态词。交互细节以 [interaction-spec.md](interaction-spec.md) 为准；两者冲突时以本文件的数据契约为准、以 interaction-spec 的界面行为为准。依据见 [审计](audit-2026-11-09.md)。

不变量（E10 任何 issue 都不得削弱）：普通/成人分区隔离与禁止跨组回退或复用；`outcome_unknown` 保留预留、不自动重试或切备；投递键 `subscription/edition/bot/chat/part` 与回执防重发；一次性配对码、仅主人私聊；Keychain 只存引用、导出无凭据；来源文本是不可信数据；迁移前备份、失败回滚、旧版不写新版 schema。

---

## 1. 「简报」对象与配置 schema v4

### 1.1 决定：沿用 `subscriptions` 实体作为简报，不新建实体

v3 的 `subscription` 已经拥有简报需要的全部字段（时间、时区、目标 Bot、来源、条数、样式、开关），而且 `pipeline_jobs`、`schedule_scopes`、`delivery_manifests` 和投递键都以 `subscription_id` 为键。新建 `digest` 实体会改动这些持久化键并破坏回执防重发，收益为零。因此：

- **内部名保持 `subscriptions`，用户可见名统一为「简报」。** `subscription_id` 继续是简报的稳定 ID。
- **`categories` 退化为内置只读目录**（`id / name / partition`），不再承载任何可编辑设置。
- 「schedule scope」「route」「target」本来就不是配置实体，只是派生物；它们只从界面词表中消失，后端名称不变。

### 1.2 v3 → v4 字段去向

| v3 位置 | v4 | 迁移规则 |
|---|---|---|
| `schema_version: 3` | `4` | — |
| `ui_locale`, `news_output_locale`, `owner_id`, `x_api` | 不变 | 原样保留 |
| `timezone` | 不变；**新库默认 = 系统 IANA 时区**（读取失败时 `Asia/Tokyo`） | 已有值原样保留 |
| `group_styles {normal, adult}`、`categories[].style` | **删除** | 每个简报写入它在 v3 下的**有效样式**，按 v3 原优先级一次算出：简报自身非空值 > 所属分类 `style` > 所属分区 `group_styles` > `text`；然后删除两处 |
| `categories[].primary_profile_id / backup_profile_id` | **删除**，移到 `subscriptions[].primary_profile_id / backup_profile_id`（新增，可空） | 该分类下每个简报继承分类的值；之后分类上删除 |
| `categories[].id / name / partition` | 保留，只读内置 | — |
| `subscriptions[]` 全部 v3 字段 | 保留 | `style` 由「可空 + 多层继承」改为**非空**（值由上一行算出） |
| `subscriptions[].focus_weights` | 保留（界面「国内/娱乐」滑块的数据） | — |
| `sources[]`, `accounts[]`, `model_profiles[]`, `bots[]` | 不变 | — |

样式优先级由五层收敛为三层：**本次请求（Telegram「做报纸」）> 单独发的 X 账号 > 简报**。分类与分区默认层被删除。

迁移沿用现有备份 → `BEGIN IMMEDIATE` → 变换 → 校验 → 提交的机制；失败回滚并保留原库；v4 启动遇到 v5 库拒绝写入。迁移增加 config revision，使所有旧路由快照失效。

### 1.3 拆分

「拆成两份」= 复制当前简报为一个新 `subscription`（同 `category_id`，新 ID，名称加后缀），两份各自持有时间、Bot、来源与 `focus_weights`。「并回」= 删除第二份；第二份已产生的历史 job / 回执保留在原表，不迁移。

---

## 2. 默认值表（单人本机）

| 决策 | 默认 | 理由（单人场景） | 由谁实现 |
|---|---|---|---|
| 全局时区 | 新库取系统 IANA 时区；已有库不变 | 用户就在这台 Mac 前，系统时区就是他的时区 | R03 |
| 简报时区 | 新建/拆分时取全局时区 | 同上；界面仍可逐份修改 | R03 |
| 发送时间 | 内置每类一个时间（08:00 … 22:00，与 v3 相同） | 已合理 | — |
| 每期条数 | 5 | 已合理 | — |
| 样式 | `text` | 不额外花钱 | R03 |
| 目标 Bot | **首个配对成功的普通 Bot**：写入所有 `bot_ids` 为空的普通简报；第二个起不自动分配；成人简报永不自动分配 | 只有一个 Bot 时让用户再选一次是纯负担；成人仍须显式 | R04 |
| 调度总开关 | 新库 `enabled = true`；升级时若已有启用的简报而调度为关，保持关（界面显示「已暂停全部推送」）；否则设为开 | 「开启简报 = 会推送」是人的预期；升级不得突然开始推送 | R03 |
| 准备预留（hold） | 内置常量：普通 / 成人每期 **$0.50**（500 000 µUSD）；探测每次 **$0.01**；升级时只填补为空的值 | 只用于防止单期失控；用户不需要理解 | R03 / R04 |
| 报纸预留 | 开启报纸时，为空的项填入：生图每页 **$0.40**、视觉校验每页 **$0.05**、每期总额 **$1.00**（`generation_hold` 400 000 / `vision_hold` 50 000 / `task_limit` 1 000 000 µUSD） | 让「开启报纸」一步可用；已有值不覆盖 | R04 |
| 图片 / 语音提问预留 | 开启时为空的项填入：视觉 **$0.05**、转写 **$0.05**（`vision_hold` / `stt_hold` 各 50 000 µUSD） | 同上 | R04 |
| 价格表 | 允许为空；**未知价格不阻塞**。调用照常进行，结算记 `cost_source = unpriced`，用量（token）照实记录 | 用户关心的是「新闻到了没有」；账单以供应商为准 | R03 |
| 月度上限 | **新库默认 $20**（20 000 000 µUSD），可清空为不限；已有库不变。有上限时：已知费用 + 未计价调用按其预留计入，达到即停发并在概览「需要注意」中出现 | 首次使用就有保护；与引导页文案一致 | R03 |
| 次级上限（生图月额、供应商额、X 分区 / 账号额） | 不新增默认；**已有值原样保留并继续生效**。任何一项非空时，「接入 › 费用」显示「其他上限」行，逐项列出并可清除；触发时按 reason 显示具体文案 | 不静默删除用户设过的限制，也不让它们变成看不见的阻塞 | R03（数据）/ R10（界面） |
| X 每日读取上限 | 新库 **200 条/天**（普通 + 成人合计）；已有库若为 `null` 保持不限并在「需要注意」提示 | 防止误配账号耗尽额度 | R03 |
| 预算、提醒、视频时区 | 新库与全局时区取同一个系统时区（`budget.model.timezone`、`budget.x.timezone`、X 提醒与视频策略的 `timezone`）；界面不单独暴露；已开启的预算周期不受影响（spec 21 规则） | 五处时区合一 | R03 |
| 能力探测 | 保存 Key 后**自动做一次文字探测**；视觉 / 生图 / 转写只在开启对应功能时探测；`tts` 从能力列表移除 | 用户只问「Key 能用吗」 | R04 |
| 来源 | 开启一个空简报时，把该分类推荐目录中分区匹配的源加为**待验证**并自动试采集；试采集成功才启用 | 推荐目录已知分区与分类 | R09（UI）+ 现有 op |
| 帖子类型 | 原帖 + 引用 | 已合理 | — |
| 补发窗口 / 提前准备 | 360 分钟 / 15 分钟，固定，不在界面暴露 | 已合理 | — |

## 3. 状态词汇（一等状态与对应操作）

后端保留各表原有字段；R02 / R05 在控制接口上输出统一的 `{state, reason}`，Swift 只认下表左列。

| 界面状态 | 来源（occurrence.status / job / delivery target） | 用户动作 → 操作 |
|---|---|---|
| 等待中 | `planned` | — |
| 准备中 | `preparing`, `waiting` | — |
| 延迟 | `late` | — |
| 已发送 | `delivered`；target `delivered` | — |
| 部分发送 | `partial`；target `partial` | 检查并补发 → `delivery.resolve`（需确认可能重复） |
| 结果未知 | `outcome_unknown`（模型或投递） | 检查并重试 → 模型：`jobs.resume(acknowledge_duplicate_charge)`；投递：`delivery.resolve(acknowledge_duplicate_send)` |
| 已跳过 | `no_news`, `skipped`, `superseded` | — |
| 已暂停 | job `paused` 或调度总开关关 | 恢复 → `jobs.resume` / 调度开关 |
| 等你决定 | `held`（部分投递后目标变化） | 继续 / 停止 → `schedule.resolve` |
| 未能发送 | `blocked`, `cancelled`；target `blocked` / `revoked` | 按 `reason` 映射的修复动作（见 interaction-spec §2.4） |

`blocked` 不再单独出现在界面；它总是带一个 `reason`，界面显示 reason 对应的文案与修复按钮。

## 4. 用户可见词表

以 [interaction-spec §0.2](interaction-spec.md#02-用户可见词表三语以-zh-hans-为准en--ja-在-copy-表中对齐) 为准，本契约追加两条硬规则：任何界面文案不得出现 subscription、category、scope、route、target、hold、probe、revision、µUSD / 微美元；金额一律美元两位小数。

## 5. 被替代的冻结条款

下列 spec 的对应条款自本契约冻结起由 E10 替代；原文件保留，只在文末追加「Superseded by E10」小节指向这里。

| Spec | 被替代的条款 | 替代为 |
|---|---|---|
| 10 versioned-config | Tokyo 默认时区 | §2 系统时区 |
| 11 effective-routing | `group_styles` 与分类 `style` 两层；分类级主备覆盖 | §1.2 三层样式；主备覆盖在简报上 |
| 19 provider-capabilities | 保存配置零网络；探测只在用户显式调用、由用户给出 hold；五种能力分别登记 | §2 保存 Key 即文字探测、内置探测 hold；按需探测；移除 tts |
| 21 budget-ledger | 未配置价格即 `pricing_unknown` 拒绝派发；模型与 X 各自时区 | §2 未计价照常执行；预算时区跟随全局 |
| 29 durable-scheduling | 调度默认关闭、升级保持关闭；hold 未配置即阻止付费准备 | §2 调度开关规则；内置 hold |
| 31 telegram-targets | 不自动分配任何目标 | §2 首个普通 Bot 自动成为空简报的目标 |
| 33 native-settings | 五页结构、沿用旧 mockup、不重新设计 | interaction-spec + docs/mockup/redesign |
| 34 subscriptions-sources | 旧 mockup 不变；编辑使用 sheet | interaction-spec §5 内联编辑 |
| 35 model-bot-settings | 用户手填微美元 hold 与验证能力 | interaction-spec §6 |
| 40 local-operations | 只对全新实例导入；诊断三件套在主界面 | 导入规则不变；排障工具收进「高级」（interaction-spec §8.5） |

## 6. 不做的事

不新建 `digest` 表或重命名持久化键；不改变计划槽的稳定 ID 与已完成期次的身份（spec 29：改时间不重发已完成的期次）；不引入多租户、团队权限、分布式队列或云端管理；不改变分区隔离、`outcome_unknown`、投递键和配对的语义；不内置供应商价格；不删除旧 spec 文件。
