@testable import TildeUI
import Testing

/// Rules that hold in every state of the session flow, for every event; the contract rows
/// name the single rules.
struct SessionFlowTests {
    typealias Open = SessionFlow.Open

    /// A state of the flow with the facts of the session's data.
    struct State {
        let flow: SessionFlow
        let facts: SessionFlow.Facts

        var mode: SessionFlow.Mode { flow.mode }
    }

    /// Every kind of state: each activity, with and without pauses, a panel, each canvas and each
    /// question; sending; Sent; no session. Operation 3 is the one under way.
    static let states: [State] = {
        let activities: [SessionFlow.Activity] = [
            .annotating, .recording(.ready), .recording(.starting(operation: 3)), .recording(.recording), .recording(.paused),
            .recording(.finishing(operation: 3, thenSend: false)), .recording(.finishing(operation: 3, thenSend: true)),
            .picking(isPickerOpen: false), .picking(isPickerOpen: true),
        ]
        var opens: [Open] = []
        for activity in activities {
            for pauses in [[], [SessionFlow.PauseReason.user], [.hold, .otherApp]] as [Set<SessionFlow.PauseReason>] {
                for panel in [nil, SessionFlow.Panel.comment, .preview] {
                    for question in [nil, SessionFlow.Question.clearAll, .cancelSession, .discardComment, .discardRecording, .restore] {
                        opens.append(Open(activity: activity, pauses: pauses, panel: panel, question: question))
                    }
                }
            }
        }
        for canvas in [SessionFlow.Canvas.draw, .wireframe] {
            opens.append(Open(canvas: canvas))
            opens.append(Open(pauses: [.user], canvas: canvas))
        }
        let modes = opens.map(SessionFlow.Mode.open) + opens.prefix(18).map { .sending(operation: 3, returnTo: $0) }
            + [.sent(operation: 3), .idle]
        // With and without notes, and with and without text in the comment: the first
        // comment of a session has text and no note yet.
        let states = modes.flatMap { mode in
            [(0, false), (0, true), (2, false), (2, true)].map { notes, hasText in
                State(flow: SessionFlow(mode: mode, lastOperation: 3), facts: SessionFlow.Facts(notes: notes, commentHasText: hasText))
            }
        }
        return states.filter(isReachable)
    }()

    /// Only states a session can be in: a question is about something that is there.
    private static func isReachable(_ state: State) -> Bool {
        if case .sending(_, let returnTo) = state.mode {
            // Send takes no question with it.
            return returnTo.question == nil
        }
        guard case .open(let open) = state.mode, let question = open.question else {
            return true
        }
        // Choosing holds no question, and only the comment's own is asked while it is open.
        if open.activity.isPicking || (open.panel == .comment && question != .discardComment) {
            return false
        }
        switch question {
        case .discardRecording: return open.clipInProgress
        case .discardComment: return open.panel == .comment && state.facts.commentHasText
        case .clearAll: return state.facts.notes > 0
        case .cancelSession: return state.facts.notes > 0 || open.holdsClip
        case .restore: return true
        }
    }

    static let events: [SessionFlow.Event] = [
        .begin, .ended, .escape, .togglePause, .toggleAnnotating, .resume, .startShortcut,
        .requestClearAll, .requestCancel, .confirm, .dismissConfirmation, .restore, .openBrowser, .deleteNote, .editNote, .holdBegan, .holdEnded, .otherAppInFront,
        .scopeAppInFront, .openComment, .clickAway, .submitComment, .openPreview, .closePreview, .toggleList,
        .startDrawing, .finishDrawing, .undoDrawing, .redoDrawing, .shapeFinished, .startWireframe, .wireframeTaken,
        .toggleRecordingMode, .record, .stop,
        .clipStarted(3), .clipStarted(2), .clipStartFailed(3), .clipStartFailed(2), .clipFinished(3), .clipFinished(2),
        .clipFailed(3), .clipFailed(2), .captureStopped, .windowClosed, .windowButton, .openPicker, .choose,
        .send, .sendFinished(3), .sendFinished(2), .sendFailed(3), .sendFailed(2), .sentShown(3), .sentShown(2), .pushFailed,
    ]

    /// Runs every event in every state; `check` gets the state before, the event, the state
    /// after and the effects.
    private func everyTransition(_ check: (State, SessionFlow.Event, SessionFlow, [SessionFlow.Effect]) -> Void) {
        for state in Self.states {
            for event in Self.events {
                var next = state.flow
                let effects = next.handle(event, state.facts)
                check(state, event, next, effects)
            }
        }
    }

    private static func isOutside(_ event: SessionFlow.Event) -> Bool {
        switch event {
        case .ended, .holdEnded, .otherAppInFront, .scopeAppInFront, .clipStarted, .clipStartFailed, .clipFinished, .clipFailed, .captureStopped,
             .windowClosed:
            true
        default:
            false
        }
    }

    /// A question waits for its answer: under it, only the answers, Esc, the session's end
    /// and changes from outside act.
    @Test func aQuestionBlocksEveryOtherEvent() {
        everyTransition { state, event, next, effects in
            guard case .open(let open) = state.mode, open.question != nil, !open.activity.isPicking else {
                return
            }
            if [.confirm, .dismissConfirmation, .escape].contains(event) || Self.isOutside(event) {
                return
            }
            #expect(next == state.flow && effects.isEmpty, "\(open) + \(event) gave \(effects)")
        }
    }

