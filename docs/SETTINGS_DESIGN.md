# 设置窗口设计约定

本轮是现有原生设置窗口的视觉与信息层级改进，不改变审批默认值、Hook 配置、
快捷键绑定或状态机。保留 Agent Notch 图标与像素刘海，不复制第三方界面或素材。

## 设计来源

- 用户要求：更清晰、美观，参考 Apple 的原生设计语言。
- [Apple Settings](https://developer.apple.com/design/human-interface-guidelines/settings)：
  保持稳定、明确的分类导航，窗口标题反映当前页面。
- [Apple Typography](https://developer.apple.com/design/human-interface-guidelines/typography)：
  使用系统字体，以尺寸、字重和语义颜色表达层级。
- [Apple Materials](https://developer.apple.com/design/human-interface-guidelines/materials)：
  使用平台材质与语义色，考虑减少透明度和对比度设置。

## 当前实现

- 技术栈保持 SwiftUI / AppKit，macOS 15.5 起可用；不引入 WebView 或新视觉依赖。
- 系统 `List(.sidebar)` 负责导航、选中和键盘语义；切换页面不加过渡动画。
- 通用保留语言、审批方式和刘海行为；提醒与静默放入通知，三个录制器放入快捷键。
  声音、显示器和桥接仍在系统页，所有原控件与绑定保留。
- 只在外观页展示隔离的模拟预览，使用原生分段控件切换四种状态。
- 页面标题 24 pt，正文/控制标签 13 pt，说明 11 pt，原生 SF Symbols 图标。
- 设置分组复用 `SettingsSurface`；系统底色、细分隔线，无装饰渐变或点阵背景。
  增强对比度时加深分组边界；减少透明度时侧栏使用不透明系统底色。
- 内容最大宽度 660 pt，窗口最小内容尺寸 780 × 560 pt；右侧可滚动。
- 硬件刘海仍使用黑色背景，与跟随系统外观的设置窗口分开处理。

## 验收边界

- 检查六页导航、当前页标题、滚动复位、外观预览与快捷键录制器可见性。
- 视觉验收不得改变审批权限、安装 Hook、设置全局快捷键或提交真实请求。
- 系统外观、减少动态效果/透明度、增强对比度的代码适配，不等同于这些系统设置的
  全部人工验收；实际检查范围另记于发布清单。
