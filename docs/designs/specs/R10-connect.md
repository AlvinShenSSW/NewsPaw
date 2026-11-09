# R10 — 接入页（#88）

冻结契约：issue #88 验收项 + `docs/planning/ux-redesign/interaction-spec.md` §6（界面行为以 §0–§2 为准），数据默认值与词表见 `contract.md`。依赖 R04（保存 Key 即自动测试、`models.health`）、R06（`BackendClient`、`EditorState`、`Words`、`FailureNote`）。叠在 R07（首次设置）与 R09（简报页）上。

## 实现

- `Connect.swift`：`ConnectData`（`@MainActor @Observable`）保存本页读到的状态并执行所有动作。配置类改动走 `EditorState`（`config.save`、`budget.save`、`newspaper.configure`、`media.configure` 都按「对最新记录套用改动、冲突重读重放一次」）；带 revision 的 targets 操作读最新 revision、冲突重试一次；Bot 操作先读 `bots.status` 取当前 generation。
- `ConnectPage.swift`：四个分区，全部就地编辑，没有 sheet；破坏性操作用 `confirmationDialog`；每个状态点都带文字；图标按钮有 `accessibilityLabel`。页面在 config revision 变化时和每 5 秒重读一次（测试结果、冷却、费用不改 revision）。
- `Pairing.swift`：首次设置窗口与本页共用的流程，替代 R07 中 `OnboardingData` 内的私有实现：`BotPairing`（Token → `credentials.set` → `bots.verify` → `bots.pair_code` → 每 2 秒读 `bots.status` 直到配对）、`KeyChecks`（`credentials.set` 后读 `models.status` 直到文字测试有结果，`pending/untested/stale` 都算等待；`models.probe` 再测一次）、`BotConnectForm`（Token 字段到配对结果的整块表单）、`PairBlock`、`Stamp`（24 小时制与「今天 / 昨天 / MM-dd」）。`OnboardingData` 只保留步骤与简报逻辑，其余转发给这两个类型，R07 的测试原样通过。
- §6.1 机器人：每个 Bot 一个 `GroupBox`。头行：字母图标、`@username · 名称`（铅笔按钮就地改名，`config.save` 只改 `name`，配对保留）、「接收 N 份简报：…」（已开启且发到它的简报）、状态（未验证 / 正在验证 / 等待配对 / 已配对 · HH:MM / 已暂停 / 已解除配对 / 需要处理）、`发测试消息`、`⋯`。等待配对时组内黄底块：生成或重新生成配对码 → `/pair <code>`、复制、倒计时、每 2 秒轮询，配对后块消失；过期后原地提示「配对码过期了」+ 重新生成。`⋯`：暂停 / 恢复、更换 Token…、解除配对…（确认）、删除机器人…（先 `targets.bot_impact`，确认框列出会不再发到它的简报、其中会变成无目标的简报和单独发的 X 账号，确认后 `targets.delete_bot`）。「允许接收成人内容」开关走 `targets.adult_permission`；关闭时若有成人简报正发到它，确认框列出这些简报。工具栏「添加机器人」在分区顶部插入内联表单（`BotConnectForm`），配对后表单收起、该 Bot 出现在列表里并显示配对时间；取消时，如果为一个被 Telegram 拒绝的 Token 建了 Bot 条目，就删掉它（`targets.delete_bot`），不留残余。
- 测试消息：`bots.test_send`（当前 generation + 新 request_id）→ 行内「已发到你的 Telegram · HH:MM」；`failed` 显示 reason 的错误文案；`outcome_unknown`（或 socket 超时，此时保留 request_id）显示「Telegram 没有回应…」+ `检查结果`（同一 request_id 调 `bots.test_status`）。
- §6.2 模型：普通 / 成人两组并排，主模型在前、备用灰字「备用：」。每行：模型名 · 供应商、11pt 说明行（`Key ••••7Qx2 · 文字 ✓ 视觉 ✓ · 验证于今天 08:12`，或出错原因）、状态、动作按钮和 `更换 Key / 填入 Key / 重新填入` Popover（SecureField + 粘贴 + 保存）。状态由 `KeyStatus.of` 从 `credentials.status`、`models.status.text`、`models.health` 算出：可用 / 未填 Key（备用说明「可选。主模型出错时接手，没填就跳过那一期。」）/ 正在测试 / 还没测试（再测一次）/ Key 无效（401、403 或格式不对，红，默认按钮「重新填入」）/ 暂时不可用（429 频繁、429 额度用完、连不上、供应商出错，黄，「再测一次」）/ 结果未知（黄，「检查并重试」先确认可能重复扣费再 `models.probe`）/ 暂停使用到 HH:MM（冷却）/ 本月预算不够 / 暂不能测试 / 读不到 Key（钥匙串错误）。组下方一行分区说明。
- 附加能力（`DisclosureGroup`，展开状态存 UserDefaults）：AI 报纸生图（`newspaper.policy` / `newspaper.configure`：开 = `enabled` + 所选模型作为生成与校验模型；关 = `enabled:false`）、语音转写（`media.policy` / `media.configure`：开 = `stt_profile`，关 = `stt_profile` 与 `stt_hold` 都清空）、自定义 API 地址（四个模型任选一个改 `base_url` / `model`，已有 Key 时随即 `models.probe` 再测）。每项：开关 + 模型 Picker + 状态（已关闭 / 等待检查 / 可用 / 未通过）。没有 TTS，也不暴露 `listen_enabled`。
- §6.3 费用：「每月最多花」整数美元输入（空 = 不限），回车或离开字段即保存，存为微美元；「本月已用 $3.42 · 文字 $3.10 · 报纸 $0.32」+「11 月 1 日起」+ 进度条；「X 每天最多读取」+「今天已读 N 条」；生图月额、供应商月额、X 分区 / 账号日额任一非空时出现「其他上限」，逐项列出用量（达到时显示「已到上限」）并各带 `清除`；说明行含未计价次数。金额一律 `dollars()` 两位小数；不出现微美元、预留、价格表、cycle_day。
- §6.4 X：一行「X API Key」，`••••Rk2m · 读取账号正常 · 验证于 …` + 状态 + `更换 Key` Popover（`credentials.set kind:x_api id:x`）。
- 后端：`credentials.status` 额外返回 `tails: {ref: 末 4 位}`，只对能读到、长度不少于 8 的值返回，绝不超过 4 个字符；读失败的引用没有 tail。
- 删除旧视图 `BotWorkspace`、`ModelWorkspace`、`RuntimePolicyWorkspace`、`CapabilityRouting`（含 sheet、微美元 hold 输入、分类模型覆盖）。X / 设置页仍在用的 `ConnectionCopy`（只留它们用到的词）、`SettingsRevision`、`ProtectedSettings`、`boundedUnits` 移到 `SettingsSupport.swift`，随 R11 / R12 删除。只服务旧模型编辑器的 `ModelProbeRequest`、`AppModel.pendingModelProbes` 及其两个测试一并删除。
- `Operation` 新增本页用到的全部操作；`FailureCopy` 新增本页可能遇到的错误码（发送通道忙、未配对、钥匙串拒绝 / 不可用、预算与媒体设置被拒、额度用完、整数金额等）。

