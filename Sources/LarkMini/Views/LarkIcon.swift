import SwiftUI
import AppKit

struct LarkIcon: View {
    var size: CGFloat = 32
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                InboxFaceIcon(size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .onAppear { image = LarkLaunch.icon() }
        .accessibilityHidden(true)
    }
}
