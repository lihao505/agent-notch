// Modified by lihao505 for Agent Notch, 2026.
import SwiftUI

/// Window controls follow system appearance; the hardware notch stays black.
private struct SettingsSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        contrast == .increased
                            ? Color.primary : Color(nsColor: .separatorColor),
                        lineWidth: contrast == .increased ? 1 : 0.5
                    )
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func settingsSurface() -> some View {
        modifier(SettingsSurface())
    }
}
