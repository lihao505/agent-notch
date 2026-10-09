# 会话批量清理的终止边界

## 已证问题

精确工具完成已带时间边界，但 Stop / 中断 / 退出 / 会话移除仍直接按 sessionId
关闭全部回复连接。若网络层已登记下一回合请求，而 Store 仍在处理旧回合终止，
该新连接会被误关。重复 Stop / 空闲完成通知也可能把清理范围向后扩大。

先让既有适配器支持隔离批量调用和边界参数，保持原无条件行为。
11 项 PermissionRoutingTests 中本轮 4 项失败，共 15 个断言失败；日志
`/tmp/agent-notch-batch-socket-before.log`。失败为新请求响应丢失及本地边界未捕获，
不是编译错误、socket 过期或真实用户审批操作。
提交前一次完整回归的唯一失败是日期夹具精度：预期 Date 没有经过 Hook 的数值秒
往返转换，而实际值已转换。预期改为同一编码往返，仍精确相等、不扩大容差；
这不计入产品修复，连接关闭/保留断言在该次运行已通过。
该次 xcresult 为
`/tmp/agent-notch-native-transport-build/Logs/Test/Test-ClaudeIsland-2026.10.09_07-56-45-+0800.xcresult`。

## 修改

- socket 层复用精确清理的边界判定：在 GCD 队列、权限锁内读取当前请求，
  仅关闭该 session 下请求时间不晚于终止边界的连接。
- 有限时间、源时间规范化及缺失时间使用接收时间的规则与精确清理一致。
  同会话新请求、其他会话均不因旧清理而关闭；不生成 allow/deny。
- Store 所有 7 个批量调用点都明确带时间，不再向生产批量路径传 nil：
  Hook 移除/ended/忽略探针用规范化源时间，中断用已接受中断时间，实际进程退出
  用已接受退出时间；本地 sessionEnded 在修改状态和跨 actor 等待前捕获 Date。
- 正常完成及重复 Stop / 空闲通知使用首次 completedAt（缺少时才用当前已接受
  完成时间），不把重复通知的较晚时间当作新回合的关闭依据。
- 仍先提交/移除内存状态，再交付外部清理。监听器继续读取最新会话状态并复核，
  不在 await 后把旧 SessionState 写回来。没有改生命周期 reducer 的接受规则。

nil 仍是 socket 服务内部显式无条件清理的兼容入口；服务整体停止也仍关闭自身
全部连接。没有新增外部协议字段、审批策略、延时、轮询、线程、全局配置或 UI 修改。

## 回归范围

新增 4 项用例，包含独立 AF_UNIX 服务与生产 Store：

1. 混合批次：两项旧请求 EOF，同会话新请求和另一会话的同工具 ID 实际收到响应。
2. Stop、中断、进程退出、SessionEnd 四个已接受终止入口：旧请求 EOF，已登记的
   更新原始请求仍可收响应。退出用假的匹配 PID 和注入空进程树，不是实际杀进程。
3. 重复 Stop：首次完成时间保持，新原始请求不因较晚重复通知而断开。
4. 本地结束：适配器暂存批量调用，断言时间捕获于调用前后之间；随后真实登记
   新连接、同 ID Store 会话重建，再交付旧清理。旧连接 EOF，新审批队列及新连接保留。

服务使用 UUID 私有路径。Store 禁用持久化、文件同步和全局副作用，使用注入
适配器、独立 parser 根目录、Claude 形状事件及空进程树；不连接真实 Agent socket。
其他既有精确身份、缺失时间、无效边界、跨会话以及精确清理回归同时保留。

最终完整 Swift 回归 340 项通过、0 失败、0 跳过，含本轮 4 项新增测试。
日志 `/tmp/agent-notch-batch-socket-tests.log`，xcresult：
`/tmp/agent-notch-native-transport-build/Logs/Test/Test-ClaudeIsland-2026.10.09_07-58-00-+0800.xcresult`。
Bridge 88 项、permission verifier 30 项及发布闸门通过，日志
`/tmp/agent-notch-batch-socket-gate.log`。
最终 Release 无签名构建通过，日志 `/tmp/agent-notch-batch-socket-release.log`。
没有新增 actor 隔离警告；既有 tmux await 和 AppIntents 元数据提示仍在。

## 剩余与未验收

这不替代真实 CLI 快速结束/新回合、重启、窗口或审批交互。只读界面清单本轮
仍报告 Mac 锁屏，没有安装、重启或绕过锁屏，也没有真实进程退出验收。
未知源时间与任意时钟偏差仍不能等同实际执行顺序；同 ID、同时间的不同执行
不能凭时间区分。socket 响应失败/过期回调的请求代次仍是后续独立检查边界。
忽略探针及 ended 的所有稀有格式不是本轮逐一连接级覆盖；调用点与源码已检查，
不把该检查等同真实不同 Agent 的全面验收。
