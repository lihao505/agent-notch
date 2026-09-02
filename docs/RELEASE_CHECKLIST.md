# Agent Notch 发布清单

## 每次提交

- [ ] `./scripts/verify-release.sh`
- [ ] Swift XCTest 通过（进程双管道/超时、状态乱序/重复、双会话审批、rollout 增量索引）
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
- [ ] 人工确认同一会话的审批不会发送给另一会话

Swift 核心测试命令：

```bash
xcodebuild -project ClaudeIsland.xcodeproj -scheme ClaudeIsland \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test
```

自动化测试已经覆盖 `sessionId + toolUseId` 交叉串会话拒绝；上面的人工项仍保留，
用于确认真实 Claude Code/CLI 与已安装 App 的完整 wire path。

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
