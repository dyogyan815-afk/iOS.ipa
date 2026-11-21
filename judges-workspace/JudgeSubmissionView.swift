// JudgeSubmissionView.swift
// BOTB Judges Edition - image assessment + crosshair submission screen.
//
// Competition id and image identity (SHA-256 of raw bytes) are carried into
// every record; the coordinate engine is the single source of truth for the
// crosshair. A loupe magnifier shows the region around the crosshair with
// the same mapping (no second coordinate system). Saved records can be
// exported as JSON. AI proposals are NOT part of this screen (see
// AIProposalView).

import SwiftUI
import PhotosUI
import UIKit

struct JudgeSubmissionView: View {
    @State private var competitionId = ""
    @State private var judgeId = ""
    @State private var note = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var imageData: Data?
    @State private var pixelSize: CGSize?
    @State private var point = CoordinateEngine.PixelPoint(x: 0, y: 0)
    @State private var statusMessage: String?
    @State private var savedRecordId: String?
    @State private var loupeZoom: CGFloat = 6
    @State private var exportedRecordJSON: String?

    private let recordsStore = RecordsStore()
    private static let loupeOptions: [CGFloat] = [3, 6, 12]

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Competition ID (e.g. BOTB-2026-R1)", text: $competitionId)
                    .autocorrectionDisabled()
                TextField("Judge ID (e.g. JUDGE-01)", text: $judgeId)
                    .autocorrectionDisabled()
            }
            Section("Image") {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose assessment image", systemImage: "photo")
                }
                if let image = image, let size = pixelSize {
                    GeometryReader { geo in
                        let fitted = CrosshairLoupe.fittedSize(pixel: size, in: geo.size)
                        VStack(spacing: 10) {
                            Image(uiImage: image)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: fitted.width, height: fitted.height)
                                .overlay(
                                    CrosshairOverlay(imageDisplaySize: fitted,
                                                     imagePixelSize: size,
                                                     point: $point))
                            if loupeZoom > 0 {
                                CrosshairLoupe(image: image, imagePixelSize: size,
                                               baseDisplaySize: fitted, point: point,
                                               zoom: loupeZoom)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    }
                    .frame(height: loupeZoom > 0 ? 480 : 330)
                    Text("Image \(Int(size.width)) x \(Int(size.height)) px  |  image_id \(imageDigestPreview)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Section("Placement") {
                Stepper(value: Binding(
                    get: { point.x },
                    set: { point.x = max(0, min($0, (Int(pixelSize?.width ?? 2) - 1))) }),
                    in: 0...max(1, Int(pixelSize?.width ?? 2) - 1)) {
                    Text("x = \(point.x) px")
                }
                Stepper(value: Binding(
                    get: { point.y },
                    set: { point.y = max(0, min($0, (Int(pixelSize?.height ?? 2) - 1))) }),
                    in: 0...max(1, Int(pixelSize?.height ?? 2) - 1)) {
                    Text("y = \(point.y) px")
                }
                TextField("Note", text: $note)
                HStack {
                    Text("Loupe").font(.footnote)
                    ForEach(JudgeSubmissionView.loupeOptions, id: \.self) { z in
                        Button("\(Int(z))x") { loupeZoom = z }
                            .buttonStyle(.bordered)
                            .tint(loupeZoom == z ? .green : .blue)
                    }
                    Button("Off") { loupeZoom = 0 }
                        .buttonStyle(.bordered)
                        .tint(loupeZoom == 0 ? .green : .blue)
                }
            }
            Section("Submit") {
                Button("Save crosshair record") { save() }
                    .disabled(!canSubmit)
                if let saved = savedRecordId {
                    Text("Saved: \(saved.prefix(16))...")
                        .font(.caption.monospaced()).foregroundStyle(.green)
                }
                if let json = exportedRecordJSON {
                    ShareLink("Export record JSON", item: json)
                }
                if let msg = statusMessage {
                    Text(msg).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Judge submission")
        .onChange(of: photoItem) { newItem in
            load(imageItem: newItem)
        }
    }

    private var imageDigestPreview: String {
        guard let data = imageData else { return "-" }
        return String(CoordinateEngine.imageSHA256(data).prefix(12)) + "..."
    }

    private var canSubmit: Bool {
        image != nil && pixelSize != nil &&
        !competitionId.isEmpty && !judgeId.isEmpty
    }

    private func load(imageItem: PhotosPickerItem?) {
        guard let item = imageItem else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let loaded = UIImage(data: data) {
                imageData = data
                image = loaded
                let w = Int(loaded.cgImage?.width ?? 0)
                let h = Int(loaded.cgImage?.height ?? 0)
                pixelSize = CGSize(width: max(2, w), height: max(2, h))
                point = CoordinateEngine.PixelPoint(x: w / 2, y: h / 2)
                savedRecordId = nil
                exportedRecordJSON = nil
                statusMessage = nil
            } else {
                statusMessage = "Could not load image."
            }
        }
    }

    private func save() {
        guard let size = pixelSize, let data = imageData else { return }
        let record = CrosshairRecordFile(
            competitionId: competitionId,
            judgeId: judgeId,
            imageId: CoordinateEngine.imageSHA256(data),
            imageWidthPx: Int(size.width),
            imageHeightPx: Int(size.height),
            xPx: point.x, yPx: point.y,
            note: note,
            createdAt: JudgeSubmission.nowISO(),
            engineVersion: CoordinateEngine.engineVersion)
        do {
            let id = try recordsStore.save(record: record)
            savedRecordId = id
            if let raw = try? recordsStore.exportRecordJSON(recordId: id),
               let text = String(data: raw, encoding: .utf8) {
                exportedRecordJSON = text
            } else {
                exportedRecordJSON = nil
            }
            statusMessage = nil
        } catch {
            statusMessage = "Save failed: \(error)"
        }
    }
}
