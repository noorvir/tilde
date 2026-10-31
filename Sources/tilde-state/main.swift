// The one way into Tilde's UI for the contract tests in Tests/Contract: it reads state files
// and draws the real views offscreen. See the README there.
//   tilde-state render <out folder> <state.json>...
//   tilde-state transition <table.json>     prints each row's resulting state as JSON
import AppKit

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "transition" {
    let table = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    FileHandle.standardOutput.write(try Transitions.run(table))
    exit(0)
}
guard arguments.count >= 4, arguments[1] == "render" else {
    print("usage: tilde-state render <out folder> <state.json>...")
    exit(2)
}

Task { @MainActor in
    // Before any view exists: the first state in a process would otherwise get other scrollers,
    // and so another layout, depending only on the order in which states are drawn.
    _ = Renderer.fixesScrollerStyle
    let out = URL(fileURLWithPath: arguments[2], isDirectory: true)
    var failed = false
    for path in arguments[3...] {
        let file = URL(fileURLWithPath: path)
        do {
            let state = try JSONDecoder().decode(UIState.self, from: Data(contentsOf: file))
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