## 依据仓库证据修正契约

- **超时没有单独的错误码。** `providers.py` 对 90 秒超时（`TimeoutError` / `httpx.RequestError`）抛 `ProviderError("outcome_unknown", outcome="unknown")`，探测记为 `status: outcome_unknown`。所以 spec 的 `provider_timeout`（30 秒）在本页表现为「结果未知」：说明「{供应商} 没有及时回应（等了 90 秒）。这次调用可能已经扣费，确认后再试一次。」+「检查并重试」（先确认）。连不上（`connection_failed`，请求未发出）归「暂时不可用」+「再测一次」。401 / 403 来自 `authentication_failed` / `permission_denied`，429 来自 `rate_limited`，额度用完的 429 是 `quota_exhausted`。
- **测试消息的「结果未知」不会再变。** `check_send.py` 把 `outcome_unknown` 作为终态写入；`bots.test_status` 只是读回同一记录。因此「检查结果」后若仍未知，行内改为「还是不能确定。看看 Telegram 里有没有收到；没有就再发一次。」+「再发一次」（新的 request_id）。
- **没有配对时间。** `bots.status` 不返回配对发生的时间；「已配对 · HH:MM」只在本页亲眼看到配对完成时显示，否则只显示「已配对」。
- **配对码不能重新显示。** 后端只存哈希（`registry.pair_code`），码只在 `bots.pair_code` 的回复里出现一次；离开页面后回来，等待配对的 Bot 显示「生成配对码」而不是旧码。码是 32 字符 URL 安全串，不是 6 位数字（同 R07）。
- **冷却按代次对齐。** `models.health` 的行带 `generation`，`models.status` 不带。本页取每个模型最新代次的一行，并且只在该行检查时间晚于当前 Key 最近一次通过的测试、`cooldown_until` 仍在未来时显示「暂停使用到 HH:MM」，避免换 Key 后仍显示旧 Key 的冷却。
- **生图与转写只支持 OpenAI 官方地址。** `supported_image_profile` / `supported_stt_profile` 要求 `provider == openai` 且 `base_url == https://api.openai.com/v1`；Picker 只列这些普通内容模型，没有时开关禁用并提示到「自定义 API 地址」修改。开启报纸必须同时有生成和校验模型（`newspaper.configure` 校验），本页把所选模型同时用于两者（已有校验模型不覆盖）。
- **X Key 没有单独的验证操作。** 「读取账号正常 · 验证于 …」取自 `x.accounts.list` 中用当前 Key 做过的最新账号检查（`state` 为 `ready / protected`；`authentication_failed` / `permission_denied` 显示 Key 无效 401 / 403）；没有账号检查时显示「已填 Key」。
- **Key 尾号是新增后端字段。** 之前没有任何操作能给出「••••7Qx2」；`credentials.status` 本来就逐个读取值，现在顺带返回末 4 位（见上）。
- **「无目标」。** 删除 Bot 的确认里用 `targets.bot_impact.last_target_subscriptions` 列出会变成无目标的简报；删除后这些简报的 `bot_ids` 为空，简报页按 R09 显示「还没选机器人」。
- **自定义 API 地址**放在附加能力里（spec §6.2 的折叠标题），因为删除旧 `ModelWorkspace` 后它是改模型地址 / 模型 ID 的唯一入口；不提供改供应商、hold 或能力列表。

