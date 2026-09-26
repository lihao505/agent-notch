# Agent Notch 状态内核第七阶段设计

日期：2026-09-26

状态：实施中（第 3 切片：协调器与原生设置页）

主题：真实回合验收与隐私安全的生命周期诊断

## 1. 背景与问题

Agent Notch 已经将 Codex 原生发现、Hook、Transcript、本地审批回调、JSONL interrupt、
进程退出和 Bridge 冷启动快照统一到 `LifecycleReducer`。前六阶段解决了已知的乱序覆盖、
旧回合复活、跨会话审批、旧 interrupt 停止新 watcher，以及工具卡片与审批队列非原子更新。

当前剩余风险不再主要是某条已知转换规则，而是跨进程真实环境中的可观测性不足：当状态没有
在预期时间触发时，只能看到最终 UI，无法快速区分“事件没有产生”“Bridge 没有送达”“文件
监听正在恢复”“解析没有生成证据”或“reducer 正确拒绝了旧证据”。继续针对表象补丁会重新
扩大状态竞争面。

本阶段不增加新的生命周期状态机。目标是在现有唯一状态入口周围增加只读、脱敏、可测试的
诊断快照，并用它完成 Claude 与 Codex 的真实回合验收。

## 2. 已选择的方案

采用“运行时诊断快照 + 原生设置页 + 确定性集成测试 + 真实验收矩阵”。

未选择的方案：

- 只依赖 `os.log`：实现最快，但日志分散在不同进程和队列，用户难以提供完整、脱敏的上下文。
- 将所有事件持久化到数据库：查询能力强，但扩大隐私、迁移、清理和故障面，当前没有必要。
- 直接继续做 UI 或新功能：短期可见，但会增加事件来源，不能解释剩余的触发时序问题。

## 3. 范围与非目标

### 本阶段包含

- 展示当前 Bridge、JSONL watcher、会话和权限等待的只读健康状态。
- 展示最近的生命周期裁决：来源、证据类别、接受/拒绝原因、前后状态和延迟。
- 明确 watcher 是正在监听、等待文件、恢复文件还是已停止。
- 手动刷新和显式复制脱敏诊断报告。
- 纯函数单元测试、隔离 socket/文件集成测试及 Claude/Codex 真实回合验收。
- 将验证结论写入发布清单，并继续区分自动化、安装态观察和真实 Agent 行为。

### 本阶段不包含

- 不修改 `LifecycleReducer` 的状态优先级，除非真实验收提供可复现的反例。
- 不记录、显示或导出提示词、回答、工具输入、工具结果、文件正文或完整路径。
- 不自动上传诊断数据，不联网，不新增遥测、数据库或第三方依赖。
- 不把 CodeBuddy 从 Experimental 提升为稳定支持。
- 不重做设置页、刘海展开页或动效系统。
- 不修改 `promo-video/`。

## 4. 架构

### 4.1 脱敏诊断模型

新增一组 `Sendable` 值类型，只表达运行健康度，不持有生产对象：

- `LifecycleDiagnosticsSnapshot`
  - 生成时间。
  - App/Bridge 总体健康等级：正常、注意、不可用。
  - 当前会话的脱敏摘要。
  - 最近的生命周期裁决。
  - Bridge、watcher 和权限队列健康快照。
- `SessionDiagnosticsSummary`
  - 临时显示标签 `S1`、`S2`，只在一次快照内稳定。
  - Agent 来源和 `LifecyclePhaseKind`。
  - 是否存在 PID、是否等待权限、距最近活动的相对时间。
  - 不包含 session ID、项目名、cwd、TTY 或 PID 数值。
- `BridgeDiagnosticsSnapshot`
  - socket 是否启动、socket 文件是否存在、是否由当前进程持有。
  - 待处理权限总数及按脱敏会话标签聚合的数量。
  - 最近接收事件距今多久；不保存事件载荷。
- `InterruptWatcherDiagnosticsSnapshot`
  - 每个脱敏会话的状态：`waitingForFile`、`watching`、`recovering`、`stopped`。
  - 最近打开成功、文件事件和恢复尝试的相对时间。
  - 只记录重试次数，不记录 JSONL 路径。
- `LifecycleDecisionDiagnostics`
  - 复用现有 `LifecycleTraceEntry` 的来源、证据、原因、前后状态和 `didMutate`。
  - 时间输出为“距快照多少毫秒/秒”，不导出绝对活动时间。
  - 延迟为 `receivedAt - observedAt`，负数按现有策略归零展示。

