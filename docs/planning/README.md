# NewsPaw 开发路线图

状态：审计与需求拆分已准备，Kimi K3.1 Pro 独立设计终审待完成；功能开发未开始。9 个 epic、33 个子 issue，全部保留当前 mockup。

- [需求基线](requirements.md)：R01–R11 与需要补齐的边界决策。
- [全盘审计](audit-2026-11-07.md)：16 项差距、已有实现证据和未决外部依赖。
- [结构化 backlog](backlog.json)：范围、依赖、验收、验证、实现入口与非目标。
- [AFK 交接](afk-handoff.md)：Codex 主导 / Kimi K3.1 Pro 单一外门 / leave-open。
- [现有界面基线](../mockup/README.md)：沿用五页 mockup，不重设计。
- [Luna 费用与已领取额度](cost-assumptions.md)：透明假设、费用边界与官方依据。

## 阶段验收

**M1：普通文字新闻的 Mac 产品闭环。** 安装后无需终端，Keychain、独立三语 UI/输出、普通主备、多 Bot、分类时间、真实源添加、证据和 outbox 可追溯；两个 Bot 分配不串线，主备/睡眠/断网/部分投递/重启均可恢复，原文不得冒充目标语言。必须有安装、升级恢复和端到端证据。

**M2：本次完整首版。** 增加 AI 仓库监控、X 普通/成人与独立账号日更、AV 独立管线、来源配图、1–2 页 AI 报纸和图片/语音交互。核验预算不越界、成人上下文不进入普通模型、三语报纸准确且手机可读。

**Later：** 明确 opt-in 的重大事件提醒与视频理解。默认关闭，不作为 M1/M2 交付前提。

所有阶段均为未完成。真实密钥和能力未配置时保留相应未验收标记，不以离线测试通过代替线上验证。第二成人站未知不阻碍已确认站点开发，但不能声称两个源已交付。

## GitHub 任务索引

| Epic | 子任务 |
| --- | --- |
| [E01 · 配置、数据与安全边界](https://github.com/AlvinShenSSW/NewsPaw/issues/1) | [F01 #10](https://github.com/AlvinShenSSW/NewsPaw/issues/10)、[F02 #11](https://github.com/AlvinShenSSW/NewsPaw/issues/11)、[F03 #12](https://github.com/AlvinShenSSW/NewsPaw/issues/12)、[F04 #13](https://github.com/AlvinShenSSW/NewsPaw/issues/13) |
| [E02 · 新闻来源、采集与证据](https://github.com/AlvinShenSSW/NewsPaw/issues/2) | [S01 #14](https://github.com/AlvinShenSSW/NewsPaw/issues/14)、[S02 #15](https://github.com/AlvinShenSSW/NewsPaw/issues/15)、[S03 #16](https://github.com/AlvinShenSSW/NewsPaw/issues/16)、[S04 #17](https://github.com/AlvinShenSSW/NewsPaw/issues/17)、[S05 #18](https://github.com/AlvinShenSSW/NewsPaw/issues/18) |
| [E03 · 模型主备、编辑与语言](https://github.com/AlvinShenSSW/NewsPaw/issues/3) | [M01 #19](https://github.com/AlvinShenSSW/NewsPaw/issues/19)、[M02 #20](https://github.com/AlvinShenSSW/NewsPaw/issues/20)、[M03 #21](https://github.com/AlvinShenSSW/NewsPaw/issues/21)、[M04 #22](https://github.com/AlvinShenSSW/NewsPaw/issues/22) |
| [E04 · X 账号聚合与节约采集](https://github.com/AlvinShenSSW/NewsPaw/issues/4) | [X01 #23](https://github.com/AlvinShenSSW/NewsPaw/issues/23)、[X02 #24](https://github.com/AlvinShenSSW/NewsPaw/issues/24)、[X03 #25](https://github.com/AlvinShenSSW/NewsPaw/issues/25)、[X04 #26](https://github.com/AlvinShenSSW/NewsPaw/issues/26) |
| [E05 · 分主题调度与可靠投递](https://github.com/AlvinShenSSW/NewsPaw/issues/5) | [Q01 #27](https://github.com/AlvinShenSSW/NewsPaw/issues/27)、[Q02 #28](https://github.com/AlvinShenSSW/NewsPaw/issues/28)、[Q03 #29](https://github.com/AlvinShenSSW/NewsPaw/issues/29) |
| [E06 · 多 Telegram Bot 与交互](https://github.com/AlvinShenSSW/NewsPaw/issues/6) | [T01 #30](https://github.com/AlvinShenSSW/NewsPaw/issues/30)、[T02 #31](https://github.com/AlvinShenSSW/NewsPaw/issues/31)、[T03 #32](https://github.com/AlvinShenSSW/NewsPaw/issues/32) |
| [E07 · 沿用现有 mockup 的原生 Mac App](https://github.com/AlvinShenSSW/NewsPaw/issues/7) | [U01 #33](https://github.com/AlvinShenSSW/NewsPaw/issues/33)、[U02 #34](https://github.com/AlvinShenSSW/NewsPaw/issues/34)、[U03 #35](https://github.com/AlvinShenSSW/NewsPaw/issues/35)、[U04 #36](https://github.com/AlvinShenSSW/NewsPaw/issues/36) |
| [E08 · 来源配图、AI 报纸与媒体交互](https://github.com/AlvinShenSSW/NewsPaw/issues/8) | [D01 #37](https://github.com/AlvinShenSSW/NewsPaw/issues/37)、[D02 #38](https://github.com/AlvinShenSSW/NewsPaw/issues/38)、[D03 #39](https://github.com/AlvinShenSSW/NewsPaw/issues/39) |
| [E09 · 运维、打包与发布验收](https://github.com/AlvinShenSSW/NewsPaw/issues/9) | [O01 #40](https://github.com/AlvinShenSSW/NewsPaw/issues/40)、[O02 #41](https://github.com/AlvinShenSSW/NewsPaw/issues/41)、[O03 #42](https://github.com/AlvinShenSSW/NewsPaw/issues/42) |
