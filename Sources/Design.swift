import SwiftUI

enum VeilStyle {
    static let accent = Color("AccentColor")
    static let ink = Color.primary
    static let muted = Color.secondary
    static let line = Color.primary.opacity(0.12)
    static let paper = Color(uiColor: .systemGroupedBackground)
    static let onAccent = Color(uiColor: .systemBackground)
}

/// System glass on iOS 26; native bordered controls on earlier systems.
struct VeilActionStyle: ViewModifier {
    var prominent = false

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large)
            } else {
                content.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
            } else {
                content.buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
            }
        }
    }
}

struct VeilGlassGroup<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content }
        } else {
            content
        }
    }
}

struct ComparisonHandleSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(.regularMaterial, in: Circle())
        }
    }
}

struct StudioBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(uiColor: .systemBackground), VeilStyle.paper],
                       startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .topTrailing) {
                RadialGradient(colors: [VeilStyle.accent.opacity(0.07), .clear],
                               center: .topTrailing, startRadius: 0, endRadius: 480)
            }
            .ignoresSafeArea()
    }
}
