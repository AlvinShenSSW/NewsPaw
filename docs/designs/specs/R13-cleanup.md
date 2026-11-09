# R13 / #91 — 删除 `.env` 旧栈，拆出 newsparse

## 冻结范围

- 把核心模块从 `news.py` 引用的解析函数移到 `src/newspaw/newsparse.py`，并改全部引用。
- 删除 `.env` 时代的单 Bot 运行栈及其测试；移除 `_LEGACY_SCHEMA` 与 Store 中 `settings / deliveries_v2 / collections / briefs` 的建表与接口。
- `newspaw --help` 只剩 `control`；去掉仅旧栈使用的依赖；README、`docs/architecture.md` 更新；打包脚本与 CI 不引用已删模块。
- 非目标：不改核心采集 / 编辑逻辑；不提升 `DATABASE_VERSION`；不删除用户数据库中已有的旧表。

## 删除与移动

| 项 | 处理 | 依据 |
|---|---|---|
| `news.py` | `git mv` 为 `newsparse.py`，只保留纯解析：`Article`、`NewsError`、`plain_text`、`public_url`、`canonical_url`、`known_av_origin`、`check_news_xml`、`_published`、`parse_evidence`、`eligible_articles`、`MAX_FEED_BYTES` 等。删除 `NewsService`、`SourceAttempt`、`RetrievalReport`、`parse_feed`、`_parse_feed`、`_deduplicate`、`KNOWN_AV_FEED` | 这些只被 `cli.py`（search/collect/run）、`bot.py`、`av.py` 使用。核心模块（evidence、source_manager、connectors、editorial、store、operations、providers、media、x、importers）只用解析函数。`news.py` 已无剩余使用者，因此整体删除 |
| `parse_evidence(_dedicated_av=...)` | 去掉该私有参数及恒为假的成人分支 | 唯一传真值的是 `NewsService(_dedicated_av=True)`（旧 `av.py`）。所有现存调用都不传，行为不变；AV 产业采集走 `connectors/av.py`，不经过此函数 |
| `bot.py`、`config.py`、`schedule.py`、`service.py`、`grok.py`、`ai.py`、`sources.py` | 删除 | issue 指定 |
| `av.py`（`AVNewsService`） | 删除 | 基于已删的 `NewsService`；在 `src` 中没有任何引用，只有 `tests/test_av.py` |
| `locking.py`（`instance_lock`） | 删除 | 只被 `cli.run` 使用。后台的数据目录锁是 `control.acquire_control_lock`（同一个 `agent.lock` 文件） |
| `config.parse_times / parse_topics` | 移到 `app_config.py`，异常改为 `ValueError`（原 `ConfigError` 即 `ValueError` 子类，文案不变） | 仍被 `app_config`（配置校验与旧偏好导入）和 `telegram/commands.py`（`/schedule`，捕获 `ValueError`）使用 |
| `service._prepare_logs / service_log_directory` | 移到 `control.py`，名为 `prepare_logs / service_log_directory` | `serve_control` 在 `NEWSPAW_BUNDLED_RESIDENT=1` 时用它们建立私有日志；这是打包后台的现行路径 |
| `cli.py` | 只保留 `control --data-dir`；删除 `init / doctor / run / service / search / collect / audit` 与 `--config` | search/collect/audit 依赖 `.env` `Settings`、`NewsService`、`Store.save_collection / get_audit`（旧 `collections / briefs` 表），无法在不改核心采集的前提下保留，因此一并删除。无其他诊断命令；`bundle_runtime` 的 self-check / check-upgrade 是独立模块入口，未改 |
| `Store` | 删除 `get / set / unseen / mark_sent / save_collection / prune_audit / save_brief / mark_brief / get_collection / get_audit` 及审计常量与脱敏辅助函数 | 只被旧栈使用 |
| `Operations.cleanup` | 删除对 `collections` 的 `audit_candidates` 修剪 | 新库没有该表；升级库的旧表不再写入（原有写入已限制最多 200 条）。Swift 的 `CleanupPreview` 原本要求 `auditCandidates`，已一并删除并加了按真实回复解码的测试 |
| `.env.example`、`sources.toml`、`.gitignore` 中的 `!.env.example` | 删除 | 只服务 `newspaw init` 和旧 `Settings` |
| 依赖 | 删除 `python-telegram-bot`、`openai`（`uv lock` 同步移除 apscheduler、pydantic、tqdm 等传递依赖）；`bundle_runtime` self-check 不再检查 `openai` | `grep` 证据：`telegram.ext` 只在 `bot.py`；`openai` 只在 `ai.py` 与 self-check。`python-dotenv` 保留：`credentials.read_legacy` 与 `app_config.import_preferences` 仍用它解析旧 `.env` |
| 测试 | 删除 `test_bot / test_config / test_schedule / test_service / test_grok / test_ai / test_av`；`test_news` 改名 `test_newsparse`，只保留解析测试；`test_av_industry` 删除两个 `NewsService` / `NewsBot` 用例；`test_store` 只保留权限测试并新增"新库无旧表" | — |

