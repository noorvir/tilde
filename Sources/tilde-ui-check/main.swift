// Checks Tilde's UI from its contract: draws each state in Tests/Contract/states through
// tilde-state, in parallel, and compares the pictures. It uses no code of Tilde.
//   tilde-ui-check [--record] [name filter]
import AppKit

let started = Date()
let limit = 60.0
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let contract = root.appendingPathComponent("Tests/Contract")
let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
let pictures = contract.appendingPathComponent("pictures/macos-\(major)")
let out = root.appendingPathComponent(".build/ui-check")
let bin = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let isRecording = CommandLine.arguments.contains("--record")
let filter = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }

let channelTolerance = 2
let maxDifferentRatio = 0.001

try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let names = try FileManager.default.contentsOfDirectory(atPath: contract.appendingPathComponent("states").path)
    .filter { $0.hasSuffix(".json") && (filter == nil || $0.contains(filter!)) }.sorted()

// Render in parallel: each worker takes every n-th state.
let workers = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
var processes: [Process] = []
for worker in 0..<workers {
    let shard = names.enumerated().filter { $0.offset % workers == worker }.map { contract.appendingPathComponent("states/\($0.element)").path }
    guard !shard.isEmpty else { continue }
    let process = Process()
    process.executableURL = bin.appendingPathComponent("tilde-state")
    process.arguments = ["render", out.path] + shard
    try process.run()
    processes.append(process)
}
var renderFailed = false
for process in processes {
    process.waitUntilExit()
    renderFailed = renderFailed || process.terminationStatus != 0
}
let rendered = Date().timeIntervalSince(started)

func pixels(_ url: URL) -> (width: Int, height: Int, bytes: [UInt8])? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
    }
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
        data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (image.width, image.height, bytes)
}

var failures: [String] = []
if isRecording {
    try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
}
for name in names {
    let base = String(name.dropLast(5))
    let actual = out.appendingPathComponent(base + ".png")
    let reference = pictures.appendingPathComponent(base + ".png")
    if isRecording {
        try? FileManager.default.removeItem(at: reference)
        try FileManager.default.copyItem(at: actual, to: reference)
        continue
    }
    guard let now = pixels(actual) else {
        failures.append("\(base): not drawn")
        continue
    }
    guard let then = pixels(reference) else {
        failures.append("\(base): no picture for macOS \(major). Look at \(actual.path), then --record")
        continue
    }
    guard now.width == then.width, now.height == then.height else {
        failures.append("\(base): size \(now.width)x\(now.height), picture \(then.width)x\(then.height)")
        continue
    }
    if now.bytes == then.bytes {
        continue
    }
    var different = 0
    for offset in stride(from: 0, to: now.bytes.count, by: 4) {
        for channel in 0..<4 where abs(Int(now.bytes[offset + channel]) - Int(then.bytes[offset + channel])) > channelTolerance {
            different += 1
            break
        }
    }
    let ratio = Double(different) / Double(now.width * now.height)
    if ratio > maxDifferentRatio {
        failures.append(String(format: "%@: %.2f%% of pixels differ: %@", base, ratio * 100, actual.path))
    }
}

failures.forEach { print("FAIL \($0)") }
let total = Date().timeIntervalSince(started)
print(String(format: "%d states in %.1f s (drawing %.1f s, limit %.0f s), %d failed", names.count, total, rendered, limit, failures.count))
if total > limit {
    print("Over the time limit.")
}
exit(failures.isEmpty && !renderFailed && total <= limit ? 0 : 1)
