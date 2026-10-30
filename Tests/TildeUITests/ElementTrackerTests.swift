@testable import TildeUI
import CoreGraphics
import Testing

struct ElementTrackerTests {
    @Test func aNoteShowsWhileEnoughOfItsElementIsInView() {
        let element = CGRect(x: 100, y: 100, width: 100, height: 40)
        let scrollArea = CGRect(x: 0, y: 0, width: 800, height: 600)

        #expect(ElementTracker.visibleFrame(element, clips: [scrollArea]) == element)
        // Half scrolled out at the top: the visible part.
        let half = CGRect(x: 0, y: 120, width: 800, height: 600)
        #expect(ElementTracker.visibleFrame(element, clips: [half]) == CGRect(x: 100, y: 120, width: 100, height: 20))
        // Less than 30 % in view, or out of view: hidden.
        let mostlyOut = CGRect(x: 0, y: 130, width: 800, height: 600)
        #expect(ElementTracker.visibleFrame(element, clips: [mostlyOut]) == nil)
        #expect(ElementTracker.visibleFrame(element, clips: [CGRect(x: 0, y: 300, width: 800, height: 300)]) == nil)
        // Every clip counts: the scroll area and the window.
        #expect(ElementTracker.visibleFrame(element, clips: [scrollArea, CGRect(x: 150, y: 0, width: 800, height: 600)]) == CGRect(x: 150, y: 100, width: 50, height: 40))
    }

    @Test func aLostElementIsFoundAgainByRoleAndNameNearestToWhereItWas() {
        let identity = ElementTracker.Identity(role: "AXStaticText", name: "Hello")
        let last = CGRect(x: 100, y: 300, width: 200, height: 20)
        let candidates = [
            ElementTracker.Candidate(role: "AXStaticText", name: "Other", frame: CGRect(x: 100, y: 300, width: 200, height: 20)),
            ElementTracker.Candidate(role: "AXStaticText", name: "Hello", frame: CGRect(x: 100, y: 900, width: 200, height: 20)),
            ElementTracker.Candidate(role: "AXStaticText", name: "Hello", frame: CGRect(x: 100, y: 260, width: 200, height: 20)),
            ElementTracker.Candidate(role: "AXButton", name: "Hello", frame: CGRect(x: 100, y: 300, width: 200, height: 20)),
        ]

        #expect(ElementTracker.bestMatch(candidates, for: identity, near: last) == 2)
    }

    @Test func anUnnamedElementIsFoundAgainOnlyAtAlmostTheSamePlace() {
        let identity = ElementTracker.Identity(role: "AXGroup", name: nil)
        let last = CGRect(x: 100, y: 300, width: 200, height: 80)
        let moved = [ElementTracker.Candidate(role: "AXGroup", name: nil, frame: CGRect(x: 100, y: 500, width: 200, height: 80))]
        let same = [ElementTracker.Candidate(role: "AXGroup", name: nil, frame: CGRect(x: 102, y: 301, width: 200, height: 80))]

        // Hidden rather than on some other group.
        #expect(ElementTracker.bestMatch(moved, for: identity, near: last) == nil)
        #expect(ElementTracker.bestMatch(same, for: identity, near: last) == 0)
        #expect(ElementTracker.bestMatch([], for: identity, near: last) == nil)
    }
}

@MainActor
struct OcclusionTests {
    @Test func windowsInFrontOfANotesWindowCoverItAndMissingWindowsHideTheirNotes() {
        let finder = AnnotationController.StackWindow(number: 1, frame: CGRect(x: 100, y: 50, width: 800, height: 600))
        let claude = AnnotationController.StackWindow(number: 2, frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        let faraway = AnnotationController.StackWindow(number: 3, frame: CGRect(x: 2000, y: 0, width: 400, height: 400))
        let back = AnnotationController.StackWindow(number: 4, frame: CGRect(x: 0, y: 0, width: 1500, height: 1000))
        // Front to back.
        let stack = [faraway, finder, claude, back]

        let result = AnnotationController.covers(of: [1, 2, 9], in: stack)

        // Finder is in front: nothing covers it. Claude is behind Finder; the faraway window
        // in front does not overlap it.
        #expect(result.covers[1] == [])
        #expect(result.covers[2] == [finder.frame])
        // A closed, minimised or other-Space window is not on screen: its notes hide.
        #expect(result.missing == [9])
    }
}

struct NoteVisibilityTests {
    @Test func aNoteHidesAndComesBackWithoutFlicker() {
        var note = NoteVisibility()
        // One odd reading changes nothing.
        #expect(note.update(similarity: 0.2) == true)
        #expect(note.update(similarity: 0.99) == true)
        // Two in a row hide it.
        #expect(note.update(similarity: 0.2) == true)
        #expect(note.update(similarity: 0.2) == false)
        // Between the thresholds it stays as it is.
        #expect(note.update(similarity: 0.8) == false)
        #expect(note.update(similarity: 0.8) == false)
        // Two matching readings bring it back.
        #expect(note.update(similarity: 0.95) == false)
        #expect(note.update(similarity: 0.95) == true)
    }

