import CoreText
import SwiftUI

/// Workspace typography; the compact island retains its own size constraints.
public enum StudioType {
    case title, section, body, caption

    var size: CGFloat {
        switch self { case .title: 20; case .section: 14; case .body: 13; case .caption: 12 }
    }
    var leading: CGFloat {
        switch self { case .title: 28; case .section: 22; case .body: 20; case .caption: 16 }
    }
    var tracking: CGFloat {
        switch self { case .title: 0; case .section: 0; case .body: 0; case .caption: 0 }
    }
    var textStyle: Font.TextStyle {
        switch self { case .title: .title2; case .section: .headline; case .body: .body; case .caption: .caption }
    }
    var font: Font {
        #if os(macOS)
        // Use one system font cascade for Chinese, Latin text and native controls.
        return .system(size: size, weight: self == .title || self == .section ? .semibold : .regular)
        #else
        _ = StudioFont.registered
        return .custom("InterTight-Regular", size: size, relativeTo: textStyle)
            .weight(self == .title || self == .section ? .semibold : .regular)
        #endif
    }
}

private enum StudioFont {
    // Process registration also works for SwiftPM previews and fixture rendering.
    static let registered: Bool = {
        guard let url = Bundle.module.url(forResource: "InterTight", withExtension: "ttf") else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()
}

private struct StudioTypography: ViewModifier {
    let role: StudioType
    func body(content: Content) -> some View {
        content.font(role.font).tracking(role.tracking)
            .lineSpacing(max(0, role.leading - role.size))
    }
}

private struct StudioSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(PaperInk(scheme).surface)
        }
    }
}

public extension View {
    func studioType(_ role: StudioType) -> some View { modifier(StudioTypography(role: role)) }
    func studioSurface(radius: CGFloat = 11) -> some View { modifier(StudioSurface(radius: radius)) }
}

public struct StudioDivider: View {
    @Environment(\.colorScheme) private var scheme
    private let vertical: Bool
    public init(vertical: Bool = false) { self.vertical = vertical }
    public var body: some View {
        Rectangle().fill(PaperInk(scheme).track)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}

/// Flat compact Mac controls retain full touch targets on iPhone.
public struct StudioRaisedButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    private let iconOnly: Bool
    public init(iconOnly: Bool = false) { self.iconOnly = iconOnly }
    public func makeBody(configuration: Configuration) -> some View {
        let palette = PaperInk(scheme)
        configuration.label
            .studioType(.body)
            .foregroundStyle(palette.strong)
            #if os(macOS)
            .padding(.horizontal, iconOnly ? 0 : 10)
            .frame(width: iconOnly ? 28 : nil, height: 28)
            #else
            .padding(.horizontal, iconOnly ? 0 : 16)
            .frame(width: iconOnly ? 44 : nil, height: 44)
            #endif
            .background(palette.elevated, in: RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
