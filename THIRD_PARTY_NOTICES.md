# Third-Party Notices

Agent Notch 的直接 Swift Package 依赖固定在
`ClaudeIsland.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`。

| 组件 | 固定版本 | 许可证 | 项目 |
| --- | --- | --- | --- |
| Sparkle | 2.9.4 | MIT-style license | <https://github.com/sparkle-project/Sparkle> |
| swift-markdown | 0.8.0 | Apache License 2.0 | <https://github.com/swiftlang/swift-markdown> |
| swift-cmark | 0.8.0 | BSD-3-Clause | <https://github.com/swiftlang/swift-cmark> |

二进制发布必须保留这些组件随源码提供的完整许可证文本。CI 的发布检查会确认依赖
版本和本清单没有明显漂移。本文件不替代各依赖自己的 LICENSE/COPYING。
