@testable import TildeUI
import AppKit
import SwiftUI

/// The drawing canvas with a wireframe over an app, as the screen shows it: the real page draws
/// the components in a look, over the app that `UnderBlurView` blurs under them.
@MainActor
enum CanvasSurface {
    static let size = CGSize(width: 680, height: 420)

    /// Two cards, a dropdown, a table, a list and a button, over `MockApp`.
    private static let shapes: [[String: Any]] = [
        ["type": "card", "rect": [18, 118, 216, 66], "label": "Plan card", "borders": allBorders],
        ["type": "card", "rect": [244, 118, 216, 66], "label": "Plan card", "borders": allBorders],
        ["type": "dropdown", "rect": [480, 132, 160, 30], "label": "Region", "borders": allBorders],
        ["type": "table", "rect": [20, 204, 420, 186], "label": "GPU table", "borders": allBorders, "rows": 3, "columns": 3],
        ["type": "list", "rect": [456, 204, 84, 186], "label": "Tags", "borders": allBorders, "rows": 4],
        ["type": "button", "rect": [556, 300, 84, 32], "label": "Launch", "borders": allBorders],
    ]
    private static let allBorders = ["top", "right", "bottom", "left"]

    /// The same components as parts of a section, with a button in the first card: each part
    /// has a white gap round its border.
    private static let nestedShapes: [[String: Any]] = [
        ["type": "section", "rect": [8, 104, 652, 296], "label": "Pricing", "borders": allBorders],
    ] + shapes + [
        ["type": "button", "rect": [130, 150, 92, 26], "label": "Choose", "borders": allBorders],
    ]

    /// The same components with texts, a table's in its header, and a free text below the
    /// dropdown.
    private static let textShapes: [[String: Any]] = zip(shapes, ["On demand", "Spot", "us-east", "GPUs", nil, "Launch"]).map { shape, text in
        var shape = shape
        shape["text"] = text
        return shape
    } + [
        ["type": "text", "rect": [480, 170, 108, 18], "text": "Prices per hour"],
    ]

    static func image(look: WireframeLook, chip: UIState.Chip?, isNested: Bool, hasTexts: Bool) async throws -> CGImage {
        let app = try await Renderer.render(NSHostingView(rootView: MockApp()), size: size, appearance: .aqua)
        let page = try await WireframePicturePage.load(html: html())
        let state = chip?.rawValue ?? "normal"
        var drawn = shapes
        if isNested {
            drawn = nestedShapes
        } else if hasTexts {
            drawn = textShapes
        }
        return try await page.picture(of: drawn, look: look, state: state, over: app, size: size)
    }

    /// The canvas's page from the sources.
    static func html() throws -> String {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Sources/TildeUI/DrawingWeb")
        guard let html = DrawingCanvas.page(in: folder) else {
            throw WireframePicturePage.Failed(reason: "no page in \(folder.path)")
        }
        return html
    }
}

/// An app under the wireframe: a header, plans and a table.
private struct MockApp: View {
    private let ink = Color(red: 0.12, green: 0.12, blue: 0.11)
    private let muted = Color(red: 0.42, green: 0.42, blue: 0.4)
    private let accent = Color(red: 0.23, green: 0.13, blue: 0.79)
    private let line = Color(red: 0.85, green: 0.84, blue: 0.82)

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.97, green: 0.97, blue: 0.96)
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Circle().fill(ink).frame(width: 16, height: 16)
                    Text("Acme cloud").font(.system(size: 14)).foregroundStyle(ink)
                    Spacer()
                    ForEach(["Models", "Pricing", "Docs"], id: \.self) { Text($0).font(.system(size: 13)).foregroundStyle(muted) }
                    Text("Sign in").font(.system(size: 12)).foregroundStyle(.white).padding(.horizontal, 14).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 4).fill(ink))
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(.white)
                Rectangle().fill(line).frame(height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text("GPUs for your own models").font(.system(size: 24)).foregroundStyle(ink)
                    Text("Rent GPUs directly, pay less with spot, or reserve capacity.").font(.system(size: 13)).foregroundStyle(muted)
                    HStack(spacing: 12) {
                        plan("On demand", "Billed per second", isChosen: true)
                        plan("Spot", "About 45% less", isChosen: false)
                        plan("Reserved", "Price per contract", isChosen: false)
                    }
                    .padding(.top, 10)
                    table.padding(.top, 12)
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)
            }
        }
    }

    private func plan(_ title: String, _ subtitle: String, isChosen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14)).foregroundStyle(isChosen ? .white : ink)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(isChosen ? Color(red: 0.79, green: 0.76, blue: 1) : muted)
        }
        .padding(.horizontal, 16)
        .frame(width: 200, height: 54, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(isChosen ? accent : .white))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isChosen ? .clear : line))
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["GPU", "Memory", "On demand"], id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 170, alignment: .leading) }
            }
            .frame(height: 36)
            ForEach([("NVIDIA B300", "288 GB", "$12.79 / h"), ("NVIDIA B200", "192 GB", "$9.99 / h"), ("NVIDIA H200", "141 GB", "$7.09 / h")], id: \.0) { row in
                HStack(spacing: 0) {
                    Text(row.0).frame(width: 170, alignment: .leading)
                    Text(row.1).frame(width: 170, alignment: .leading)
                    Text(row.2).foregroundStyle(accent).frame(width: 170, alignment: .leading)
                    Text("Launch").font(.system(size: 12)).frame(width: 72, height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(ink))
                }
                .font(.system(size: 13))
                .foregroundStyle(ink)
                .frame(height: 48)
            }
        }
        .padding(.horizontal, 20)
        .frame(width: 624, height: 200, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(line))
    }
}
