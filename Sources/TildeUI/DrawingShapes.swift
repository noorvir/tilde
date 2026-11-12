import Foundation
import TildeCore

/// Shapes as data: what the report says, and what a restore draws again.
enum DrawingShapes {
    static func moved(_ shape: [String: Any], by offset: CGVector) -> [String: Any] {
        var shape = shape
        func point(_ value: Any?) -> [Double]? {
            guard let values = value as? [NSNumber], values.count >= 2 else {
                return nil
            }
            return [values[0].doubleValue + offset.dx, values[1].doubleValue + offset.dy]
        }
        if let rect = shape["rect"] as? [NSNumber], rect.count == 4 {
            shape["rect"] = [rect[0].doubleValue + offset.dx, rect[1].doubleValue + offset.dy, rect[2].doubleValue, rect[3].doubleValue]
        }
        for key in ["from", "to"] {
            if let moved = point(shape[key]) {
                shape[key] = moved
            }
        }
        if let points = shape["points"] as? [Any] {
            shape["points"] = points.compactMap(point)
        }
        return shape
    }

    /// Where an arrow's tip is, or else the centre of the shapes: what they are linked to is there.
    static func linkPoint(of shapes: [[String: Any]]) -> CGPoint {
        if shapes.count == 1, let tip = doubles(shapes[0]["to"]), tip.count == 2, let tail = doubles(shapes[0]["from"]), tail.count == 2 {
            // A little back along the arrow: a tip snapped to an edge is on the element's border.
            let length = max(hypot(tip[0] - tail[0], tip[1] - tail[1]), 1)
            let back = min(2, length)
            return CGPoint(x: tip[0] + (tail[0] - tip[0]) / length * back, y: tip[1] + (tail[1] - tip[1]) / length * back)
        }
        let bounds = bounds(of: shapes)
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// The origin of `encode`.
    static func origin(of text: String) -> CGPoint {
        let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        guard let origin = object?["origin"] as? [NSNumber], origin.count == 2 else {
            return .zero
        }
        return CGPoint(x: origin[0].doubleValue, y: origin[1].doubleValue)
    }

    static func bounds(of shapes: [[String: Any]]) -> CGRect {
        var points: [[Double]] = []
        for shape in shapes {
            if let rect = doubles(shape["rect"]), rect.count == 4 {
                points += [[rect[0], rect[1]], [rect[0] + rect[2], rect[1] + rect[3]]]
            }
            for key in ["from", "to"] {
                if let point = doubles(shape[key]) {
                    points.append(point)
                }
            }
            for point in (shape["points"] as? [Any]) ?? [] {
                if let point = doubles(point) {
                    points.append(point)
                }
            }
        }
        guard let minX = points.map({ $0[0] }).min(), let maxX = points.map({ $0[0] }).max(),
              let minY = points.map({ $0[1] }).min(), let maxY = points.map({ $0[1] }).max()
        else {
            return .zero
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func doubles(_ value: Any?) -> [Double]? {
        (value as? [NSNumber])?.map(\.doubleValue)
    }

    /// For the report: the shapes relative to `origin`, which is the top left of their window,
    /// or of the screen, and the element they are linked to.
    static func encode(_ shapes: [[String: Any]], origin: CGPoint, element: Element?) -> String {
        let relative = shapes.map { shape -> [String: Any] in
            var moved = Self.moved(shape, by: CGVector(dx: -origin.x, dy: -origin.y))
            moved["id"] = nil
            return moved
        }
        var report: [String: Any] = ["origin": [origin.x, origin.y], "shapes": relative]
        if let data = try? JSONEncoder().encode(element), let object = try? JSONSerialization.jsonObject(with: data), element != nil {
            report["element"] = object
        }
        return DrawingPanel.json(report)
    }
}
