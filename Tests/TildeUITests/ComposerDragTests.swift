import Combine
import Foundation
import Testing
@testable import TildeUI

@MainActor
struct ComposerDragTests {
    /// Each change of the controller redraws the HUD and the preview. A drag of 60 ticks wrote
    /// the layout to it at each tick; now it writes it once, at the end, and the ticks change
    /// only the composer's own drag.
    @Test func aDragChangesTheControllerOnceAtItsEnd() async throws {
        let controller = try await Fixtures.controller()
        let video = URL(fileURLWithPath: "/tmp/clip-\(UUID().uuidString).mp4")
        var changes = 0
        let watch = controller.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }

        // As before: every tick to the controller.
        for tick in 1...60 {
            var layout = controller.layout(of: video)
            layout.screenCenter = CGPoint(x: 0.5 + Double(tick) / 1000, y: 0.5)
            controller.setLayout(layout, of: video)
        }
        let perTick = changes
        #expect(perTick >= 60)

        changes = 0
        let drag = ComposerDrag()
        var dragTicks = 0
        let dragWatch = drag.objectWillChange.sink { dragTicks += 1 }
        defer { dragWatch.cancel() }
        let start = drag.begin(from: controller.layout(of: video))
        for tick in 1...60 {
            var layout = drag.begin(from: controller.layout(of: video))
            layout.screenCenter = CGPoint(x: start.screenCenter.x + Double(tick) / 1000, y: 0.5)
            drag.move(to: layout)
        }
        #expect(changes == 0)
        #expect(dragTicks == 60)
        let kept = try #require(drag.end())
        controller.setLayout(kept, of: video)
        #expect(changes == 1)
        #expect(controller.layout(of: video).screenCenter == kept.screenCenter)
        #expect(drag.layout == nil)
    }
}
