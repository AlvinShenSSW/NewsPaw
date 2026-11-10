# NewsPaw 交互规格（E10 · 2026-11-10）

适用：macOS 14+ SwiftUI 设置 App 与菜单栏项。本文是 [Epic E10 #78](https://github.com/AlvinShenSSW/NewsPaw/issues/78) 各子 issue 的交互验收依据；视觉基线见 [docs/mockup/redesign](../../mockup/redesign/README.md)（静态 HTML + 截图）与 [Design 画布](https://claude.ai/artifact/PqJ1KV8JtV1C7LXNyGW4Pt)。问题根因见[审计](audit-2026-11-09.md)。

术语约定：下文「op」指控制 socket 操作；「现有」表示 v0.5.0 已有，「新增」表示由 R02–R05 提供。

---

## 0. 原则与词表

### 0.1 五条原则

1. **一个意图一个对象。** 用户想的是「世界新闻这一档」，界面就只有「简报」；category / subscription / scope / route / target 不出现在任何文案里。数据契约见 [contract.md](contract.md)。
2. **默认值先行，阻塞点后置。** 任何能有合理默认的字段都预填（时区 = 系统、时间 = 内置、Bot = 唯一可用、hold = 内置、价格未知 = 标注）；只有真的缺东西才打断。
3. **就地编辑，就地反馈。** 不再使用 `.sheet`；编辑在行内展开、Popover 或独立窗口完成；每个错误显示在出错的那一行，格式固定为「发生了什么 + 怎么办 + 一个按钮」。
4. **后端严谨，界面安静。** 普通/成人隔离、outcome_unknown、回执防重发、配对安全全部保留，但对用户只呈现为一行状态和一个动作。
5. **一处改，处处同步。** 暂停全部推送、Bot 目标、读取上限等状态在所有出现处一致；后台 revision 变化自动合并，不让用户看见「版本冲突」。

### 0.2 用户可见词表（三语以 zh-Hans 为准，en / ja 在 Copy 表中对齐）

| 对外词 | 对内概念 | 禁止出现的词 |
|---|---|---|
| 简报 | `subscriptions` 实体（吸收原分类级设置，见 [contract §1](contract.md)） | 订阅、分类、计划槽、路由、scope、edition |
| 机器人 | Telegram bot | Bot（中文文案中）、目标、target |
| 发送到 | subscription.bot_ids | 分配、绑定目标 |
| 模型 / Key | model profile / credential | provider、profile、credential_ref、探测、probe |
| 可用 / 未填 Key / Key 无效 | capabilities.text verified / credential missing / 4xx | untested、verified、stale、pending |
| 普通内容 / 成人内容 | partition normal / adult | 分区（可在说明文字里出现一次）、普通新闻、一般 |
| 每月最多花 / 本月已用 | budget monthly cap / spent | hold、预留、cap、quote、微美元、price table |
| 后台 | resident process + control service | 驻守进程、登录项（只在自启开关说明中出现）、daemon、service |
| 暂停全部推送 | scheduler paused | 停止调度、pause_category、jobs.pause |
| 结果未知 | outcome_unknown | unknown、未确认 |
| 等待中 / 准备中 / 已发送 / 已跳过 / 已暂停 / 延迟 | planned / preparing·waiting / delivered / skipped·no_news / paused / late | blocked、held、superseded |
| 单独发 / 并入汇总 | X account priority special / normal | 特别关注、特别账号、include_in_aggregate |
| 试采集 / 正常 / 没更新 / 待验证 / 读不到 | sources.preview / fresh / stale / preview_required / failed | health、freshness、epoch |

所有金额显示为美元、两位小数（`$3.42`）；所有时间显示为本地 24 小时制 `HH:MM`；相对时间用「今天 08:05 / 昨天 23:10 / 11-08」。

### 0.3 macOS 组件映射

| 界面元素 | SwiftUI / AppKit | 规格 |
|---|---|---|
| 主窗口 | `Window("NewsPaw", id: "main")` + `NavigationSplitView` | 默认 1180×820，最小 900×600，侧栏 200pt 固定 |
| 侧栏 | `List(selection:)` `.listStyle(.sidebar)` | 5 项；图标为 20×20 彩色圆角方块内白色 SF Symbol（概览 house.fill 蓝、简报 newspaper.fill 橙、X 账号 xmark 黑、接入 link 绿、设置 gearshape.fill 灰）；底部状态 `Label` + 11pt 说明 |
| 工具栏 | `.toolbar` `.navigationTitle(page)` | 左标题 15pt bold，右侧主操作 `Button` / `.borderedProminent` |
| 分组 | `Form` `.formStyle(.grouped)` 或 `GroupBox` | 行高 ≥ 40pt，行内 13pt 正文 + 11pt secondary 说明 |
| 开关 | `Toggle` `.toggleStyle(.switch)` | 38×22，禁用时 45% 透明并有 `.help` 说明原因 |
| 下拉 | `Picker` `.pickerStyle(.menu)` | 用于条数、语言、保留天数 |
| 分段 | `Picker` `.pickerStyle(.segmented)` | 用于样式、普通/成人、单独发/并入汇总 |
| 时间 | `DatePicker(displayedComponents: .hourAndMinute)` `.datePickerStyle(.stepperField)` | 每个时间一个控件 + 删除按钮；「＋ 加一个时间」追加 |
| 比例 | `Slider(0...100, step: 5)` 两端标签 | 仅地区类简报 |
| 折叠 | `DisclosureGroup` | 标题 12pt semibold，默认收起；记住展开状态（UserDefaults） |
| 内联编辑 | 行内 `if expanded { … }` + `.animation(.default)` | 同页同一时刻最多一个简报展开；展开时滚动到可见 |
| 浮层 | `.popover(arrowEdge:)` | 更换 Key、粘贴链接、推荐目录、单独发时间选择 |
| 独立窗口 | `Window(id: "onboarding")` | 首次设置 760×580，不可缩放，有关闭按钮 |
| 确认 | `.confirmationDialog` | 仅破坏性操作（见 §2.5） |
| 菜单栏 | `MenuBarExtra` | 见 §8.3 |
| 字体 | 系统 13pt 正文、11pt caption、15pt 标题、24pt 数字 | 不自定义字体 |
| 颜色 | `.accentColor` 系统蓝、状态点 绿 `#28A745` / 黄 `#E5A100` / 红 `#E0352B` / 灰 `#A9A9AE`、成人标签紫 `#6B21A8 / #F1E6FF` | 深色模式用系统语义色，状态点不变 |

---

## 1. 导航与窗口

### 1.1 信息架构

```
概览      首页。就绪清单（未完成时）/ 今天的推送 / 本月费用 / 需要注意
简报      9 个简报行，内联展开编辑；工具栏：导入 OPML… / 添加来源…
X 账号    普通 | 成人 分段；添加行；账号列表；汇总卡；读取上限；高级
接入      机器人 / 模型 / 费用 / X 数据连接；工具栏：＋ 添加机器人
设置      语言 / 后台 / 数据 / 高级（排障）
```

快捷键：⌘1–⌘5 切页；⌘R 刷新；⌘, 打开设置页；⌘Q 退出界面（不停后台）。页面切换保留各页滚动位置与展开状态。

### 1.2 启动路径

| 条件（来自 `setup.readiness`，R02） | 行为 |
|---|---|
| 后台未运行且登录项未注册 | 主窗口打开概览，显示「后台未运行」状态卡 + `启动后台` 主按钮（调用现有 ResidentAgent 注册 / 启动）；其它页可切换但显示同一张卡 |
| 后台运行、readiness 未完成且从未打开过向导 | 自动打开首次设置窗口（§3），主窗口在其后 |
| 后台运行、readiness 未完成、向导被跳过 | 主窗口概览，显示「还差 N 步」清单 |
| readiness 完成 | 主窗口概览，不显示清单 |

### 1.3 后台轮询与数据流

- `AppModel` 每 3 秒：`service.status` → `setup.readiness`（新增）→ `config.get` → `bots.list`。`config.get` 每轮都取（本机 socket，单人配置体积小），用它返回的 `revision` 判断是否有变化。
- 各页按需：简报页 `sources.list` + `schedule.status`；接入页 `models.status` × N + `credentials.status` + `budget.get`；X 页 `x.accounts.list` + `x.lists.list` + `x.posts.coverage`；概览 `schedule.status(today)` + `delivery.status(today)` + `budget.get`。
- 长任务一律用 `request_id` + `*.status` 轮询（R05），UI 显示行内 `ProgressView` 小圆圈 + 文案「正在…」，≥ 10 秒显示「仍在进行，可以先做别的」。

---

## 2. 全局状态与反馈规范

### 2.1 加载

| 场景 | 呈现 |
|---|---|
| 首次进入页面且无缓存 | 组内占位行（灰条 skeleton，最多 3 行），≤ 300ms 不显示 |
| 行内动作（试采集、验证、测试发送） | 按钮替换为 `ProgressView().controlSize(.small)` + 原文案；其它控件不禁用 |
| 整页刷新（⌘R） | 工具栏刷新按钮转圈；内容不清空 |

### 2.2 保存

- 字段改动在失焦、选择或开关切换后 **即时保存**（Toggle / Picker / Segmented 立即；TextField / DatePicker 失焦或回车），页脚或行尾显示「已自动保存 · HH:MM」，3 秒后淡为灰色常驻。
- 保存失败：该行下方出现 11pt 红字一行 + 按钮（重试 / 撤销），输入值保留；不弹窗、不清空。
- 不再有「保存」「取消」按钮对，除了首次设置窗口的「继续」。

### 2.3 后台 revision 变化（现有 `config_conflict` 与各域 `*_changed`）

- 轮询发现 revision 变化：静默重取 `config.get`，对**未在编辑**的字段直接刷新；对**正在编辑**的字段保留本地值并在保存时用新 revision 重试一次。
- 重试仍冲突（同一字段被 Telegram 命令改了）：行内显示「这项刚被 Telegram 里的命令改成了 X，保留你的改动？」+ `用我的` / `用它的`。
- 用户永远看不到 revision、CAS、conflict 这些词。

### 2.4 错误文案模板

`{发生了什么}。{怎么办}。` + 一个按钮。按 code 映射（R02 提供 `code / domain / field`）：

| code（示例） | 文案 | 按钮 |
|---|---|---|
| `invalid_token` | Telegram 不认这个 Token。请到 @BotFather 复制完整 Token 再试。 | 重新粘贴 |
| `webhook_conflict` | 这个机器人正被别的程序用 webhook 接管。关掉那边后再验证。 | 重新验证 |
| `duplicate_bot` | 这个机器人已经添加过了。 | 查看 |
| `pair_expired` | 配对码过期了。 | 重新生成 |
| `pair_attempts_exhausted` | 连续输错 5 次，这个码作废了。 | 重新生成 |
| `provider_http_401` | Key 被拒绝（401）。请到 {供应商} 控制台确认 Key 没有过期，再重新填入。 | 重新填入 |
| `provider_http_429` | {供应商} 说请求太频繁（429）。稍等一分钟再试。 | 再测一次 |
| `provider_timeout` | {供应商} 没有在 30 秒内回应。 | 再测一次 |
| `outcome_unknown`（模型） | 这次调用发出去了但没收到结果，可能已经扣费。确认后再试一次。 | 检查并重试 |
| `outcome_unknown`（投递） | Telegram 没有回应，这期可能已发出，也可能没有。 | 检查并补发 |
| `monthly_limit` | 本月已到 ${cap} 上限，推送已暂停。 | 调整上限 |
| `image_limit`、`provider_limit`、`partition_limit`、`account_limit`、`daily_limit` | 已达到{生图月额 / {供应商} 月额 / {分区} X 读取额 / @{账号} 读取额 / X 每日读取}上限。 | 查看上限（跳到「接入 › 费用」对应行） |
| `unsafe_url` | 这个链接指向内网或带有凭据，不能添加。 | — |
| `unsupported_source` | 还不会读这个网站，只能先存为待验证。 | 试采集 |
| `source_stale` | {来源} 已 {N} 天没有新条目。 | 试采集 |
| `keychain_locked` | 钥匙串被锁定，解锁后 NewsPaw 才能读到 Key。 | 打开钥匙串访问 |
| `internal_error` | NewsPaw 内部出了问题，已记录在日志里。 | 复制诊断信息 |

### 2.5 需要确认的操作（`confirmationDialog`，标题 + 影响 + 两个按钮）

关闭一个简报（说明：今天 18:00 的那期不会发）；删除机器人（列出失去目标的简报）；解除配对；移除来源（列出受影响简报）；改 X 账号分区（`x.accounts.partition_impact`）；停止后台；清理数据；导入设置。
**不需要确认**：开关开启、改时间、改条数、切换样式、暂停全部推送（可逆且有明显状态）。

### 2.6 空状态

每个列表为空时显示一行 13pt 灰字说明 + 一个主按钮：「还没有机器人。添加一个后，简报才有地方发。」+ `＋ 添加机器人`。

### 2.7 可访问性

所有状态点配文字（不只颜色）；图标按钮有 `accessibilityLabel`；展开/收起有 `accessibilityValue`；Tab 顺序按视觉顺序；`accessibilityReduceMotion` 时展开无动画。

### 2.8 状态词汇（R05 #83）

`jobs.get`、`schedule.status` 的每条 occurrence、`delivery.status` 的每个 target 都带同一个 `state` 字段（`src/newspaw/vocabulary.py`），界面只按它显示；原有 `status` / `reason` 保留用于说明文案。

| `state` | 界面 | occurrence `status`（`reason`） | job `status` | target `status` |
|---|---|---|---|---|
| `waiting` | 等待中 | `planned`、`rescheduled`（改到了更晚的时间） | — | — |
| `preparing` | 准备中 | `preparing`、`waiting`、`delivering` | 收集 / 编辑 / `inflight` / `waiting` / `awaiting_delivery` | `pending`、`inflight` |
| `late` | 延迟 | `late` | — | — |
| `delivered` | 已发送 | `delivered` | — | `delivered` |
| `partial` | 部分发送 | `partial` | — | `partial` |
| `model_unknown` | 结果未知（模型） | reason `model_outcome_unknown`（`waiting`/`late`/`outcome_unknown`） | `outcome_unknown` | — |
| `delivery_unknown` | 结果未知（投递） | `outcome_unknown`（其他 reason）；`waiting`/`late` 且 reason `delivery_outcome_unknown` | — | `outcome_unknown` |
| `skipped` | 已跳过 | `no_news`、`skipped`、`superseded` | `no_news`、`stale` | `skipped` |
| `abandoned` | 已放弃补发 | 投递有 part 的 `resolution.action == skip` 且没有仍未知的 part（优先于其他） | — | 同左 |
| `paused` | 已暂停 | `waiting`/`late` 且 reason `job_paused` | `paused` | reason `job_paused` |
| `held` | 等你决定 | `held` | — | — |
| `failed` | 未能发送 | `blocked`、`cancelled` | `cancelled`、`blocked`、`refused`、`collection_failed` | `blocked`、`revoked` |

调度总开关关闭时的「已暂停全部推送」由界面根据 `scheduling_enabled` 叠加，不是一个后端状态。

---

## 3. 首次设置窗口（R07 #85）

独立窗口 760×580，三步，顶部步骤条（✓ / 当前 / 待），底部左「先跳过，稍后在「接入」里填」，右「上一步」「继续（默认）」。任何一步跳过都允许，跳过项之后在概览清单里继续出现。

### 步骤 1 · 连接 Telegram

| 元素 | 规格 |
|---|---|
| 说明 | 「在 Telegram 里找 @BotFather 新建一个机器人，把它给你的 Token 粘贴到这里。」+ 链接「怎么做？」（打开 Telegram 官方页） |
| Token 字段 | `SecureField`，粘贴即触发 `credentials.set(kind=bots)` → `bots.verify`（R05 后为轮询）；行尾状态：正在验证… / ✓ @username / 错误文案 |
| 配对块 | 验证成功后出现：「在 Telegram 里打开 @username，发送：」+ 大号等宽 `/pair 482 913` + `复制` + 倒计时「9 分 40 秒后失效」；每 2 秒轮询 `bots.status`，paired 后块变为绿色「已配对 · 08:05」并自动启用「继续」 |
| 过期 | 倒计时归零 → 文案「配对码过期了」+ `重新生成` |
| 多 Bot | 本步只接一个；文案末尾「还可以在「接入」里再加一个只收成人内容的机器人」 |

### 步骤 2 · 模型 Key

| 元素 | 规格 |
|---|---|
| 模型下拉 | 默认「GPT-6 Luna（OpenAI）· 推荐」；选项：MiMo Flash；自定义…（展开 URL + 模型 ID 两个字段） |
| Key 字段 | `SecureField` + `粘贴`；失焦或粘贴后 `credentials.set` → 后端自动文字探测（R04） |
| 结果行 | 绿点「测试通过」+「刚才发了一条很短的测试消息，模型正常回复（{model} · {秒} · 约 ${cost}）」+ `再测一次`；失败按 §2.4 |
| 折叠 1 | 「我也想看 AV 产业 / X 成人博主 · 可选」→ 展开 DeepSeek Key 字段，同样自动探测 |
| 折叠 2 | 「高级：自定义 API 地址 / 备用模型」 |
| 费用说明 | 一行 12pt：费用由你自己的账号承担…默认每月最多 $20（contract §2；可在「接入」改或清空） |

### 步骤 3 · 选择简报

| 元素 | 规格 |
|---|---|
| 列表 | 9 个简报，每行：图标、名称、一句说明、默认时间、开关；默认勾选 世界新闻、日本 |
| 发送到 | 自动选中唯一已配对的普通 Bot；成人简报行灰显并说明「需要成人模型 Key 和允许成人的机器人」 |
| 底部 | 主按钮 `完成并试发一期`（默认）→ 对第一份勾选的简报触发 §5.6，关闭窗口，打开概览；次按钮 `完成，等定时推送` → 只关闭窗口。两种都写 `onboardingSeen`；清单第 4 步在第一份简报（试发或定时）到达后完成 |

完成或跳过都写 UserDefaults `onboardingSeen = true`；readiness 仍未完成时概览清单接管。

---

## 4. 概览（R08 #86）

### 4.1 布局

两列：左 `minmax(0,1fr)`，右 320pt。工具栏右：`立即发一期…`（Popover 选简报）、`管理简报`（默认按钮，跳简报页）。日期行：「2026 年 11 月 9 日 星期日 · Asia/Tokyo（跟随系统）」。

### 4.2 就绪清单（`setup.readiness`）

标题「还差 N 步，就能收到第一份简报」+ 进度条「k / 4」。固定四步：机器人已配对 → 模型 Key 已验证 → 选择要收的简报 → 发一期试试。每步：圆点（✓ 绿 / 数字蓝 = 当前 / 数字灰 = 待）、标题、11pt 说明（含实际实体：@bot、模型名、时间）、右侧按钮（已完成 `查看`；当前步 默认按钮 `去开启` / `去接入`；待步无按钮）。按钮跳转对应页并把目标控件滚动到可见、高亮 1 秒。四步完成后整组淡出并不再显示；说明行「完成后这个区域会自动消失。」

### 4.3 今天的推送（`schedule.status` 当日 + `delivery.status`）

按计划时间排序；每行：`HH:MM`（44pt 等宽）、简报图标、名称、11pt 说明、状态。状态映射：

| occurrence / delivery | 状态点 + 文案 | 说明行 | 动作 |
|---|---|---|---|
| delivered | 绿「已发送 07:59」 | → @bot · N 条 | — |
| planned / preparing / waiting | 灰「等待中」 | 「17:45 开始准备」或「正在准备…」 | — |
| late（正在补发） | 黄「延迟」 | 「原定 08:00，正在补发」 | — |
| no_news / skipped | 灰「已跳过」 | 「没有合格的新条目」 | — |
| paused | 灰「已暂停」 | 「全部推送已暂停」 | `恢复`（跳设置） |
| partial | 黄「部分发送」 | 「3 / 5 段已到达」 | `检查并补发` |
| outcome_unknown，reason `model_outcome_unknown` | 黄「结果未知」 | 「写简报的模型调用发出去了但没收到结果，可能已经扣费。」 | `确认后重试` → 确认框说明可能重复扣费 → `jobs.resume(acknowledge_duplicate_charge: true)` |
| outcome_unknown（投递 part） | 黄「结果未知」 | 「Telegram 没有回应，这期可能已发出，也可能没有。」 | `检查并补发` → 确认框说明可能重复 → `delivery.resolve(action: retry, acknowledge_duplicate_send: true)`；`不再补发` → 确认框「这一期（或其中这一段）将不再发送，之后也不会自动重试」→ `delivery.resolve(action: skip)` |
| 投递 part 的 `resolution.action == skip`（用户选了不再补发） | 灰「已放弃补发」 | 「你选择了不再补发这一期」；多段时「其中 N 段已放弃补发」 | 无（不显示补发按钮，也不使用「没有合格的新条目」说明） |
| held（reason `partial_assignment_changed`） | 黄「等你决定」 | 「这期已发出一部分，之后发送对象变了。」 | `继续发剩下的` → `schedule.resolve(continue)`；`停止` → `schedule.resolve(stop)` |
| blocked、cancelled；target blocked / revoked | 红「未能发送」 | 具体 reason 文案（§2.4） | reason 对应的修复按钮 |

右上「最近 7 天 ›」展开为同格式 7 天列表（同页，不新开窗）。

### 4.4 本月费用（`budget.get`）

24pt `$3.42` + 「/ 上限 $20」（新库默认）或「/ 不限」；进度条（无上限时不显示）；说明「文字 $3.10 · 报纸生图 $0.32 · 11 月 1 日起」；分隔后「X 今日读取 84 / 200 条」。含 unpriced 时追加「其中 N 次未计价」。到限时整卡黄边 + `调整上限`。

### 4.5 需要注意

来源 stale（`sources.list.health.freshness == stale`）、备用模型未填（信息级）、Key 失效、后台未注册自启、Bot 等待配对。每条：状态点、标题、说明、链接「查看… ›」。无事项时整组隐藏。

### 4.6 后台未运行

整页替换为一张组：「后台没有运行」+ 「NewsPaw 的推送由一个后台程序完成，它会在登录时自动启动。」+ `启动后台`（默认）+ `打开登录项设置`（回退）。启动中显示进度；连上后恢复正常页面。

---

## 5. 简报（R09 #87）

### 5.1 列表行（收起态，高 44pt）

图标（26pt 圆角方块，Unicode 单字：世 日 澳 中 数 AI AV X；成人用紫色）、名称（+ 紫色「成人」标签）、11pt 摘要、状态、开关、`编辑` 链接按钮。

摘要规则：
- 开启：「每天 08:00 → @bot · 3 个来源 · 下一期 明天 08:00」；多个时间「每天 08:30、18:30」；多个 Bot「→ 2 个机器人」。
- 关闭：「关闭中 · 开启后默认每天 09:00 → @bot · 推荐 3 个来源」。
- 成人缺前置：「关闭中 · 需要成人模型 Key 和一个允许成人内容的机器人」+ 行内 `去接入补齐`，开关禁用。

状态：今天最近一期的 §4.3 状态；无则不显示。

### 5.2 开关行为

- 关 → 开：若来源为空则自动带入该分类推荐目录中 `partition` 匹配的源为待验证草稿并后台逐个 `sources.preview`；若无 Bot 则不允许开启并提示；成功后行展开到编辑态。
- 开 → 关：`confirmationDialog`「关闭「日本」？今天 18:30 的那期不会发；来源和设置都会保留。」`关闭` / `取消`。

### 5.3 展开编辑态（`DisclosureGroup`，同页仅一个展开）

标签列 88pt 右对齐，控件列自适应。

| 行 | 控件 | 保存 | 说明 |
|---|---|---|---|
| 发送时间 | N 个 `DatePicker(.stepperField)` + `×`；`＋ 加一个时间`（默认 +1 小时）；右侧「时区 Asia/Tokyo（跟随系统）· 改」→ Popover 时区搜索列表 | 失焦 | 同一天重复时间去重；最多 6 个 |
| 发送到 | 每个 Bot 一个 `Toggle(.checkbox)`；成人专用 Bot 对普通简报灰显 + 「成人专用」；普通 Bot 对成人简报灰显 + 「不接收成人内容」 | 立即 | 只剩一个可用 Bot 时自动勾选且不可取消（说明：只有一个可用机器人时会自动选中。） |
| 每期条数 | `Picker(.menu)`：最多 3 / 5 / 8 / 10 / 15 条 | 立即 | 说明「新闻不够时少发，不凑数。」 |
| 样式 | `Picker(.segmented)`：文字 + 链接 / 带来源配图 / AI 报纸 | 立即 | 选 AI 报纸且未配置生图能力 → 行内黄字「需要先在「接入 › 附加能力」开启生图」+ 链接；样式不可选 |
| 国内 / 娱乐 | `Slider` 0–100 步长 5，两端「国内 70%」「娱乐 30%」 | 失焦 | 仅 japan / australia / china |
| 来源（子表） | 见 §5.4 | — | — |
| 高级 | `DisclosureGroup`：换模型（Picker 继承 / 指定）、拆成两份（按钮，确认后生成第二个简报行，名称后缀「· 娱乐」）、暂停这份简报（与开关等价，保留） | — | — |
| 页脚 | 左「已自动保存 · 08:40」；右 `预览这期会选什么`、`立即试发一期`（默认） | — | — |

### 5.4 来源子表

子表头：「来源 · 3 个启用」+ 右侧 `从推荐目录添加`（Popover：该分类推荐源列表，勾选即加入为待验证并自动试采集）、`粘贴链接`（Popover：URL 字段 → `sources.discover` → 显示识别结果「RSS · 国内」或「还不会读这个网站」）。

每行：`Toggle(.checkbox)` 启用、26pt 字母图标、名称（11pt：类型 · 范围 · 最近条目时间）、状态、`试采集` 链接按钮。

| `health` / `preview_ready` | 状态 | 复选框 | 按钮 |
|---|---|---|---|
| fresh | 绿「正常」 | 可用 | 试采集 |
| stale（> 72h） | 黄「N 天没更新」 | 可用 | 试采集 |
| not yet previewed | 灰「待验证」 | 禁用 | `试采集后启用`（成功后自动勾选） |
| last_attempt failed / rate_limited | 红「读不到 · 原因」 | 可用但建议 | 试采集 |
| unsupported | 灰「还不会读这个网站」 | 禁用 | 移除 |

试采集中：按钮替换为小进度圈 + 「正在读取…」；结果出现在该行下方一行 11pt：「取到 12 条，最新 08:20」或错误文案，5 秒后收起为状态点。
移除来源：行尾 `⋯` 菜单 → 移除（确认，列出受影响简报）。

### 5.5 OPML 导入（工具栏）

`fileImporter` → `sources.import_opml` → 结果 Popover：按分类列出草稿、重复、跳过；全部为待验证，用户在各简报里试采集后启用。

### 5.6 立即试发一期

点击 → `subscriptions.preview` 显示 Popover「将选 N 条，发到 @bot，约 ${cost}」+ `发送` → 立即派发一期（新增 op 或现有 jobs 触发）→ 概览「今天的推送」出现该期并按 §4.3 更新；按钮期间显示进度。成功后行内「已发送 · 查看」。

### 5.7 拆分

高级 › 拆成两份：确认「把「日本」拆成「日本」和「日本 · 娱乐」两份？各自有时间和机器人；现有来源按范围分配。」→ 生成第二行并展开它。合并：第二行高级 › 并回「日本」。

---

## 6. 接入（R10 #88）

### 6.1 机器人

每个机器人一组（`GroupBox`）：

- 头行：30pt 字母图标、`@username · 名称`（名称可内联改）、11pt「接收 N 份简报：…」、状态、`发测试消息`、`⋯`。
- 状态映射（`bots.status`）：unverified 灰「未验证」/ verifying 进度 / verified 蓝「等待配对」/ paired 绿「已配对 · HH:MM」/ paused 灰「已暂停」/ unpaired 黄「已解除配对」/ 错误红 + §2.4。
- 等待配对时组内插入黄底块：说明 + 大号 `/pair 482 913` + `复制` + `重新生成` + 倒计时；每 2 秒轮询，paired 后块消失。
- 「允许接收成人内容」`Toggle`；关闭时若有成人简报正发到它 → 确认并列出。
- `发测试消息` → `bots.test_send` → 行内「已发到你的 Telegram · 08:12」或 outcome_unknown 文案 + `检查结果`（`bots.test_status`）。
- `⋯` 菜单：暂停 / 恢复、解除配对（确认）、删除（确认，`targets.bot_impact` 列出受影响简报）。
- 工具栏 `＋ 添加机器人` → 顶部插入一组内联表单：Token 字段 + 粘贴 → 自动验证 → 配对块（同 §3 步骤 1）。

### 6.2 模型

两组并排：「普通内容 · 世界 · 日本 …」与「成人内容 · AV 产业 · X 成人博主」。各含主行与备行（备行灰字「备用：」前缀，默认显示，不再折叠成 sheet）。

每行：模型名 · 供应商、11pt「Key ••••7Qx2 · 文字 ✓ 视觉 ✓ · 验证于今天 08:12」、状态、`更换 Key` / `填入 Key`（Popover：SecureField + 粘贴 + 保存；保存即探测）。

| `models.status.text.state` + `credentials.status` | 状态 | 说明 |
|---|---|---|
| verified | 绿「可用」 | 验证时间 |
| missing credential | 灰「未填 Key」 | 备用：「可选。主模型出错时接手，没填就跳过那一期。」 |
| failed 401/403 | 红「Key 无效」 | §2.4 文案 + 默认按钮 `重新填入` |
| failed 429 / timeout | 黄「暂时不可用」 | 「再测一次」 |
| outcome_unknown | 黄「结果未知」 | 「检查并重试」 |
| cooldown（`models.health`） | 黄「暂停使用到 HH:MM」 | 「连续失败 N 次，HH:MM 后自动恢复」 |

组下方说明一行：「普通内容和成人内容分开用不同的模型；一边出错不会拿另一边兜底。」
折叠「附加能力：AI 报纸生图 · 语音转写 · 自定义 API 地址」：展开后每项一行：开关 + 使用哪个模型（Picker）+ 状态；开启时才探测对应能力。TTS 不出现。（0.6.3 起由 `docs/designs/specs/R18-elevenlabs-speech.md` 覆盖：附加能力新增一行「语音简报（ElevenLabs）」。）

### 6.3 费用（`budget.get` / `budget.save`）

- 「每月最多花」`TextField` 美元整数，可空（占位「不限」）；说明「到上限后停发并在概览里提醒；留空表示不限。」
- 进度行「本月已用 $3.42 · 文字 $3.10 · 报纸 $0.32 · 11 月 1 日起」。
- 「X 每天最多读取」`TextField` 条数 + 「今天已读 84 条」。
- 「其他上限」行：仅当生图月额、供应商额、X 分区 / 账号额任一非空时出现，逐项列出（如「生图每月最多 $5」）并各带 `清除`；对应 reason（`image_limit`、`provider_limit`、`partition_limit`、`account_limit`）按 §2.4 显示。
- 说明行「用量按模型返回的 token 数计价；没有价格信息的模型会标为「未计价」，不会因此停发。」
- 不出现：hold、价格表、cycle_day；次级上限只在「其他上限」行出现（见上）。

### 6.4 X 数据连接

一行：「X API Key」+ 11pt「••••Rk2m · 读取账号正常 · 验证于昨天 20:28」+ 状态 + `更换 Key`（Popover）。

---

## 7. X 账号（R11 #89）

### 7.1 工具栏

`Picker(.segmented)`「普通账号 · 5」「成人博主 · 0」。成人页在缺成人模型 Key 时顶部黄色说明行 + `去接入`，列表仍可浏览但添加禁用。

### 7.2 添加行

`TextField` 占位「@用户名，或粘贴 X List 链接」+ `添加`（默认）；说明「会读一次账号资料（1 次读取），确认账号存在、是否受保护。」
结果内联在添加行下：可读 → 直接加入列表并高亮；受保护 → 「这个账号设了保护，读不到它的帖子」+ `仍然添加` / `放弃`；不存在 → 红字；List → 「12 个成员，默认整体并入汇总；新成员会先问你分区」+ `添加`。

### 7.3 账号行（44pt）

头像字母圆、`@handle · 名称`、11pt「原帖 + 引用 · 昨天读到 23:10 · 今天 N 条新帖」、状态、`Picker(.segmented)`「单独发 · 21:30 / 并入汇总」、`⋯`。

- 选「单独发」→ Popover：时间 `DatePicker` + 发送到（Bot 复选，默认继承汇总的 Bot）+ 样式；保存后分段文案带时间。
- 选「并入汇总」→ 立即保存。
- `⋯`：帖子类型（原帖 / 引用 / 回复 / 转帖 复选）、改分区（`partition_impact` 后确认）、移除（确认）。
- 状态（`x.accounts.list.state`）：ready 绿「可读」/ protected 黄「读不到」/ unavailable·invalidated 红「账号不存在或已停用」/ credential_changed 黄「需要重新验证」/ permission_denied 红「X Key 没有读取权限」。

List 行：方形图标、名称 · N 个成员、「成员全部并入汇总 · 新加入的成员会先问你是不是普通内容」、待确认数 + `查看`（Popover 列出新成员，每个选普通 / 成人 / 忽略）。

### 7.4 汇总卡与读取上限

- 「普通账号汇总」：「每天 20:30 → @bot」「3 个并入汇总的账号 + 1 个 List · 文字 + 链接」+ `在简报里改`（跳简报页并展开 X 汇总行）。
- 「每天最多读取」：`TextField` + 「条 / 天 · 今天已读 84」+ 进度条；说明「普通和成人账号合计。想分开限额可以在「高级」里设。」

### 7.5 高级（折叠）

大事件即时提醒（开关 + 规则列表，现有 x.alerts）、视频内容检查（开关 + 预算，现有 x.video）、分区各自限额（两个数字）。默认全部关闭；说明「默认都关闭，不会增加读取量或费用。」

---

## 8. 设置与菜单栏（R12 #90）

### 8.1 语言

两行 `Picker(.menu)`：界面语言（UserDefaults + `config.save ui_locale`）、新闻输出语言（`config.save news_output_locale`，说明「改了之后，还没发出的那几期会按新语言重新生成」）。

### 8.2 后台

| 行 | 控件 | 行为 |
|---|---|---|
| 状态 | 绿「运行中」+ 11pt「今天 07:02 启动 · 版本 0.5.0 (6)」+ `重启` `停止`（红字） | 停止需确认「停止后菜单栏将不再推送，直到你再次打开 NewsPaw。」 |
| 登录这台 Mac 时自动启动 | `Toggle`（SMAppService） | 注册失败（如 Launch Constraint）→ 行内说明 + `打开登录项设置` |
| 暂停全部推送 | `Toggle` | 说明「暂停期间不采集、不花钱、不发送；恢复后只补最近一期。菜单栏里也有这个开关。」 |
| 说明 | 「关闭这个窗口不会停止后台，后台会一直在菜单栏里。」 | — |

### 8.3 菜单栏 `MenuBarExtra`

```
● 后台运行中 · 下一期 18:00 科技数码      （状态行，不可点）
────────
打开 NewsPaw                               ⌘O
暂停全部推送 / 恢复推送                     （切换项，带 ✓）
────────
退出 NewsPaw 界面                           ⌘Q   （后台继续）
```
暂停时图标变灰并显示「已暂停」。不再在菜单栏放「停止后台」（移到设置页并需确认）。

### 8.4 数据

存放位置 + `在访达中显示`；设置备份 `导出设置…`（NSSavePanel，无凭据）`导入…`（NSOpenPanel → `preview_import` 差异列表 Popover → `apply_import`，不开启任何简报）；「保留抓取记录和日志」`Picker` 7 / 30 / 90 天。

### 8.5 高级 / 排障（折叠）

诊断信息（`ops.diagnostics` → 复制 / 保存）、支持快照、备份校验、清理旧数据（`cleanup` 预览后确认）、任务与投递记录（只读表：`jobs.list` / `delivery.status`）。说明「给开发者看的工具。正常使用不需要打开。」

---

## 9. 每页数据依赖

| 页 | 现有 op | 新增 / 变更（issue） |
|---|---|---|
| 启动 / 概览 | service.status, config.get, bots.list, schedule.status, delivery.status, budget.get, sources.list, credentials.status | `setup.readiness`（R02）、`delivery.resolve` 文案所需 reason（R02）、unpriced 计数（R03） |
| 首次设置 | credentials.set, bots.verify, bots.pair_code, bots.status, models.status, config.save | 保存即探测（R04）、单 Bot 自动目标（R04）、verify 轮询（R05） |
| 简报 | config.get/save, subscriptions.preview/save, sources.list/discover/preview/save/assign/delete/import_opml/impact, targets.*, route.preview | 简报字段收敛（v4，R03）、discover/preview 轮询（R05）、立即试发一期 op（R03） |
| 接入 | bots.*, credentials.*, models.status/probe, budget.get/save, targets.bot_impact, newspaper.policy, media.policy | models.health（R04）、按需能力（R04）、月度 USD 上限（R03） |
| X 账号 | x.accounts.*, x.lists.*, x.posts.coverage, x.alerts.*, x.video.*, budget.get | accounts.add 轮询（R05）、单独发/并入汇总映射到 priority + times（R11） |
| 设置 | config.save locale, service.status/stop, ops.export_settings/preview_import/apply_import/cleanup/diagnostics, SMAppService | 暂停全部推送 = scheduler 单开关（R03）、策略并入导出（R05） |

---

## 10. 验收清单（跨 issue，端到端）

1. 全新数据目录 → 首次设置窗口 → 不离开窗口完成配对、Key、两份简报 → `完成并试发一期` → 手机收到一期 → 概览无清单、今天的推送出现三行（试发的一期显示「已发送」，两份简报的定时期次显示「等待中」）。另走一遍 `完成，等定时推送`：概览只剩第 4 步「发一期试试」，第一份定时简报到达后清单消失。
2. 把系统时间推到 08:00 → 概览行变「已发送」，Telegram（假服务器）收到一条。
3. 拔网线后触发一期 → 概览出现「结果未知」+ `检查并补发` → 恢复网络点击 → 变为「已发送」且 Telegram 只收到一条。
4. 在 Telegram 里用命令改时间 → App 3 秒内刷新；同时在 App 改同一字段 → 出现「用我的 / 用它的」，不出现任何 revision 字样。
5. 填一个 401 的 Key → 接入页红色「Key 无效」+ 供应商名 + `重新填入`；概览「需要注意」出现同一条。
6. 关闭唯一 Bot 的「允许成人」→ 成人简报自动变为「无目标」并在简报页给出 `去接入补齐`。
7. 全程不出现：sheet、微美元、hold、IANA 手填、「语言未保存到后台」。
8. 三语 + 浅/深色截图各 6 页归档到 `docs/mockup/redesign/actual/`。
