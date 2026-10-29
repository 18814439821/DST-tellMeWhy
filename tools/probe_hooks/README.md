# probe_hooks：拦截点判定（开发期工具，不随发布物交付）

一个可直接装进游戏的客户端 mod。它**只在客户端 Lua 的各个可能入口挂只读观测点，把命中的实参打到 `client_log.txt`**，不改文本、不吞消息、不发网络请求、不写文件。

目标只有两个：

1. **能不能拿到**"我自己发出的那条全局聊天"的完整原文；
2. 拿到它的同时**能不能知道 whisper 标志**（决定 plan §4.1 的"只对全局生效"是否可实现）。

> 背景：官方脚本文档显示 `ChatInputScreen` 是用 `TheNet:Say()` 发送的（`screens/chatinputscreen`，Based on build **714014**）。如果聊天在 C++ 侧直接发 RPC，那么包装 Lua 的 `SendRPCToServer(RPC.Say)` 永远不命中——这正是 plan §二 #5 标记的最高风险。本 probe 就是为它定案的。

---

## 零、分阶段排查（先做这个）

这个 mod 现在是**分阶段**的：`stage.lua` 里只有一个全局变量，改数字、重启游戏就切一级。每级只加一个钩子，一旦哪级出问题，一眼就知道是哪个钩子。

| stage | 装了什么 | 通过标准 |
| --- | --- | --- |
| 0 | 什么都不装，只打一行日志 | 能进主菜单/进世界，日志出现 `[probe] boot stage=0`、`[probe] stage0 done` |
| 1 | + `A.rpc`（SendRPCToServer） | 同上，且多一行 `[probe] A wrapped` |
| 2 | + `C.*`（ChatHistory） | 多 `[probe] C.listener install true` / `C.onsay wrapped` |
| 3 | + `D.chatinput`（ChatInputScreen） | 打开一次聊天框，出现 `[probe] D.screen` |
| 4 | + `B.thenet`（TheNet 代理） | 多 `[probe] B proxy installed` |
| 5 | + `C.chatqueue`（聊天队列） | 多 `[probe] C.chatqueue.wrapped` |

改法：

```lua
-- stage.lua
PROBE_STAGE = 0   -- 只改这个数字
```

日志在 `%USERPROFILE%\Documents\Klei\DoNotStarveTogether\client_log.txt`，搜 `[probe]`。**先只测 stage 0**：如果 stage 0 都进不去，说明问题不在钩子上（见下方"启动就闪退"）。

### 启动就闪退时先看这个

`client_log.txt` 的修改时间如果**没有变化**，说明游戏在写到日志之前就退出了——那时 DST 还没开始加载任何 Lua mod。此时：

1. 先确认这个 mod 是否**真的被启用**（Mods 菜单里勾选过）。没勾选过的本地 mod 根本不会执行，只会在扫描时读一下 `modinfo.lua`。
2. 把 `mods\probe_hooks` 整个移走再启动：仍然闪退 → 与本 mod 无关（查 Steam 验证文件、关掉 Steam++/加速器、显卡驱动）。
3. 能启动 → 再放回来，从 stage 0 开始一级级加。

---

## 一、挂了哪六处

| 标记 | 位置 | 能拿到什么 | 性质 |
| --- | --- | --- | --- |
| `A.rpc` | 包装全局 `SendRPCToServer`，只记 `rpc == RPC.Say` | 消息文本 + 第 2 个实参（疑似 whisper） | 发送侧，零侵入 |
| `B.thenet` | 把全局 `TheNet` 换成透传代理（默认开，**只进世界后装**） | `TheNet:Say(...)` / `TheNet:SendRPCToServer(Say,...)` 的实参 | 发送侧，侵入式，**第一次 Say 后自动还原** |
| `C.onsay` | 包装 `ChatHistory:OnSay`（参数不预设签名，按 `argc` 全量打印） | 服务端回包：guid/userid/name/prefab/message/whisper | 接收侧 |
| `C.listener` | 注册 `ChatHistory:AddChatHistoryListener` | `chat_message` 表：`sender_userid` / `message` / `whisper` / `localonly` | 接收侧，**首选** |
| `C.chatqueue` | 包装聊天队列 widget 的 `AddChatLine` | UI 层最终文本（兜底） | 接收侧 |
| `D.chatinput` | `ChatInputScreen` 每次构造时包装 `OnTextEntered`/`DoSend`/`SendChat`/`Close` | **发送前**的 `chat_edit` 原文 + `self.whisper` | UI 层 |

