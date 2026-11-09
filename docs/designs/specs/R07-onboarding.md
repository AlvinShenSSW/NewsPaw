# R07 — 首次设置窗口（#85）

冻结契约：issue #85 验收项 + `docs/planning/ux-redesign/interaction-spec.md` §3。依赖 R04（保存 Key 即自动探测）、R06（外壳、`BackendClient`、`EditorState`、`FailureNote`）、R09（开启简报的流程：带入推荐来源、试采集、自动选唯一机器人）。叠在 R09 上。

## 实现

- `Onboarding.swift`：独立窗口 `Window(id: "onboarding")` 760×580，顶部步骤条（✓ / 当前 / 待），底部「先跳过」「上一步」「继续（默认，Return）」。
- 首次启动：后台已连上、`setup.readiness` 未完成且从未关闭过此窗口（UserDefaults `onboardingSeen`）时自动打开；应用菜单「首次设置…」可再次打开。完成或跳过最后一步写 `onboardingSeen`；之后未完成项由概览清单（R08）接管。
- 步骤 1：粘贴 Token（长粘贴自动提交，或 Return / 验证）→ 没有机器人时用 `config.save` 新建一个（无 Token）→ `credentials.set(kind: bots)` → `bots.verify` → `bots.pair_code`。配对块显示 `/pair <code>`、复制、倒计时；每 2 秒读 `bots.status` 直到配对，变为绿色「已配对 · 时间」并启用「继续」；过期后提示并可重新生成。失败在本步内显示错误码文案和重试。
- 步骤 2：模型下拉（GPT-6 Luna 推荐 / MiMo Flash / 自定义 URL + 模型 ID）改 `normal_primary` 的 provider/base_url/model，`credentials.set(kind: model_profiles)` 保存 Key；后台自动测试（R04），窗口读 `models.status` 直到有结果，显示通过（含模型名）或失败原因和「再测一次」（`models.probe`，直接用其返回结果）。折叠：成人 DeepSeek Key（`adult_primary`）、高级：备用 MiMo Key（`normal_backup`）。费用说明含默认 $20 月上限。
- 步骤 3：列出所有简报，默认勾选世界、日本；成人简报缺前置时禁用并说明。「完成并试发一期」逐个用 R09 的 `DigestsData.turnOn` 开启所选简报，再对第一份已开启的普通简报 `subscriptions.send_now` 并打开概览；「完成，等定时推送」只开启。任一简报开不了时窗口不关闭，该行显示原因。没有可用机器人时两个完成按钮禁用。

## 依据仓库证据修正契约

- 配对码是后端生成的 32 字符 URL 安全串（`registry.pair_code`），不是 6 位数字；窗口显示完整 `/pair <code>` 并提供复制。
- 探测结果没有耗时和费用字段（`providers.py` 记录只有 status / reported_model / usage），结果行显示模型名，不显示秒数和金额。
- `models.status` 在新 Key 的探测完成前返回旧 Key 的结果并标为 `stale`；窗口把 `stale` 视为仍在等待，避免把旧结果当成新 Key 的结果。
- 「高级」只放备用模型 Key；自定义 API 地址放在模型下拉的「自定义…」里（issue 非目标：不暴露其他高级项）。

## 验证

`swift test`：`OnboardingTests` 用内存后台覆盖粘贴 Token → 验证 → 配对码 → 轮询到配对、Token 被拒的行内原因、配对码过期后停止等待并可重新生成、保存主 Key 改模型并读到测试通过、测试失败原因与再测一次、测试无结果时报告而不是无限等待、完成时开启两份简报并试发第一份、开不了的简报保留原因、自动打开只在未完成且未关闭过时发生、三语文案。离屏截图：三步 × 三语 × 浅/深色。

真实 Telegram / 模型供应商联调未做（需要真实凭据，按约定单独启用）。
