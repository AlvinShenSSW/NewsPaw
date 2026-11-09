# R12 — 设置页与菜单栏（#90）

冻结契约：issue #90 的四条验收 + `docs/planning/ux-redesign/interaction-spec.md` §8（状态词与反馈规范按 §0.2、§2，数据依赖按 §9 的「设置」行），视觉基线 `docs/mockup/redesign/settings.png`。依赖 R06（`BackendClient`、`EditorState`、`Words`、`FailureNote`、菜单栏骨架）；叠在 R10（`afk/r10-connect`）上。R05（导出含运行策略）未合入，导入 / 导出按当前 `ops.preview_import` / `ops.apply_import` 的形状实现。

## 冻结的 issue 契约

| # | 验收 / 规格行 | 本 issue 交付 |
|---|---|---|
| A1 | 自启开关与 SMAppService 实际状态一致，失败时给系统设置入口（§8.2 第 2 行） | 开关只在 `SMAppService.Status == .enabled` 时为开；每 2 秒与每次操作后重读实际状态。`requiresApproval` 显示「需要在系统设置里允许」+ `打开登录项设置`；`notFound` 显示找不到登记 + 同一按钮；注册 / 注销失败（旧版后台仍在、升级检查不过、`register()` 抛错如 Launch Constraint）行内说明 + `打开登录项设置`。开发版（未打包）开关禁用并说明原因。 |
| A2 | 暂停全部推送在设置页、菜单栏、侧栏状态三处一致（§8.2 第 3 行、§8.3） | 唯一来源 `AppModel.schedulingPaused`（`setup.readiness.scheduling_enabled`）；三处都读它，切换走同一个 `AppModel.setPaused`（`schedule.configure` 经 `EditorState` 合并），保存后立即重读快照；Telegram 等处的改动由 3 秒轮询带回。 |
| A3 | 导入前显示将改动的项目列表；导入不自动开启任何简报（§8.4） | 选择文件 → `ops.preview_import` → Popover 列出将改动的项目（语言、时区、哪些简报、来源 / 机器人 / X 账号 / 模型的增删改、因含凭据或私有地址被略去的项数）并写明「导入后所有简报保持关闭」→ `导入` 才调用 `ops.apply_import`（带预览给出的 digest 与 revision）。App 在导入前后不发送任何开启简报或调度的操作；后台本身把导入的简报与来源全部置为关闭（`_scrub_settings`）。 |
| A4 | 停止后台需确认并说明「菜单栏将不再推送」（§8.2 第 1 行、§2.5） | `停止`（红字）→ `confirmationDialog`「停止后台？」+「停止后菜单栏将不再推送，直到你再次打开 NewsPaw。」；菜单栏不再有停止项。 |

逐行对照 §8：

- **§8.1 语言**：两行 `Picker(.menu)`。界面语言写 UserDefaults，并在连上后台时 `config.save ui_locale`；新闻输出语言 `config.save news_output_locale`（未连上时禁用并说明），说明「所有简报的标题和摘要。改了之后，还没发出的那几期会按新语言重新生成。」两者都经 `EditorState` 合并保存（R06 已有）。
- **§8.2 后台**：状态行（色点 + 文字「运行中 / 已暂停全部推送 / 没有运行 / 正在停止」，11pt「今天 07:02 启动 · 版本 0.5.0 (5)」）+ `重启` + `停止`（红字，需确认）；后台没有运行时改为 `启动后台`。登录项开关、暂停全部推送开关（说明「暂停期间不采集、不花钱、不发送；恢复后只补最近一期。菜单栏里也有这个开关。」）、关窗说明。
- **§8.3 菜单栏**：不可点的状态行「后台运行中 · 下一期 18:00 科技数码」（暂停时「已暂停全部推送」；「下一期」取调度的全部 scope——已开启的简报，以及其下有 remote id、按自己时间单独发的 X 账号（显示 @账号）——只算有机器人可发的，与概览共用 `OverviewData.slots`；都没有时只显示状态）；`打开 NewsPaw ⌘O`；`暂停全部推送` 切换项（暂停时带 ✓）；`退出 NewsPaw 界面 ⌘Q`（后台继续）。暂停时图标改为空心爪印并显示「已暂停」。菜单里没有停止后台。
- **§8.4 数据**：存放位置（数据目录，`~` 缩写）+ `在访达中显示`；`导出设置…`（`ops.export_settings` → `NSSavePanel`，文件权限 0600，说明不含 Key 和 Token）/ `导入…`（见 A3）；「保留抓取记录和日志」`Picker` 7 / 30 / 90 天。
- **§8.5 高级 / 排障**：`DisclosureGroup` 默认收起、展开状态存 UserDefaults，说明「给开发者看的工具。正常使用不需要打开。」诊断信息（`ops.diagnostics` → 复制 / 保存…）、支持快照（`ops.support_snapshot` → 保存…）、备份校验（在数据目录里选一个备份文件 → `ops.verify_backup`）、清理旧数据（`ops.cleanup` 预览 → 确认 → `apply`）、任务与投递记录（只读：`jobs.list`，展开一行读 `delivery.status`）。
- **替换与删除**：`OperationsWorkspace`（诊断 sheet、`OperationsCopy`）与 `ResidentControls`（旧登录项区块）删除；`SettingsPage` 用新分区重写。「后台没有运行」卡片（§4.6）改用同一套后台控制：`启动后台` + `打开登录项设置`。
- **一并关闭的延期发现**：R06-11（`service.stop` 失败只显示通用「没能确认后台已经停止」）——失败时记录结构化错误（后台错误码原样；连接断开 = `backend_unreachable`；回复不对 = `invalid_reply`），外壳用 `FailureNote` 显示该错误码的文案。R06-10 的设置 / 运维部分——新分区的每个失败都按错误码显示 `FailureCopy`（行内 `FailureNote`），不再有 `OperationsCopy.failure` 这类通用句。

