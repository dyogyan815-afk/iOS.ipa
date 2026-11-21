// CoordinateEngine.swift
// BOTB Judges Edition - Authoritative Coordinate Engine (Swift port)
//
// MIRRORS engine/coordinate_engine.py rule-for-rule:
//   - P space: integer pixels, origin top-left, x right, y down (CANONICAL)
//   - N space: x_n = x / W, y_n = y / H in [0, 1)
//   - round-half-to-even on inverse mapping, then clamp
//   - geometric median via Weiszfeld (maxIter 100, tol 1e-7, eps 1e-9)
//   - distances Euclidean in pixels
//
// IMPORTANT: this port is delivered as source for integration into the
// authorized BOTB application project. It has NOT been compiled in this
// Linux workspace (no Apple toolchain available); see BUILD_REPORT.md.

import Foundation
import CryptoKit

public enum CoordinateEngine {
    public static let engineVersion = "1.0.0"
    public static let weiszfeldMaxIter = 100
    public static let weiszfeldTol = 1e-7
    static let eps = 1e-9

    public enum CoordinateError: Error, Equatable {
        case outsideBounds
        case invalidDimensions
        case invalidInput
        case noPoints
        case unknownMethod(String)
    }

    // MARK: - Canonical identity

    public static func imageSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical JSON: UTF-8, sorted keys, compact separators, no "/" escaping.
    public static func canonicalJSON(_ object: Any) throws -> Data {
        let formatter = JSONEncoder()
        formatter.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try formatter.encode(AnyEncodable(object))
    }

    public static func recordHash(_ object: Any) throws -> String {
        imageSHA256(try canonicalJSON(object))
    }

    // MARK: - Points and conversions

    public struct PixelPoint: Equatable, Hashable, Codable {
        public var x: Int
        public var y: Int
        public init(x: Int, y: Int) { self.x = x; self.y = y }
    }

    public struct ImageIdentity: Equatable, Hashable {
        public let sha256: String
        public let widthPx: Int
        public let heightPx: Int
        public init(data: Data, widthPx: Int, heightPx: Int) {
            self.sha256 = CoordinateEngine.imageSHA256(data)
            self.widthPx = widthPx
            self.heightPx = heightPx
        }
        public init(sha256: String, widthPx: Int, heightPx: Int) {
            self.sha256 = sha256
            self.widthPx = widthPx
            self.heightPx = heightPx
        }
        public func validate(pointInside p: PixelPoint) throws {
            guard widthPx >= 2, heightPx >= 2 else { throw CoordinateError.invalidDimensions }
            guard p.x >= 0, p.x < widthPx, p.y >= 0, p.y < heightPx else {
                throw CoordinateError.outsideBounds
            }
        }
    }

    public static func clamp(_ value: Int, _ lo: Int, _ hi: Int) -> Int {
        max(lo, min(hi, value))
    }

    public static func toNormalized(_ p: PixelPoint, width: Int, height: Int)
        throws -> (Double, Double) {
        guard width >= 2, height >= 2 else { throw CoordinateError.invalidDimensions }
        guard p.x >= 0, p.x < width, p.y >= 0, p.y < height else {
            throw CoordinateError.outsideBounds
        }
        return (Double(p.x) / Double(width), Double(p.y) / Double(height))
    }

    /// Round-half-to-even, then clamp. Round-trip error is at most 1 px/axis.
    static func roundHalfEven(_ v: Double) -> Int {
        let f = Foundation.round(v)
        let diff = abs(v - Foundation.trunc(v))
        if abs(v - f) == 0.5 && diff >= 0.5 {
            // exact .5 cases: choose even neighbor
            let floorV = Foundation.floor(v)
            let floorIsEven = Int(floorV).isMultiple(of: 2)
            return Int(floorIsEven ? floorV : f)
        }
        return Int(f)
    }

    public static func fromNormalized(_ nx: Double, _ ny: Double,
                                      width: Int, height: Int) throws -> PixelPoint {
        guard width >= 2, height >= 2 else { throw CoordinateError.invalidDimensions }
        guard nx.isFinite, ny.isFinite, nx >= -1.0, nx <= 2.0, ny >= -1.0, ny <= 2.0 else {
            throw CoordinateError.invalidInput
        }
        return PixelPoint(x: clamp(roundHalfEven(nx * Double(width)), 0, width - 1),
                          y: clamp(roundHalfEven(ny * Double(height)), 0, height - 1))
    }

    public static func roundtripErrorPx(_ p: PixelPoint, width: Int, height: Int) throws -> (Int, Int) {
        let (nx, ny) = try toNormalized(p, width: width, height: height)
        let q = try fromNormalized(nx, ny, width: width, height: height)
        return (abs(q.x - p.x), abs(q.y - p.y))
    }

    // MARK: - Distances

    public static func euclideanDistancePx(_ a: PixelPoint, _ b: PixelPoint) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    public static func normalizedDistance(_ a: PixelPoint, _ b: PixelPoint,
                                          width: Int, height: Int) throws -> Double {
        let diag = (Double(width) * Double(width) + Double(height) * Double(height)).squareRoot()
        guard diag > 0 else { throw CoordinateError.invalidDimensions }
        return euclideanDistancePx(a, b) / diag
    }

