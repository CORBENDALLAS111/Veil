import SwiftUI

/// Lucide vectors pinned to 53fab88; ISC/Feather MIT notices bundled.
struct LucideIcon: View {
    let name: String
    var size: CGFloat = 22
    var body: some View {
        Image("lucide-" + name).renderingMode(.template).resizable()
            .scaledToFit().frame(width: size, height: size).accessibilityHidden(true)
    }
}
struct LucideLabel: View {
    let title: String
    let icon: String
    var body: some View {
        HStack(spacing: 10) { LucideIcon(name: icon, size: 20); Text(title) }
            .accessibilityElement(children: .combine)
    }
}