## 验证

- `uv run pytest -q`：912 passed, 1 skipped；`uv run ruff check .` 通过。新增 `test_status_names_each_available_key_by_its_last_four_characters`。
- `swift test --package-path macos/NewsPaw` 与 `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test …`：120 个测试通过。`ConnectTests` 的内存后台按真实语义实现（`credentials.set` 换引用并重置 Bot 验证 / 配对与模型能力，被拒的 Token 由 `bots.verify` 的状态报告，Bot 操作校验 generation，配置 / 预算 / 媒体操作校验 revision），覆盖：内联添加并配对 Bot、被拒 Token 的原因与取消后不留条目、配对码过期后原地重新生成、已存 Bot 从组内生成配对码、删除前列出影响再删除、关闭成人内容列出并移除成人简报、测试消息送达 / 未知 → 检查结果 / 失败原因、暂停 / 恢复 / 解除配对带当前 generation、改名保留配对、Bot 状态映射、保存 Key 后读到结果（`stale` 与 `pending` 视为等待）、401 / 403 / 429 / 超时文案与动作各不相同、冷却显示与过期、钥匙串与等待状态、附加能力开关写入策略、改地址后再测、整数美元 ↔ 微美元与空 = 不限、非整数被拒且不发请求、本期费用拆分与其他上限、清除单项上限不动其余、X Key 保存与尾号、尾号映射与短 Key 无尾号、三语文案且不含内部词、`Operation` 全部存在于后端 `OPERATIONS`、相对时间。
- 离屏截图（隔离后台，无真实 Key、无 Bot）：`connect-*` 与新增的 `connect-open-*`（添加表单 + 附加能力展开）× 三语 × 浅 / 深色。

未做：真实 Telegram / 模型供应商 / X 联调（需要真实凭据，按约定单独启用）；隔离后台没有 Bot 和 Key，Bot 分组、配对块、可用 / 失败的模型行只由单元测试覆盖，未截图核对。
