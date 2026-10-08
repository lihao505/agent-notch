# tmux 唯一目标与稳定面板身份

## 已证缺口

旧 Finder 对相同 cwd 的多个面板及多个进程祖先候选直接返回第一项。
聊天 transport 另有一套 TTY → PID → cwd 回退：已知进程找不到时，也可能命中
另一个使用同一项目目录的面板。这是源码和隔离用例证实的风险，未向真实 Agent
发送消息复现错发。修复前两项行为测试均失败，日志
`/tmp/agent-notch-tmux-routing-before.log`；未将测试编译错误计作行为复现。

按 session:window.pane 编号保存目标还有另一个边界：关闭前一面板后，剩余面板
可复用原编号。因此解析正确也不代表稍后使用旧编号仍指向同一个面板。

## 最小修改

- 保留既有 TmuxTargetFinder / ProcessExecutor / ProcessTreeBuilder，聊天发送复用
  同一个 Finder，删除重复的 TTY 解析代码。没有引入新依赖、轮询器或私有协议。
- 已知 PID 时只接受唯一的进程祖先匹配；失败不降级到 TTY 或 cwd。
  没有 PID、但有 TTY 时只接受唯一 TTY；失败同样不降级。
  两者均未知时保留唯一 cwd 的兼容路径，但目录匹配仍只是启发式，不是会话身份证明。
- 所有发现目标携带原生 `%pane_id`，操作参数使用此 ID，不再使用可复用的编号。
  仍保留 session/window/pane 元数据以及旧手工初始化入口，避免无关 API 重写。
- 链接窗口造成重复行时按物理 pane ID 去重；不同物理面板不因同目录而合并。
  畸形行、同 ID 的冲突元数据及非法 ID 使整个查询失败，避免部分解析产生假唯一。
- 使用制表符分列，保留普通空格；默认 runner 添加原生 `-u` 输出选项。
  直接命令的字节检查证实 `LC_ALL=C` 下制表符变为 `_`，`-u` 则保留 `09` 字节。
  不是 ProcessExecutor 修改了输出。包含分隔符的异常元数据仍保守拒绝，不宣称
  支持任意控制字符路径。

tmux 官方手册明确 pane ID 在其生命周期内不变，但唯一性范围是该服务器；
`-u` 可强制 UTF-8 输出。依据：[tmux 官方手册](https://man.openbsd.org/tmux.1)。
本轮不声称解决 server 重启后 ID 重用、跨 socket 路由或 PID 重用。

## 测试范围

新增 TmuxTargetFinderTests，覆盖歧义目录、歧义进程祖先、空格、链接窗口去重、
畸形/冲突行、TTY 唯一性、PID 失败不回退、PID 优先于旧 TTY、缺失 PID 的
保守回退、稳定 ID 校验及旧初始化兼容。

真实 tmux 3.7b 夹具使用 mktemp 独立目录、`-S` 私有 socket、`-f /dev/null`，
不修改用户配置、不操作默认服务器，不向真实 Agent 发送输入：

1. 独立会话创建两个运行 `/bin/sleep 60` 的面板，cwd 含中文与空格。
2. 相同 cwd 查询拒绝；真实 pane PID 和 TTY 查询得到对应稳定 ID。
3. 不存在的 PID 即使 TTY / cwd 有匹配也拒绝。
4. 关闭原夹具面板后，旧编号确实解析到剩余面板；旧稳定 ID 不解析到它，
   `select-pane` 对关闭的 ID 返回失败。
5. 关闭私有服务器后 `list-panes` 连接失败；defer 清理所属临时目录及遗留 socket。

夹具中的 display-message 对不存在的目标可能以 0 退出并输出空行，因此测试
同时使用真正操作面板的 select-pane 验证拒绝；不能把空行当作另一个面板。
tmux 退出后可能保留 socket 路径，服务器停止以连接失败而非路径消失判断。
最初夹具也修正了 test-host 的 /tmp 与 /private/tmp 归一化差异，使用物理 pwd。
这些夹具修正不计作产品业务缺陷。

若运行环境没有 tmux，真实夹具会明确 XCTSkip，不能把该环境的模拟测试结果
写成真实 tmux 验收。本机安装了 tmux，完整回归的跳过数需为 0。
CI 增加 tmux 依赖准备步骤，已有安装时复用；仅在 GitHub 临时 runner 安装，
不修改本机软件或用户服务，避免远端缺少 tmux 时静默跳过本轮真实夹具。

本机完整 xcresult：298 passed、0 failed、0 skipped。
路径 `/tmp/agent-notch-native-transport-build/Logs/Test/Test-ClaudeIsland-2026.10.09_03-55-36-+0800.xcresult`。
Bridge 88 项、审批检查器 30 项及发布闸门通过。
Release 无签名构建通过，日志 `/tmp/agent-notch-tmux-routing-release-build.log`。
这不等于签名、安装或实际界面验收。

## 发布与未验收边界

本轮不安装覆盖运行版，不改 Hook、全局审批策略、Codex/CodeBuddy CLI transport，
不向真实会话发消息。真实 Agent 发送、终端重新连接、焦点多客户端准确性、
全屏开关的所有触发入口和动画流畅度仍按原生命周期矩阵逐项验收。
稳定 ID 解决的是同一服务器生命周期内的编号复用；手工创建的旧目标没有 ID，
仍保留原兼容行为，不应被外推为稳定身份保证。
