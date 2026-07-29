# 独立发布风险审计

审计日期：2026-07-29。本文是发布工程清单，不构成法律意见。

## 已处理

- 已移除 Mixpanel SDK、遥测 token、设备标识采集和 Claude 版本采集；应用不再内置产品分析上报。
- 已加入 `NOTICE`，说明该代码库包含基于 Vibe Notch 的 Apache-2.0 衍生代码和本项目新增部分。
- 已为本轮修改的上游文本源文件加入 “Modified by lihao505 for Agent Notch, 2026.” 声明；替换的二进制素材另由素材来源文档记录。
- 桌宠和加载器生产帧使用本地 Pixelorama 资源；生产 PNG 透明、无内置光晕。其来源说明位于相邻素材目录的 README。
- 已切换到 Agent Notch 品牌、`io.github.lihao505.AgentNotch` Bundle ID 和项目自有 GitHub 更新地址。
- 未配置独立 Sparkle 公钥时自动更新默认关闭，正式脚本拒绝使用占位公钥发布。
- 发布脚本默认创建 Draft Release，并明确拒绝发布到上游仓库。
- 应用内置 Claude Hook 使用完整解释器与脚本路径判断归属，不再按文件名子串删除条目。
- 已加入隐私、安全、贡献、第三方依赖清单、CI 和可执行发布检查。
- 已移除上游 Apple Developer Team ID；签名构建必须显式传入发布者自己的 Team ID。
- Agent Bridge 已并入主仓库、加入 CI，并随应用资源同版本打包。

## 发布阻断项

| 优先级 | 风险 | 证据 | 上线前动作 |
| --- | --- | --- | --- |
| P0 | 自动审批可能造成用户误操作 | 工具权限可被自动允许 | 默认单次审批；将自动/完全信任限定为普通工具权限，不绕过问答、计划确认、macOS 权限或外部账户授权。 |
| P1 | 第三方依赖许可证随包分发 | Sparkle、swift-markdown、swift-cmark 已固定版本并建立清单 | 在 DMG/公开仓库保留完整许可证文本，并在升级依赖时同步清单。 |
| P1 | 竞品视觉/商标混淆 | 产品能力规格已改为独立需求文档 | 公开仓库与营销不得声称“一比一复刻”，或使用任何竞品的名称、图标、截图、文案或素材。 |
| P2 | 代码与运行时命名仍是 ClaudeIsland | socket、hooks、日志 subsystem 与 Xcode scheme 大量保留旧名 | 在确定项目名后做一次受控重命名；不要把 Claude/Codex 商标用于产品名称。 |

## 外部凭据阻断项

以下项目不能由源码替代，需要发布者账号完成：

- Developer ID Application 证书、App ID 与 notarization profile；
- 独立 Sparkle 私钥的离线备份，以及对应公钥写入 `Info.plist`；
- `lihao505/agent-notch` 远程仓库存在且 GitHub CLI 有发布权限；
- Claude Code、Codex 和 CodeBuddy 的真实版本兼容性矩阵；
- 商标检索和商业发行前的专业法律复核。

## 独立发布边界

- 可以实现“刘海中的多 Agent 状态、审批、会话跳转和聊天”等功能需求。
- 不应复制任何竞品的代码、图标、动画帧、截图、营销文案、付费/授权逻辑或可识别的整体界面表达。
- 不应暗示与任何竞品、上游项目、Anthropic、OpenAI 或 Apple 存在官方合作、认可或从属关系。
- 在商业化或跨地区发布前，应由有资质的知识产权律师复核品牌检索、素材授权、隐私政策和消费者条款。
