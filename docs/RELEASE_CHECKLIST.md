# Agent Notch 发布清单

## 每次提交

- [ ] `./scripts/verify-release.sh`
- [ ] Swift XCTest 通过（进程双管道/超时、状态乱序/重复、同会话审批 FIFO、跨会话精确路由、rollout 增量索引）
- [ ] Debug 无签名构建通过
- [ ] Release 无签名构建通过
- [ ] Python Agent Bridge 测试通过
- [ ] 设置界面关键控件和真实刘海预览人工检查通过

## 首次公开源码仓库前

- [x] 产品名改为 Agent Notch
- [x] Bundle ID 改为 `io.github.lihao505.AgentNotch`
- [x] 更新源改为 `lihao505/agent-notch`
- [x] 默认关闭未配置密钥的自动更新
- [x] 保留 Apache-2.0 LICENSE 与 NOTICE
- [x] 为本轮修改的上游文本源文件加入显著修改声明
- [x] 将固定 revision 的第三方完整许可证纳入仓库与 App Resources
- [x] 记录自制图标和像素素材来源
- [x] 加入隐私、安全、贡献和第三方依赖说明
- [x] 创建 `lihao505/agent-notch` 并启用 Security Advisory
- [x] 敏感文件名与常见密钥格式扫描通过
- [x] README 明确当前仅提供源码构建，未签名、未公证
- [x] 将 Agent Bridge vendored 到主仓库并加入 CI
- [x] 仓库公开后启用默认分支保护（禁止强推与删除）
- [ ] 确认未将本地 `promo-video/` 工作素材误纳入源码或发布包；若未来发布，先单独筛选、压缩并核对素材许可
- [ ] 人工视觉相似性与商标检索完成

## 首个功能 Beta 前

- [ ] 全局快捷键在另一应用前台时展开／收起；修改、清除与重启恢复；快速开关无延迟抢焦点，跨显示器切换仍有效
- [ ] 上一个／下一个会话真实按键循环切换；会话消失及状态变更后目标正确；三个动作的重复组合键提示、暂停和解除冲突验收

- [ ] 在真实 Claude Code 回合验收状态、跳转与完成边界
- [ ] 在真实 Codex 回合验收状态、跳转、回复与完成边界
- [ ] CodeBuddy（Experimental）在真实完整回合验收状态、跳转、原生记录与 CLI 续接；完成前不得宣称稳定支持
- [x] 按当前官方 Codex Hooks 文档确认 allow/deny wire format
- [x] 使用已安装 bridge + 实际刘海按钮完成 allow/deny 端到端回写验收
- [ ] 在真实 Claude Code/CLI `PermissionRequest` 回合完成端到端 allow/deny 点击验收
- [x] 真实 Claude CLI/SDK 经生产 Bridge 接收大于 4 KiB 的分段多行问题答案并继续至 Stop（测试 socket，非实际刘海界面）
- [x] 真实 Claude command hook → 已安装刘海单题自定义回答 → Agent 继续至 Stop；长答案返回任务列表后仍保留
- [ ] 真实 Claude 多题分页、单选/多选提交和计划确认的完整界面验收
- [ ] 人工确认同一会话的审批不会发送给另一会话
- [ ] 关闭“问题自动展开”后，`AskUserQuestion` 只显示小刘海待处理状态；普通审批与计划审查仍自动展开

Swift 核心测试命令：

```bash
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test
```

自动化测试已经覆盖 `sessionId + toolUseId` 交叉串会话拒绝、同一会话多个交互按
FIFO 逐个呈现，以及旧批准回调不会擦除较新的完成状态；上面的人工项仍保留，
用于确认真实 Claude Code/CLI 与已安装 App 的完整 wire path。