现有 `LifecycleTraceEntry` 继续保持全局最多 500 条、仅内存。诊断层不复制第二个无限队列。

### 4.2 数据提供者

新增 `LifecycleDiagnosticsCoordinator`，职责仅为组装快照：

1. 从 `SessionStore` 异步读取脱敏会话摘要与现有生命周期轨迹。
2. 在 MainActor 读取 `InterruptWatcherManager` 缓存的 watcher 状态。
3. 从 `HookSocketServer` 读取锁保护的只读健康计数。
4. 将真实 session ID 在组装期间映射为 `S1`、`S2`，映射不持久化、不导出。
5. 发布不可变的 `LifecycleDiagnosticsSnapshot` 给设置页。

协调器不处理生命周期事件、不改变 session、不启动或停止 watcher，也不发送权限响应。
设置页显示时每秒刷新一次；离开页面或关闭窗口后取消刷新任务。用户也可以手动刷新。

### 4.3 watcher 状态

`JSONLInterruptWatcher` 在自己的串行队列中更新一个小型状态枚举，通过状态回调通知
`InterruptWatcherManager` 缓存最新值：

- `start()` 且文件不存在：`waitingForFile`
- 文件已打开并安装 DispatchSource：`watching`
- rename/delete/revoke、读取失败或重开重试：`recovering`
- reducer 接受完成/中断/结束并清理，或 App 停止监控：`stopped`

回调只传递枚举、重试次数和时间，不传路径或文件内容。状态回调不得反向改变 watcher，
避免诊断层进入控制回路。

### 4.4 Hook socket 状态

`HookSocketServer` 增加只读诊断快照。需要跨队列读取的字段使用独立锁保护的轻量状态，
而不是从 UI 对 socket 串行队列执行同步调用，从而避免死锁。状态包括启动结果、最近事件时间、
当前待处理权限计数和 socket 所有权；不包含 tool name、tool ID、input 或回复内容。

## 5. 原生诊断页面

在设置侧栏新增“诊断 / Diagnostics”，使用现有系统侧栏、语义色、`SettingsSurface`、系统字体
和 SF Symbols，不引入 WebView 或图表依赖。页面拆到独立 `LifecycleDiagnosticsView.swift`，
不继续扩大 `NotchStudioSettingsView.swift`。

页面自上而下包含：

1. **总体状态**：正常、需要注意或不可用；显示最近刷新时间和“刷新”按钮。
2. **连接健康**：Bridge socket、JSONL watcher 数量、等待文件/恢复数量、待处理权限数量。
3. **当前会话**：`S1` 等临时标签、来源、当前状态和最近活动相对时间。
4. **最近裁决**：最新优先，显示来源、证据、接受/忽略、原因、状态变化和处理延迟。
5. **隐私说明与复制**：明确应用不会自动保存或上传报告，内容不包含对话/工具输入/路径；
   “复制诊断报告”只有用户点击时才写入剪贴板。

复制动作使用 macOS 系统剪贴板，若用户启用通用剪贴板，系统可能将内容同步到其其他设备；
页面需直接说明这一点，不把应用不上传等同于剪贴板绝对仅在本机。

空状态分别表达：没有活动会话、尚无裁决、Bridge 未启用、watcher 正在等待文件。健康告警
使用图标和文字，不只依靠颜色。列表支持键盘和 VoiceOver，减少动态效果时不增加动画。

## 6. 报告格式与隐私

`DiagnosticsReportFormatter` 是纯函数，生成稳定排序的 UTF-8 JSON，便于用户提交 issue 或
发给维护者。报告包含：

- schema 版本、App 版本、macOS 主版本和生成时的健康等级。
- 脱敏会话、连接健康、watcher 状态和最多最近 100 条裁决。
- 所有时间均相对于报告生成时间，单位明确。

报告不得包含以下键或值：

- 原始 session ID、tool use ID、PID/TTY 数值。
- cwd、用户目录、文件名或 JSONL 路径。
- prompt、message、answer、tool input、tool result、reason 文本或权限回复。
- socket 客户端内容、环境变量和用户配置原文。

`reason` 在报告中只表示 `LifecycleTransitionReason.rawValue`；它不是用户输入的拒绝理由。
测试将使用包含敏感标记的 fixture，确认输出中不存在这些标记和原始路径。

## 7. 错误与恢复策略