`C.onsay` 与 `C.listener` 的依据是 `chathistory` 页（build **714014**）给出的签名：

- `OnSay(guid, userid, netid, name, prefab, message, colour, whisper, isemote, user_vanity)`
- `AddToHistory(type, sender_userid, sender_netid, sender_name, message, colour, icondata, whisper, localonly, text_filter_context)`
- `AddChatHistoryListener(fn)`，`fn` 收到 `chat_message` 表

`A.rpc` 的依据是 `networkclientrpc` 页（build **722832**）：`SendRPCToServer` 是客户端→服务端的 Lua 通道，`TheNet` 负责实际发送。

---

## 二、安装

1. 目录名必须是 `probe_hooks`。本机**已经放好一份**：`E:\steam\steamapps\common\Don't Starve Together\mods\probe_hooks`；如果删掉了，把仓库里的 `tools/probe_hooks/` 整个复制过去即可（另一处候选路径：`%USERPROFILE%\Documents\Klei\DoNotStarveTogether\mods\probe_hooks`）。
2. 启动游戏 → **Mods** → 勾选 `Probe Hooks`（客户端 mod 列表里）。
3. （可选，开发期）在 `mods\modsettings.lua` 加一行 `ForceEnableMod("probe_hooks")`，好处是即使 mod 报错被自动禁用，下次启动仍会加载。
4. **测试期间不要同时开其它聊天类 mod**（它们也会包装同一批函数，会让"谁命中"变模糊）。

---

## 三、测试动作（5 条，一次做完）

进入世界、等 HUD 出现后，按顺序：

| # | 频道 | 输入 | 用来验证 |
| --- | --- | --- | --- |
| 1 | SAY（全局） | `ds: hi` | 主用例：能拿到原文 + 私聊标志 |
| 2 | SAY | `DS：hi`（**全角冒号**，中文输入法直接打） | 字节数口径 + 全角归一化必要性（plan §二 #7） |
| 3 | WHISPER | `ds: whisper-test` | 私聊标志是否可读（plan §二 #5、§八 3.5） |
| 4 | SAY | `hello` | 对照：普通消息不该"触发"，但接收侧仍会看到 |
| 5 | SAY | `ds: hi`（**间隔 > 2 秒**再发一次） | 同文本重复命中计数（plan §十 #12 的去重窗口取值） |

每条发完停 1 秒，全部发完后退出游戏。**5 条都要发**，缺一条就有一项判定没有数据。

---

## 四、看日志

位置：`%USERPROFILE%\Documents\Klei\DoNotStarveTogether\client_log.txt`（搜 `[probe]`）。

一条 `ds: hi` 正常情况下长这样（时间递增）：

```text
[probe] #021 t=128.412 D.chatinput OnTextEntered whisper=false text=[ds: hi](6B) argc=0
[probe] #022 t=128.430 A.rpc RPC.Say argc=2 a1=[ds: hi](6B) a2=false
[probe] #023 t=128.455 C.onsay argc=10 1=12345 2=KU_xxx 3=... 
[probe] #024 t=128.455 C.onsay.decoded is_self=true userid=KU_xxx name=[Wilson] prefab=wilson msg=[ds: hi](6B) whisper=false
[probe] #025 t=128.456 C.listener is_self=true userid=KU_xxx name=[Wilson] whisper=false localonly=false msg=[ds: hi](6B) keys=...
```

读法：

