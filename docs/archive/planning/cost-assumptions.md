# Luna 与 API credit 估算

2026-11-07 用户确认：已领取 OpenAI ChatGPT Pro $100 档的 $100 API credit。本轮未读取私人账单、余额或项目权限。

[OpenAI 官方额度规则](https://developers.openai.com/api/docs/guides/chatgpt-api-credits)：已激活额度属于绑定 API organization，NewsPaw 应使用其项目 Key；Responses 文本/视觉、Images 和内置工具等 API 用量可计入，未用额度按账单周期到期不结转。其他服务商与 X 另计，不能混成一个可互通的余额。

[Luna 官方价格](https://developers.openai.com/api/docs/models/gpt-6-luna)：标准短上下文输入 $0.10 / 百万 token、输出 $0.50 / 百万 token。以下不计算缓存优惠，假设每次请求低于长上下文门槛、不用 Fast/区域溢价；计费输出包含推理 token，所有步骤和失败重试也计入。

| 假设每日总用量 | 30 天文字费用 |
| --- | --- |
| 500,000 输入 + 100,000 输出 | $3.00 |
| 2,000,000 输入 + 400,000 输出 | $12.00 |

这不是实际测量或套餐保证。若另外按三倍重试/额外编辑余量计算，分别为 $9/$36。生图、搜索工具、音频、X、MiMo/DeepSeek/Grok 不在上述 token 算式内。OpenAI 搜索/生图可消耗同一额度但单独计价。M03 预算任务需显示费用分项、价格更新时间、估算/实测区别和未知用量预留；不能因为用户有额度就默认为全部可支出，也不自动充值。