    private func picture(_ level: (Int, Int) -> UInt8) -> NoteFingerprint {
        NoteFingerprint(levels: (0..<48).flatMap { y in (0..<48).map { x in level(x, y) } })
    }

    @Test func differentContentWithTheSameBrightnessIsNotAlike() {
        // Like two pages of text: the same amount of dark on white, in other places.
        let page = picture { x, y in (x / 3 + y / 3).isMultiple(of: 2) ? 255 : 40 }
        let other = picture { x, y in (x / 3 + y / 3).isMultiple(of: 2) ? 40 : 255 }
        #expect(page.similarity(to: page) > 0.99)
        #expect(page.similarity(to: other) < 0.2)
    }

    @Test func plainAreasCompareByBrightness() {
        let white = picture { _, _ in 255 }
        let red = picture { _, _ in 90 }
        let text = picture { x, _ in x.isMultiple(of: 4) ? 0 : 255 }
        #expect(white.similarity(to: white) == 1)
        #expect(white.similarity(to: red) == 0)
        #expect(white.similarity(to: text) == 0)
    }
}

struct PageIdentityTests {
    @Test func addressesAndTitlesTellPagesApart() {
        let feed = PageIdentity(url: "https://x.com/home", title: "Home / X")
        #expect(feed.isSamePage(as: PageIdentity(url: "https://x.com/home", title: "(1) Home / X")) == true)
        #expect(feed.isSamePage(as: PageIdentity(url: "https://x.com/explore", title: "Home / X")) == false)
        // One failed read of the address does not hide the note.
        #expect(feed.isSamePage(as: PageIdentity(url: nil, title: "Home / X")) == nil)

        let folder = PageIdentity(url: nil, title: "Downloads")
        #expect(folder.isSamePage(as: PageIdentity(url: nil, title: "Desktop")) == false)

        // The Simulator: the title stays the same, so the picture must decide.
        let simulator = PageIdentity(url: nil, title: "iPhone 16")
        #expect(simulator.isSamePage(as: simulator) == nil)
        #expect(PageIdentity(url: nil, title: nil).isSamePage(as: simulator) == nil)
    }

    @Test func aFragmentIsTheSamePage() {
        #expect(PageIdentity.withoutFragment("https://a.test/docs#intro") == "https://a.test/docs")
        #expect(PageIdentity.withoutFragment("https://a.test/#/inbox") == "https://a.test/#/inbox")
    }
}

struct HoldGestureTests {
    @Test func holdingAloneBeginsAndReleasingEnds() {
        var gesture = HoldGesture()
        #expect(gesture.flagsChanged(key: true, others: false, at: 0) == nil)
        #expect(gesture.delayPassed(at: 0.15) == .began)
        #expect(gesture.flagsChanged(key: false, others: false, at: 2) == .ended)
    }

    @Test func aTapOrAChordIsNoHold() {
        var gesture = HoldGesture()
        _ = gesture.flagsChanged(key: true, others: false, at: 0)
        #expect(gesture.flagsChanged(key: false, others: false, at: 0.05) == nil)
        #expect(gesture.delayPassed(at: 0.15) == nil)

        _ = gesture.flagsChanged(key: true, others: false, at: 1)
        gesture.otherInput()
        #expect(gesture.delayPassed(at: 1.15) == nil)
        #expect(gesture.flagsChanged(key: false, others: false, at: 1.2) == nil)
    }
}
