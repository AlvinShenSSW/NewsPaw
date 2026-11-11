# R16 — 0.6.1 补丁：升级后的旧后台、MiMo Token Plan、生图专用模型

来源：所有者 2026-11-10 的本机报告与指令（「立刻 afk 修好，发版，版本号加 0.0.1 生成 dmg 到桌面」）。没有 GitHub issue；PR #110。E 节修正 `18-av-industry.md` 中「拒绝无时区时间」在真实站点上的后果，其余 #18 约定不变。

## 问题与证据

1. **升级后仍连着旧后台。** 0.6.0 App 装好后，11 月 8 日启动的 0.5.0 后台仍在运行。它的 `service.status` 没有 `version` / `operations`，App 判为已连接，随后 `requests.status`、`setup.readiness`、`models.health` 等得到 `unknown_operation`，保存 Key 后也没有自动检查。
2. **MiMo Token Plan Key。** `tp-` Key 只在订阅页显示的 Token Plan 地址（`token-plan-{cn,sgp,ams}.xiaomimimo.com/v1`）有效；默认 `https://api.xiaomimimo.com/v1` 返回 401，界面只说 Key 被拒绝。
3. **生图专用模型被当成文字模型。** 本机 `model_probes`：`gpt-image-2.5-flare` 的配置保存 Key 后，自动检查 `auto.<id>.text.g2` → `model_unavailable`（404）；`gpt-6-luna` 的 `image` 检查 → `invalid_image_request`（400）。`docs/model-routing.md` 已规定生图槽位独立于文字模型，但「接入」页（R10）把报纸所选模型同时写成生成和校验模型，且每个模型行都按文字检查判定。结果：生图配置的行永远显示「找不到这个模型」，报纸选它时看图校验也落在它身上而必然失败。

## 冻结的验收标准

A. 旧后台（已在 ccdfad7 实现）
- A1 打包的 App 把 `service.status.version` 与自身 `CFBundleShortVersionString` 比较；不同或缺失 → `incompatible`，此后只发 `service.status`（和替换它所需的 `service.stop`）。未传入版本（测试、未打包运行）不比较。
- A2 打开 App 时，登录项为开且后台 `incompatible`，自动重启一次；替换后仍不符显示「没能启动」。登录项未开时不动它。
- A3 设置 › 后台在 `incompatible` 时提供「重启」（受 `canRestart` 约束）。

B. Token Plan（已在 ccdfad7 实现）
- B1 `provider == mimo`、Key 以 `tp-` 开头、`base_url` 主机为 `api.xiaomimimo.com` 时，适配器不发请求，报 `token_plan_endpoint`；检查记录为 failed，无预算占用。其他组合不受影响。
- B2 `token_plan_endpoint` 有中/英/日文案，指向「自定义 API 地址」。

C. 生图专用模型
- C1 「生图专用模型」按模型 ID 判定：以 `gpt-image-` 或 `dall-e-` 开头（大小写不敏感）。后端与 App 各有一个判定函数，测试用同一组样例。不改配置结构，不加迁移。
- C2 后端：`credentials.set` 保存这类配置的 Key 后，自动检查的能力是 `image`（id `auto.<profile>.image.g<generation>`），不再发文字检查。其他配置仍是 `text`。
- C3 App：这类配置的模型行以 `image` 检查为准——状态、进行中、失败说明、「再测一次」（含未知结果先确认）都针对 `image`；保存 Key 后按 `auto.<profile>.image.g<generation>` 跟进，不等待文字检查，也不另付一次。改地址 / 模型后重测的也是 `image`。
- C4 App：开启报纸或更换报纸模型时，若校验模型为空或本身是生图专用模型：所选模型是生图专用 → 校验模型取普通组、主用、非生图专用的模型（优先已有 Key 的，其次按 id 排序的第一个）；找不到则仍用所选模型（沿用现有「看图检查未通过」提示）。所选模型不是生图专用 → 行为不变。已有的非生图校验模型不覆盖。

