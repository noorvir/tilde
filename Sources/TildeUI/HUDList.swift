import SwiftUI

/// The annotations so far, styled like a context list: thumbnail, type chip, comment.
struct AnnotationList: View {
    @ObservedObject var controller: AnnotationController

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(controller.drafts.enumerated()), id: \.element.id) { index, draft in
                if index > 0 {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.leading, PillMetrics.leadingInset).padding(.trailing, PillMetrics.endInset)
                }
                AnnotationRow(number: index + 1, draft: draft, controller: controller)
            }
        }
        .padding(.vertical, 4)
        .frame(width: HUDView.width)
        .hudCard()
        .environment(\.colorScheme, .dark)
    }
}

private struct AnnotationRow: View {
    let number: Int
    let draft: Draft
    @ObservedObject var controller: AnnotationController
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Thumbnail(data: draft.annotation.image)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("\(number)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.tildeBlue))
                    if case .region = draft.annotation.target {
                        Text("Selected region")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(draft.isUnfinished ? "\(draft.chip) draft" : draft.chip)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
                    }
                }
                Text(draft.annotation.comment.isEmpty ? "No comment" : draft.annotation.comment)
                    .font(.system(size: 13))
                    .foregroundStyle(draft.annotation.comment.isEmpty ? .secondary : .primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // A button's click does not reach the row's tap gesture, so Delete never opens the preview.
            HUDButton(image: Image(systemName: "trash"), size: 26, isDestructive: true, help: "Delete note") {
                controller.deleteDraft(draft.id)
            }
            .disabled(!controller.canEditNotes)
        }
        .padding(.leading, PillMetrics.leadingInset)
        .padding(.trailing, PillMetrics.endInset)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(isHovered ? 0.06 : 0)).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { controller.preview(draft.id) }
        .tildeTooltip("Preview")
    }
}

private struct Thumbnail: View {
    let data: Data?
    @StateObject private var decoded = DecodedImage()

    var body: some View {
        Group {
            if let image = decoded.image(of: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 52, height: 36)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.1)))
    }
}
