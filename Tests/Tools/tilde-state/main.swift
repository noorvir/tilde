// The one way into Tilde's UI for the contract tests in Tests/Contract: it reads state files
// and draws the real views offscreen.
//   tilde-state render <out folder> <state.json>...
//   tilde-state transition <table.json>     prints each row's resulting state as JSON
import AppKit

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "transition" {
    let table = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    // Top-level code runs on the main thread.
    FileHandle.standardOutput.write(try MainActor.assumeIsolated { try Transitions.run(table) })
    exit(0)
}
if arguments.count == 3, arguments[1] == "demo-mocks" {
    Task { @MainActor in
        do {
            let out = URL(fileURLWithPath: arguments[2], isDirectory: true)
            try await (ProcessInfo.processInfo.environment["DEMO_FLOW"] == nil ? DemoMocks.run(out: out) : DemoFlow.run(out: out))
            exit(0)
        } catch {
            print(error)
            exit(1)
        }
    }
    RunLoop.main.run()
}
guard arguments.count >= 4, arguments[1] == "render" else {
    print("usage: tilde-state render <out folder> <state.json>...")
    exit(2)
}

// A caret that blinks would be in some pictures and not in others: it stays on.
UserDefaults.standard.register(defaults: ["NSTextInsertionPointBlinkPeriodOn": 1_000_000_000.0, "NSTextInsertionPointBlinkPeriodOff": 1.0])

Task { @MainActor in
    // Before any view exists: the first state in a process would otherwise get other scrollers,
    // and so another layout, depending only on the order in which states are drawn.
    _ = Renderer.fixesScrollerStyle
    // A first drawing that counts for nothing: the first scroll view of a process lays out
    // differently from the next ones.
    _ = try? await Surfaces.warmUp()
    let out = URL(fileURLWithPath: arguments[2], isDirectory: true)
    var failed = false
    for path in arguments[3...] {
        let file = URL(fileURLWithPath: path)
        do {
            let state = try UIState(file: file)
            let image = try await Surfaces.image(of: state)
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            try png.write(to: out.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".png"))
        } catch {
            print("\(file.lastPathComponent): \(error)")
            failed = true
        }
    }
    exit(failed ? 1 : 0)
}
RunLoop.main.run()
