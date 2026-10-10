# 嵌套工具的终止边界

日期：2026-10-10

## 背景与参考

继续处理状态触发时序，参考既有[终止工具历史](2026-10-09-terminal-tool-history.md)、
[子任务失败收尾](2026-10-10-subagent-failure-tracking.md)与生命周期验收矩阵。
本轮不修改页面、动效或图表，没有匹配的专用实现 Skill，也不引入新的 UI 依赖。

原清理只关闭顶层 running / waitingForApproval 工具，嵌套列表保留 running。
父 Agent 已成功但内部结果缺失时，父行还会被整体跳过。
此外，异步子 Agent 文件合并直接写入新列表，终止后重读旧文件可以再次出现 running。
因此卡片已等待输入、父工具已关闭，内部指示仍与主回合终止状态不一致。

## 隔离与复现

子 Agent 读取原来绕过 `claudeProjectsRoot` 注入参数，直接使用用户项目目录。
先让现有路径解析器接受可选根目录，实例解析传入已有 override；
生产默认目录、nested 优先及 flat 回退策略不变，静态调用保持兼容。
这一步仅确保回归使用独立临时 JSONL，不能计为嵌套终止问题已经修复。

在该目录支持下新增 3 项生产 Store 回归，修正前 14 项针对性测试有 5 项
断言失败，全部来自新增用例：Stop / 中断、已成功父工具及终止后重读文件。
文件用例的活动态对照首先读到 running / success，排除了“根本没有读到工具”的假通过。
日志 `/tmp/agent-notch-nested-terminal-before.log`。
这是隔离状态复现，不是实际 CLI 子 Agent 或界面逐帧录制。

## 修改范围

- 已接受主回合终止时，同时关闭嵌套 running / waitingForApproval 占位状态；
  保留已知 success / error，父工具已有结果也不修改。
- 子 Agent 文件读取返回并取得最新会话后，先检查父容器与最新工具终止边界：
  已关闭父容器的未完成子行不能重新运行；活动容器内不晚于终止边界的旧子行关闭，
  新边界之后的当前工具仍可运行。
- 使用已有 interrupted 展示状态，不伪造工具执行成功，也不宣称 CLI 实际被取消。
- 不改 lifecycle reducer、Hook / socket 协议、审批身份、FIFO、超时预算或通知。

## 测试覆盖与边界

1. 主回合 Stop 与中断分别关闭未完成子行，同时保留内部工具 success / error。
2. 父 Agent 已成功，主回合终止仍能关闭缺少结果的内部行，父 success 不变。
3. 实际隔离子 Agent JSONL：活动态正常运行，Stop 后重读不重启；新主回合的顶层
   工具继续运行；旧父容器的较晚文件行仍关闭，新父容器的边界后内部工具仍 running。

文件回归是明确的串行“终止后迟到合并”，没有强制制造读取等待期间的竞态；
不能据此宣称所有异步交错已逐一通过。既有 history generation 保护不变。
已完成文件行的 error / interruption 解析，以及旧文件是否覆盖更强的 Hook 结果，
仍是独立后续检查项，不由这次边界过滤宣称全部解决。

完整 Swift 355 项通过，0 失败、0 跳过，xcresult 摘要已核实：
`/tmp/agent-notch-native-transport-build/Logs/Test/Test-ClaudeIsland-2026.10.10_10-39-05-+0800.xcresult`。
日志 `/tmp/agent-notch-nested-terminal-tests.log`。
Bridge 88 项、verifier 30 项和发布元数据/脚本检查通过，
日志 `/tmp/agent-notch-nested-terminal-gate.log`。
Release 无签名构建通过，日志 `/tmp/agent-notch-nested-terminal-release.log`。
既有 TmuxTargetFinder 多余 await、AppIntents 元数据跳过警告仍在，
不宣称全部项目无警告。

Mac 的只读界面清单仍报告锁屏。本轮未绕过锁屏、未安装新构建，
真实子 Agent 回合、快速切换、全屏与动画继续按完整生命周期矩阵验收。
本机安装二进制 SHA-256 已重新核实为
`8804c0bb8fb28e1a91766c3ba9f3ecd4b22e4f95fdc9aea0e1d789e15df7ece1`，
仍是 b410c80 全屏策略版本，不将本轮源码/构建结果说成已安装或已运行。
