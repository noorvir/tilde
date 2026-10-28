import TildeCore
import Testing

struct CompactPathTests {
    let group = AccessibilityNode(role: "AXGroup", name: nil, selector: nil)

    @Test func collapsesUnnamedRunsAndKeepsNamedAncestors() {
        let nodes = [AccessibilityNode(role: "AXWindow", name: "Claude", selector: nil)]
            + Array(repeating: group, count: 3)
            + [AccessibilityNode(role: "AXGroup", name: nil, selector: "#sidebar.flex")]
            + Array(repeating: group, count: 2)
            + [
                AccessibilityNode(role: "AXList", name: nil, selector: nil),
                group,
                AccessibilityNode(role: "AXStaticText", name: nil, selector: nil),
            ]

        #expect(compactPath(nodes) == [
            "AXWindow \"Claude\"",
            "AXGroup ×3",
            "AXGroup #sidebar.flex",
            "AXGroup ×2",
            "AXList",
            "AXGroup",
            "AXStaticText",
        ])
    }

    @Test func startsAtTheWebAreaAndKeepsTheLastSegments() {
        let chrome = [
            AccessibilityNode(role: "AXWindow", name: "Overview", selector: nil),
            AccessibilityNode(role: "AXGroup", name: nil, selector: ".BrowserRootView"),
            AccessibilityNode(role: "AXScrollArea", name: nil, selector: nil),
        ]
        let page = (1...9).map { AccessibilityNode(role: "AXGroup", name: nil, selector: ".level\($0)") }
        let nodes = chrome
            + [AccessibilityNode(role: "AXWebArea", name: "Overview", selector: nil)]
            + page
            + [AccessibilityNode(role: "AXStaticText", name: nil, selector: nil)]

        let path = compactPath(nodes, limit: 4)

        #expect(path == ["…", "AXGroup .level7", "AXGroup .level8", "AXGroup .level9", "AXStaticText"])
        #expect(compactPath(Array(nodes.suffix(3)), limit: 4) == ["AXGroup .level8", "AXGroup .level9", "AXStaticText"])
        #expect(compactPath(chrome + [nodes[3], page[0]]) == ["AXWebArea \"Overview\"", "AXGroup .level1"])
    }
}