- 某个数据源读取失败时仍展示其余快照，并将该分区标为“暂不可用”，不让设置页崩溃。
- 快照组装超过 500 毫秒时保留上一份结果并显示“刷新延迟”，不阻塞主线程。
- App 关闭、设置窗口关闭或页面切走时取消刷新；再次进入立即拉取新快照。
- 复制报告失败时显示本地错误提示，不自动改用文件写入或网络发送。
- watcher 长时间 `waitingForFile` 只是可见状态，不由诊断层擅自重启；生产 watcher 的现有退避
  恢复仍是唯一控制逻辑。

## 8. 测试设计

### 8.1 单元测试

- 轨迹保持 500 条上限并按时间稳定排序。
- session ID 映射为稳定的单次快照标签，报告中不泄漏原值。
- 报告格式稳定，绝对时间转换为相对时间。
- 包含路径、中文提示词、工具输入和拒绝文本的 fixture 全部被排除。
- Bridge 健康等级、watcher 四种状态和总体健康聚合正确。
- 页面刷新任务在离开页面后取消，不重复启动。
- 空状态、错误状态和“需要注意”状态均有文本语义。

### 8.2 隔离集成测试

- 使用临时 Unix socket 验证启动、事件接收、权限计数、超时和停止的健康快照。
- 为 watcher 提供测试专用文件 URL，验证晚创建、半行 UTF-8、truncate、rename、delete
  后的状态序列与恢复；`revoke` 通过提取后的事件决策函数确定性验证，不依赖系统偶发事件，
  且所有测试都不读取用户真实 `~/.claude`。
- 注入旧 interrupt 后确认 reducer 拒绝，watcher 状态仍为 `watching`。
- 精确工具完成被拒绝时，权限计数和等待卡片保持一致；接受时同时收口。
- 两个会话并行时，诊断标签、权限计数和裁决记录不串会话。

### 8.3 真实回合验收

每项都记录 Agent、App 版本、开始条件、可见状态、诊断原因和最终结果：

1. 先启动 Codex 回合，再启动 App：一次发现轮询内出现“工作中”。
2. Codex 连续两轮快速切换：旧完成/中断不覆盖新回合。
3. Codex 工具和子 Agent：工作、工具活动、完成状态顺序正确。
4. Claude Code 正常回合：Hook、Transcript 和 Stop 对齐。
5. Claude Code 运行中重启 App：恢复任务且 watcher 回到 `watching` 或明确 `waitingForFile`。
6. Claude `PermissionRequest`：允许、拒绝和超时均只处理精确请求。
7. Claude 同会话双请求：FIFO 展示，先后完成不产生矛盾卡片。
8. Claude 双会话并行请求：不跨会话回写。
9. Claude 中断和下一轮快速开始：旧 interrupt 被拒绝且新 watcher 保持工作。
10. 关闭问题自动展开：问题只显示待处理状态，普通批准和计划审查仍遵循各自规则。

CodeBuddy 使用相同清单单独执行，结果继续标记 Experimental，不阻塞 Claude/Codex 本阶段交付。

## 9. 完成标准

- 所有生产状态改变仍只经 `SessionStore.process()` 和现有 reducer；诊断代码没有写路径。
- 设置页能解释当前状态、数据源健康度以及最近一次接受/拒绝原因。
- 复制报告通过隐私 fixture 和稳定格式测试，默认不落盘、不联网。
- Swift 全量测试、Bridge 测试、verifier、Debug/Release 构建及发布脚本全部通过。
- 安装 Release 后，诊断页可通过原生辅助功能访问，空态、活动态和需要注意态清晰。
- Claude 与 Codex 的真实验收矩阵逐项记录；未执行或失败的项目继续保留为未完成，不用自动化
  测试替代。
- 每次实现更新单独提交并推送 GitHub，等待远端 CI 成功；`promo-video/` 始终不进入提交。

## 10. 实施顺序

1. 增加纯诊断模型、报告 formatter 和隐私测试。
2. 为 SessionStore、HookSocketServer、JSONL watcher 增加只读快照，不改变控制逻辑。
3. 增加协调器和设置页诊断入口。
4. 补隔离集成测试并跑全量发布闸门。
5. 安装 Release，检查辅助功能、页面状态与中途启动。
6. 执行 Claude/Codex 真实回合矩阵，修复有证据的剩余问题。
7. 更新发布清单，提交、推送并等待 GitHub CI。
