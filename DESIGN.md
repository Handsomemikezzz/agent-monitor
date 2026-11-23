# agent-status 设计

在 macOS 菜单栏放一个状态灯，汇总 Claude Code、Codex 和 Antigravity 的会话状态。点击下拉菜单里的会话，可以跳回对应的应用。

| 颜色 | 含义 |
|---|---|
| 🟨 黄 | 在等你的会话：权限审批、提问（AskUserQuestion）、计划确认 |
| 🟩 绿 | 运行中 |
| 🟦 蓝 | 已完成、你还没看 |

已完成且看过的、被中断的会话不显示。

**状态只来自会话本身，不用计时器判断。** 运行再久也是运行中，没看的完成再久也是未读，直到会话真的变了（新事件、对话记录、你在 App 里点开、归档）。唯一的时间限制是记录清理：不显示的记录（已读、中断、已关闭），会话超过 24 小时没有活动就删掉；扫描"还没有记录的会话"也只看最近 24 小时。

菜单栏里是一个连在一起的圆角色块，分成黄、绿、蓝三段，每段里写着对应的会话数。点开是一个面板，详见第 4 节。截图见 README。

## 设计原则

- **没有常驻监控进程。** hook 触发时写一次文件，并通知菜单栏立即刷新。每次刷新时再读一下应用自己的记录来校正（见第 2 节末尾），只读最近活跃的会话。
- **采集和显示分开。** 两边通过一个状态目录交换数据。显示层从 SwiftBar 插件换成原生 App 时，hook 部分一行没改。
- **hook 必须快，且不能影响会话。** 毫秒级完成，固定 `exit 0`，不往 stdout 输出任何内容（`PreToolUse` 之类的事件会把 stdout 当成返回给它的指令）。

## 架构

```
Claude Code hooks ─┐                                       ~/.agent-status/
Codex hooks ───────┼─► bin/agent-status hook <agent> ─►     <agent>-<session_id>.json
Antigravity hooks ─┘   (适配器把事件翻译成通用事件，            │
                        再交给同一个状态机)                     │
                                                               ▼
                                     菜单栏 App 监听目录 → agent-status status → 徽标 + 面板
                                                               │ 点击
                                                               ▼
                                     bin/agent-status open <key>  → open 深链接 / 激活终端
```

## 1. 已确认的环境事实

以下来自对本机已安装版本的检查，日期 2026-11-19。

| 项目 | 结论 | 来源 |
|---|---|---|
| Claude Desktop 会跑用户级 hooks | ✅ 它启动 CLI 时带 `--setting-sources=user,project,local` | 进程参数 |
| Desktop 会话 ID | hook 进程能拿到环境变量 `CLAUDE_CODE_HOST_SESSION_ID=local_<uuid>`，`CLAUDE_CODE_ENTRYPOINT=claude-desktop` | 会话环境 |
| Claude 跳转链接 | `claude://claude.ai/epitaxy/local_<uuid>`（App 自己对外给的就是这种链接）。另一种 `claude://code/continue?session=local_<uuid>` 也能用，但受 App 的"入口"设置控制。两种都要 `local_` 格式的 ID，不能用 CLI 的 UUID | Claude.app URL 处理代码；已实测在两个会话之间跳转 |
| Codex App | `/Applications/ChatGPT.app`，bundle id 是 `com.openai.codex`，注册了 `codex://` | Info.plist |
| Codex 跳转链接 | `codex://threads/<threadId>` | ChatGPT.app 代码 |
| Codex App 会话标识 | App 里会话的 hook 环境变量 `CODEX_INTERNAL_ORIGINATOR_OVERRIDE=Codex Desktop` | 实测（debug.log） |
| Codex App 内部会话 | App 会自己开一些很短的后台会话（提示词是 `# Overview` 的概要、"You are an expert at upholding safety…" 的安全审查），同样触发 hook、环境变量也一样，但 `transcript_path` 是 null，不在 `threads` 表里，用 `codex://threads/<id>` 打开会显示"Chat unavailable on this computer"。你自己的会话从第一个事件起就带 `transcript_path` | 实测（debug.log、state_5.sqlite） |
| Codex hooks | `hooks` 已是 stable。CLI 0.169 支持 `SessionStart`、`UserPromptSubmit`、`PreToolUse`、`PermissionRequest`、`PostToolUse`、`Stop`、`Interrupt`、`SessionEnd`、`SubagentStop` | `codex features list`、二进制字符串 |
| Codex `notify` | 已被 Computer Use 占用，只能挂一个程序，**不使用** | `~/.codex/config.toml` |

