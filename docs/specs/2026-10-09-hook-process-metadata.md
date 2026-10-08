# Hook 进程与终端元数据的部分更新

## 已证缺口

ProcessTreeBuilder 已有 400 ms 拓扑缓存和 500 ms cwd 缓存，SessionStore 的 Hook
路径也已只在新会话 / PID / TTY 变化时查询；本轮没有把已有缓存说成新实现。
但以下边界仍未满足：

- HookEvent 的 PID 是可选字段，当前事件未提供时，旧逻辑直接把已知 PID 清空。
  之后相同 PID 再出现，会被误当作进程变化并再次查询拓扑。
- TTY 变化会触发查询，但 forceRefresh 没包含 ttyChanged，可能仍获得旧快照。
  TTY 变化的事件如果同时没有 PID，旧路径根本不查询。
- 明确的新 PID 未附带 TTY 时，会话仍保留旧终端。tmux transport 先按 TTY 定位，
  所以该残留值不只是显示问题，而是错误终端定位风险。

这些是源码与隔离事件序列已证问题，不是实际终端错发消息的实机复现。

## 最小修改

仅修改 SessionStore 的当前 Hook 元数据更新路径：

1. 缺失 PID 是部分更新，保留已知 PID；仍未知的新会话保持未知。
2. 新会话或明确 PID / TTY 变化时，按已知 PID 强制刷新拓扑。
3. 新 PID 缺少 TTY 时，只取新拓扑中该 PID 的 TTY，找不到则清空旧 TTY。
   初次出现的 PID 缺少 TTY 时也使用同一规则。
4. 不改变旧 Hook 的生命周期排序：未被接受的旧事件不能替换元数据或触发查询。
5. 相同 PID / TTY 的常规事件不查询；不把 TTL 缓存或生命周期状态当成进程身份。

Hook 查询通过可注入的同步 provider 调用既有 ProcessTreeBuilder，生产默认实现不变。
恢复持久化 / 桥接快照的查询路径没有改造，不引入新缓存、计时器、线程或依赖。
不修改 Hook 协议、发送 transport、审批策略、全局配置或页面布局。
本轮不是对 ps/lsof 全局异步调度、缓存并发合并或 PID 重用防护的完整证明。

## 回归与性能边界

新增 SessionStoreProcessMetadataTests，provider 模拟短时缓存并记录是否强制刷新，
不读取用户进程表、不发送真实终端消息、不触碰生产 socket。

- 缺失 PID 后仍保留 PID / TTY / tmux；随后 9 次同 PID / TTY 事件不新增查询。
  整个序列只查询一次，修复前查询两次且 PID 曾丢失。
- 同 PID 改 TTY，分别覆盖事件带 PID / 不带 PID：立即强制刷新，并更新 tmux 判断。
- 新 PID 无 TTY，分别覆盖新进程记录存在 / 拓扑缺失：使用新 TTY / 清空旧 TTY。
- 迟到旧 Hook 不替换 PID / TTY，不触发拓扑查询。

修复前 4 项测试中 3 项行为失败，共 9 个断言失败；旧 Hook 保护测试通过。
最初测试文件的 ProcessInfo 与 Foundation 同名导致编译错误，限定应用模块名后
才得到上述行为复现，未把编译错误当作业务缺陷证据。
失败日志 `/tmp/agent-notch-process-metadata-before.log`。

修复后完整 xcresult：287 passed、0 failed、0 skipped。
路径 `/tmp/agent-notch-native-transport-build/Logs/Test/Test-ClaudeIsland-2026.10.09_03-33-24-+0800.xcresult`。
Bridge 88 项、审批检查器 30 项及发布闸门通过；Release 无签名构建通过，
日志 `/tmp/agent-notch-process-metadata-release-build.log`。

以上查询次数来自生产 SessionStore 入口与隔离 provider；没有测量真实 CPU、
ps/lsof 耗时或刘海帧率，不宣称完成性能基准或所有终端定位准确率验收。
本轮未安装，实际运行版与源码分开判断；真实 PID / TTY 变化、tmux 重连、
多终端发送以及原生命周期矩阵的待执行场景仍需实机验证。
