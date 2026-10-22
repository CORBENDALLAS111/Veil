import SwiftUI

enum VeilStyle {
    static let ink = Color(red: 0.12, green: 0.19, blue: 0.17)
    static let muted = Color(red: 0.39, green: 0.45, blue: 0.41)
    static let paper = Color(red: 0.96, green: 0.96, blue: 0.93)
    static let accent = Color(red: 0.78, green: 0.88, blue: 0.68)
    static let line = Color(red: 0.84, green: 0.87, blue: 0.81)
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, minHeight: 58)
            .foregroundStyle(VeilStyle.paper)
            .background(VeilStyle.ink, in: Capsule())
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct NoiseEmblem: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle().fill(VeilStyle.accent.opacity(0.24)).frame(width: 240, height: 240)
            Circle().stroke(VeilStyle.line.opacity(0.7), lineWidth: 1).frame(width: 280, height: 280)
            Canvas { context, size in
                for row in 0..<21 {
                    for col in 0..<21 {
                        let x = Double(col - 10)
                        let y = Double(row - 10)
                        let distance = sqrt(x * x + y * y)
                        guard distance < 10 else { continue }
                        let radius = max(0.65, (1 - distance / 11) * 2.8)
                        let offset = expanded ? sin(x * 2.7 + y * 1.3) * 1.8 : 0
                        let rect = CGRect(x: Double(size.width) / 2 + x * 11 + offset,
                                          y: Double(size.height) / 2 + y * 11, width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(VeilStyle.ink.opacity(0.16 + (1 - distance / 11) * 0.55)))
                    }
                }
            }.frame(width: 248, height: 248)
            Image(systemName: "viewfinder")
                .font(.system(size: 82, weight: .ultraLight))
                .foregroundStyle(VeilStyle.ink)
        }
        .frame(height: 290)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { expanded = true }
        }
    }
}