    // MARK: - Consensus

    public static func perAxisMedian(_ points: [PixelPoint]) throws -> PixelPoint {
        guard !points.isEmpty else { throw CoordinateError.noPoints }
        let xs = points.map(\.x).sorted()
        let ys = points.map(\.y).sorted()
        let n = points.count
        let mx: Int
        if n % 2 == 1 { mx = xs[n / 2] }
        else { mx = roundHalfEven(Double(xs[n / 2 - 1] + xs[n / 2]) / 2.0) }
        let my: Int
        if n % 2 == 1 { my = ys[n / 2] }
        else { my = roundHalfEven(Double(ys[n / 2 - 1] + ys[n / 2]) / 2.0) }
        return PixelPoint(x: mx, y: my)
    }

    public static func geometricMedian(_ points: [PixelPoint]) throws -> (Double, Double) {
        guard !points.isEmpty else { throw CoordinateError.noPoints }
        let med = try perAxisMedian(points)
        var fx = Double(med.x), fy = Double(med.y)
        for _ in 0..<weiszfeldMaxIter {
            var wsum = 0.0, sx = 0.0, sy = 0.0
            for p in points {
                let dx = Double(p.x) - fx, dy = Double(p.y) - fy
                let d = max((dx * dx + dy * dy).squareRoot(), eps)
                let w = 1.0 / d
                wsum += w; sx += w * Double(p.x); sy += w * Double(p.y)
            }
            let nx = sx / wsum, ny = sy / wsum
            let step = Foundation.sqrt((nx - fx) * (nx - fx) + (ny - fy) * (ny - fy))
            fx = nx; fy = ny
            if step < weiszfeldTol { break }
        }
        return (fx, fy)
    }

    public struct Consensus: Equatable {
        public let method: String
        public let xPx: Int
        public let yPx: Int
        public let rawX: Double
        public let rawY: Double
        public let tolerancePx: Double
        public let maxSpreadPx: Double
        public let agreementRatio: Double
        public let nJudges: Int
        public let engineVersion: String
    }

    public static func consensus(_ points: [PixelPoint], method: String = "geometric_median")
        throws -> PixelPoint {
        let raw: (Double, Double)
        switch method {
        case "geometric_median": raw = try geometricMedian(points)
        case "per_axis_median":
            let m = try perAxisMedian(points); raw = (Double(m.x), Double(m.y))
        default: throw CoordinateError.unknownMethod(method)
        }
        return PixelPoint(x: roundHalfEven(raw.0), y: roundHalfEven(raw.1))
    }

    public static func pairwiseMaxSpread(_ points: [PixelPoint]) -> Double {
        guard points.count > 1 else { return 0.0 }
        var worst = 0.0
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                worst = max(worst, euclideanDistancePx(points[i], points[j]))
            }
        }
        return worst
    }

    public static func withinTolerance(_ a: PixelPoint, _ b: PixelPoint,
                                       tolerancePx: Double) -> Bool {
        precondition(tolerancePx >= 0, "tolerance must be >= 0")
        return euclideanDistancePx(a, b) <= tolerancePx
    }

    public static func agreementRatio(_ points: [PixelPoint], consensusPoint: PixelPoint,
                                      tolerancePx: Double) throws -> Double {
        guard !points.isEmpty else { throw CoordinateError.noPoints }
        let hits = points.filter { withinTolerance($0, consensusPoint, tolerancePx: tolerancePx) }.count
        return Double(hits) / Double(points.count)
    }

    public static func evaluateConsensus(_ points: [PixelPoint], tolerancePx: Double,
                                         method: String = "geometric_median") throws -> Consensus {
        guard !points.isEmpty else { throw CoordinateError.noPoints }
        let c = try consensus(points, method: method)
        let (rawX, rawY): (Double, Double)
        switch method {
        case "geometric_median": rawX = try geometricMedian(points).0; rawY = try geometricMedian(points).1
        default:
            let m = try perAxisMedian(points); rawX = Double(m.x); rawY = Double(m.y)
        }
        let ratio = try agreementRatio(points, consensusPoint: c, tolerancePx: tolerancePx)
        return Consensus(method: method, xPx: c.x, yPx: c.y, rawX: rawX, rawY: rawY,
                         tolerancePx: tolerancePx, maxSpreadPx: pairwiseMaxSpread(points),
                         agreementRatio: ratio, nJudges: points.count,
                         engineVersion: engineVersion)
    }
}

// MARK: - AnyEncodable helper for canonical JSON of mixed dictionaries

struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    init(_ value: Any) {
        if let v = value as? Encodable { encodeFunc = { try v.encode(to: $0) } }
        else if let d = value as? [String: Any] { encodeFunc = { try [String: AnyEncodable](uniqueKeysWithValues: d.map { ($0.key, AnyEncodable($0.value)) }).encode(to: $0) } }
        else if let a = value as? [Any] { encodeFunc = { try a.map { AnyEncodable($0) }.encode(to: $0) } }
        else { encodeFunc = { _ in throw CoordinateEngine.CoordinateError.invalidInput } }
    }
    func encode(to encoder: Encoder) throws { try encodeFunc(encoder) }
}