## 2. 事件 → 状态

每个会话一个状态：`running`、`waiting`、`done`、`idle`。`done` 再按 `seen` 分成未读（蓝色）和已读（不显示）；`idle`（中断、长时间没动静）也不显示。

| 状态 | Claude Code | Codex |
|---|---|---|
| running | `UserPromptSubmit`；`PostToolUse`（审批通过，清除黄色） | `UserPromptSubmit`、`PostToolUse` |
| **waiting** | `PermissionRequest`；`PreToolUse` 匹配 `AskUserQuestion\|ExitPlanMode`；`Notification`（`permission_prompt`）作兜底 | `PermissionRequest` |
| **done** | `Stop` | `Stop` |
| idle | 对话记录里出现 `[Request interrupted by user`（Esc、拒绝审批） | `Interrupt` |
| 隐藏 | 终端会话：`SessionEnd`；Desktop 会话：归档 | 终端会话：`SessionEnd`；App 会话：归档 |

- `SessionStart` 不改变状态。Desktop 恢复旧会话、上下文压缩时都会触发它，并不代表开始了新一轮。
- 不监听 `SubagentStop`，否则子任务结束时会提前变色。
- Claude 的 `Notification` 里 `idle_prompt` 不处理（它表示空闲超过 60 秒，不是新事件）。
- `SessionEnd` 后记录保留但隐藏，免得下面的扫描又把它找回来。
- Codex 事件没有 `transcript_path` 的直接忽略（App 的内部会话）。有对话记录的，再看 rollout 第一行 `session_meta`：`thread_source` 不是 `user`、或 `source` 里有 `subagent` 的是子代理线程，隐藏。
- Claude Desktop 和 Codex App 每次退出都会给所有会话发 `SessionEnd`，重新打开某个会话时发 `SessionStart(resume)`。所以对 App 会话（`jump` 是深链接的）忽略 `SessionEnd`，以归档为准。没见过的会话收到 `SessionStart` 时，状态从对话记录里读，不默认成空闲。

### 用应用自己的记录校正

只靠 hook 会漏掉三类情况：Esc 中断、拒绝审批（都不发 hook）、安装前就开着且之后没触发过 hook 的会话。所以菜单每次刷新时，对最近活跃的会话再读三样东西：

| 来源 | 读什么 | 用来做什么 |
|---|---|---|
| 对话记录末尾（Claude：`~/.claude/projects/*/<id>.jsonl`；Codex：`rollout-*.jsonl`，路径来自 hook 的 `transcript_path` 或 Codex 数据库） | 最后一轮的结果：结束（`stop_reason: end_turn`、`stop_hook_summary` / `task_complete`）、中断（`[Request interrupted by user` / `turn_aborted`）、还在跑 | 对话记录比最近一次 hook 新（多于 2 秒）时，以对话记录为准。审批和提问只认 hook |
| Claude Desktop 的会话文件 `~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json` | `cliSessionId`、`title`、`isArchived`、`lastFocusedAt` | 发现会话、显示真实标题、隐藏归档；完成后又点开过（`lastFocusedAt` ≥ 完成时间）算已读 |
| Claude Desktop 的 Local Storage（`Local Storage/leveldb` 里的 `epitaxy-unread-v1`） | 侧边栏的未读标记 `unreadIds` | 我们没看着它完成的会话（重新打开的旧对话、扫描发现的会话），以 Desktop 自己的未读标记为准 |
| Claude Code 的会话登记 `~/.claude/sessions/<pid>.json` | 每个运行中进程的 `sessionId` 和 `pid`，进程在文件就在 | 终端会话的进程没了就算结束（隐藏），即使没收到 `SessionEnd` |
| Codex 数据库 `~/.codex/state_*.sqlite`（只读） | `threads` 的标题、`archived`、`originator`；`thread_read_receipts.first_unread_turn` | 发现会话、显示标题、隐藏归档；`originator = Codex Desktop` 时生成 `codex://threads/<id>`；未读标记直接用 App 自己的 |

一轮结束算不算未读：只有我们看着这一轮在跑（之前是运行中或等你处理），或者 App 自己把它标成未读，才算未读。只从对话记录里发现的结束（比如在 Desktop 里重新打开一个旧对话，它会发 `SessionStart(resume)`），默认已读。

