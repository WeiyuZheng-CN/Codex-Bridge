# Codex Vibe Software

这不是一个要求用户理解配置文件的传统安装器，而是一套可以交给 AI
安装、适配和继续生长的软件核心。

它包含当前四入口启动界面、各模式的启动逻辑、无密钥配置模板，以及供安装
agent 理解架构的说明。它不包含 API Key、个人登录、会话、日志或某台电脑的
运行数据。

## 最简单的用法

1. 解压 ZIP。
2. 在 Codex、DeepSeek、Cline 或其他可信的编程 agent 中打开整个文件夹。
3. 对它说：`请安装这个 Vibe Software，先阅读 START-HERE-FOR-AI.md。`
4. 告诉 agent 你想用哪些模式。只有相应模式才需要凭据。
5. 密钥请在安装器弹出的本地隐藏输入框中输入，或只告诉 agent 一个包外的
   私密密钥文件路径；不要把密钥发进聊天。
6. 安装完成后结束当前任务，完全退出 Codex，再打开桌面的 `Codex` 快捷方式。

Local Qwen3.6 的运行、GPU 调优、故障排查、回滚和验收规则集中记录在
docs/LOCAL-QWEN36-AI-MAINTENANCE-GUIDEBOOK.md；维护该模式的 agent 应完整
阅读它。

## Local Qwen3.6 资产边界

本仓库保存的是围绕 Local Qwen3.6 构建的产品：Codex 接入、四入口启动器、
配置模板、模型目录、GPU 调优规则和 AI 维护手册。为避免仓库过大以及重复
分发模型，Qwen3.6 GGUF 权重、CUDA/llama.cpp 运行时、缓存和本机 profile
不会上传到 GitHub。

目标电脑需要从官方来源单独准备模型和运行时。安装 agent 会检查它们是否已
放在安全的外部目录，并按维护手册中的文件大小和 SHA-256 校验；不会把权重
写入这个源代码包。

官方参考：

- Qwen3.6：<https://ollama.com/library/qwen3.6:35b-a3b-coding>
- llama.cpp：<https://github.com/ggml-org/llama.cpp/releases/tag/b10964>

gitignore 已保护 GGUF、常见模型格式、Local Qwen 运行目录和运行时压缩包，
降低误提交大型权重的风险。

## 项目结构

```text
core/                    当前四入口运行核心、模型目录和配置模板
docs/                    架构、后续改造和旧版兼容说明
archive/                 不参与安装的 Moon Bridge 和旧配置历史归档
references/deepseek/     当前 DeepSeek 官方配置参考
START-HERE-FOR-AI.md     安装 Agent 的唯一首要入口
Install-*.ps1 / .cmd     安装与验证入口
```

安装 Agent 先读 `START-HERE-FOR-AI.md`，只在需要深入理解时再进入
`docs/`。旧 Moon Bridge、旧双 Transfer 模板和历史修复脚本不再混入当前核心，
但会保留在 archive/ 中供迁移和回滚使用；它们也可从 Git commit `0924440`
或更早的 release 恢复。

可选模式包括 ChatGPT、DeepSeek（V4 Pro、V4 Flash、V4 Flash Vision）、
OpenAI Transfer 和 Local Qwen3.6。Local Qwen3.6 使用本机 loopback 上的
llama.cpp Responses API，并且不需要 OpenAI 登录；模型与 CUDA 启动器位于
`%USERPROFILE%\Documents\Codex\local-qwen36`，profile 位于同级的
`local-qwen36-codex`。Transfer 使用一份 `auth.json` 配置；
`OpenAI-transfer-Pro` 与 `OpenAI-transfer` 由中转站网页对同一个 Key 做服务端切换。
Local Qwen3.6 currently uses the full 262K context with CUDA `q8_0` KV cache,
Flash Attention, and low reasoning with a 512-token budget. The Codex model
catalog exposes the complete local reasoning scale: minimal, low, medium,
high, xhigh, and max. Low remains the default.
The local server also uses a bundled Codex-compatible Jinja template to handle
Codex multi-message requests.
The installer deploys that template and its Local Qwen server launcher beside
the externally staged model/runtime, so the fix is retained after reinstall.
未安装的模式仍保留在漂亮界面中，
但会淡化显示；以后可以让 agent 补装。

仓库还提供 `references/deepseek/260909` 的官方 native/vision 参考；旧版
Transfer 兼容说明位于 `docs/LEGACY-COMPATIBILITY.md`。需要最新配置或
凭据时，agent 会让用户打开 <https://ai-pixel.online/keys> 并点击“使用密匙”；
页面返回的信息应保存在仓库外或通过本地隐藏输入框使用，不能粘贴到聊天或
提交到 GitHub。

## Vibe Software 的思路

- 包提供可靠的核心和清楚的架构，不穷举所有电脑环境。
- agent 负责观察当前电脑、询问真正缺少的信息并做小范围适配。
- 检查脚本用于定位问题，不是阻止合理修改的认证关卡。
- 用户提出新需求后，agent 可以备份、修改、验证并记录本地演化。
- 有价值的新功能可以清除个人数据后，以补丁或新版核心分享给别人。

首次安装提示语在 `START-HERE-FOR-AI.md`，后续改造提示语在
`docs/EVOLVE-WITH-AI.md`，具体架构在 `docs/ARCHITECTURE.md`。

中转站官方资料：

- <https://docs.ai-pixel.online/docs/api>
- <https://docs.ai-pixel.online/docs/api/responses>
- <https://docs.ai-pixel.online/docs/api/models>
- <https://docs.ai-pixel.online/docs/normal-client-setup>
- <https://docs.ai-pixel.online/docs/normal-account-mode>

如果“使用密匙”返回 API Key Mode 或额外 actor 请求头，agent 应保留兼容配置，
不要强行套用共享 `auth.json` 形状。
