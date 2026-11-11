# 新闻来源与添加流程

2026-11-07 更新。下方目录区分 RSS、Atom、官方 API、已适配的网页元数据和待适配入口。后台可按已配置的来源做公开预览。现有 mockup 仍是界面设计参考。下方连通性来自隔离的公开探测，未启用用户的订阅或发送新闻。

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

### 公开入口与覆盖

下表为 2026-11-07 UTC 的手动探测。连通性与发布时间分开判断，结果随来源及网络变化。

| 分类 | 入口 | 观察与限制 |
| --- | --- | --- |
| 国际 | [BBC World RSS](https://feeds.bbci.co.uk/news/world/rss.xml) | HTTP 200。21 条中 14 条在近 24 小时内发布。 |
| 国际 | [CNN 新闻 sitemap](https://edition.cnn.com/sitemap/news.xml) | HTTP 200。适配器识别 World 和明确地区板块的标题、链接、发布时间。栏目网页超过抓取大小上限，旧 World RSS 过期。sitemap 只覆盖发布者列出的条目。 |
| 国际 | [AP World](https://apnews.com/world-news) | 公开栏目向采集客户端返回 HTTP 403，保留为待适配候选。 |
| 日本 | [NHK RSS](https://news.web.nhk/n-data/conf/na/rss/cat0.xml)、Yahoo! JAPAN [国内 RSS](https://news.yahoo.co.jp/rss/topics/domestic.xml)及[娱乐 RSS](https://news.yahoo.co.jp/rss/topics/entertainment.xml) | 各返回 HTTP 200。NHK 有 7 条、两个 Yahoo Topics 入口各 8 条近 24 小时条目。Yahoo 是精选入口，尽可能沿用原出版商归因。ORICON 的网页尚待适配。 |
| 澳洲 | [Guardian Australia RSS](https://www.theguardian.com/australia-news/rss)、[ABC 娱乐](https://www.abc.net.au/news/entertainment) | Guardian 20 条中 4 条在近 24 小时内发布。ABC 娱乐页提供带时区的文章元数据。ABC 综合栏目及 SBS 仍为候选，ABC 原 RSS 已停更。 |
| 中国 | 中新网[国内 RSS](https://www.chinanews.com.cn/rss/china.xml)及[文娱 RSS](https://www.chinanews.com.cn/rss/culture.xml)、联合早报[中国](https://www.zaobao.com.sg/news/china)及[娱乐](https://www.zaobao.com.sg/entertainment) | 中新网两个入口各 30 条，近 24 小时分别 30 条和 7 条。联合早报栏目和样本详情页可读，抽样保留公开结构化元数据，遇付费标记则跳过该条。 |
| 科技数码 | [MacRumors Front RSS](https://feeds.macrumors.com/MacRumors-Front)、[Apple Newsroom Atom](https://www.apple.com/newsroom/rss-feed.rss) | MacRumors 20 条中 8 条符合近 24 小时。Apple 20 条只有更新时间，未进入近期新闻。IEEE Spectrum 网页仍待适配。 |
| AI | [OpenAI News RSS](https://openai.com/news/rss.xml)、[Hugging Face Blog RSS](https://huggingface.co/blog/feed.xml)、GitHub／Hugging Face 官方 API | 两个 RSS 入口 HTTP 200，采样近 24 小时未见新条目。官方 API 入口需逐来源预览。 |

网页预览最多取一个栏目和六篇详情。采集只保留标题、链接、明确发布时间和标为公开的页面描述。权限限制、跳转和结构变化会显示在结果里。带明确时间的历史条目可以留作背景。只要日期缺失、没有时区或晚于采集时间，就不会进入近期简报。

### OpenAI 定向搜索

搜索在普通来源的本机控制接口独立配置。默认关闭。选择一个通过文字探测、使用官方 API 地址的普通 OpenAI 配置后，可按已启用的普通订阅发起一次搜索。只把公开类别词和已启用的目录来源域名交给 OpenAI；固定使用一次工具调用，并在发出前检查模型单价和本次授权额度。当前开发验收用模拟响应，真实账户权限与扣费需另行验证。

搜索记录保存请求词、供应商、返回的引用链接及证据范围。只保留授权来源的引用标题作为线索。使用来源本身可核验的发布时间和公开摘要作为新闻证据。重复请求编号只查原记录，无法确认结果时保留预算占用。模型和工具调用的计费口径见 [OpenAI Web Search](https://developers.openai.com/api/docs/guides/tools-web-search) 与 [OpenAI API 价格](https://developers.openai.com/api/docs/pricing)。

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

## 成人来源的参考核对

用户记得曾使用两个网站。本次回查所提供的 `av-research-brief.py`，仅能确认 `HOME_URL` 指向 `fiu758.com`，脚本将来源称为“AV研究所”。它先取首页列表，再获取每篇详情，最多输出 6 条候选，并保留链接、时间和图片字段；不是在该脚本里调用两个站点，也不能据此断定历史定时任务只使用这一个来源。

提供的 `news-briefs.md` 未列出第二站；下载目录中未找到旧 `daily-news-fetcher.py`，本机也没有 `~/.openclaw` 工作区可继续核对。第二来源仍待用户补充旧脚本、任务配置或名称。mockup 仅加入已确认的参考站点并标注第二站待确认，未访问或执行成人采集脚本。现有 NewsPaw 原型探测过的同域 RSS 是另一个采集入口，不算第二个网站。

## 依据与入口

- [BBC RSS 说明](https://support.bbc.co.uk/platform/feeds/NewsFeeds.htm)、[AP World](https://apnews.com/world-news)、[Reuters Connect](https://reutersagency.com/content-delivery-platforms/reuters-connect/)。
- [Yahoo RSS](https://news.yahoo.co.jp/rss)、[ORICON](https://www.oricon.co.jp/)、[マイナビ RSS](https://news.mynavi.jp/top/notice/rss/)。Yahoo RSS 目录页在研究浏览器中受限，上述两个 Feed 由本机 HTTP 单独探测。
- [ABC RSS 停更说明](https://help.abc.net.au/hc/en-us/articles/6147104938383-Why-are-RSS-feeds-no-longer-being-updated)、[ABC 娱乐](https://www.abc.net.au/news/entertainment)、[SBS](https://www.sbs.com.au/news)、[Guardian API](https://open-platform.theguardian.com/access/)。
- [中新网 RSS 目录](https://www.chinanews.com.cn/rss/)、[联合早报中国](https://www.zaobao.com.sg/news/china)、[联合早报娱乐](https://www.zaobao.com.sg/entertainment)。
- [MacRumors](https://www.macrumors.com/)、[Apple Newsroom](https://www.apple.com/newsroom/)、[IEEE Spectrum](https://spectrum.ieee.org/)。
- [OpenAI 公告](https://openai.com/news/)、[Anthropic 公告](https://www.anthropic.com/news)、[DeepMind](https://deepmind.google/blog/)、[DeepSeek GitHub](https://github.com/deepseek-ai)、[Hugging Face API](https://huggingface.co/docs/hub/api)、[GitHub Releases API](https://docs.github.com/en/rest/releases/releases)。Qwen 旧博客已指向新站，不能只监控旧博客地址。
- [OpenAI Skills](https://github.com/openai/skills)、[Anthropic Skills](https://github.com/anthropics/skills)、[MLX LM](https://github.com/ml-explore/mlx-lm)、[Ollama](https://github.com/ollama/ollama)、[vLLM](https://github.com/vllm-project/vllm)、[RSSHub](https://github.com/DIYgod/RSSHub)。