Codex 的终端会话：hook 触发时记下执行它的 `codex` 进程（pid 和启动时间），进程不在了就算结束。

面板按每个会话进入当前状态的时间排序（`since`），而不是最近一次事件的时间。运行中的会话每次调用工具都会更新，按事件时间排的话，它在列表里会不停换位置，点击时鼠标下面的那一行可能已经换了，点了没反应。

另外，Stop 触发时如果 Claude Desktop 在最前面，而且这个会话是最近一次点开的那个（也就是你正看着它完成），直接记为已读。

Desktop 和 Codex App 退出时会给会话发 `SessionEnd`。会话本身保留，但进程已经没了，所以如果当时是运行中或等你处理，改成 idle（这一轮结束了）；已完成的不变。

## 3. 状态文件

`~/.agent-status/<tool>-<session_id>.json`，先写 `.tmp` 再 `mv`，保证原子：

```json
{
  "tool": "claude",
  "session_id": "3f2a…",
  "state": "waiting",
  "reason": "permission",
  "cwd": "/Users/me/proj",
  "title": "proj",
  "name": "Desktop 或 Codex 里的会话标题",
  "transcript": "/Users/me/.claude/projects/-Users-me-proj/3f2a….jsonl",
  "updated_at": 1763515200,
  "seen": false,
  "jump": { "kind": "url", "target": "claude://code/continue?session=local_8c1d…" }
}
```

`jump` 在 hook 里一次算好，显示层只负责执行：

| 来源 | 判定 | `jump` |
|---|---|---|
| Claude Desktop | `CLAUDE_CODE_HOST_SESSION_ID` 存在 | `url`：`claude://claude.ai/epitaxy/$CLAUDE_CODE_HOST_SESSION_ID` |
| Codex App | `CODEX_INTERNAL_ORIGINATOR_OVERRIDE` 以 `desktop` 结尾（不分大小写，实测值 `Codex Desktop`），或数据库里 `originator = Codex Desktop` | `url`：`codex://threads/<session_id>` |
| 终端里的 CLI（两者都一样） | 以上都不满足 | `app`：根据 `TERM_PROGRAM` 激活对应终端（iTerm、Terminal、Ghostty、VS Code 等）。v2 再按 tty 精确定位到具体 tab |

## 4. 显示层：原生菜单栏 App

`app/main.swift`，单文件 SwiftUI + AppKit，`install` 时用 `swiftc` 编译成 `build/Agent Status.app`（`LSUIElement`，没有 Dock 图标），用 LaunchAgent `io.github.agent-status` 登录时启动。第一版用的是 SwiftBar 插件，但 SwiftBar 的下拉菜单是系统 NSMenu，只能一行行文字，做不出卡片、分段控件这类面板，所以换成了自己的 App。

- **只负责画。** 状态逻辑全在 `bin/agent-status`，App 运行 `agent-status status` 拿 JSON（各类数量 + 要显示的会话），点击时运行 `agent-status open <key>` / `seen-all`。
- **什么时候刷新：** 用 `DispatchSource` 监听状态目录，hook 写完文件就立即刷新；打开面板时刷新；徽标上有会话时每 30 秒刷新一次（让第 2 节的校正能跟上 Esc、拒绝审批、在 App 里点开这类不发 hook 的变化），没有会话时不做任何定时刷新。一次刷新大约 0.1 秒 CPU。正在跑时又来的刷新请求合并成一次。
- **徽标：** 一个圆角胶囊，分成黄 / 绿 / 蓝三段实心色块，数字写在色块里（黄底用深色字，绿、蓝底用白字），三段一直显示；数量为 0 的那段颜色变淡，突出有会话的段。用 AppKit 按屏幕倍率直接画，颜色固定，在深浅两种菜单栏里都醒目。
- **面板：** 三个状态块（等你处理、运行中、已完成未读），点一下只看这一类，再点取消；全部 / Claude / Codex 分段筛选，带各自的会话数；按"等你处理 → 已完成未读 → 运行中"分组的会话行，每行显示应用图标、标题、状态、多久以前、最后一条提示词，点击跳回；底部是"全部已读"（有未读时才出现）、"打开状态目录"和"退出"。会话超过 6 个时列表可滚动。截图见 `docs/images/panel.png`。
- 面板语言跟随系统（中文或英文）。
- `AGENT_STATUS_OPEN_PANEL=1` 启动时会自动打开面板并打印窗口号，方便用 `screencapture -l` 截图。