问答协议补充验证：`scripts/verify-claude-question.py --live` 复用官方 SDK，
隔离用户配置、Bridge 持久化及真实 App socket。2026-09-14 使用本机 Claude Code
2.1.195 / SDK 0.2.152 验证通过：17,821 字节的中文答案分段回传，随机答案标记
被 Agent 消费，且没有调用备用权限回调。完整命令和验收边界见
`AgentBridge/README.md`。此结果不勾选上面的真实 UI、普通审批及完整回合验收项。
同日指定已安装的 Bridge 再次复测通过（17,841 字节），App 保持关闭；安装前保留了
旧 App 与旧 Bridge 的备份，未重写 Agent 配置。

2026-09-15 使用 `--live --app` 补充已安装 App 的原生界面验收（同上 CLI/SDK 版本）：
通过 macOS 辅助功能操作实际“自定义答案”控件和“提交”按钮，8,855 字节中文草稿
在返回任务列表、重新打开同一提问后完整保留，9,419 字节答案回包被 Agent 消费。
固定会话 UUID 与目录隔离加固后又通过一次实际提交复测；两次均收到同请求的
PostToolUse 和 Stop，没有备用审批回调。中断/超时未提交的测试明确判为失败，未计入通过。
本轮未改 App 界面、未改持久 Hook 配置；测试会话清理后恢复 App 关闭状态。

2026-09-15 全局展开／收起快捷键：复用 KeyboardShortcuts 2.4.0（保留 Xcode 16.4
构建兼容性），未预设组合键。10 项新增 Swift 测试覆盖松键单次切换、重复启动监听、
停用后排队事件失效、可用性恢复不重放、显示器更换后目标解析、聊天恢复和迟到焦点／
启动动画保护；全套 123 项测试通过。已安装 Release 的设置窗口可见录制控件，
检查后仍为未绑定。尚未将跨应用真实按键、录制保存／清除、重启恢复及物理显示器
切换计为已通过；不以模拟事件流测试替代这些验收。

2026-09-16 增加上一个／下一个会话快捷键，继续复用 KeyboardShortcuts 2.4.0。
鼠标列表与键盘共用排序规则，并以会话 ID 处理相同时间的排序；按键执行时读取最新
可见集合，不保存注册时的会话快照。新增 12 项测试覆盖循环、空集合／单会话、结束／
移除的会话、提示词时间优先、关闭后切换、焦点代际以及多动作冲突暂停／解除；
全套 135 项 Swift 测试通过。真实跨应用按键、录制保存／清除、冲突提示交互和重启
恢复尚待验收，三个动作均保持默认未绑定，不执行审批或终端跳转。
已安装 Release 的原生辅助功能树和截图确认三个录制控件与说明正常显示；未设置
测试组合键，未改审批模式。检查后退出 App，确认进程与 socket 已清理。

2026-09-16～17 设置窗口视觉改进：改用原生侧栏、系统语义色与统一分组样式，
通知和快捷键分为独立页面，隔离预览只保留在外观页。真实已安装 Release 的中文深色
界面已检查六页、外观/系统页滚动、切页回顶、标题更新、侧栏方向键导航、四种模拟
预览状态及三个未绑定录制器；辅助功能树确认分类选中状态和控件标签。
本轮未操作审批模式、Hook 开关、声音选择、静默规则或快捷键绑定。
最小窗口拖拽未确认实际尺寸变化，不能计为通过；浅色、英文和系统辅助显示设置
的完整视觉矩阵仍待验收。设计来源与范围见 `docs/SETTINGS_DESIGN.md`。

2026-09-17 刘海展开页与快捷设置：任务列表改为标题／独立状态／活动／操作分层，
问答与计划只进入结构化交互页，普通批准入口再检查请求类型。快捷设置改为原生分段、
菜单与开关；保留全部原选项，顶部导航和底部完整设置／退出固定，中部可滚动。
新增 26 项测试，全套 161 项 Swift 测试、79 项 Bridge 测试及 5 项 verifier 测试通过；
Debug／Release 构建通过。窄宽度离线截图覆盖中文任务行及中英文快捷设置，含最小内容高度、
修复提示与更新中状态；截图测试的所有设置写入和动作计数均为零。
离屏重复文字／图标在部分英文快照中存在缓存漏画，不能将附件产出等同完整视觉通过；
完整语言、VoiceOver、减少动态效果与真实权限回合的验收仍待补充。
最终 Release 已安装并启动，签名为本机 ad-hoc，非 Developer ID／公证发行。真实中文
任务页截图及辅助功能树确认两个会话、工作／完成状态和独立详情／归档按钮；
自动化在物理刘海点击与展开持续性上未稳定复现，未把快捷设置安装版的完整滚动、
键盘导航、详情点击、真实 Hook／登录项变更计为已通过，也未为了视觉检查修改这些设置。
设计来源、行为边界与测试方法见 `docs/EXPANDED_TASK_LIST_DESIGN.md`。

