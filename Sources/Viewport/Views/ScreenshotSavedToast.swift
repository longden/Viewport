import AppKit
import SwiftUI

struct ScreenshotSavedToast: View {
    let url: URL
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(url.lastPathComponent)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }

                Button("Copy") {
                    copyScreenshot()
                }

                Spacer(minLength: 0)

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
        }
        .padding(12)
        .frame(minWidth: 280, maxWidth: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(
            cornerRadius: 12,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }

    private func copyScreenshot() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if ["png", "jpg", "jpeg", "gif", "tiff", "bmp"]
            .contains(url.pathExtension.lowercased()),
           let image = NSImage(contentsOf: url) {
            pasteboard.writeObjects([image])
        } else {
            pasteboard.setString(url.path, forType: .string)
        }
    }
}
