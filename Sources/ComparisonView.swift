import SwiftUI

struct ComparisonView: View {
    let original: UIImage
    let processed: UIImage?
    @Binding var position: Double

    var body: some View {
        VStack(spacing: 14) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    VeilStyle.line.opacity(0.4)
                    Image(uiImage: processed ?? original).resizable().scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    if processed != nil {
                        Image(uiImage: original).resizable().scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: geometry.size.width * position)
                            }
                        Rectangle().fill(.white).frame(width: 1.5)
                            .offset(x: geometry.size.width * position)
                        Image(systemName: "chevron.left.chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(VeilStyle.ink)
                            .frame(width: 38, height: 38)
                            .background(.white, in: Circle())
                            .shadow(color: .black.opacity(0.1), radius: 10, y: 3)
                            .offset(x: geometry.size.width * position - 19)
                            .accessibilityHidden(true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 25))
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { value in
                    guard processed != nil, geometry.size.width > 0,
                          abs(value.translation.width) > abs(value.translation.height) else { return }
                    position = min(1, max(0, value.location.x / geometry.size.width))
                })
            }
            .aspectRatio(max(0.55, min(1.6, original.size.width / max(1, original.size.height))), contentMode: .fit)
            .frame(maxHeight: 440)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(processed == nil ? "Выбранное фото" : "Сравнение до и после")
            if processed != nil {
                HStack {
                    Text("Оригинал")
                    Slider(value: $position, in: 0...1)
                        .tint(VeilStyle.ink)
                        .accessibilityLabel("Граница сравнения")
                        .accessibilityIdentifier("comparisonSlider")
                    Text("Результат")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(VeilStyle.muted)
            }
        }
    }
}