2026-09-18 刘海点击与设置导航补充：鼠标监听在收到事件时保存系统提供的全局坐标，
不再等主队列消费时读取已移动的光标；ViewModel 只关闭面板，不合成第二次外部点击。
透明区域真正被窗口拦下的事件只由 NotchPanel 转发原始副本，保留坐标、按键、修饰键
和双击次数；命中检测显式转换窗口／父视图坐标。闭合态增加具名“展开 Agent Notch”
辅助功能按钮，展开动作幂等，不覆盖已经打开的设置或聊天内容。
新增 13 项隔离 Swift 测试覆盖事件快照、点击接管悬停、外部关闭、可访问展开、负屏幕
坐标、翻转／偏移父视图、原事件复制及测试宿主审批策略写入隔离。
最终全套 174 项 Swift 测试通过；测试不向桌面投递鼠标事件。隔离修复后的完整测试运行
前后，真实审批策略文件的 SHA-256、mtime、inode 与权限均一致。
已安装 Release 的真实界面通过原生辅助功能展开、快捷设置滚动到底部、返回任务、
详情入口、点击透明区关闭，以及刘海左右翼坐标点击展开；关闭再展开保留所选聊天。
这补充了上一轮尚未完成的设置页导航验收，不代表跨显示器物理操作、VoiceOver 全流程、
外部应用单击计数、快捷键、真实审批与 Hook／登录项变更均已验收。
实机检查发现并补全“悬停展开”和“智能体桥接”开关的辅助功能名称，菜单关闭图标
明确标为“返回任务列表”；未在视觉检查中操作设置或权限开关。
代码审查发现已有偏好初始化会让 XCTest 宿主重写真实审批策略文件，现已在落盘边界
禁止测试宿主写入；普通 App 的策略同步不受影响，不以“测试未点击开关”等同完全隔离。
本轮发布检查首次出现 tmux relay 用例 3 秒内未生成捕获文件，单次隔离复测及随后完整
79 项 Bridge／5 项 verifier 测试均通过；首次原因尚未确认，不能以重跑通过视为根因已修复。
后续测试加固应增加超时前诊断、单调时钟及显式独立 tmux server，避免依赖继承环境。

2026-09-24 Codex 状态内核第一阶段：将原生 rollout 的发现与轮询统一交给纯函数
`LifecycleReducer` 仲裁，以轮次开始、完成、Hook 和观测时间建立明确的代际边界；冷启动
发现可创建“工作中”，旧 active／completed 证据不能覆盖新轮次或审批状态，missing／unknown
按宽限期收敛。新增有界、仅内存且不含对话文本、工具输入和路径的决策轨迹，为后续诊断页
预留数据源。新增 10 项矩阵测试，全套 189 项 Swift 测试、79 项 Bridge 测试及 5 项 verifier
测试通过，Release 无签名构建通过。将 Release 安装到 `/Applications/Agent Notch.app` 后，
在本条 Codex 任务已经执行到中途时重启 App，原生辅助功能树确认刘海立即发现 1 个任务并
显示“工作中”；安装包与构建产物主二进制 SHA-256 一致。本轮没有迁移 Claude／CodeBuddy、
审批或其他直接状态写入，也尚未把完整完成边界和多轮快速切换计为真实端到端通过。