失败路径（每个都有测试或明确的处理）：后台未运行（数据与高级操作禁用；状态行给 `启动后台`）、操作被拒（按错误码行内显示）、回复丢失（`backend_unreachable`）、导入在预览阶段被拒（如 `restore_requires_fresh_instance`，不发 `apply`）、导入时设置刚变（`configuration_changed` / `preview_changed`：自动重新预览一次并请用户再确认，不静默套用）、面板取消（什么都不发生、不报错）、SMAppService 错误（见 A1）、文件过大或不是 JSON（本地拒绝，不发请求）。

## 非目标

- 不改 launchd 注册机制本身（PR #77 范围）：仍是 `SMAppService.agent(plistName:)` + 现有 plist（`KeepAlive.SuccessfulExit = false`），注册前的旧服务与升级检查原样保留。
- 单人本机 App：不引入新系统、新进程、自动清理任务、多用户或远程管理。
- 不新增导出内容（R05 的策略并入导出不在本 issue）。
- 不做真实凭据联调；不发送真实消息。

## 依据仓库证据修正契约

- **关闭自启 = 停止并注销。** SMAppService 注销一个 LaunchAgent 时 launchd 会把它停掉；本 issue 不改注册机制，所以关掉开关只能是「先 `service.stop` 等后台安全退出，再注销」（沿用 `ResidentAgent.disable(waitForWorker:)`）。mockup 的说明「关闭后，重启电脑要手动打开 NewsPaw 才会推送」与此不符，改为「关闭后后台会停止，不再推送，直到你重新打开这个开关。」，并且关闭前确认（同一影响等同停止后台，§2.5）。
- **重启与启动用 `launchctl kickstart`。** plist 的 `KeepAlive.SuccessfulExit = false` 使 `service.stop` 正常退出后 launchd 不会自己拉起后台，旧界面在「已注册但已停止」时没有任何启动入口。`ResidentAgent.start()` 只在登录项为 `.enabled` 时执行 `launchctl kickstart gui/<uid>/io.newspaw.resident`（启动已登记的任务，不改登记）；未注册时「启动后台」= 注册（`RunAtLoad` 随即启动）。`重启` = `service.stop` → 等进程退出（现有 `--check-stopped`，最多 6 秒）→ `kickstart`。App 启动时若登录项已开而后台没在运行，就启动一次——这样确认框里「直到你再次打开 NewsPaw」成立。
- **`--check-stopped` 不等于进程已退出。** `ControlServer.close()` 在进程退出前就释放 `agent.lock`，此时 `kickstart`（不带 `-k`）面对仍在运行的旧进程什么也不做，旧进程随后以 0 退出，launchd 不再拉起。所以 `waitUntilStopped` 在锁释放后继续等到 `launchctl print` 不再列出 `pid`（同一 6 秒上限）；所有 `kickstart`（重启、启动后台、后台没有运行卡片、打开 NewsPaw 时的自动启动）都经同一个 `BackendControl.launch`：先等旧进程退出，再 kickstart，仍没连上就再 kickstart 一次。
- **启动时间与版本是新增后台字段。** `service.status` 原来只返回 `protocol_version / state / operations`。现在额外返回 `started_at`（控制服务开始监听的 UTC 时间）与 `version`（`newspaw.__version__`）；App 端可选解码，旧后台不显示这一行。括号里的构建号取 App 包的 `CFBundleVersion`，只在它的短版本与后台版本一致时显示。
- **保留天数没有后台设置，清理也不是定时任务。** `ops.cleanup` 原来固定清理 7 天前的记录，且只在用户手动清理时运行。本 issue 让 `ops.cleanup` 接受可选的 `retention_days ∈ {7, 30, 90}`（缺省仍为 7，旧调用不变），选择存 UserDefaults（默认 30 天），由「清理旧数据」带上；说明写明「清理旧数据时只删除早于这个天数的记录；还没发出的简报引用到的记录不会被清。」不新增自动清理（非目标）。
- **导入只对未使用过的实例开放。** `Operations._fresh` 要求当前库是全新默认状态，否则预览就以 `restore_requires_fresh_instance` 拒绝；所以「将改动的项目」是导入文件相对当前（默认）设置的差异，由 App 比较 `config.get` 与预览返回的、后台已清洗的 `settings` 得出，名称只取清洗后的值。Popover 自身就是 §2.5 要求的确认（标题 + 影响列表 + `导入` / `取消` 两个按钮），不再叠一层对话框。
- **备份校验只认数据目录里的文件名。** `ops.verify_backup` 只接受数据目录下 `<库名>.backup-<32 位十六进制>` 的文件名；App 用 `NSOpenPanel` 从数据目录选文件，选到别处的文件在本地以 `invalid_backup` 拒绝，不发请求。
- **任务状态词。** `jobs.list` 的 `status` 是流水线阶段；只读表把它映射到 §0.2 / contract §3 的词（准备中、等待投递、已跳过、未能发送、已暂停、结果未知、已取消），投递明细用 `delivery.status` 每个机器人的 `status` 与「已发 n / 共 m 段」。没有投递记录（`missing_delivery`）显示「还没有投递记录」。