`agent-status open`：执行 `jump`，同时把该会话标成 `seen=true`，蓝色就从徽标上消失。黄色不受影响，要等真正处理完才清除。

**蓝色消失的情况：** 在该会话里发下一条消息（`UserPromptSubmit`）；从面板点进去；在 App 里点开它。不会因为时间到了自动消失。

## 5. 适配器：怎么接入一个新的 agent

`bin/agent-status` 里每个 agent 一个 `Agent` 子类，登记在 `AGENTS`。状态机只有一份（`next_state`），只认通用事件：

| 通用事件 | 含义 | 状态 |
|---|---|---|
| `start` | 会话开始或恢复，本身不代表新一轮 | 不变（新会话由对话记录决定） |
| `prompt` / `working` | 发了消息 / 模型在干活 | 运行中 |
| `wait` | 要你审批、回答、确认计划（`reason` 区分） | 等你处理 |
| `wait_hint` | 较弱的"等你"信号，只在没有更好信号时用 | 等你处理 |
| `tool_done` | 工具结束（审批或提问已回应） | 运行中 |
| `turn_done` | 一轮结束 | 已完成未读 |
| `interrupt` | 被中断 | 不显示 |
| `end` | 会话关闭 | 隐藏 |

一个适配器提供：

- `translate(event, data)`：把它的 hook 事件翻译成上面的通用事件，带上会话 ID、目录、对话记录路径、提示词。返回 `None` 表示忽略（比如 Codex App 的内部会话）。
- `jump`：怎么跳回去。有对话级链接用链接，否则激活 App 或启动它的终端。
- `turn(path)`：读对话记录末尾，判断最后一轮是结束、中断、等待还是在跑。
- `scan`：读它自己的本地记录，补标题、归档、子代理、"你上次查看的时间"或已读标记。
- `on_screen`：一轮结束时，你是不是正看着它（是就直接算已读）。
- `hook_output`：有些 agent 要从钩子的 stdout 读决定，这里给出"照常继续"的答复。
- `install` / `uninstall`：写入、移除它的钩子配置。

菜单栏 App 不认识具体的 agent：`status` 输出里每个会话带 `app`（显示名）和 `bundle`（图标用），筛选栏按实际出现的 agent 生成。

### Antigravity（实验性）

- 钩子配置：`~/.gemini/config/hooks.json`，格式和 Claude 不同（顶层是"钩子名 → 事件"）。我们写在 `agent-status` 这个名字下，不动别的条目。
- 钩子由后台的 `agy --hub` 进程执行，它只在启动时读配置。只退出 App 不够，要结束 `agy --hub` 进程（或重新登录）才会生效。
- 事件：`SessionStart`、`PreInvocation`（模型开始工作，算运行中，没有"提交提示词"事件）、`PostInvocation`、`PreToolUse`、`PostToolUse`、`Stop`。payload 是 camelCase：`conversationId`、`cwd`、`workspacePaths`、`transcriptPath`、`lastUserInput`、`hookEventName`，环境变量里还有 `ANTIGRAVITY_CONVERSATION_ID`（`cwd`、`hookEventName` 和这个环境变量文档里没写，实测有）。
- `PreToolUse` 和 `Stop` 必须在 stdout 给出 `decision`。我们一律答 `allow`，`PreToolUse` 只挂在 `ask_question|ask_permission` 上，不碰其他命令的审批。
- 对话记录：`<数据目录>/brain/<id>/.system_generated/logs/transcript_full.jsonl`（文档写的是 `transcript.jsonl`，实测 hook 给的是 `_full`，格式一样），每行一步，有 `type`、`status`、`created_at`。最后一步是不带 `tool_calls` 的 `PLANNER_RESPONSE` 就是结束；状态 `WAITING` 当作等你处理（还没在真实会话里见到）。
- 标题和子代理：`<数据目录>/conversation_summaries.db` 的 `conversation_summaries` 表（`title`、`nesting_depth`）。
- 已读：`<数据目录>/annotations/<id>.pbtxt` 里的 `last_user_view_time`。
- 跳转：注册了 `antigravity://`，但没有已知的对话级链接，只能把 App 切到前台。
- 数据目录：App 是 `~/.gemini/antigravity`，IDE 是 `~/.gemini/antigravity-ide`，CLI 是 `~/.gemini/antigravity-cli`。

## 6. 仓库结构

