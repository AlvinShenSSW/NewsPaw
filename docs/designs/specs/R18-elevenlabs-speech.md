# R18 — 0.6.3：用 ElevenLabs 朗读简报（按需）

来源：所有者 2026-11-10 的指令。没有 GitHub issue。所有者的原话与选择：

- 「elevenlabs 主要是文字转语音」
- 触发：「只有我特别要求语音简报的时候，这个功能上也要加上」→ 只按需，不随简报自动发送；界面要能开启这项能力。
- 失败时：「只发文字」。
- 声音：「界面里填 Voice ID」（预填一个官方预设声音）。

这一条覆盖 `interaction-spec.md` §6.2「TTS 不出现」与 R10「不暴露 `listen_enabled`」。

## 现状（已读代码）

- 语音只有一条路径：在 Telegram 里**回复一份已送达的普通简报**发送 `/listen`（`telegram/commands.py`）。`MediaCommands.plan(listen=True)` 要求媒体策略 `listen_enabled`；`_prepare_media` 取该简报冻结的条目（最多 8 条的「标题. 正文」），调用 `self.media.speech.synthesize(text, locale)` 得到 MP3（≤ `MAX_SPEECH` = 1 MiB），先发带链接的文字再发 `sendAudio`；合成失败时只发文字并加一句 `voice_unavailable`。
- `speech` 现在是 `LocalSpeech`（macOS `say` + ffmpeg），文本清洗后截到 1200 字符。`listen_enabled` 在 0.6 界面没有入口，默认关闭。
- Key 只能挂在配置文档里的引用上：`model_profiles[*].credential_ref`、`bots[*].credential_ref`、`x_api.credential_ref`（`credentials.py`；不在文档里的钥匙串条目会被当作孤儿清理）。配置文档 `schema_version` 现为 4，顶层字段集合固定（`app_config._TOP_FIELDS`）。
- 预算账本的 `operation` 取值为 `text / search / vision / image / stt`（`budget.py`）。

## ElevenLabs 接口（来自官方文档，2026-11-10 读取）

- `POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}`，请求头 `xi-api-key`，JSON 体 `text`（必填）、`model_id`（默认 `eleven_multilingual_v2`），查询参数 `output_format`（默认 `mp3_44100_128`，可选 `mp3_44100_64` 等）；200 返回音频文件；422 为参数校验错误。<https://elevenlabs.io/docs/api-reference/text-to-speech/convert>
- `eleven_multilingual_v2`：29 种语言，含中文、日语、英语，单次 10,000 字符。<https://elevenlabs.io/docs/models>
- 文档示例里的 `voice_id`：`JBFqnCBsd6RMkjVDRZzb`。

## 冻结的验收标准

S1 配置与 Key
- 配置文档新增顶层 `speech_api: {"credential_ref": null, "voice_id": "JBFqnCBsd6RMkjVDRZzb"}`，`schema_version` 升到 5；从 4 升级时补上这一块（默认值如上）。`voice_id` 校验为 1–64 位 ASCII 字母数字。数据库版本随之递增，沿用现有迁移前自动备份；设置导出 / 导入像 `x_api` 一样不带出 Key 引用。
- `credentials.set / remove` 接受 `kind: "speech_api"`、`id: "elevenlabs"`，行为与 `x_api` / `x` 相同（Key 进钥匙串，文档里只有引用）。`voice_id` 通过 `config.save` 修改。

S2 合成
- 新增 ElevenLabs 语音提供方：请求上面的接口，`model_id` 固定 `eleven_multilingual_v2`，`output_format=mp3_44100_64`；通过现有的受限 HTTP 客户端（固定源 `https://api.elevenlabs.io`，不跟随重定向，响应上限 `MAX_SPEECH`）；结果必须是非空且不超过 `MAX_SPEECH` 的 MP3，否则算失败。发送的文本沿用 `LocalSpeech` 的清洗与 1200 字符上限。
- `/listen`：`speech_api.credential_ref` 已设置时用 ElevenLabs（声音取当前 `voice_id`）；未设置时保持现有 `LocalSpeech` 行为不变。使用 ElevenLabs 时任何失败（Key 被拒、额度、限流、超时、返回不是合格 MP3、预算不足）都**只发文字**并附一句「语音暂时不可用」的说明（三种语言），不回退到 macOS 朗读。
- 仍然只对普通简报、只在所有者回复该简报发 `/listen` 时触发；不新增自动语音，不改授权与范围检查。成人分区的内容不会发给 ElevenLabs。

S3 预算与记录
- 每次 ElevenLabs 合成（含测试）先在预算账本占用再调用：`operation="tts"`，provider `elevenlabs`，分区 `normal`，占用额 `DEFAULT_HOLD`（50,000 微美元，未计价）；结果未知的调用按现有规则保留为未知。预算拒绝时不发请求，按 S2 只发文字。「接入」页的费用拆分里新增「语音」一项。