2026-09-25 状态内核第二阶段：Hook 的 active、交互、压缩、完成、会话结束与移除
不再直接争写 `SessionState`，而是和 Codex 原生轮询共用 `LifecycleReducer`。原生完成时间
及当前轮次成为统一边界；相同或更旧的迟到 Hook 不能把已完成任务重新标为“工作中”，
新的 Hook 可以开始下一轮，Stop 可权威结束待审批状态，旧 SessionEnd 不能删除已恢复会话，
权限请求也可以正确打断压缩态。决策轨迹只保留脱敏后的状态类别，不再持有
`PermissionContext` 或工具输入。新增 6 项回归测试后，全套 195 项 Swift 测试、79 项
Bridge 测试及 5 项 verifier 测试通过，Release 无签名构建通过。安装 Release 后，构建产物
和 `/Applications/Agent Notch.app` 主二进制 SHA-256 一致；真实原生辅助功能树确认在本条
Codex 任务执行中途启动／重启 App 时，刘海能发现 1 个任务并显示“工作中”及当前活动摘要。
迟到 Hook 的跨源时序矩阵由自动化验证，本轮没有向真实用户会话注入伪造 Hook，因此不把
这些自动化用例记为真实跨进程端到端通过。Transcript fallback、本地交互回调以及
Claude／CodeBuddy 原生发现仍有直接状态写入，后续继续迁入统一内核。

2026-09-25 状态内核第三阶段：Claude／CodeBuddy 的 Transcript fallback 不再直接写入
`phase` 和 `completedAt`。用户消息、运行工具与最终助手文本会携带原始消息时间进入
`LifecycleReducer`，异步解析完成后若发现更新的 Hook、Stop、审批结果或 socket 失败边界，
旧 transcript 只更新呈现内容，不再错误恢复“工作中”、提前结束新回合或清理新工具。
原生 active 证据也不再回退已知轮次开始时间。新增 6 项 reducer／SessionStore 时序测试，
全套 201 项 Swift 测试、79 项 Bridge 测试及 5 项 verifier 测试通过，Release 无签名构建
通过。安装 Release 后，构建与 `/Applications/Agent Notch.app` 主二进制 SHA-256 一致；
在本条 Codex 任务执行中途重启 App，原生辅助功能树仍确认 1 个任务、状态“工作中”和
当前活动摘要。真实 Claude／CodeBuddy 的乱序跨进程回合本轮未主动注入，自动化时序矩阵
不替代该端到端验收；本地交互回调、interrupt 和进程退出仍待完全迁入统一 reducer。

2026-09-25 状态内核第四阶段：Agent Notch 本地处理的批准、拒绝与 socket 发送失败
不再直接修改 `phase`、`lastHookEventAt` 和 `completedAt`，而是以不含工具输入和回复内容的
本地交互证据进入 `LifecycleReducer`。同会话多个请求仍按 FIFO 显示下一项；旧回调不能跨越
较新的完成边界。修复一个实际竞态：发送失败的回调如果晚于新的活动 Hook 到达，只移除
自己对应的旧请求并保持“工作中”，不再把已经恢复的任务错误降为“空闲”。新增 4 项
reducer／SessionStore 回归测试，全套 205 项 Swift 测试、79 项 Bridge 测试及 5 项 verifier
测试通过，Release 无签名构建通过。安装态检查只验证新 Release 能启动并从本条进行中的
Codex 任务恢复“工作中”状态；本轮没有故意制造真实权限 socket 故障，因此乱序失败场景
仍以确定性自动化测试为证。Hook／JSONL 工具完成后的队列收口、interrupt 与进程退出仍有
直接状态写入，后续继续迁入统一 reducer。

2026-09-25 状态内核第五阶段：Hook／JSONL 工具完成、JSONL interrupt、进程退出以及
Bridge 冷启动快照恢复均进入统一时序裁决。修复一个会误关审批页的精确身份错误：过去任意
工具完成事件在会话处于审批态时都可能触发回退，现在只有匹配 `toolUseId` 的事件才能消费
对应队列项，并且先由 reducer 接受原始时间戳，随后才提交队列变更。JSONL 工具结果和中断
保留源时间；缺少时间的工具结果只更新卡片内容，不再作为生命周期证据。旧 interrupt 不会
停止更新的 Hook 活动，进程退出也必须匹配会话当前 PID，避免旧进程的迟到检查结束已换代的
任务。新增 10 项 reducer／SessionStore 回归测试，全套 215 项 Swift 测试、79 项 Bridge 测试
及 5 项 verifier 测试通过；发布元数据与脚本校验通过。自动化覆盖乱序和身份栅栏，但本轮
仍不把伪造事件测试记为真实跨进程 interrupt、进程退出或 Bridge 冷启动端到端验收。

