# Agent Notch 的 Codex 接入步骤

Codex 和 Claude Code 不同,有两道额外机制,导致新加的钩子不会立刻生效。装好后必须处理这两步,否则 Codex 永远不显示在刘海里。

## 1. 重载:Codex 只在启动时读一次 `hooks.json`

已经在跑的 Codex 会话用的是它启动那一刻的配置。改完 `hooks.json` 后必须让 Codex 重新启动:

- **CLI codex**:退出当前会话,重新 `codex`(新进程即重载)。
- **ChatGPT.app 里的 Codex**:完全退出 App(⌘Q)再打开。

## 2. 信任:Codex 会跳过"未信任"的钩子命令

Codex 有 hook 信任机制(对应 `--dangerously-bypass-hook-trust` 选项)。新加的钩子命令在被信任前会被**静默跳过**——这就是日志为空、刘海不显示的根因。

### 授予信任(推荐:交互式一次性确认)

启动交互式 `codex`,它检测到新钩子会弹出审阅/信任提示,确认即可持久保存:

```bash
codex
```

看到类似 "new hooks detected / trust these hooks?" 的提示时,确认信任 `notch-bridge.py`。

### 验证是否生效

1. 让 Codex 执行任意一个工具动作(例如"列出当前目录文件")。
2. 打开调试日志确认钩子被调用:

```bash
NOTCH_BRIDGE_DEBUG=1   # 需要在启动 Codex 的环境里设置
cat ~/.multiagent-notch/logs/codex.log
```

- 日志有内容 → 通了,Codex 会话应出现在刘海。
- 日志仍为空 → 信任没成功,或你用的 Codex 版本不执行命令钩子(改用 CLI codex)。

## 排查

| 现象 | 原因 | 处理 |
|---|---|---|
| 日志空 | 没重载 / 没信任 | 重启 Codex + 交互式确认信任 |
| 有日志但刘海不显示 | Agent Notch 没运行 | 启动 `/Applications/Agent Notch.app` |
| 权限按钮点了没反应 | 决策格式不被接受 | 见 README「PermissionRequest」一节 |
