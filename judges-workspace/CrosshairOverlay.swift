// CrosshairOverlay.swift
// BOTB Judges Edition - crosshair placement and adjustment overlay.
//
// Placement, adjustment and display route ONLY through CoordinateEngine;
// the drag gesture updates a PixelPoint, never a raw CGPoint.

import SwiftUI

struct CrosshairOverlay: View {
    let imageDisplaySize: CGSize
    let imagePixelSize: CGSize
    @Binding var point: CoordinateEngine.PixelPoint
    var consensusPoint: CoordinateEngine.PixelPoint?
    var otherJudges: [CoordinateEngine.PixelPoint] = []

    @State private var dragStart: CoordinateEngine.PixelPoint?
    @State private var fineAdjust = false

    private func pixel(from location: CGPoint) -> CoordinateEngine.PixelPoint {
        guard imageDisplaySize.width > 0, imageDisplaySize.height > 0 else {
            return CoordinateEngine.PixelPoint(x: 0, y: 0)
        }
        let nx = Double(location.x / imageDisplaySize.width)
        let ny = Double(location.y / imageDisplaySize.height)
        return (try? CoordinateEngine.fromNormalized(
            nx, ny, width: Int(imagePixelSize.width),
            height: Int(imagePixelSize.height))) ?? .init(x: 0, y: 0)
    }

    private func displayOffset(_ p: CoordinateEngine.PixelPoint) -> CGPoint {
        CGPoint(x: Double(p.x) / Double(imagePixelSize.width) * imageDisplaySize.width,
                y: Double(p.y) / Double(imagePixelSize.height) * imageDisplaySize.height)
    }

    var body: some View {
        ZStack {
            ForEach(Array(otherJudges.enumerated()), id: \.offset) { _, p in
                MarkerDot(at: displayOffset(p))
            }
            if let c = consensusPoint {
                ConsensusMarker(at: displayOffset(c))
            }
            ActiveCrosshair(at: displayOffset(point), label: "\(point.x), \(point.y) px")
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStart == nil { dragStart = point }
                    var candidate = pixel(from: value.location)
                    if fineAdjust, let start = dragStart {
                        let dx = Double(value.location.x - value.startLocation.x)
                        let dy = Double(value.location.y - value.startLocation.y)
                        candidate = CoordinateEngine.PixelPoint(
                            x: start.x + Int(dx / 4).clamped(-25...25),
                            y: start.y + Int(dy / 4).clamped(-25...25))
                    }
                    point = candidate
                }
                .onEnded { _ in dragStart = nil }
        )
        .onLongPressGesture(minimumDuration: 0.4) { fineAdjust.toggle() }
    }
}

private struct MarkerDot: View {
    let at: CGPoint
    var body: some View {
        Circle()
            .stroke(Color.blue.opacity(0.55), lineWidth: 1.5)
            .frame(width: 14, height: 14)
            .position(at)
    }
}

private struct ConsensusMarker: View {
    let at: CGPoint
    var body: some View {
        Image(systemName: "scope")
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(.green)
            .position(at)
    }
}

private struct ActiveCrosshair: View {
    let at: CGPoint
    let label: String
    var body: some View {
        ZStack {
            CrosshairShape()
                .stroke(Color.red, lineWidth: 2)
                .frame(width: 40, height: 40)
                .position(at)
            Text(label)
                .font(.caption.monospaced())
                .padding(4)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                .position(x: at.x, y: max(CGFloat(24), at.y - 34))
        }
    }
}

struct CrosshairShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        p.move(to: CGPoint(x: rect.minX, y: c.y)); p.addLine(to: CGPoint(x: rect.maxX, y: c.y))
        p.move(to: CGPoint(x: c.x, y: rect.minY)); p.addLine(to: CGPoint(x: c.x, y: rect.maxY))
        p.addEllipse(in: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18))
        return p
    }
}

extension Int {
    func clamped(_ range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Loupe magnifier (zoom with synchronized coordinates)
//
// The loupe shows the region around the current crosshair point using the
// SAME pixel <-> display mapping as the main canvas (scaled by `zoom`), so
// there is no second coordinate system: whatever is under the loupe's center
// crosshair IS the current `point`.

struct CrosshairLoupe: View {
    let image: UIImage
    let imagePixelSize: CGSize
    /// Display size the image occupies on the main (un-zoomed) canvas.
    let baseDisplaySize: CGSize
    let point: CoordinateEngine.PixelPoint
    var zoom: CGFloat = 6
    var side: CGFloat = 170

    /// Aspect-fit display size for a pixel-size image inside a container.
    static func fittedSize(pixel: CGSize, in container: CGSize) -> CGSize {
        guard pixel.width >= 1, pixel.height >= 1, container.width > 0, container.height > 0 else {
            return CGSize(width: 100, height: 75)
        }
        let scale = min(container.width / pixel.width, container.height / pixel.height)
        return CGSize(width: (pixel.width * scale).rounded(), height: (pixel.height * scale).rounded())
    }

    var body: some View {
        let px = max(CGFloat(imagePixelSize.width), 1)
        let py = max(CGFloat(imagePixelSize.height), 1)
        let display = CGPoint(x: CGFloat(point.x) / px * baseDisplaySize.width,
                              y: CGFloat(point.y) / py * baseDisplaySize.height)
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: baseDisplaySize.width * zoom, height: baseDisplaySize.height * zoom)
                    .position(x: center.x - display.x * zoom, y: center.y - display.y * zoom)
                CrosshairShape()
                    .stroke(Color.red, lineWidth: 2)
                    .frame(width: 40, height: 40)
                    .position(center)
            }
            .clipped()
        }
        .frame(width: side, height: side)
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.green, lineWidth: 2))
        .accessibilityLabel("Magnified view centered on the crosshair")
    }
}
