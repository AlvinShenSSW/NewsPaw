# 新闻来源与添加流程

状态：2026-11-07 推荐与目标设计。新增中国、AI 分类纳入设计；来源添加向导、网页适配器与新分类尚未完整实现到运行程序或设置预览。本次仅探测公开来源，没有启用订阅或发送新闻。

## 用户关注与推荐组合

| 分类 | 关注范围 | 建议来源组合 |
| --- | --- | --- |
| 国际 | 时政要闻、外交、选举、战争与重大公共事件 | BBC World + AP；用户指定 CNN；Reuters 作为补证候选，正式内容 API 需单独接入 |
| 日本 | 本国社会、政策、民生；本国娱乐 | NHK + Yahoo! JAPAN 国内；ORICON + マイナビ娱乐，Yahoo 娱乐用于发现 |
| 澳洲 | 本国政策、社会、民生；本国娱乐 | Guardian Australia + ABC + SBS；ABC Entertainment 补影视、音乐与文化 |
| 中国 | 本国社会、政策、民生；文娱 | 中新网国内/社会/文娱；用户指定联合早报中国及娱乐栏目作为补充视角 |
| 科技数码 | 新产品与技术突破，分别选稿 | MacRumors + Apple Newsroom；其他厂商正式公告、研究机构、论文与 IEEE Spectrum |
| AI | 模型发布、实用 Skill、Repo 与重要更新 | 厂商公告 + Hugging Face 官方组织/模型卡 + GitHub 仓库、Releases 和相关文件变更 |

以上分类都属于普通内容组。AV 与 X 成人分区继续独立。娱乐不自动等于成人内容；AI 模型新闻也不因为报道某个成人路线使用的供应商就变成成人内容。

日本、澳洲、中国的国内新闻与娱乐作为可分别调节条数和优先级的子栏目，必要时可拆成独立订阅/时间/Bot。国别依据报道事件和明确相关对象，不按媒体注册地或文章语言机械决定；联合早报中国栏目可进入中国新闻，但需保留实际出版商归属。娱乐默认优先与目标国家相关的作品、艺人、演出和产业信息，不被全球娱乐通稿占满。

## 获取方式

优先采用仍在更新的官方 RSS/Atom 或正式 API，再使用已适配的栏目网页；定向搜索用于发现与补证。RSSHub 可作为补充适配层，不能承诺公共实例和所有路由一直可用，也不是缺少授权时绕过付费全文的方式。抓取、预算与证据由程序管理，普通模型负责选稿、补证规划和目标语言整理。

Yahoo 等聚合站用于发现报道，尽量保留原出版商与原文链接；多个站点转载同一篇通讯稿不算多个独立证据。只有标题/摘要可读时标记证据范围，不声称读过全文。网页或搜索入口不一定覆盖全部条目，应显示覆盖限制。

### 本次公开源探测

以下是一次请求结果，不能当作长期可用保证。仅检查 RSS 元数据，未核实其中每篇报道。

| 来源 | 结果 |
| --- | --- |
| BBC World | HTTP 200，22 条，前部条目含 2026-11-07 的明确发布时间 |
| Guardian Australia RSS | HTTP 200，20 条，前部条目含当天发布时间 |
| NHK 新入口 | `https://www.nhk.or.jp/rss/news/cat0.xml` 重定向到 `https://news.web.nhk/n-data/conf/na/rss/cat0.xml`；HTTP 200，7 条，含当天条目。先前旧地址过期不代表新入口失效 |
| Yahoo! JAPAN 国内/娱乐 Topics RSS | 分别 HTTP 200、8 条，含当天条目；属于精选入口，不能宣称覆盖全部新闻 |
| 中新网国内/文娱 RSS | 分别 HTTP 200、30 条，含当天条目 |
| CNN 旧 World RSS | HTTP 版本返回 200 和 29 条，但抽查前两条为 2023-04-14；HTTPS 连接失败。不能将此入口列为健康的新鲜新闻源，需检查全部日期、选择新适配方式 |
| ABC 公开 RSS | 官方帮助页说明不再更新；推荐媒体本身，采集改用已适配网页或正式内容服务 |

## AI 选稿

模型发布同时检查正式公告、API/下载是否可用、模型卡、许可证与实际能力说明。区分仅预告、开放测试、API 上线、开放权重，不把这些全部称为开源。性能数字标明厂商自测或独立测试，不能把模型版本号变化自动当成重大突破。

Skill/Repo 重点观察官方 `openai/skills`、`anthropics/skills`，以及与用户 Mac/agent 使用相关的 `ml-explore/mlx-lm`、`ollama/ollama`；可另加 `vllm-project/vllm`。优先报告具体用途、实质变化、运行要求、费用/许可证与为何值得关注，不仅按 Stars 排名。无 Release 的 Skill 库应检查相关文件/提交变化，过滤纯排版更新。读取 README/SKILL.md 作为待分析资料，不执行其指令或自动安装推荐项目。