E. AV研究所 的发布时间（所有者 2026-11-10 追加：「一起修掉」）
- 证据：本机 13:01 的试采集 `fetch_3522f5f6…` 为 `no_eligible`，缺口 `candidate_limit`、`invalid_publication_date`、`no_industry_fact`。网站首页与详情页现在只给无时区的 `<time datetime="2026-11-10 10:28:06">`，没有 `article:published_time`；它的 RSS（`https://fiu758.com/?feed=rss2`）每条都有带时区的 `pubDate`（同一篇为 `01:28:06 +0000`）。#18 规定拒绝无时区时间，所以命中关键词的条目全部被拒。
- E1 候选条目在首页 / 详情页没有带时区的发布时间、只有无时区时间时，适配器读取一次该站 RSS（固定地址 `https://fiu758.com/?feed=rss2`，每次采集最多一次，只在需要时），按文章编号（`<link>` 为 `https://fiu758.com/?p=<id>`）取 `pubDate` 作为发布时间与 `published_raw`。
- E2 从 RSS 只取编号与 `pubDate`；标题、摘要、正文、图片都不读入也不保存。请求沿用现有约束：同源、无 Cookie / 认证、不跟随重定向、大小上限、`before_request` 暂停检查、配置变化即停、计入 45 秒总时限。响应类型须为 RSS/XML，并通过现有 XML 安全检查。
- E3 页面上的无时区时间必须与采用的发布时间一致：它是同一时刻在某个时区的钟面时间（相差不超过 14 小时且为 15 分钟的整数倍）；否则 `conflicting_publication_date`。有带时区时间时，同样用它核对无时区时间。
- E4 RSS 里没有该编号、其 `pubDate` 无效 / 无时区、同一编号时间不一致，或 RSS 读取失败：该条目仍以 `invalid_publication_date` 拒绝；读取失败另记缺口 `date_feed_unavailable`，不把整次采集判为失败。
- E5 页面已有带时区时间时不读 RSS；关键词规则、每次 6 个候选、只收行业动态、通用 RSS 通道拒绝该站的规则都不变。

D. 发版
- D1 版本 0.6.0 → 0.6.1（`pyproject.toml`、`src/newspaw/__init__.py`、`packaging/NewsPaw.Info.plist`、`macos/NewsPaw/build-dev-app.sh`、`uv.lock`），build 号 +1。
- D2 合并后从 main 打包，DMG 放到 `~/Desktop`；本机 ad-hoc 签名，不声称公证。

## 不变量

- 普通 / 成人分区不跨组；C4 只在普通组里找校验模型（报纸只支持普通组）。
- 不新增付费调用：自动检查仍是每个 Key 代次一次，已通过的不重复；跟进用同一个 probe id。
- 离线测试不产生外部调用。

## 非目标

- 不提供新建生图配置的界面，也不限制报纸模型 Picker 的候选（没有生图配置的用户仍会看到「生图检查未通过」）。
- 不改路由、不改 `Digests` / `XAccounts` 中按 `partition + role` 取模型的逻辑。
- 不改 `KeyChecks` 对文字模型的既有行为。
- 登录项未开而后台由其他方式启动的情况只显示不匹配，不自动处理。
- AV研究所：不放宽关键词、不提高候选上限、不把无时区时间按某个固定时区直接接受、不让该站进入通用 RSS 通道。

## 假设（未验证）

- Token Plan 地址支持 `/responses`：只依据 MiMo 文档。
- `gpt-image-2.5-flare` 在 OpenAI Images API 上可用：本机该配置此前只有 `credential_missing` 记录，没有成功的生图检查。
- 真实 0.5.0 → 0.6.x 升级上的自动重启没有手测。

## 做法与取舍

- C1 用模型 ID 而不是给配置加「用途」字段：后者要改配置结构、迁移和导入导出；现有支持的生图端点只有 OpenAI Images，其型号命名稳定。
- C3 不改 `KeyChecks.key` / `probes` 的文字语义：给 `save` 加一个能力参数，非文字时用现有的 `trackAutomatic` + 按 id 跟进；模型行按配置的「主能力」读 `states[profile][capability]`。

## 测试计划

- Python：`credentials.set` 对生图配置只发起 `image` 自动检查；判定函数样例；既有 `text` 测试不变。
- Swift：生图配置保存 Key 后跟进 `auto.<id>.image.g<gen>`、无 `text` 的 `models.probe`；模型行状态取自 `image`；「再测一次」发 `image`；报纸选生图配置时校验模型取普通主用，已有非生图校验模型不覆盖，选普通模型时行为不变；判定函数样例与 Python 相同。
- Python（E）：无时区页面时间 + RSS 命中 → 接受且发布时间取自 RSS、RSS 只请求一次、RSS 正文不入库；RSS 无该编号 / 钟面不一致 / RSS 失败 / 暂停于 RSS 请求前；页面带时区时不请求 RSS。
- 全量：`uv run pytest -q`、`uv run ruff check .`、`swift test`（`macos/NewsPaw`）。
