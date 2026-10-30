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