- **D 在最前**：输入框先拿到原文，然后才进发送。
- **A 在 D 之后**：这条聊天确实经过 Lua 的 `SendRPCToServer(RPC.Say)`。
- **A 不出现**：坐实 plan §二 #5 的风险——聊天没走 Lua 的 RPC 包装。
- **C 两条**：服务端已经把消息回显给自己，语义上正好满足"不吞消息"。
- `Text()` 打印的 `[原文](字节数)`：`ds: hi` 是 `(6B)`；全角 `DS：hi` 会是 `(7B)`（全角「：」占 3 字节，半角占 1）。**字节数对得上，说明拿到的就是原文，没有被词表过滤改写**（plan §十 #7）。
- 普通的 `hello` 也会产生 `C` 行（接收侧监听所有聊天，这是正常的）。**判定不看"有没有输出"，看 `is_self=true` 且 `msg` 就是自己发的那条。**
- 第 1 条和第 5 条是同一文本：应各产生 **1 条** `C.listener`（合计 2 条）。若其中一条出现 2 次以上，说明存在重复回显或历史重放，去重窗口要按实测调（plan §十 #12）。

---

## 五、判定表（照抄进 plan §4.1）

| 观察结果 | 结论 | 采用 |
| --- | --- | --- |
| `C.listener` 命中，且 `is_self=true`、`whisper=false` | 接收侧最稳，且天生满足"消息已发出" | **主用 `C.listener`**，`C.onsay` 作退路 |
| `A.rpc` 也命中 | 发送侧同样可达（最干净） | 可改 `A` 为主，`C.listener` 兜底 |
| `A.rpc` 不命中、`D.chatinput` 命中 | 聊天绕过 Lua RPC（`TheNet:Say` 直发） | 主用 `C.listener`，`D` 作发送前旁路 |
| `C.*` 全不命中 | `ChatHistory` 变了 | 退回 `D.chatinput`（发送前），并反馈日志 |
| 只有 `B.thenet` 命中 | 只能侵入式替换 `TheNet` | 下策，需评估稳定性后再定 |
| whisper 那条 `whisper=true` | 私聊标志一路可用 | plan 的 `whisper == false` 过滤可实现 |
| whisper 那条 `whisper` 为 nil/false | 标志不可信 | 改用"发送前 `D`"（`self.whisper`）判私聊 |

---

## 六、一键分析

```powershell
powershell -ExecutionPolicy Bypass -File .\analyze.ps1
powershell -ExecutionPolicy Bypass -File .\analyze.ps1 -LogPath "D:\path\to\client_log.txt"
```

输出六行命中次数 + 结论（接收侧/发送侧/UI 侧是否可用、能否识别自己、能否读到 whisper），再附最后 40 条 `[probe]` 原文。

> 脚本在仓库的 `tools/probe_hooks/` 里；`mods/probe_hooks/` 只放了 `modinfo.lua` + `modmain.lua` 两个游戏要读的文件。

> 这个脚本故意只用 ASCII：Windows PowerShell 5.1 读无 BOM 的 UTF-8 会按 ANSI 解析，中文文案会乱码；中文说明都放在本文件里。

---

## 七、收尾

- 测完把 `tools/probe_hooks` 从 `mods` 删掉（或取消勾选）。
- 把 `[probe]` 段落或 `analyze.ps1` 的输出贴回，结论回填 plan.md §4.1 / §八 第 0.5 步 / §十 的 1、2、3 条。

---

## 八、已知不确定（都设计成"从日志里读出来"，不靠猜）

- **方法签名随 build 变**：`C.onsay` 先打 `argc=` 与每个位置的 `type:value`，再按文档签名打一条 `decoded`；两者对不上就说明签名变了。`D.class` 会打印 `ChatInputScreen` 上所有含 Enter/Send/Say/Submit/Chat/Close 的方法名，方法被改名时能立刻看出来。
- **`ChatHistory` 可能晚于 mod 加载**：probe 在 mod 加载、进世界（`AddGamePostInit`）、角色生成（`AddPlayerPostInit`）三个时机各尝试安装一次，重复安装由 `__DS_PROBE` 幂等挡住。
- **`B` 的侵入性**：默认开启，但**只在进世界后安装**（主界面与联机列表不会碰到被替换的 `TheNet`），且**第一次 `Say` 调用返回后立刻换回真身**，暴露窗口只有一次调用。若聊天时游戏异常，把 Mod 配置里的 `TheNet:Say proxy (B)` 改成 `Off` 重测，`A/C/D` 不受影响。
- **`AddChatLine` 的类路径**：同时挂了 `widgets/redux/scrollablechatqueue` 与 `widgets/chatqueue`，命中哪个看日志；两条都没有也不影响主判定（`C.onsay`/`C.listener` 在更上游）。