## 验证

- 后端：`service.status` 带 `started_at` 与 `version`；`ops.cleanup` 的 `retention_days` 只接受 7 / 30 / 90，30 天时 10 天前的记录不是候选。
- Swift（`swift test` 与 `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test`）：内存后台按 `control.py` / `operations.py` 的语义实现（预览要求全新实例、apply 校验 digest 与 revision、导入的简报与来源全部关闭、cleanup 预览 / 执行、`delivery.status` 无记录时 `missing_delivery`、`schedule.configure` 校验 revision 并反映到 `setup.readiness`）。
- 离屏截图：`WindowSnapshots` 增加设置页高级展开的一张（隔离后台）。

### 结果（实现后）

- `uv run pytest -q`：811 passed, 1 skipped；`uv run ruff check .` 通过。新增 `test_status_names_when_the_backend_started_and_its_version`、`test_cleanup_takes_a_retention_of_seven_thirty_or_ninety_days`、`test_cleanup_keeps_records_younger_than_the_chosen_retention`（修改前均失败）。
- `swift test` 与 `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test`：191 个测试通过（基线 166；`SettingsTests` 新增 26 个，旧 `CleanupPreview` 解码测试并入 `cleanupRepliesAreCountedFromTheBackendsShape`）。先写的测试在实现前失败：R06-11 三种停止失败都没有记录错误码、停止确认文案不符，其余因新接口不存在而无法编译。
- 离屏截图：`settings-*` 与 `settings-open-*` × 三语 × 浅 / 深色（隔离后台，无 Key、无 Bot），版式与 `docs/mockup/redesign/settings.png` 一致。

未做：打包版的登录项注册、`launchctl kickstart` 与菜单栏图标变灰只由单元测试与代码路径覆盖，需在安装版上目视确认（离屏渲染无法画出菜单栏）；无真实凭据联调。

### 内部评审第 1 轮（已修复，回归测试先失败）

