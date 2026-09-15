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
