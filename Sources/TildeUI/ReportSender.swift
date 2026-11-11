import AppKit
import os
import TildeCore

/// Makes the report of a session from its notes and takes it where it goes: the inbox, the
/// clipboard for a session without an agent, and the remote machines for that copy's images.
@MainActor
struct ReportSender {
    struct Report {
        let feedback: Feedback
        /// Its folder in the inbox.
        let folder: URL
    }

    /// Where sent reports go, and where a report without an agent is copied; tests give their own.
    var inbox = inboxRoot
    var pasteboard = NSPasteboard.general
    private let log = Logger(subsystem: "dev.tilde.app", category: "annotate")

    /// The report of `drafts`, saved to the inbox. It waits for every note's screenshots.
    func save(_ drafts: [Draft], of session: SessionStore.Session) async throws -> Report {
        var annotations: [Annotation] = []
        for draft in drafts {
            let captures = await draft.capture.value
            let annotation = draft.annotation
            annotations.append(Annotation(
                id: annotation.id, comment: annotation.comment, target: annotation.target, frame: annotation.frame,
                image: captures.image, contextImage: captures.contextImage
            ))
        }

        let feedback = Feedback(annotations: annotations)
        let inbox = self.inbox
        let folder = try await Task.detached { try saveToInbox(feedback, sessionID: session.id, node: session.node, root: inbox) }.value
        return Report(feedback: feedback, folder: folder)
    }

    /// Copies the report of a session without an agent.
    func copy(_ report: Report) {
        let text = reportText(for: report.feedback, folder: report.folder, linkFolder: homeRelativePath(report.folder))
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Sends a copied report's folder to each remote machine, so that one paste works on any of
    /// them. Returns the machines it did not reach.
    func push(_ report: Report) async -> [String] {
        await Self.push(report.folder, to: NodeStore().load().map(\.host), log: log)
    }

    private nonisolated static func push(_ folder: URL, to machines: [String], log: Logger) async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            for machine in machines {
                group.addTask {
                    do {
                        try await RemotePush.push(folder, to: machine)
                        return nil
                    } catch {
                        log.error("could not send feedback to \(machine, privacy: .public): \(String(describing: error), privacy: .public)")
                        return machine
                    }
                }
            }
            return await group.reduce(into: [String]()) { failed, machine in
                if let machine {
                    failed.append(machine)
                }
            }
        }
    }
}