- R12-01：设置页状态行在暂停时显示「已暂停全部推送」（橙），与侧栏、菜单栏同词（`AppModel.settingsStatus`）。
- R12-02：清理按预览时的保留天数执行（`SettingsData.cleanupDays`）；改了保留天数就丢弃旧预览。
- R12-03：见上「`--check-stopped` 不等于进程已退出」；内存后台可模拟「kickstart 时旧进程还在退出」。
- R12-04：页面轮询 `BackendControl.reload(model:)`：登录项状态变化就清掉旧提示；后台连上后清掉启动 / 停止类提示。
- R12-05：重启时没能及时停下用重启自己的说明（不再说「自动启动没有关闭」）。
- R12-06：导出、诊断、快照从第一个字节起就是 0600（同目录 0600 临时文件 + rename），不再事后 chmod，也不会因卷不支持权限位把已写好的文件报成失败。此项的测试只能验证结果（覆盖 0644 旧文件后为 0600、无残留临时文件、写不进去报 `file_write_failed`），旧实现同样通过——窗口期在测试里不可观测。
- R12-07：内存后台的 digest 改为确定性（同一文件同一 revision 同一 digest），`apply_import` 先查 revision，与 `operations.py` 一致；删去现实中不会发生的「同 revision 但 digest 变化」用例。冲突后重新预览保留为防御路径：真实后台下它给出 `restore_requires_fresh_instance`。

### 外部评审第 1 轮（Kimi，已修复，回归测试先失败）

- R12-08：清理预览在途时改了保留天数，回来的结果按旧天数计数，不再显示、也不能被确认执行；预览开始时先清掉旧预览。导入不存在同类竞态：选文件、预览、应用共用 `run("import")`，进行中再点直接返回。
- R12-09：差异列表比较 `apply_import` 写入的每个顶层字段。`categories`（可写的 `name` / `partition`）显示为「简报类型」改动，用受影响的简报名称表述（「世界新闻：改为成人内容」「…：名称改为 …」，以及新增 / 移除数）；`described` 之外的任何顶层字段有差异时追加「还有其他设置会改动。」，所以只有文档真的完全相同时才显示「导入不会改动任何项目」。

### 外部评审第 2 轮（Kimi，R12-10，只改说明）

- 事实：`ops.cleanup` 里 X 帖子正文的清理（`x/timelines.py` 的 `purge_expired`）固定按 24 小时（`_AGE`，与 24 小时采集窗口相同），不受 `retention_days` 影响；保留天数固定为 7 天时也是这样。
- 分诊：让保留天数也决定 X 正文保留 30 / 90 天会改变 X 数据规则，超出本 issue 的冻结范围，不改后台。
- 修正（契约说明）：保留天数只管抓取记录、快照、日志与图片。说明行写明「X 帖子正文不按这个天数，超过 24 小时就会清掉」；清理预览把这一项标为「超过 24 小时的 X 帖子正文 N」，不再让人以为它也按所选天数计。测试 `theTwentyFourHourRuleForXPostTextIsStatedBesideTheRetentionChoice`（修改前失败）。

### 外部评审第 3 轮（Codex Sol 代 Kimi，已修复，回归测试先失败）

- R12-11：「下一期」只看简报时间，漏了单独发的 X 账号（`scheduler._scopes` 给它们独立的时间）。抽出 `OverviewData.slots`（按 `_scopes` 生成昨天到明天、晚于现在的每个时段），概览的 `upcoming` 与菜单栏的 `nextDelivery` 都从这里取，不再有第二份实现；只算有机器人的时段：账号自己的 `bot_ids`（非 null 时，与 `routing` 一致），否则简报的。菜单栏对账号显示「@账号」。测试 `theNextDeliveryCountsASpecialXAccountsOwnTime`。
- R12-12：导入差异列表放进最高 320pt 的 `ScrollView`，说明与「导入 / 取消」按钮在滚动区外始终可见；短列表保持紧凑。测试 `aLongImportListScrollsAndKeepsItsButtonsInView`（200 份长名称简报，改前高度远超上限）。

### 外部评审第 4 轮（Codex Sol 代 Kimi，已修复，回归测试先失败）

- R12-13：刚停止后立即「启动后台」（或打开 NewsPaw 自动启动）时，socket 已断但旧进程还在退出，`kickstart` 不起作用、旧进程以 0 退出后一直停着——与 R12-03 同因。重启与启动共用 `BackendControl.launch`（等 launchd 不再显示 pid → kickstart → 没连上再 kickstart 一次）；等不到旧进程退出时不 kickstart，显示「没能启动后台」。`enable()`（打开自启、未注册时启动）不经此路：未注册就没有 launchd 任务，关闭自启时已在注销前等旧进程退出。测试：`startingRightAfterAStopWaitsForTheOldProcessToExit`、`startingAsksLaunchdAgainWhenTheOldProcessWasStillExiting`、`openingNewsPawRightAfterAStopStartsTheBackendOnceItHasExited`、`aBackendThatNeverExitsIsNotKickstarted`；原有两个用例的调用序列相应变为先 `wait` 再 `start`。

