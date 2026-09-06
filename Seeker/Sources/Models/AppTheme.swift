import Observation
import SwiftUI

/// Global, persisted visual style shared by the main window, Settings and
/// every standalone utility window. File-management behaviour remains native
/// to macOS; the Explorer option changes the app chrome and information layout.
@MainActor
@Observable
final class AppTheme {
    static let shared = AppTheme()

    var interfaceStyle: InterfaceStyle {
        didSet { SettingsManager.shared.interfaceStyle = interfaceStyle }
    }

    var isExplorer: Bool { interfaceStyle == .windowsExplorer }

    private init() {
        interfaceStyle = SettingsManager.shared.interfaceStyle
    }
}

struct ThemePalette {
    let style: InterfaceStyle
    let colorScheme: ColorScheme

    var isExplorer: Bool { style == .windowsExplorer }

    var accent: Color {
        isExplorer ? Color(red: 0.0, green: 0.47, blue: 0.84) : .accentColor
    }

    var windowBackground: Color {
        guard isExplorer else { return .clear }
        return colorScheme == .dark
            ? Color(red: 0.125, green: 0.125, blue: 0.125)
            : Color(red: 0.953, green: 0.953, blue: 0.953)
    }

    var contentBackground: Color {
        guard isExplorer else { return .clear }
        return colorScheme == .dark
            ? Color(red: 0.10, green: 0.10, blue: 0.10)
            : .white
    }

    var chromeBackground: Color {
        guard isExplorer else { return .clear }
        return colorScheme == .dark
            ? Color(red: 0.16, green: 0.16, blue: 0.16)
            : Color(red: 0.973, green: 0.973, blue: 0.973)
    }

    var controlBackground: Color {
        guard isExplorer else { return Color.primary.opacity(0.04) }
        return colorScheme == .dark ? Color.white.opacity(0.07) : .white
    }

    var border: Color {
        isExplorer
            ? (colorScheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.14))
            : Color.primary.opacity(0.08)
    }

    var hover: Color {
        isExplorer
            ? accent.opacity(colorScheme == .dark ? 0.22 : 0.11)
            : Color.primary.opacity(0.06)
    }

    var selection: Color {
        isExplorer
            ? accent.opacity(colorScheme == .dark ? 0.34 : 0.20)
            : Color.accentColor.opacity(0.20)
    }

    var cornerRadius: CGFloat { isExplorer ? 4 : 8 }
    var listRowHeight: CGFloat { isExplorer ? 28 : 22 }
}

private struct AppThemeRootModifier: ViewModifier {
    let theme: AppTheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme.isExplorer {
            content.tint(ThemePalette(style: theme.interfaceStyle, colorScheme: .light).accent)
        } else {
            content
        }
    }
}

extension View {
    func appThemeRoot(_ theme: AppTheme = .shared) -> some View {
        modifier(AppThemeRootModifier(theme: theme))
    }
}