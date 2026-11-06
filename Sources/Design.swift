import SwiftUI

enum VeilStyle {
    static let accent = Color.primary
    static let ink = Color.primary
    static let muted = Color.secondary
    static let line = Color.primary.opacity(0.12)
    static let paper = Color(uiColor: .systemGroupedBackground)
    static let onAccent = Color(uiColor: .systemBackground)
}
struct VeilActionStyle: ViewModifier {
    var prominent = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large) }
            else { content.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large) }
        } else { content.buttonStyle(LegacyGlassButton(prominent: prominent)) }
    }
}
private struct LegacyGlassButton: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, prominent ? 23 : 15).padding(.vertical, 16)
            .background {
                if prominent { Capsule().fill(VeilStyle.accent) }
                else { Circle().fill(.ultraThinMaterial).overlay(Circle().stroke(.primary.opacity(0.12), lineWidth: 0.75)) }
            }
            .opacity(configuration.isPressed ? 0.65 : 1).scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
struct VeilGlassGroup<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *) { GlassEffectContainer(spacing: 12) { content } }
        else { content }
    }
}
struct VeilGlassSurface: ViewModifier {
    var radius: CGFloat = 26
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency { content.background(VeilStyle.paper, in: RoundedRectangle(cornerRadius: radius)) }
        else if #available(iOS 26.0, *) { content.glassEffect(.regular, in: .rect(cornerRadius: radius)) }
        else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(.primary.opacity(0.10), lineWidth: 0.75))
        }
    }
}
struct ComparisonHandleSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.glassEffect(.regular.interactive(), in: .circle) }
        else { content.background(.regularMaterial, in: Circle()) }
    }
}
struct StudioBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var drift = false
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(uiColor: .systemBackground)
                if !reduceTransparency {
                    Ellipse().fill(Color.primary.opacity(scheme == .dark ? 0.13 : 0.08))
                        .frame(width: proxy.size.width * 1.1, height: proxy.size.height * 0.55)
                        .rotationEffect(.degrees(drift ? -24 : 18))
                        .offset(x: proxy.size.width * (drift ? 0.24 : -0.22), y: -proxy.size.height * 0.18).blur(radius: 65)
                    Ellipse().fill(Color.primary.opacity(scheme == .dark ? 0.06 : 0.05))
                        .frame(width: proxy.size.width * 0.9, height: proxy.size.height * 0.35)
                        .rotationEffect(.degrees(-35)).offset(x: proxy.size.width * 0.28, y: proxy.size.height * 0.27).blur(radius: 70)
                }
            }
            .onAppear { if !reduceMotion { drift = true } }
            .animation(reduceMotion ? nil : .easeInOut(duration: 12).repeatForever(autoreverses: true), value: drift)
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
struct HomeSculpture: View {
    var body: some View {
        ZStack {
            Circle().fill(.primary.opacity(0.07)).frame(width: 210, height: 210).blur(radius: 38).offset(y: 25)
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 38, style: .continuous)
                    .fill(LinearGradient(colors: [.primary.opacity(0.10), .primary.opacity(0.015)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 38).stroke(LinearGradient(colors: [.primary.opacity(0.27), .primary.opacity(0.03), .primary.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                    .frame(width: 151, height: 187)
                    .rotationEffect(.degrees(Double(index - 1) * 17 - 8)).offset(x: CGFloat(index - 1) * 36, y: CGFloat(abs(index - 1)) * 12)
            }
            LucideIcon(name: "aperture", size: 57).foregroundStyle(.primary.opacity(0.8)).rotationEffect(.degrees(-8))
            HStack(spacing: 7) {
                Circle().fill(.primary).frame(width: 5, height: 5)
                Text("ON DEVICE").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2)
            }.padding(.horizontal, 15).padding(.vertical, 10).modifier(VeilGlassSurface(radius: 20)).offset(x: 73, y: 94)
        }.frame(height: 262).frame(maxWidth: .infinity).accessibilityHidden(true)
    }
}