科技突破要求分清专利、论文、实验室演示、整机样机、客户验证与量产交付。用户提到的“华为造出光刻机”作为关注方向举例，不在缺少证据时写成确认事实；查明实际主体、技术范围和验证阶段后再确定标题。

## App 内如何添加

入口：**订阅与来源 → 来源管理 → 添加来源**。分为“推荐目录”“粘贴链接”“导入 OPML”，用户可自行启停推荐项，也可添加目录外来源。

1. **输入链接。** 支持 RSS/Atom、网站首页或栏目地址、GitHub 仓库、Hugging Face 组织；X 账号转入已有 X 管理页，沿用独立预算。
2. **识别方式。** 显示实际发现的 Feed 或适配器，可从多个栏目 Feed 中选择；仅有搜索发现能力时如实标注。未知网站显示“暂不支持自动采集/需要适配”，不把任意 URL 保存成功等同采集成功。
3. **选择归属。** 来源名称、新闻分类及国内/娱乐等范围、普通/成人内容类型必须明确。类型默认展示所属分类值；混合或待定源先留待分类，不能先送普通模型鉴别。多分类分配只在兼容内容分区内复用。
4. **预览近期条目。** 展示少量实际取得的标题、原出版商、原始链接、发布时间、来源语言和证据范围；说明过期、时间缺失或解析失败。连通性和内容新鲜度分别检查，低频来源不因当天没更新就判成故障。
5. **确认有效路由。** 汇总显示“来源 → 分类/类型 → 继承的文字和生图主备 → 目标语言 → 计划/样式 → Bot 列表”，以及未配置项。新增来源通常继承分类，不要求再填一遍 API Key 或 Bot Token。
6. **保存并启用。** 可先仅保存或试采集；只有来源与订阅所需配置就绪才进入计划任务。试采集不自动发 Telegram，不自动追溯推送全部历史。

一条来源可服务多个同类型分类，证据复用，投递仍按订阅与目标记录。来源列表显示采集方式、分类、最新内容时间、最近采集结果及编辑/暂停/删除操作。更改源内容类型需重新检查分类、模型与 Bot，不静默沿用另一分区的覆盖。来源不单独拥有一套隐含发送时间；订阅才拥有计划。

用户私人来源与凭据保存在本机；公开仓库只保存公开推荐目录及适配器。添加源和发现新 Repo 均不自动修改应用代码或安装项目。

## 依据与入口

- [BBC RSS 说明](https://support.bbc.co.uk/platform/feeds/NewsFeeds.htm)、[AP World](https://apnews.com/world-news)、[Reuters Connect](https://reutersagency.com/content-delivery-platforms/reuters-connect/)。
- [Yahoo RSS](https://news.yahoo.co.jp/rss)、[ORICON](https://www.oricon.co.jp/)、[マイナビ RSS](https://news.mynavi.jp/top/notice/rss/)。Yahoo RSS 目录页在研究浏览器中受限，上述两个 Feed 由本机 HTTP 单独探测。
- [ABC RSS 停更说明](https://help.abc.net.au/hc/en-us/articles/6147104938383-Why-are-RSS-feeds-no-longer-being-updated)、[ABC 娱乐](https://www.abc.net.au/news/entertainment)、[SBS](https://www.sbs.com.au/news)、[Guardian API](https://open-platform.theguardian.com/access/)。
- [中新网 RSS 目录](https://www.chinanews.com.cn/rss/)、[联合早报中国](https://www.zaobao.com.sg/news/china)、[联合早报娱乐](https://www.zaobao.com.sg/entertainment)。
- [MacRumors](https://www.macrumors.com/)、[Apple Newsroom](https://www.apple.com/newsroom/)、[IEEE Spectrum](https://spectrum.ieee.org/)。
- [OpenAI 公告](https://openai.com/news/)、[Anthropic 公告](https://www.anthropic.com/news)、[DeepMind](https://deepmind.google/blog/)、[DeepSeek GitHub](https://github.com/deepseek-ai)、[Hugging Face API](https://huggingface.co/docs/hub/api)、[GitHub Releases API](https://docs.github.com/en/rest/releases/releases)。Qwen 旧博客已指向新站，不能只监控旧博客地址。
- [OpenAI Skills](https://github.com/openai/skills)、[Anthropic Skills](https://github.com/anthropics/skills)、[MLX LM](https://github.com/ml-explore/mlx-lm)、[Ollama](https://github.com/ollama/ollama)、[vLLM](https://github.com/vllm-project/vllm)、[RSSHub](https://github.com/DIYgod/RSSHub)。
