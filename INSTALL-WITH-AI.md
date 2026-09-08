# 把这个文件夹交给 AI

1. 新电脑先安装并打开一次 Codex。
2. 解压本包，用可信的编程 agent 打开整个文件夹。
3. 发送一句：`请安装这个 Vibe Software，先阅读 START-HERE-FOR-AI.md。`
4. agent 会询问你需要哪些模式，以及真正缺少的凭据。
5. 不要把 API Key 发进聊天。可以只给密钥文件路径，或者在 agent 打开的
   本地隐藏输入框中输入。
6. agent 报告安装完成后，结束任务并完全退出 Codex，再双击桌面 `Codex`。

你不需要学 PowerShell，也不需要手工修改 TOML/JSON/YAML。电脑环境不同、
中转站更新或以后想增加功能时，继续把需求告诉 agent；它可以先备份，再对
本地版本做小范围修改。后续修改的通用提示语见 `EVOLVE-WITH-AI.md`。

`Install.cmd` 只是没有 agent 时的备用入口。Vibe Software 的主要界面是你与
agent 的自然语言对话，以及安装完成后的四卡片启动窗口。

