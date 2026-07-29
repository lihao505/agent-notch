# Agent Notch 素材来源与发布闸门

所有状态为“阻断”的项目都不得随公开仓库、DMG、官网或付费版本发布。

| 素材包 | 路径 | 当前来源记录 | 发布状态 | 上线前要求 |
| --- | --- | --- | --- | --- |
| App 图标 | `ClaudeIsland/Assets.xcassets/AppIcon.appiconset/` | Agent Notch 自制图标；源文件为 `docs/assets/agent-notch-app-icon-black-pet-v1.png`，由 `scripts/generate-agent-notch-cover.py` 与 `scripts/build-app-icon-set.py` 生成。桌宠部分沿用已记录的用户授权生产帧。 | 可用（项目自制） | 发布包保留源 PNG、生成脚本与本表。 |
| Vibe Pet 生产帧 | `ClaudeIsland/Resources/VibePet/` | 用户于 2026-07-29 确认由其使用 AI 生成，并授权 Agent Notch 商用与发布；保留对应 `.pxo` 源文件与技术 README。 | 可用（声明已记录） | 发布包保留本表、源文件与生成记录；如合作发行，补充书面授权归档。 |
| Pixel Loaders 生产帧 | `ClaudeIsland/Resources/PixelLoaders/` | 用户于 2026-07-29 确认由其使用 AI 生成，并授权 Agent Notch 商用与发布；保留对应 Pixelorama 源文件与技术 README。 | 可用（声明已记录） | 发布包保留本表、源文件与生成记录；如合作发行，补充书面授权归档。 |
| SF Symbols | 系统符号 | Apple 平台 API 提供 | 待审 | 仅按 Apple 的平台许可使用，不作为独立导出素材。 |
| Sparkle / swift-markdown / swift-cmark | Swift Package 依赖 | `Package.resolved` 与 `THIRD_PARTY_NOTICES.md` | 可用（许可证已识别） | 发布包保留完整 LICENSE/COPYING；升级版本时重新审计。 |

## 像素素材生产规范

- 生产帧必须是透明、硬边、无内置光晕的 PNG；外部 glow 只在运行时渲染。
- 保留 Pixelorama `.pxo`、帧导出脚本、spritesheet 与变更记录。
- 新增素材必须先写入本表，才能接入 App Bundle。
- 不能确认来源的帧、GIF、参考截图或调色板不得进入生产资源目录。
