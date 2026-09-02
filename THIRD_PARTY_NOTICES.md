# Third-Party Notices

Agent Notch 的直接 Swift Package 依赖固定在
`ClaudeIsland.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`。
下列许可证原文取自该文件锁定的准确 revision，并同时打包进 App 的
`Contents/Resources/ThirdPartyLicenses/`。

| 组件 | 固定版本 / revision | 许可证 | 随附原文 | 项目 |
| --- | --- | --- | --- | --- |
| Sparkle | 2.9.4 / `b6496a74a087257ef5e6da1c5b29a447a60f5bd7` | MIT 与上游汇总的第三方许可 | [`ThirdPartyLicenses/Sparkle-2.9.4-LICENSE.txt`](ThirdPartyLicenses/Sparkle-2.9.4-LICENSE.txt) | <https://github.com/sparkle-project/Sparkle> |
| swift-markdown | 0.8.0 / `3c6f9523da3a1ec2fd829673e472d95b8097a3b8` | Apache License 2.0（含 Runtime Library Exception） | [`ThirdPartyLicenses/swift-markdown-0.8.0-LICENSE.txt`](ThirdPartyLicenses/swift-markdown-0.8.0-LICENSE.txt) | <https://github.com/swiftlang/swift-markdown> |
| swift-cmark | 0.8.0 / `924936d0427cb25a61169739a7660230bffa6ea6` | BSD-2-Clause；上游 `COPYING` 另汇总其打包内容的 MIT、CC-BY-SA-4.0 与 BSD-2-Clause 声明 | [`ThirdPartyLicenses/swift-cmark-0.8.0-COPYING.txt`](ThirdPartyLicenses/swift-cmark-0.8.0-COPYING.txt) | <https://github.com/swiftlang/swift-cmark> |

二进制发布必须保留这些完整许可证文本。发布检查会确认依赖版本、revision、许可证
文件哈希和 Xcode Resources 引用没有漂移。本文件不替代各依赖自己的 LICENSE/COPYING。
