import AVKit
import SwiftUI

struct MovieComparisonView: View {
    let original: URL
    let processed: URL?
    let aspectRatio: CGFloat
    let maximumHeight: CGFloat
    @State private var showsOriginal = false
    @State private var player: AVPlayer?

    private var url: URL { showsOriginal ? original : (processed ?? original) }

    var body: some View {
        VStack(spacing: 10) {
            VideoPlayer(player: player)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(maxHeight: maximumHeight)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .accessibilityIdentifier("videoPreview")
            if processed != nil {
                Picker("Просмотр видео", selection: $showsOriginal) {
                    Text("До").tag(true)
                    Text("После").tag(false)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("videoComparison")
            }
        }
        .task(id: url) {
            player?.pause()
            player = AVPlayer(url: url)
        }
        .onDisappear { player?.pause(); player = nil }
    }
}