## 决策与证据

**旧数据导入（`legacy.preferences` / `legacy.secrets`）保留。** `docs/planning/requirements.md` 第 59 行要求 Keychain 就绪后由用户在本机显式导入旧 `.env` 的秘密；`docs/designs/specs/13-local-control.md` 定义了这两个控制操作。它们不依赖 `config.py`：`credentials.read_legacy` 自己做 O_NOFOLLOW、大小与权限检查并用 `dotenv_values` 解析；`Store.import_legacy_config` 读取旧 bot 写入 `settings` 表的 `topics / times`。新库不再有 `settings` 表，所以读取前先查 `sqlite_master`，没有就视为空偏好。Swift 目前没有调用这两个操作（`grep -rn "legacy\." macos` 无结果），即导入入口尚无界面，README 已注明。

**迁移只做最小改动。** `migrations.py` 只删 `_LEGACY_SCHEMA` 和 `_initialize` 中执行它的循环，不提升 `DATABASE_VERSION`、不删表：
- 新库（version 0 → 24）不再创建旧表。
- v0.5.0 库（version 24，含旧表）打开时不迁移，旧表与数据原样保留。
- 更早版本（如 23）升级时照常备份，旧表保留；`_upgrade_*` 不触碰旧表。
- version 0 的早期 bot 库（只有 `settings`、`deliveries`）照常初始化；不再把 `deliveries` 复制到 `deliveries_v2`，因为已无读者。
- R05 分支把同文件的 `DATABASE_VERSION` 改为 25，与本次删除相邻，合并时会有一处只需保留两边改动的文本冲突。

**备份校验。** `Operations.verify_backup` 原先要求每个备份都有 `settings deliveries`（version ≥ 0）和 `deliveries_v2 collections briefs`（version ≥ 1），并要求同版本备份的列与当前库所有表一致。新库的备份没有旧表，升级库却有，因此：必需表清单去掉旧表；列比较跳过 `_LEGACY_TABLES`。`_fresh`（恢复前的"全新实例"检查）不变：升级库中旧表若有数据，仍阻止导入可移植设置，以免覆盖尚未导入的旧偏好。

**旧 LaunchAgent。** 旧 `service.py` 安装的 `io.newspaw.agent` 运行 `.venv/bin/python -m newspaw --config … run`。更新代码后该命令不存在，KeepAlive 会以 30 秒节流反复启动失败。`ResidentAgent.swift` 在该 label 仍被加载时拒绝注册新登录项（`legacyServiceActive`），已有保护；README 与 `packaging/README.md` 写明了用旧版本卸载或用 `launchctl bootout` 手动停止的方法。

## 验证

- `uv run pytest -q`：807 passed, 1 skipped。
- `uv run ruff check .`：通过。本次修改的文件中，`ruff format --check` 在 main 上已通过的仍然通过；main 上本就不通过的（`bundle_runtime.py`、`tests/test_migrations.py`、`tests/test_operations.py`）手工编辑，格式差异块数与 main 相同。
- `uv run newspaw --help`：只列出 `{control}`。测试覆盖 `run / service / init / doctor / search / collect` 均被 argparse 拒绝。
- 迁移测试：`test_new_database_has_no_tables_of_the_removed_env_bot`；`test_v050_database_with_legacy_tables_opens_and_keeps_them[23|24]`（按 v0.5.0 原样建旧表并写入数据，打开后版本正确、旧表数据保留、显式导入读到旧 `topics / times`，23 时生成一个备份）；`test_explicit_import_on_a_new_database_has_no_legacy_preferences`；备份校验 `test_backup_verification_ignores_tables_of_the_removed_env_bot[live|backup]`。
- `grep -rn "from .news import\|newspaw.news" src`：无结果。`packaging/`、`.github/workflows/`、`macos/` 不引用已删模块。
- `uv build`：成功；wheel 不含已删模块，`Requires-Dist` 不含 python-telegram-bot / openai。
- `swift test --package-path macos/NewsPaw`：93 个测试通过。
- `packaging/build-macos.sh`（`UV_OFFLINE=1`，输出到临时目录）：完整构建成功，`validate_bundle.py` 通过，`NewsPawResident --self-check` 输出 `{"state":"bundled","python":[3,13,7]}`；打包内无 telegram / openai / pydantic。用 `--fixture-control <临时目录>` 启动打包后台，`config.get` 返回 ok，新库没有旧表。脚本本身不签名、不公证，本次也未进行这两步。
