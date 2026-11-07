import SwiftUI

public enum DiscoBrandVariant: String, Sendable {
    /// Icon only (`disco-icon.png`): App Icon, window badge, and compact sheet header badge.
    case iconOnly = "DiscoIcon"
    /// Wordmark only (`logo-text-only.png`): Compact inline Navigation Bar center title (`ios-navbar__inline-title`).
    case logoTextOnly = "DiscoLogoText"
    /// Full horizontal lockup (`icon-logo-text.png`): Sidebar header lockup on iPad/Mac and Empty State hero lockup.
    case iconLogoText = "DiscoIconLogoText"
}

/// Renders the official ColorDisco brand assets according to `@samios` spatial hierarchy rules.
public struct BrandAssetView: View {
    public let variant: DiscoBrandVariant
    public let height: CGFloat

    public init(variant: DiscoBrandVariant, height: CGFloat) {
        self.variant = variant
        self.height = height
    }

    public var body: some View {
        Image(variant.rawValue, bundle: .module)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(height: height)
            .accessibilityLabel(accessibilityLabelText)
    }

    private var accessibilityLabelText: String {
        switch variant {
        case .iconOnly:
            return "Disco App Icon"
        case .logoTextOnly:
            return "disco"
        case .iconLogoText:
            return "Disco Color Grading Studio"
        }
    }
}