    /// While the report is made, only its own results, the hold key and the session's end act;
    /// an older result changes nothing and throws away a clip.
    @Test func nothingActsWhileSending() {
        everyTransition { state, event, next, effects in
            guard case .sending = state.mode else {
                return
            }
            switch event {
            case .sendFinished(3), .sendFailed(3), .holdEnded, .ended:
                return
            case .clipStarted, .clipFinished:
                #expect(next == state.flow && effects == [.dropClip], "\(event) gave \(effects)")
            default:
                #expect(next == state.flow && effects.isEmpty, "\(event) gave \(effects)")
            }
        }
    }

    /// A result of an operation that is not under way changes nothing, and only throws away
    /// its recorder or file.
    @Test func aStaleResultOnlyDropsItsClip() {
        everyTransition { state, event, next, effects in
            switch event {
            case .clipStarted(2), .clipFinished(2):
                #expect(next == state.flow && (effects == [.dropClip] || effects.isEmpty), "\(state.mode) + \(event) gave \(effects)")
            case .clipStartFailed(2), .clipFailed(2), .sendFinished(2), .sendFailed(2), .sentShown(2):
                #expect(next == state.flow && effects.isEmpty, "\(state.mode) + \(event) gave \(effects)")
            default:
                break
            }
        }
    }

    /// While choosing, only the window button, Esc, the picker, a choice, the record toggle,
    /// Draw, the hold key, the front app and the session's end act.
    @Test func choosingTakesOnlyItsEvents() {
        everyTransition { state, event, next, effects in
            guard case .open(let open) = state.mode, open.activity.isPicking else {
                return
            }
            switch event {
            case .escape, .windowButton, .openPicker, .choose, .toggleRecordingMode, .startDrawing, .holdEnded, .otherAppInFront, .scopeAppInFront, .ended:
                return
            case .clipStarted, .clipFinished:
                #expect(next == state.flow && effects == [.dropClip], "\(event) gave \(effects)")
            default:
                #expect(next == state.flow && effects.isEmpty, "\(open) + \(event) gave \(effects)")
            }
        }
    }

    @Test func aSessionStartsOnlyFromNone() {
        everyTransition { state, event, next, _ in
            guard case .begin = event else {
                return
            }
            switch state.mode {
            case .idle, .sent:
                #expect(next.session != nil)
            case .open, .sending:
                #expect(next == state.flow)
            }
        }
    }

    /// The pill shows a question only while ↩ on it still does what it says, to something that
    /// is there: notes to clear, a session with notes or a clip to close, words to discard, a
    /// clip in progress to throw away, notes to replace.
    @Test func aQuestionIsAskedOnlyWhileReturnStillLosesSomething() {
        everyTransition { state, event, next, kept in
            guard case .open(let open) = next.mode, let question = open.question, state.mode != next.mode else {
                return
            }
            // A clip that the event saved is a note by now.
            var facts = state.facts
            if kept.contains(.keepClip) {
                facts.notes += 1
            }
            var answered = next
            let effects = answered.handle(.confirm, facts)
            let context = "\(state.mode) + \(event)"
            switch question {
            case .clearAll: #expect(effects.contains(.clearDrafts) && facts.notes > 0, "\(context)")
            case .cancelSession: #expect(effects.contains(.cancelSession) && (facts.notes > 0 || open.holdsClip), "\(context)")
            case .discardComment: #expect(effects.contains(.closeComposer) && facts.commentHasText, "\(context)")
            case .discardRecording: #expect(effects.contains(.exitRecording) && open.clipInProgress, "\(context)")
            case .restore: #expect(effects.contains(.restoreDrafts), "\(context)")
            }
        }
    }

    /// No question opens over a comment but the comment's own, so ↩ typed in the comment never
    /// answers a question about the session.
    @Test func aQuestionNeverOpensOverAComment() {
        everyTransition { state, event, next, _ in
            guard case .open(let open) = next.mode, open.panel == .comment, let question = open.question else {
                return
            }
            #expect(question == .discardComment, "\(state.mode) + \(event) asks \(question) over a comment")
        }
    }

    /// Esc on a question about the session dismisses it and changes nothing else.
    @Test func escOnAQuestionOnlyDismissesIt() {
        everyTransition { state, event, next, effects in
            guard event == .escape, case .open(var open) = state.mode, let question = open.question, question != .discardComment,
                  !open.activity.isPicking
            else {
                return
            }
            open.question = nil
            #expect(next.mode == .open(open) && effects.isEmpty, "\(state.mode) + Esc gave \(next.mode), \(effects)")
        }
    }

    /// An effect whose data the caller gives comes only from the event that gives it, so the
    /// caller never misses it.
    @Test func aDataEffectComesOnlyFromItsOwnEvent() {
        everyTransition { state, event, _, effects in
            for effect in effects {
                let isOwn = switch (effect, event) {
                case (.showComment, .openComment), (.showPreview, .openPreview), (.applySource, .choose), (.finishSend, .sendFinished),
                     (.adoptClip, .clipStarted), (.keepClip, .clipFinished), (.dropClip, .clipStarted), (.dropClip, .clipFinished),
                     (.showPushFailure, .pushFailed), (.askRestore, .restore), (.deleteNote, .deleteNote), (.editNote, .editNote):
                    true
                case (.showComment, _), (.showPreview, _), (.applySource, _), (.finishSend, _), (.adoptClip, _), (.keepClip, _),
                     (.dropClip, _), (.showPushFailure, _), (.askRestore, _), (.deleteNote, _), (.editNote, _):
                    false
                default:
                    true
                }
                #expect(isOwn, "\(state.mode) + \(event) gave \(effect)")
            }
        }
    }
}
