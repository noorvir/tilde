// Checks Tilde's UI from its contract: draws each state in Tests/Contract/states through
// tilde-state, in parallel, and compares the pictures. It uses no code of Tilde.
//   tilde-ui-check [--record] [name filter]
// TILDE_STATE names the drawing tool; by default it is next to this one.
import AppKit

let started = Date()
let limit = 60.0
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let contract = root.appendingPathComponent("Tests/Contract")
let os = ProcessInfo.processInfo.operatingSystemVersion
let major = "\(os.majorVersion).\(os.minorVersion)"
let pictures = contract.appendingPathComponent("pictures/macos-\(major)")
let out = root.appendingPathComponent(".build/ui-check")
let stateTool = ProcessInfo.processInfo.environment["TILDE_STATE"].map(URL.init(fileURLWithPath:))
    ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("tilde-state")
let isRecording = CommandLine.arguments.contains("--record")
let filter = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }

// Only for pictures made on another setup: on the same one they must match exactly.
let channelTolerance = 2
let maxDifferentRatio = 0.001

try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let names = try FileManager.default.contentsOfDirectory(atPath: contract.appendingPathComponent("states").path)
    .filter { $0.hasSuffix(".json") && (filter == nil || $0.contains(filter!)) }.sorted()

// Render in parallel: each worker takes every n-th state.
let workers = ProcessInfo.processInfo.activeProcessorCount
var processes: [Process] = []
for worker in 0..<workers {
    let shard = names.enumerated().filter { $0.offset % workers == worker }.map { contract.appendingPathComponent("states/\($0.element)").path }
    guard !shard.isEmpty else { continue }
    let process = Process()
    process.executableURL = stateTool
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
// Pictures count only on the macOS they were made on.
let hasPictures = FileManager.default.fileExists(atPath: pictures.path)
if !hasPictures, !isRecording {
    print("SKIP pictures: none for macOS \(major). Drawing was checked, pictures were not compared.")
}
// Pictures depend on the exact macOS and on the SDK the drawing tool was built against.
func toolSDK() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/vtool")
    process.arguments = ["-show-build", stateTool.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return text.split(separator: "\n").first { $0.contains("sdk") }?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "  ", with: "") ?? "sdk unknown"
}
let setup = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(toolSDK())\n"
let setupFile = pictures.appendingPathComponent("recorded-on.txt")
let recorded = try? String(contentsOf: setupFile, encoding: .utf8)
let isExact = recorded == setup
if isRecording {
    try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
    try setup.write(to: setupFile, atomically: true, encoding: .utf8)
} else if hasPictures, !isExact {
    print("WARNING pictures were recorded on \((recorded ?? "an unknown setup\n").dropLast()), this is \(setup.dropLast()): pixels approximate")
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
    guard hasPictures else {
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
    guard !isExact else {
        failures.append("\(base): pixels differ: \(actual.path)")
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

// State plus event gives state: each row's `expect` must be part of the result.
func contains(_ whole: Any?, _ part: Any?) -> Bool {
    if let part = part as? [String: Any] {
        guard let whole = whole as? [String: Any] else { return false }
        return part.allSatisfy { contains(whole[$0.key], $0.value) }
    }
    if part is NSNull {
        return whole == nil || whole is NSNull
    }
    if let part = part as? NSObject, let whole = whole as? NSObject {
        return part == whole
    }
    return false
}

let tables = (try? FileManager.default.contentsOfDirectory(atPath: contract.appendingPathComponent("transitions").path))?.filter { $0.hasSuffix(".json") } ?? []
var rowCount = 0
for table in tables.sorted() {
    let path = contract.appendingPathComponent("transitions/\(table)")
    let process = Process()
    process.executableURL = stateTool
    process.arguments = ["transition", path.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [[String: Any]] ?? []
    let results = (try? JSONSerialization.jsonObject(with: output)) as? [[String: Any]] ?? []
    guard rows.count == results.count else {
        failures.append("\(table): got \(results.count) results for \(rows.count) rows")
        continue
    }
    for (row, result) in zip(rows, results) {
        rowCount += 1
        // Missing keys in the result are nil, so an expected null matches them.
        if !contains(result, row["expect"]) {
            failures.append("\(table): \(row["name"] ?? "?"): got \(result), expected \(row["expect"] ?? "?")")
        }
    }
}

failures.forEach { print("FAIL \($0)") }
let total = Date().timeIntervalSince(started)
print("\(rowCount) transition rows")
print(String(format: "%d states in %.1f s (drawing %.1f s, limit %.0f s), %d failed", names.count, total, rendered, limit, failures.count))
if total > limit {
    print("Over the time limit.")
}
exit(failures.isEmpty && !renderFailed && total <= limit ? 0 : 1)
