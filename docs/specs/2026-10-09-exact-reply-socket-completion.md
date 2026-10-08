# 精确工具完成后的回复 socket 清理

## 已证问题

SessionStore 的有效 transcriptCompleted 会移除对应内存审批，但没有取消挂起的
回复连接；因此队列已推进，旧 Hook 客户端仍在等待。既有精确取消仅按
(sessionId, toolUseId) 删除，GCD 执行时若同键已登记新请求，旧取消会误关新连接。

先加入独立注入适配器和完成边界参数，保持原行为，用私有 AF_UNIX 服务复现。
5 项 PermissionRoutingTests 中本轮 2 项失败，共 3 个断言；日志
`/tmp/agent-notch-socket-completion-before.log`。
失败包括实际 EOF 读取超时及新请求无法收到 deny 响应，不是仅查看状态字典。

## 修改

- 只有经过既有时间戳仲裁、实际消费对应请求的日志完成事件才发出清理。
  先提交会话更新，再跨主线程调用；await 后不写回旧快照。
- 现有完成 Hook 的清理也带入规范化后的源事件时间，不再发送无边界取消。
- socket 队列在真正删除前、权限锁内比较当前请求时间和完成时间。
  比较使用既有 lifecycleObservedDate 的规范化规则；没有有效源时间的请求使用
  实际接收时间。比完成边界更新的请求保留，非有限完成时间拒绝。
- 目标仍是完整 session/tool 键，不取消同会话其他请求，不伪造 allow/deny。
  关闭旧客户端让其获得 EOF，后续请求仍经原响应机制处理。
- 主线程协议使用 HookPermissionCanceller 适配器；HookSocketServer 保持原 GCD
  队列和权限锁的隔离方式，避免协议推断把全部 socket 私有方法放到 MainActor。

nil 完成边界仍是内部显式无条件取消的兼容 API，不是外部 Hook 新字段。
SessionStore 本轮的两个生产精确完成路径都传明确时间；不修改审批预算、
FIFO、CLI 输入、全局配置、权限、文件发现或通知策略。

## 回归范围

新增 4 项测试（原有 3 项保持）：

1. 直接完成、完整历史、增量日志三个入口分别走独立真实 socket + 生产 Store：
   对应连接收到 EOF，队列仍保留下一项，下一客户端实际收到 deny。
2. 同 session/tool 键替换后，旧连接已 EOF；旧完成边界不会关新连接，
   新客户端实际收到正常响应。
3. 过旧与无时间戳完成均不能消费内存队列，也不能关连接，客户端仍可收响应。
4. 请求无源时间时，用接收时间保护新请求；非有限完成边界同样不关连接。

服务使用 UUID 私有 socket 路径，不连接真实 Agent 的 socket；Store 禁用持久化、
文件同步和外部生命周期全局副作用，注入自己的适配器及独立 parser 根目录。
新的 Store 夹具用 Claude 形状事件，避免创建 Codex 会话时访问实际标题索引。
测试服务端/客户端都在 teardown 关闭，未改变真实审批策略。

本地最终 Swift 全套 336 项通过、0 失败、0 跳过，含本轮 4 项新增回归。
日志 `/tmp/agent-notch-socket-completion-tests.log`，xcresult：
`/tmp/agent-notch-native-transport-build/Logs/Test/Test-ClaudeIsland-2026.10.09_07-11-18-+0800.xcresult`。
Bridge 88 项、permission verifier 30 项和发布闸门通过；日志
`/tmp/agent-notch-socket-completion-gate.log`。
最终 Release 无签名构建通过；日志 `/tmp/agent-notch-socket-completion-release.log`。
独立适配器避免本轮协议对 GCD 实现引入 MainActor 隔离警告；既有 tmux await
和 AppIntents 元数据提示仍在，不宣称整个项目零警告。

## 未验收边界

这证明私有服务的连接 EOF/保留和生产 Store 交付，不是实际 Agent Notch 安装版
或真实 CLI 审批重启验收。没有安装、重启、全屏、动画或通知的本轮验证。
本轮只读界面清单再次报告 Mac 锁屏，未绕过锁屏。
已完成工具没有对应内存审批项时，不主动推断某个未知 socket 应关闭。
同 ID、同源时间的不同执行无法凭时间区分；任意跨源时钟偏差也没有保证。
整个会话结束时的批量 cancelPendingPermissions 仍是独立边界，本轮不宣称
已解决该批量取消与下一回合并发到达的所有竞态。