S4 测试 Key 与声音
- 新增 `speech.check`（必填 `request_id`）：用当前 Key 与 `voice_id` 合成一句固定短句（「NewsPaw audio test.」）并校验结果。同一个 `request_id` 只合成一次，重复请求返回同一条记录；记录绑定当时的 Key 代次与 `voice_id`，换 Key 或换声音后旧记录不再代表当前配置。结果区分：通过、Key 被拒（401/403）、声音或请求无效（404/422）、额度或限流（429 等）、连接失败（确定未发出）、结果未知。属于可能等待网络的长操作，按现有长操作约定返回。
- 新增只读 `speech.status`：当前是否有 Key、`voice_id`、最近一次检查的结果及其是否仍对应当前配置。

S5 界面（「接入 › 附加能力」）
- 新增一行「语音简报（ElevenLabs）」：开关（写媒体策略的 `listen_enabled`；没有 Key 时不可开启并说明原因）、Key（填入 / 更换，显示尾号）、Voice ID 输入框（回车或离开即保存，格式不对不保存并提示）、状态与「测试」按钮（`speech.check`；结果未知或仍在测试时再测先确认，与模型行同一规则）。保存 Key 或改 Voice ID 后不自动付费测试，状态显示为「未测试」。
- 一行说明：在 Telegram 里回复一份简报发送 `/listen` 即可收到语音；简报文字会发送给 ElevenLabs。
- 附加能力标题与所有新文案提供简体中文 / English / 日本語，不出现内部词（probe、hold、profile 等）。失败原因用现有 `FailureCopy` 机制，新增的错误码都有三语文案。

S6 发版
- 版本 0.6.2 → 0.6.3，build 9（同 R16 D1 的五个文件）；合并后从 main 打包，DMG 放到 `~/Desktop`；ad-hoc 签名，不声称公证。

## 不变量

- 普通 / 成人分区不跨组；`/listen` 的授权、范围与过期检查不变。
- 不新增自动付费调用：只有 `/listen` 和所有者点「测试」会调用 ElevenLabs。
- Key 只在钥匙串；日志、诊断导出、错误信息里不出现 Key 或简报全文。
- 模型无权执行 shell、修改订阅或目标；离线测试不产生外部调用（ElevenLabs 一律用假传输）。
- 单人本机系统，不引入通用的「语音提供方注册表」。

## 非目标

- 不做随简报自动发送的语音、不做自然语言触发（「给我语音版」）、不做成人简报朗读。
- 不提供模型、语速、音色参数的界面；不按语言分别选声音；不列出账号里的声音。
- 不改 `LocalSpeech`，不在 ElevenLabs 失败时回退到它。
- 不改语音转文字（仍只支持 OpenAI）。

## 假设（未验证）

- 示例声音 `JBFqnCBsd6RMkjVDRZzb` 对所有者的账号可用；不可用时测试会报「声音或请求无效」，换成账号里的 Voice ID 即可。
- 错误状态码的含义（401 Key 无效、429 限流等）按通用约定映射，文档只明确列了 422；未用真实 Key 调用过。
- 每次合成的实际费用由 ElevenLabs 订阅额度决定，账本只记占用与次数，不换算美元。

## 做法

- 配置块、凭据种类、升级函数照 `x_api` 的写法；提供方模块放在 `src/newspaw/media/`，与 `image_provider.py` / `speech_provider.py` 并列，错误用 `ProviderError`。
- `MediaCommands` 的 `speech` 按当前配置选择 ElevenLabs 或 `LocalSpeech`；`_prepare_media` 的失败路径不变（已是只发文字）。
- 检查记录用一张小表（请求 id、Key 代次、voice_id、开始 / 结束时间、结果），模式同 `model_probes` 的 begin / finish，不复用模型配置表。
- Swift 侧照 X Key 行与现有附加能力行的写法；`Operation` 增加两个操作，契约测试保证后端存在。

## 测试计划

- Python：配置 4→5 升级与校验（含非法 `voice_id`）；`credentials.set/remove` 的 `speech_api`；提供方的请求形状（URL、头、体、`output_format`）、各状态码映射、超大 / 非 MP3 响应、连接失败与结果未知；`/listen` 在有 Key 时走 ElevenLabs、失败只发文字且不调用 `say`、无 Key 时仍走本机；预算占用 / 拒绝 / 未知；`speech.check` 同一 id 只调用一次、换 Key / 换声音后记录失效；导出不含 Key 引用。
- Swift：附加能力行的开关前置条件、Key 保存与尾号、Voice ID 校验与保存、测试结果各状态与确认规则、三语文案齐全且无内部词、`Operation` 契约。
- 全量：`uv run pytest -q`、`uv run ruff check .`、`swift test`（`macos/NewsPaw`，含 `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`）。
