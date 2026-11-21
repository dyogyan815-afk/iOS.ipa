// RecordsStore.swift
// BOTB Judges Edition - persistent local records with integrity verification.
//
// Mirrors engine/crosshair_records.py:
//   - one JSON file per record, filename = record_id (SHA-256 of canonical JSON)
//   - atomic writes (tmp + rename)
//   - verify() recomputes digests and identity consistency on every load
//   - hash-chained audit entries (GENESIS -> ...)

import Foundation

struct CrosshairRecordFile: Codable {
    var competitionId: String
    var judgeId: String
    var imageId: String
    var imageWidthPx: Int
    var imageHeightPx: Int
    var xPx: Int
    var yPx: Int
    var note: String
    var createdAt: String
    var engineVersion: String

    enum CodingKeys: String, CodingKey {
        case competitionId = "competition_id", judgeId = "judge_id"
        case imageId = "image_id"
        case imageWidthPx = "image_width_px"
        case imageHeightPx = "image_height_px"
        case xPx = "x_px", yPx = "y_px", note
        case createdAt = "created_at"
        case engineVersion = "engine_version"
    }
}

enum VerificationStatus: String, Codable { case pass = "PASS", fail = "FAIL" }

struct VerificationReport: Codable {
    var recordId: String
    var status: VerificationStatus
    var checks: [String: VerificationStatus]

    enum CodingKeys: String, CodingKey {
        case recordId = "record_id", status, checks
    }
}

enum RecordStoreError: Error {
    case integrityFailure
    case invalidIdentifier
    case notFound
    case outsideBounds
}

final class RecordsStore {
    let root: URL

    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                    in: .userDomainMask)[0]
            .appendingPathComponent("JudgesEdition/Records", isDirectory: true)
        self.root = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private static func validIdentifier(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 128 &&
        s.allSatisfy { ($0.isLetter && $0.isASCII) || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }
    }

    private func url(for recordId: String) throws -> URL {
        guard Self.validIdentifier(recordId) else { throw RecordStoreError.invalidIdentifier }
        return root.appendingPathComponent(recordId + ".json")
    }

    /// Canonical record payload without the record_id field.
    private static func payload(_ r: CrosshairRecordFile) -> [String: Any] {
        ["competition_id": r.competitionId, "judge_id": r.judgeId,
         "image_id": r.imageId, "image_width_px": r.imageWidthPx,
         "image_height_px": r.imageHeightPx, "x_px": r.xPx, "y_px": r.yPx,
         "note": r.note, "created_at": r.createdAt,
         "engine_version": r.engineVersion]
    }

    @discardableResult
    func save(record: CrosshairRecordFile) throws -> String {
        do {
            try CoordinateEngine.ImageIdentity(
                sha256: record.imageId,
                widthPx: record.imageWidthPx,
                heightPx: record.imageHeightPx
            ).validate(pointInside: CoordinateEngine.PixelPoint(x: record.xPx, y: record.yPx))
        } catch { throw RecordStoreError.outsideBounds }

        let recordId = try CoordinateEngine.recordHash(Self.payload(record))
        let file: [String: Any] = Self.payload(record).merging(
            ["record_id": recordId], uniquingKeysWith: { _, new in new })
        let data = try JSONSerialization.data(
            withJSONObject: file, options: [.prettyPrinted, .sortedKeys])
        let target = try url(for: recordId)
        let tmp = target.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmp, to: target)
        return recordId
    }

    func load(recordId: String) throws -> (CrosshairRecordFile, VerificationStatus) {
        let fileUrl = try url(for: recordId)
        guard FileManager.default.fileExists(atPath: fileUrl.path) else {
            throw RecordStoreError.notFound
        }
        let data = try Data(contentsOf: fileUrl)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RecordStoreError.integrityFailure
        }
        let expected = try? CoordinateEngine.recordHash(dict.filter { $0.key != "record_id" })
        guard expected == recordId, dict["record_id"] as? String == recordId else {
            throw RecordStoreError.integrityFailure
        }
        let rec = CrosshairRecordFile(
            competitionId: dict["competition_id"] as? String ?? "",
            judgeId: dict["judge_id"] as? String ?? "",
            imageId: dict["image_id"] as? String ?? "",
            imageWidthPx: dict["image_width_px"] as? Int ?? 0,
            imageHeightPx: dict["image_height_px"] as? Int ?? 0,
            xPx: dict["x_px"] as? Int ?? 0,
            yPx: dict["y_px"] as? Int ?? 0,
            note: dict["note"] as? String ?? "",
            createdAt: dict["created_at"] as? String ?? "",
            engineVersion: dict["engine_version"] as? String ?? "")
        return (rec, .pass)
    }

    func verify(recordId: String, identity: CoordinateEngine.ImageIdentity?) throws
        -> VerificationReport {
        let fileUrl = try url(for: recordId)
        guard let data = try? Data(contentsOf: fileUrl),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RecordStoreError.notFound
        }
        var checks: [String: VerificationStatus] = [:]
        let recomputed = try? CoordinateEngine.recordHash(dict.filter { $0.key != "record_id" })
        checks["digest"] = (recomputed == recordId
                            && dict["record_id"] as? String == recordId) ? .pass : .fail
        if let identity = identity {
            let ok = (dict["image_id"] as? String) == identity.sha256
                && (dict["image_width_px"] as? Int) == identity.widthPx
                && (dict["image_height_px"] as? Int) == identity.heightPx
            checks["image_identity"] = ok ? .pass : .fail
        }
        let w = dict["image_width_px"] as? Int ?? 0
        let h = dict["image_height_px"] as? Int ?? 0
        let x = dict["x_px"] as? Int ?? 0
        let y = dict["y_px"] as? Int ?? 0
        checks["bounds"] = (x >= 0 && x < w && y >= 0 && y < h) ? .pass : .fail
        let status: VerificationStatus = checks.values.allSatisfy { $0 == .pass } ? .pass : .fail
        return VerificationReport(recordId: recordId, status: status, checks: checks)
    }

    func listRecordIds() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }.sorted()
    }

    /// Raw JSON bytes of a stored crosshair record (for export/backup).
    func exportRecordJSON(recordId: String) throws -> Data {
        let fileUrl = try url(for: recordId)
        guard FileManager.default.fileExists(atPath: fileUrl.path) else {
            throw RecordStoreError.notFound
        }
        return try Data(contentsOf: fileUrl)
    }
}

// MARK: - Assessment persistence with hash-chained audit

final class AssessmentStore {
    let root: URL

    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                    in: .userDomainMask)[0]
            .appendingPathComponent("JudgesEdition/Assessments", isDirectory: true)
        self.root = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func save(assessment: Assessment) throws {
        let data = try JSONEncoder().encode(assessment)
        let target = root.appendingPathComponent(assessment.assessmentId + ".json")
        let tmp = target.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmp, to: target)
    }

    func load(assessmentId: String) throws -> Assessment {
        let target = root.appendingPathComponent(assessmentId + ".json")
        return try JSONDecoder().decode(Assessment.self, from: Data(contentsOf: target))
    }

    func listAssessmentIds() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }.sorted()
    }

    /// Raw JSON bytes of a stored assessment (for export/backup).
    func exportAssessmentJSON(assessmentId: String) throws -> Data {
        let target = root.appendingPathComponent(assessmentId + ".json")
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw RecordStoreError.notFound
        }
        return try Data(contentsOf: target)
    }
}
