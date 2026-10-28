# AGENTS.md

本仓库只做一件事：给饥荒联机版（DST）做一个"聊天框里问 AI"的客户端 Mod + 本机桥接。
**权威方案是 [plan.md](plan.md)**，本文件只回答两件事：游戏 API 去哪里查、查到的结论落到哪里。

## 当前状态（动手前先读）

- 方案已定稿，但**第 0.5 步还没完成**：识别聊天输入的拦截点尚未验证（[plan.md:128](plan.md#L128) 的 §4.1、[plan.md:78](plan.md#L78) 的 #5）。
- 在 `tools/probe_hooks.lua` 有结论之前，不要写 `mod/modmain.lua` 的实现 —— 聊天可能走 `TheNet:Say` 而不经过 Lua 的 `SendRPCToServer`，写早了可能整套返工。
- 本机**没有安装 DST**：涉及"实测"的条目只能在用户机器上完成；代理侧能做的是**查证**（文档 / 源码），查不到就标记"待实测"，不要用记忆补全。

## 两份资料

### A. 接口文档站（首选，本环境可直接抓取）

- 基址 <https://vietnd69.github.io/dst-api-webdocs/docs/>，入口 `getting-started`（mod 目录结构、`modinfo.lua` 字段、`configuration_options` 格式）。
- 每页顶部有 `Based on game build <build>` —— **引用前先记下这个号**，它是判断"文档有没有滞后"的唯一依据。
- <https://vietnd69.github.io/dst-api-webdocs/docs/getting-started/change-log> 按 build 列出 Added / Modified 文件，用来确认"我要用的文件最近改没改"。
- 页面是自动生成的结构化摘要：Overview / Properties / Dependencies / Main functions。够回答"有没有这个 API、谁在调它、参数和返回值是什么"；**精确到行的实现要回源码**。
- 本项目常用页：`screens/chatinputscreen`、`networkclientrpc`、`networking`、`netvars`、`chathistory`、`widgets/redux/chatline`、`screens/playerhud`、`wordfilter`、`tuning`、`mods`、`modindex`、`frontend`，以及 `components/<name>`、`prefabs/<name>` 两类模式页（例：`components/abysspillargroup`）。

### B. 源码仓库（真相，本机取不到）

- <https://github.com/vietnd69/dst-scripts> —— 游戏最新版解包出来的 `scripts/`，路径与游戏内 `scripts/...` 一一对应（如 `scripts/screens/chatinputscreen.lua`、`scripts/networkclientrpc.lua`）。
- 本机限制（实测）：`web_fetch` 访问 github.com / raw.githubusercontent.com 被拒（解析到非公网 IP）；`pwsh` 目前因沙箱 ACL 报错（`SetNamedSecurityInfoW failed ... grantWrite(<workspace>)`），`git clone` 也跑不了。
- 因此：文档站能答就不绕路；确实要源码时**请用户粘贴文件内容**，或先修好 shell 再 `git clone` 到 `refs/dst-scripts/`（该目录不入库）。

## 查证流程

1. 在文档站定位页面，记下 `Based on game build`。
2. 读 Overview + Dependencies + Main functions，确认"谁调谁、参数与返回值"。
3. 结论写回 [plan.md](plan.md)：答了 §十 的 Open Question 就删掉或改写那一条，新增约束就落到对应章节。
4. 判定不了就标"待实测"，并在 §八 冒烟清单里补一条**可执行**的判定（谁来做、看什么日志、通过标准）。

**完成判据**：每条技术断言都能给出"页面 URL + build 号"或"源码文件路径"；给不出的一律标"待实测"。

抓取注意：文档站整页很长，左导航占大头，抓取常在正文中途被截断（实测 `screens/chatinputscreen` 的 Methods 段拿不到）。只取到 Overview 就够判断时不要贪多；缺哪段就说缺哪段，或请用户粘贴，**不要猜补**。

## 结论落到哪里

- 行为 / 接口变更：[plan.md](plan.md) 在先，代码在后。
- 会话结论：追加到 [.workbuddy/memory](.workbuddy/memory/)`/<日期>.md`（一天一个文件，按已有条目风格续写）。
- 代码注释里写指向，不复制 plan.md 的长段推理。

## 不可违反的三条（细节见 [plan.md:128](plan.md#L128) 与 [plan.md:311](plan.md#L311)）

- 识别是旁路：原文先照常发出，再触发 AI。
- 只对本人发出的、非私聊（`whisper == false`）的消息触发；回答不得以 `ds:` 开头。
- Mod 入口只认 `modinfo.lua` + `modmain.lua`；`api_version = 10`；配置项只有 checkbox / slider / select。

## 环境备忘

- 本地 mod 规范位置（文档站给出）：`%USERPROFILE%\Documents\Klei\DoNotStarveTogether\mods\`；游戏根目录下也有 `mods/`，真实路径以用户机器实测为准（[plan.md:334](plan.md#L334) 第 0 步）。
- 全部文档与注释用中文，代码标识符用英文。
