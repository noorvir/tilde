import AppKit
import SwiftUI
import TildeCore

/// Saved sessions for the History page, newest first.
@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var records: [SessionRecord] = []
    @Published var expanded: Set<String> = []
    let archive: SessionArchive
    /// The session on screen, which cannot be restored.
    let currentID: () -> String?
    let onRestore: (SessionRecord) -> Void
    let icon: (SessionRecord) -> NSImage?

    init(
        archive: SessionArchive, currentID: @escaping () -> String? = { nil },
        onRestore: @escaping (SessionRecord) -> Void = { _ in }, icon: @escaping (SessionRecord) -> NSImage? = { _ in nil }
    ) {
        self.archive = archive
        self.currentID = currentID
        self.onRestore = onRestore
        self.icon = icon
    }

    func reload() {
        records = archive.all()
    }

    func restore(_ record: SessionRecord) {
        onRestore(record)
        reload()
    }

    func delete(_ record: SessionRecord) {
        archive.delete(record.id)
        archive.flush()
        reload()
    }

    /// Every session but the one on screen, whose notes and recordings are still in use.
    func clear() {
        archive.deleteAll(except: currentID())
        archive.flush()
        reload()
    }

    /// The report as an agent or the clipboard gets it.
    func copyReport(_ record: SessionRecord) {
        let annotations = record.notes.map { note in
            let images = archive.images(of: note, in: record.id)
            return Annotation(id: note.id, comment: note.comment, target: note.target, frame: note.frame, image: images.image, contextImage: images.contextImage)
        }
        let feedback = Feedback(annotations: annotations)
        // An unsent session has no report folder yet; it gets one, as Send makes, so the
        // report's file names are there.
        guard let folder = record.reportFolder.map({ URL(fileURLWithPath: $0, isDirectory: true) }) ?? (try? saveToInbox(feedback, sessionID: record.id, node: record.node)) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportText(for: feedback, folder: folder), forType: .string)
    }

    func canRestore(_ record: SessionRecord) -> Bool {
        record.id != currentID() && !record.notes.isEmpty
    }
}

struct HistorySettings: View {
    @ObservedObject var history: HistoryModel
    @State private var confirmsClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsSection("Sessions") {
                if history.records.isEmpty {
                    SettingsRow(title: "No sessions yet", subtitle: "Sessions are saved while you annotate") {
                        EmptyView()
                    }
                }
                ForEach(Array(history.records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 {
                        SettingsDivider()
                    }
                    HistoryRow(history: history, record: record, isExpanded: expandedBinding(record))
                }
            }

            SettingsSection("Keeping") {
                SettingsRow(title: "Kept for \(SessionArchive.keptDays) days", subtitle: "And always the last \(SessionArchive.keptCount) sessions") {
                    Button("Clear History") {
                        confirmsClear = true
                    }
                    .disabled(history.records.isEmpty)
                }
            }
        }
        .onAppear(perform: history.reload)
        .confirmationDialog("Delete all saved sessions?", isPresented: $confirmsClear) {
            Button("Clear History", role: .destructive, action: history.clear)
        } message: {
            Text("Their notes and images are deleted. Sent reports stay in the inbox.")
        }
    }

    private func expandedBinding(_ record: SessionRecord) -> Binding<Bool> {
        Binding {
            history.expanded.contains(record.id)
        } set: { isExpanded in
            if isExpanded {
                history.expanded.insert(record.id)
            } else {
                history.expanded.remove(record.id)
            }
        }
    }
}

/// A session: when, for whom, where, how many notes and how it ended, with Restore; open,
/// its notes and the other actions.
private struct HistoryRow: View {
    @ObservedObject var history: HistoryModel
    let record: SessionRecord
    @Binding var isExpanded: Bool
    @State private var confirmsDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                icon
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(record.title)
                            .font(.system(size: 14))
                        StateBadge(state: record.id == history.currentID() ? nil : record.state)
                    }
                    Text(Self.subtitle(record))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                if history.canRestore(record) {
                    Button("Restore") {
                        history.restore(record)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            }
            .accessibilityElement(children: .contain)

            if isExpanded {
                details
                    .padding(.leading, 16 + 12 + 10 + 24 + 10)
                    .padding(.trailing, 16)
                    .padding(.bottom, 14)
            }
        }
        .contextMenu {
            actions
        }
        .confirmationDialog("Delete this session?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) {
                history.delete(record)
            }
        } message: {
            Text("Its notes and images are deleted.")
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let image = history.icon(record) {
            Image(nsImage: image)
                .resizable()
        } else {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(record.notes.enumerated()), id: \.element.id) { index, note in
                HStack(alignment: .top, spacing: 10) {
                    NoteThumbnail(data: history.archive.images(of: note, in: record.id).image)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(index + 1). \(note.chip)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(note.comment.isEmpty ? "(no comment)" : note.comment)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 8) {
                actions
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Copy Report") {
            history.copyReport(record)
        }
        .disabled(record.notes.isEmpty)
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([history.archive.folder(record.id)])
        }
        Button("Delete", role: .destructive) {
            confirmsDelete = true
        }
        .disabled(record.id == history.currentID())
    }

    /// "29 Oct 2026, 14:02 · Codex · 3 notes".
    static func subtitle(_ record: SessionRecord) -> String {
        let date = record.created.formatted(date: .abbreviated, time: .shortened)
        let count = record.notes.count
        let notes = "\(count) \(count == 1 ? "note" : "notes")"
        if record.isLocal {
            return "\(date) · \(notes)"
        }
        return "\(date) · \(record.client) · \(notes)"
    }
}

private struct StateBadge: View {
    /// Nil for the session on screen.
    let state: SessionRecord.State?

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.13)))
    }

    private var title: String {
        switch state {
        case nil: "In progress"
        case .active: "Unfinished"
        case .sent: "Sent"
        case .cancelled: "Cancelled"
        case .restored: "Restored"
        }
    }

    private var color: Color {
        switch state {
        case nil: .tildeBlue
        case .active: .orange
        case .sent: .green
        case .cancelled, .restored: .secondary
        }
    }
}

private struct NoteThumbnail: View {
    let data: Data?

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.primary.opacity(0.06)
            }
        }
        .frame(width: 44, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.1)))
    }
}
