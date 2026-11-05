import TildeCore
import SwiftUI

/// The session's notes beside the page, grouped by page. Notes on the page that is open are
/// active, with a line to their element; notes on other pages are muted, and a click opens
/// their page.
struct NotesPanel: View {
    @ObservedObject var controller: AnnotationController
    @ObservedObject var browser: BrowserController

    var body: some View {
        let groups = Self.groups(controller.drafts)

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notes")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(controller.drafts.count)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .frame(height: 40)

            if controller.drafts.isEmpty {
                Text("Annotate the page, and your notes show here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(groups, id: \.page) { group in
                            PageGroup(group: group, controller: controller, browser: browser)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                // Adds to the cards' values from inside the list instead of replacing them.
                .transformAnchorPreference(key: NoteGeometry.self, value: .bounds) { value, bounds in value.panel = bounds }
            }
        }
        .background(RoundedRectangle(cornerRadius: BrowserMetrics.pageRadius).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: BrowserMetrics.pageRadius).strokeBorder(Color.white.opacity(0.1)))
    }

    struct Group {
        /// The page URL, or "" for notes outside the browser.
        let page: String
        let title: String?
        let notes: [(number: Int, draft: Draft)]
    }

    /// Notes grouped by page in the order the pages were first annotated; the numbers are the
    /// notes' order in the session.
    static func groups(_ drafts: [Draft]) -> [Group] {
        var order: [String] = []
        var notes: [String: [(Int, Draft)]] = [:]
        var titles: [String: String] = [:]
        for (index, draft) in drafts.enumerated() {
            let page = draft.anchor?.url ?? ""
            if notes[page] == nil {
                order.append(page)
            }
            notes[page, default: []].append((index + 1, draft))
            if case .element(.web(let element)) = draft.annotation.target, !element.title.isEmpty {
                titles[page] = titles[page] ?? element.title
            }
        }
        return order.map { Group(page: $0, title: titles[$0], notes: notes[$0] ?? []) }
    }
}

private struct PageGroup: View {
    let group: NotesPanel.Group
    @ObservedObject var controller: AnnotationController
    @ObservedObject var browser: BrowserController

    var body: some View {
        let isCurrent = !group.page.isEmpty && group.page == browser.pageURL

        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                // The page title over its path; without a title, the path alone.
                Text(group.page.isEmpty ? "Other windows" : group.title ?? PageAnchor.shortName(of: group.page))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                if !group.page.isEmpty, group.title != nil {
                    Text(PageAnchor.shortName(of: group.page))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)

            ForEach(group.notes, id: \.draft.id) { note in
                NoteCard(
                    number: note.number, draft: note.draft, isOnPage: isCurrent || group.page.isEmpty,
                    isFound: browser.anchorRects[note.draft.id] != nil || group.page.isEmpty,
                    isSelected: browser.selectedNote == note.draft.id, controller: controller, browser: browser
                )
            }
        }
    }
}

/// One note: its number, what it points at, and the comment, editable in place. Delete shows
/// under the pointer.
private struct NoteCard: View {
    let number: Int
    let draft: Draft
    /// On the page that is open; other pages' notes are muted.
    let isOnPage: Bool
    let isFound: Bool
    let isSelected: Bool
    @ObservedObject var controller: AnnotationController
    @ObservedObject var browser: BrowserController
    @State private var comment = ""
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(number)")
                    .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.tildeBlue))
                Text(target)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    controller.deleteDraft(draft.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.red)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .disabled(!controller.canEditNotes)
                .help("Delete this note")
                .accessibilityLabel("Delete note \(number)")
            }

            TextField("Comment", text: $comment, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .lineLimit(1...6)
                .disabled(!controller.canEditNotes)
                .onSubmit { controller.updateComment(draft.id, comment) }
                .onChange(of: comment) { _, text in
                    controller.updateCommentSoon(draft.id, text)
                }

            if let status {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(isSelected ? 0.1 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Color.tildeBlue : Color.white.opacity(0.1)))
        .opacity(isOnPage ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering in
            isHovered = hovering
            browser.hoveredNote = hovering ? draft.id : nil
        }
        .anchorPreference(key: NoteGeometry.self, value: .bounds) { NoteGeometry.Value(cards: [draft.id: $0]) }
        .onAppear { comment = draft.annotation.comment }
        .accessibilityElement(children: .contain)
    }

    private var target: String {
        if draft.anchor?.isRegion == true {
            return "Region"
        }
        return draft.chip
    }

    private var status: String? {
        if !isOnPage, let page = draft.anchor?.url {
            return "on \(PageAnchor.shortName(of: page))"
        }
        if !isFound {
            return "Not found on this page"
        }
        return nil
    }

    /// An active note highlights its element and scrolls to it; a muted one opens its page
    /// and scrolls there. Clicking the selected active note again clears the highlight.
    private func select() {
        if isOnPage, browser.selectedNote == draft.id {
            browser.selectedNote = nil
            return
        }
        browser.reveal(draft.id)
    }
}
