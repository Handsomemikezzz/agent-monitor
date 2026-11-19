# agent-status 设计

在 macOS 菜单栏放一个状态灯，汇总 Claude Code 和 Codex 的会话状态。点击下拉菜单里的会话，可以跳回对应的应用。

| 颜色 | 含义 |
|---|---|
| 🟥 红 | 在等你的会话：权限审批、提问（AskUserQuestion）、计划确认 |
| 🟩 绿 | 已完成、你还没看的会话 |
| ⬜ 灰 | 其他会话（运行中或空闲） |

菜单栏并排显示三个圆角框，每个框里是对应的会话数，例如 `[2][1][0]`。徽标由 `src/render.swift` 画成 2x PNG（144 dpi），安装时编译一次，同一组数字只渲染一次并缓存在 `~/.agent-status/cache/`。没有 `swiftc` 时退回成单个彩色圆点加数字（优先级：红 > 绿 > 灰）。

## 设计原则

- **没有常驻监控进程，不轮询。** 只在 hook 触发时写一次文件，并通知菜单栏刷新。
- **采集和显示分开。** 两边通过一个状态目录交换数据。显示层可以从 SwiftBar 换成原生 App，hook 部分不用改。
- **hook 必须快，且不能影响会话。** 毫秒级完成，固定 `exit 0`，不往 stdout 输出任何内容（`PreToolUse` 之类的事件会把 stdout 当成返回给它的指令）。

## 架构

```
Claude Code hooks ─┐                                   ~/.agent-status/
                   ├─► bin/agent-status hook <tool> ─►   claude-<session_id>.json
Codex hooks ───────┘   (从 stdin 读事件 JSON，           codex-<session_id>.json
                        从环境变量读跳转信息)                    │
                                                               ▼
                                     菜单栏（SwiftBar 插件）读目录 → 汇总颜色 → 下拉列表
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
| Codex App 会话标识 | App 启动 codex 时设了 `CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_work_desktop` | ChatGPT.app 代码 |
| Codex hooks | `hooks` 已是 stable。CLI 0.169 支持 `SessionStart`、`UserPromptSubmit`、`PreToolUse`、`PermissionRequest`、`PostToolUse`、`Stop`、`Interrupt`、`SessionEnd`、`SubagentStop` | `codex features list`、二进制字符串 |
| Codex `notify` | 已被 Computer Use 占用，只能挂一个程序，**不使用** | `~/.codex/config.toml` |

## 2. 事件 → 状态

每个会话一个状态，取值 `running`、`waiting`、`done`。`running` 在菜单栏里算灰色。

| 状态 | Claude Code | Codex |
|---|---|---|
| running | `SessionStart`、`UserPromptSubmit`、`PostToolUse`（审批通过，清除红色） | `SessionStart`、`UserPromptSubmit`、`PostToolUse` |
| **waiting** | `PermissionRequest`；`PreToolUse` 匹配 `AskUserQuestion\|ExitPlanMode`；`Notification`（`permission_prompt`）作兜底 | `PermissionRequest` |
| **done** | `Stop` | `Stop`、`Interrupt` |
| 删除文件 | `SessionEnd` | `SessionEnd` |

- 不监听 `SubagentStop`，否则子任务结束时会提前变绿。
- Claude 的 `Notification` 里 `idle_prompt` 不处理（它表示空闲超过 60 秒，不是新事件）。

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
  "updated_at": 1763515200,
  "seen": false,
  "jump": { "kind": "url", "target": "claude://code/continue?session=local_8c1d…" }
}
```

`jump` 在 hook 里一次算好，显示层只负责执行：

| 来源 | 判定 | `jump` |
|---|---|---|
| Claude Desktop | `CLAUDE_CODE_HOST_SESSION_ID` 存在 | `url`：`claude://claude.ai/epitaxy/$CLAUDE_CODE_HOST_SESSION_ID` |
| Codex App | `CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_work_desktop` | `url`：`codex://threads/<session_id>` |
| 终端里的 CLI（两者都一样） | 以上都不满足 | `app`：根据 `TERM_PROGRAM` 激活对应终端（iTerm、Terminal、Ghostty、VS Code 等）。v2 再按 tty 精确定位到具体 tab |

## 4. 显示层（v1：SwiftBar 插件）