```
agent-status/
├── DESIGN.md
├── README.md                 # 安装与使用（英文，面向开源）
├── bin/
│   └── agent-status          # 单文件 Python：适配器、状态机，以及 hook / status / open / install 等子命令
├── app/
│   ├── main.swift            # 菜单栏 App
│   └── Info.plist
├── tests/
│   └── test_states.py        # 状态切换测试（假事件 + 假对话记录）
├── docs/images/              # README 里的截图
├── install.sh                # 写入 hooks、编译并启动 App（先备份，可重复运行）
└── uninstall.sh
```

核心是一个只用标准库的 Python 脚本 `bin/agent-status`，用系统自带的 `/usr/bin/python3` 运行。hook、状态计算、跳转、安装都是它的子命令，不依赖 `jq`。

## 7. 实测结果（2026-11-19）

1. ✅ Desktop 会触发 `PermissionRequest`。一次 AskUserQuestion 依次触发：`PreToolUse` → `PermissionRequest`（tool_name 也是 AskUserQuestion）→ `Notification(permission_prompt)` → 回答后触发 `PostToolUse`。所以 `PermissionRequest` 遇到提问类工具时要记成"提问"，不能记成"审批"。修改 `settings.json` 后，正在运行的 Desktop 会话会实时加载新 hook。
2. ✅ Codex hook 收到的 `session_id`（UUIDv7）就是 threadId。`codex://threads/<id>` 能让 Codex App 切到对应会话。
3. ✅ Codex 不会为新 hook 主动弹出信任提示。`hooks/list` 能看到所有 hook，状态是 `untrusted`。`agent-status trust-codex` 用的接口和 Codex App 的 Settings → Hooks 页面一样（`codex app-server` 的 `config/batchWrite` 写入 `hooks.state."<key>".trusted_hash`），必须在终端里由用户输入 `y` 确认。信任后，`codex exec` 依次触发 `SessionStart → UserPromptSubmit → Stop → SessionEnd`；交互界面里遇到审批会触发 `PermissionRequest`（tool_name 是 `Bash`），按 Ctrl-C 拒绝审批会触发 `Interrupt`。
4. ✅ 两种 Claude 链接都能在两个会话之间来回跳转（用 `get_window_layout` 确认过当前显示的是哪个会话）。
5. ✅（已不再使用 SwiftBar）SwiftBar 2.1.1 在菜单栏里不认单独的 `sfcolor`，要用 base64 编码的 `sfconfig`；下拉菜单里的 `sfimage` 圆点只能是黑色。
6. ✅ 深链接会把 App 切到对应会话，但如果你正在用别的 App，它的窗口不会到最前面，`open -b` 也拉不上来。所以点击后再用 AppleScript 的 `tell application id … to activate` 激活一次，这样可以。
7. ✅ 子进程会继承 `CLAUDE_CODE_HOST_SESSION_ID`（比如在 Desktop 会话里启动的 codex 或 claude）。所以只有 `CLAUDE_CODE_ENTRYPOINT=claude-desktop` 时才生成 Desktop 会话的跳转链接。
8. ✅ Codex App 里真实会话的 hook 环境变量是 `CODEX_INTERNAL_ORIGINATOR_OVERRIDE=Codex Desktop`（和从 App 代码里推断的 `codex_work_desktop` 不一样），判断时不区分大小写。App 退出时会给会话发 `SessionEnd(other)`；Claude Desktop 重启时也一样，重新打开会话时再发 `SessionStart(resume)`。

## 8. 已知限制

- Claude 里按 Esc 中断、拒绝审批都不发 hook，要等下次刷新读到对话记录才从徽标上消失，最多 30 秒（打开面板时会立即刷新）。
- 终端会话的进程没了会自动结束，目前支持 Claude Code 和 Codex；Antigravity CLI 还不行。
- 如果你一直看着某个 Desktop 会话、但 Desktop 不在最前面时它完成了，会记成未读，直到你切走再切回来、在面板里点它或发下一条消息。
- Desktop 会话文件和未读标记、Claude Code 的会话登记、对话记录格式、Codex 数据库表结构都是应用内部的东西，升级后可能变化。读不到时只是少了校正，hook 那部分照常工作。
- App 是本机编译、ad-hoc 签名的，不经过公证，所以只能用 `install.sh` 在本机构建，不能直接分发 .app。
- 深链接属于两个应用的内部接口，没有公开文档，升级后可能失效。所以 `agent-status open` 在链接打不开时，至少要把对应应用切到前台。
