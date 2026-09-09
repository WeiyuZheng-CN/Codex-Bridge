# Codex Vibe Software

这不是一个要求用户理解配置文件的传统安装器，而是一套可以交给 AI
安装、适配和继续生长的软件核心。

它包含漂亮的四卡片启动界面、各模式的启动逻辑、无密钥配置模板、
Moon Bridge 及源码，以及供安装 agent 理解架构的说明。它不包含 API Key、
个人登录、会话、日志或某台电脑的运行数据。

## 最简单的用法

1. 解压 ZIP。
2. 在 Codex、DeepSeek、Cline 或其他可信的编程 agent 中打开整个文件夹。
3. 对它说：`请安装这个 Vibe Software，先阅读 START-HERE-FOR-AI.md。`
4. 告诉 agent 你想用哪些模式。只有相应模式才需要凭据。
5. 密钥请在安装器弹出的本地隐藏输入框中输入，或只告诉 agent 一个包外的
   私密密钥文件路径；不要把密钥发进聊天。
6. 安装完成后结束当前任务，完全退出 Codex，再打开桌面的 `Codex` 快捷方式。

可选模式包括 ChatGPT、DeepSeek V4 Pro、DeepSeek V4 Flash、
`OpenAI-transfer-Pro` 和 `OpenAI-transfer`。未安装的模式仍保留在漂亮界面中，
但会淡化显示；以后可以让 agent 补装。

仓库还提供 `configuration/260902` 的脱敏中转站参考配置。需要最新配置或
凭据时，agent 会让用户打开 <https://ai-pixel.online/keys> 并点击“使用密匙”；
页面返回的信息应保存在仓库外或通过本地隐藏输入框使用，不能粘贴到聊天或
提交到 GitHub。

## Vibe Software 的思路

- 包提供可靠的核心和清楚的架构，不穷举所有电脑环境。
- agent 负责观察当前电脑、询问真正缺少的信息并做小范围适配。
- 检查脚本用于定位问题，不是阻止合理修改的认证关卡。
- 用户提出新需求后，agent 可以备份、修改、验证并记录本地演化。
- 有价值的新功能可以清除个人数据后，以补丁或新版核心分享给别人。

安装提示语在 `START-HERE-FOR-AI.md`，后续改造提示语在
`EVOLVE-WITH-AI.md`，具体架构在 `AI-INSTALLATION-GUIDE.md`。