- `plugins/agent-status.1m.sh`：读目录，输出图标和下拉列表。文件名里的 `1m` 只是兜底刷新周期，平时由 hook 写完后调 `open -g "swiftbar://refreshplugin?name=agent-status"` 立即刷新。
- 下拉每行显示：`🟡 Claude · proj — 等待审批（3 分钟前）`。点击执行 `agent-status open`。
- `agent-status open`：执行 `jump`，同时把该会话标成 `seen=true`，绿色就会消失。红色不受影响，要等真正处理完才清除。
- 底部提供"全部标为已读"和"清理过期会话"两个菜单项。

**绿色在以下情况消失：** 在该会话里发下一条消息（`UserPromptSubmit`）；从菜单点进去；超过 TTL（默认 2 小时）。

以后想去掉 SwiftBar 依赖，可以写一个原生 Swift 小程序（`NSStatusItem` + `DispatchSource` 监听目录），继续读同一个状态目录。

## 5. 仓库结构

```
agent-status/
├── DESIGN.md
├── README.md                 # 安装与使用（英文，面向开源）
├── bin/
│   └── agent-status          # 单文件：hook / menu / open / install 子命令
├── plugins/
│   └── agent-status.1m.sh    # SwiftBar 插件
├── install.sh                # 合并写入 ~/.claude/settings.json 和 ~/.codex/hooks.json（先备份，保证重复运行结果不变）
└── uninstall.sh
```

核心是一个只用标准库的 Python 脚本 `bin/agent-status`，用系统自带的 `/usr/bin/python3` 运行。hook、菜单、跳转、安装都是它的子命令，不依赖 `jq`。

## 6. 实测结果（2026-11-19）

1. ✅ Desktop 会触发 `PermissionRequest`。一次 AskUserQuestion 依次触发：`PreToolUse` → `PermissionRequest`（tool_name 也是 AskUserQuestion）→ `Notification(permission_prompt)` → 回答后触发 `PostToolUse`。所以 `PermissionRequest` 遇到提问类工具时要记成"提问"，不能记成"审批"。修改 `settings.json` 后，正在运行的 Desktop 会话会实时加载新 hook。
2. ✅ Codex hook 收到的 `session_id`（UUIDv7）就是 threadId。`codex://threads/<id>` 能让 Codex App 切到对应会话。
3. ✅ Codex 不会为新 hook 主动弹出信任提示。`hooks/list` 能看到所有 hook，状态是 `untrusted`。`agent-status trust-codex` 用的接口和 Codex App 的 Settings → Hooks 页面一样（`codex app-server` 的 `config/batchWrite` 写入 `hooks.state."<key>".trusted_hash`），必须在终端里由用户输入 `y` 确认。信任后，`codex exec` 依次触发 `SessionStart → UserPromptSubmit → Stop → SessionEnd`；交互界面里遇到审批会触发 `PermissionRequest`（tool_name 是 `Bash`），按 Ctrl-C 拒绝审批会触发 `Interrupt`。
4. ✅ 两种 Claude 链接都能在两个会话之间来回跳转（用 `get_window_layout` 确认过当前显示的是哪个会话）。
5. ✅ SwiftBar 2.1.1 在菜单栏里不认单独的 `sfcolor`，要用 base64 编码的 `sfconfig`（`renderingMode: Palette`）才能显示颜色。
6. ✅ 深链接会把 App 切到对应会话，但如果你正在用别的 App，它的窗口不会到最前面，`open -b` 也拉不上来。所以点击后再用 AppleScript 的 `tell application id … to activate` 激活一次，这样可以。
7. ✅ 子进程会继承 `CLAUDE_CODE_HOST_SESSION_ID`（比如在 Desktop 会话里启动的 codex 或 claude）。所以只有 `CLAUDE_CODE_ENTRYPOINT=claude-desktop` 时才生成 Desktop 会话的跳转链接。
8. ⏳ Codex App 里真实会话的 hook 环境变量（`CODEX_INTERNAL_ORIGINATOR_OVERRIDE`）还没见到实际值，是根据 App 代码推断的。下次在 App 里用 Codex 时，打开 `.debug` 就能确认。如果推断不对，会退回用 `__CFBundleIdentifier` 激活 Codex App，不会跳到具体会话。

## 7. 已知限制

- 在 Claude 里按 Esc 中断不会触发 `Stop`，状态会停在 running，直到下一条消息或 TTL 到期。Codex 有 `Interrupt` 事件，不受影响。
- 审批被拒绝时不会触发 `PostToolUse`。Codex 会触发 `Interrupt`，状态回到灰色；Claude 这边红色会一直保留，直到 `Stop` 或下一条消息。
- 深链接属于两个应用的内部接口，没有公开文档，升级后可能失效。所以 `agent-status open` 在链接打不开时，至少要把对应应用切到前台。
