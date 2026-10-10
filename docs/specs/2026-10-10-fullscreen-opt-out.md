# 浮动刘海的全屏空间退出策略

日期：2026-10-10

## 修正范围与依据

「设置 → 通用 → 全屏时显示刘海」已存在，默认开启且可持久化。
这次只修正关闭时的 AppKit 窗口标志，不新增配置项、窗口扫描、轮询、权限或依赖。

| Before | After | Why |
| --- | --- | --- |
| 关闭时设置 `fullScreenNone` | 关闭时设置 `fullScreenPrimary` | 前者限制窗口自身全屏能力；Apple 明确推荐后者用于退出其他应用全屏空间 |
| 切换只清理 auxiliary / none | 每次清理 auxiliary / primary / none，再设置一个策略 | 从旧策略迁移及反复切换均不残留冲突标志 |

依据为 Apple 的 [canJoinAllApplications 说明](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications)：
浮动窗口可参与其他应用的全屏空间，明确退出该行为应使用 `fullScreenPrimary`。
开启仍使用 [fullScreenAuxiliary](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/fullscreenauxiliary)。
没有改变 `.stationary`、`.canJoinAllSpaces`、`.ignoresCycle`、窗口层级、鼠标穿透或审批处理。
已有展示入口保护继续复用 AppKit 的 `isOnActiveSpace`，不根据窗口尺寸猜测全屏。

使用 emil-design-eng 的交互一致性规范；没有视觉改版或键盘动画。
检查过本地 React 组件资源，但这次原生窗口策略不需要 Web 组件。
指定品牌设计与曲线动画目录缺失，不因此引入替代依赖。

## 自动化证据

加强已有策略回归，而不是增加同义测试数量：从旧 `fullScreenNone` 开始，
依次关闭、开启、关闭、开启；验证 primary / auxiliary 互斥、none 清除、其余标志保留。
修正前该测试有 4 项断言失败；修正后完整 Swift 349 项通过，0 失败、0 跳过。
Bridge 88 项、verifier 30 项及发布脚本检查通过。
Release 无签名构建通过。仍有既有 TmuxTargetFinder 多余 await 和 AppIntents
元数据跳过警告，不宣称整个项目无警告。

本地完整结果：
`/tmp/agent-notch-native-transport-build/Logs/Test/Test-ClaudeIsland-2026.10.10_08-44-35-+0800.xcresult`。
这是实际 NSPanel 策略断言，不是 WindowServer 的全屏像素验收。

## 本轮安装前原生观察与边界

Mac 已解锁。在旧安装版 c2bb316 上，新建仅供测试的 TextEdit 空白窗口，
完成原生全屏进入/退出、开关关闭后重新进入、全屏内修改开关；开启时刘海可访问并可展开。
关闭时辅助功能仍可访问刘海，但后台窗口也可能出现在辅助功能树中，
单窗口截图不包含其他应用的合成图层，不能据此证明刘海实际泄漏或隐藏。

观察结束后恢复全屏显示为开启，退出 TextEdit 全屏，关闭仅新建的空白测试文档；
用户原有未命名文档保留不变。没有保存或上传界面截图。

真正的关闭状态像素隐藏、顶部鼠标/快捷键/审批触发、全屏内动态修改、
快速 Space 切换及多显示器独立 Space 仍需独立验收，不能由策略测试代替。
同会话双请求并存 FIFO、审批中重启和并行混合超时也不因本轮修改改为通过。

## 修正版安装校验

通过应用菜单正常退出旧版，确认其进程和生产 socket 均消失后，再更新 bundle。
修正版 Release 已本机 ad-hoc 签名，构建与安装 bundle 的严格签名校验通过，
两者主二进制 SHA-256 均为
`8804c0bb8fb28e1a91766c3ba9f3ecd4b22e4f95fdc9aea0e1d789e15df7ece1`。
旧 c2bb316 bundle 保留在 `/tmp/agent-notch-install-backup.o7OchE/Agent Notch.app`，
这是临时回退副本，不是长期备份或公证发行。

安装后尝试原生启动复查时，界面工具明确报告 Mac 已锁屏，无法自动解锁。
没有绕过锁屏；安装完成不等于启动成功，新版全屏显示/隐藏行为仍未实机验证。
前面记录的单屏观察仅属于旧安装版，不能转移归因到修正版。