2026-09-25 状态内核第六阶段：中断监听器与权限 socket 的启动、精确撤销和整会话清理
不再由 UI 回调抢先执行，而是在 `SessionStore` 接受同一条生命周期证据后统一提交。由此修复
一个真实时序漏洞：旧 JSONL interrupt 即使被 reducer 判为过期，也会在此前无条件停掉新回合
监听器。工具完成也改为状态、结果、审批队列同一裁决后原子更新；精确请求缺少源时间或时间
早于当前边界时，卡片继续保持“等待批准”，不会出现“已成功但仍待批准”的矛盾呈现。
JSONL 增量读取现会保留跨回调半行和拆分 UTF-8，支持带空格／乱序键的合法 JSON，处理截断、
rename、delete、revoke 与文件晚创建重试，并限制异常单行缓存。新增 6 项时序与解析测试，
全套 221 项 Swift 测试、79 项 Bridge 测试及 5 项 verifier 测试通过；发布元数据校验和
Release 无签名构建通过。对 Release 做本机 ad-hoc 签名并安装后，安装包与构建产物主二进制
SHA-256 一致；在本条 Codex 任务运行中重启 App，原生辅助功能树确认刘海立即显示 1 个任务、
状态“工作中”和当前活动摘要。真实跨进程文件轮换、物理中断与权限回写仍需真实 Agent 回合
验收，不能仅凭确定性测试和本次冷启动检查宣称全部端到端场景已覆盖。

2026-09-26 状态内核第七阶段第 1 切片：新增只读、脱敏的生命周期诊断值模型与稳定 JSON
报告格式。报告将原始会话 ID 映射为单次快照标签，只输出状态类别、计数与相对时长；
`LifecycleTraceEntry` 补充证据是否被接受，仍不保留提示词、工具输入或路径。新增 5 项
隐私、排序、上限与健康聚合测试，全套 226 项 Swift 测试、79 项 Bridge 测试、5 项
verifier 测试、发布脚本校验和 Release 无签名构建通过。本切片尚未连接运行时数据源或
设置页，也未执行真实 Claude/Codex 回合矩阵；不能将数据模型通过测试视为诊断页或
跨进程触发时序已经验收。

## 可选：签名二进制发行

以下项目不是公开源码仓库的前置条件；只有未来提供免 Gatekeeper 警告的官方安装包
时才需要：

- [ ] 加入 Apple Developer Program
- [ ] 设置自己的 `AGENT_NOTCH_DEVELOPMENT_TEAM`，不得沿用上游 Team ID
- [ ] 使用 Developer ID Application 证书归档
- [ ] notarization 与 stapling 成功
- [x] 使用独立 Keychain account 生成 Agent Notch Sparkle 密钥
- [x] 将对应公钥写入 Info.plist
- [ ] 将 `.sparkle-keys/eddsa_private_key` 离线加密备份

签名发行命令：

```bash
AGENT_NOTCH_DEVELOPMENT_TEAM=你的团队ID ./scripts/build.sh
AGENT_NOTCH_PUBLISH=0 ./scripts/create-release.sh
```

默认创建 GitHub Draft Release。检查 DMG、appcast、签名和安装体验后，再在 GitHub
后台发布；只有显式设置 `AGENT_NOTCH_PUBLISH=1` 才会直接公开。

任何未完成的功能 Beta 项都必须在 Release Notes 中标为已知限制，不能用“已完全
支持”替代真实回合验收。CodeBuddy 在上述验收全部完成前必须标为 Experimental。
