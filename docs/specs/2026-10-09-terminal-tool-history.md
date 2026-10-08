# 迟到工具历史的终止边界

## 已证问题

现有 LifecycleReducer 已拒绝旧 transcript 越过 Stop / 中断边界修改会话 phase，
但 createChatItem 对没有 tool_result 的历史工具一律创建 running 行。
于是会话已等待输入或中断，迟到历史却重新产生运行中指示；下一回合开始后，
旧工具也可能与新工具同时显示 running。这是生产 SessionStore 入口的隔离事件
序列复现，不是实际界面录像或真实 CLI 回合。

新增测试最初 5 项中 4 项失败，已完成结果的成功状态对照通过；
失败日志 `/tmp/agent-notch-terminal-tools-before.log`。
未把编译错误、服务日志或界面不可操作计作业务复现。

## 最小修改

- 在现有 ToolTracker 保留最近一次已接受的工具终止边界。
- 仅在已经被 reducer 接受的 Stop、结束、中断、进程退出或 transcript / Codex
  完成路径记录边界。被拒绝的旧中断不能推进此字段。
- 不随下一回合清空该边界；/clear 重置工具去重状态时也保留它。
- 创建历史工具时，有已完成结果的行保持原成功处理；无结果且时间不晚于
  已接受终止边界的行使用现有 interrupted 展示状态，而不是 running。
  历史行不删除，当前回合边界之后的工具仍正常运行。
- 完成会话合并历史后再次检查 reducer 结果：未被接受为新回合的工具行，
  即使时间晚于 Stop 也不能留下 running 指示，不把边界推到当前接收时间。
  该附加用例在初次时间边界修复后仍失败，日志
  `/tmp/agent-notch-terminal-tools-unconfirmed-before.log`；增加合并后检查修复。
- 持久化增加可选的精确秒时间戳；旧快照缺少字段仍可解码。
  初始化已有完成会话时，将其 completedAt 纳入工具终止边界。

这里的 interrupted 延续已有“终止后关闭未完成占位行”策略，不是证明工具
在 CLI 实际执行失败；缺少工具结果时不伪造成功内容。
不改 LifecycleReducer、审批请求 ID / FIFO、socket、Hook 协议或通知声音。

## 持久化精度回归

第一次将新字段按 Date 写入时，项目原有 ISO-8601 编码策略会截掉小数秒。
测试在同一秒内安排旧工具 0.5 秒、终止 0.8 秒，之后开启新回合并保存/恢复。
恢复得到的边界为 0 秒，旧工具再次显示 running；精度与状态两个断言失败。
日志 `/tmp/agent-notch-terminal-tools-persistence-before.log`。

新字段改为数值秒，保存精确边界，而不是扩大时间容差或把整个当前回合关闭。
这仅修复新工具边界字段；未宣称旧持久化日期字段的小数秒精度均已修复。

## 验收范围

8 项隔离测试覆盖：

1. Stop 后迟到的完整历史行仍保留，但不再 running。
2. 中断后迟到的增量工具行关闭，会话仍 idle，不制造成功完成。
3. 下一回合中旧工具关闭，新工具继续 running，会话保持 processing。
4. 已知完成工具仍 success。
5. /clear 重置后工具终止边界不丢失，旧/新工具状态仍分离。
6. 被拒绝的旧中断不推进边界、不关闭当前工具。
7. 活动会话保存/恢复后精确到小数秒，旧/新工具状态保持正确。
8. 时间较晚但没有新回合证据的工具行不会在完成卡片上留下 running 指示。

测试使用隔离 parser 根目录和快照文件、不连接生产 socket、不写全局配置。
持久化恢复夹具仅使用测试宿主自身 PID 作为存活进程；不是重启实际应用。
原有恢复测试同时覆盖没有新增字段的旧快照兼容路径。

完整 xcresult：306 passed、0 failed、0 skipped。
路径 `/tmp/agent-notch-native-transport-build/Logs/Test/Test-ClaudeIsland-2026.10.09_04-28-48-+0800.xcresult`。
Bridge 88 项、审批检查器 30 项、发布闸门及 Release 无签名构建通过。
Release 日志 `/tmp/agent-notch-terminal-tools-release-build.log`；不是签名安装验收。


## 未验收与剩余边界

本轮未安装，不向真实 Agent 发送消息。真实快速 Stop / 中断、应用重启后的
工具指示与 JSONL 监听数仍按生命周期矩阵验收，不由隔离测试改为通过。
旧快照未记录上一回合终止时间且当前又已 resumed 时，不能凭空恢复未知边界；
仅离线 bridge active 快照也没有上一回合边界，不能宣称跨任意离线过程完整保证。
延迟工具结果对既有 interrupted 占位行的进一步结果修正，及 /clear 前异步
文本历史的代次校验不是本轮修改范围，不将它们说成已完成。
无可信时间戳、跨来源时钟偏差仍需要独立证据，不能把接收时间等同执行时间。
