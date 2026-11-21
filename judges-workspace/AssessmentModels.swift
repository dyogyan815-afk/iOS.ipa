// AssessmentModels.swift
// BOTB Judges Edition - Record formats mirroring schemas/assessment.schema.json
// and engine/multi_judge.py. Individual judge submissions are authoritative;
// AI proposals are stored separately and never enter the judges array.

import Foundation

struct Crosshair: Codable, Equatable {
    var xPx: Int
    var yPx: Int
    var imageWidthPx: Int
    var imageHeightPx: Int

    enum CodingKeys: String, CodingKey {
        case xPx = "x_px", yPx = "y_px"
        case imageWidthPx = "image_width_px"
        case imageHeightPx = "image_height_px"
    }
}

struct JudgeSubmission: Codable, Equatable, Identifiable {
    var judgeId: String
    var crosshair: Crosshair
    var submittedAt: String
    var note: String

    enum CodingKeys: String, CodingKey {
        case judgeId = "judge_id", crosshair
        case submittedAt = "submitted_at", note
    }
    var id: String { judgeId }

    static func nowISO() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }
}

struct ApprovalRecord: Codable, Equatable {
    var status: String   // PENDING | APPROVED | REJECTED
    var approver: String?
    var decidedAt: String?

    enum CodingKeys: String, CodingKey {
        case status, approver
        case decidedAt = "decided_at"
    }
}

struct AuditEntry: Codable, Equatable, Identifiable {
    var timestamp: String
    var actor: String
    var action: String
    var details: [String: String]
    var prevEntryHash: String
    var entryHash: String

    enum CodingKeys: String, CodingKey {
        case timestamp, actor, action, details
        case prevEntryHash = "prev_entry_hash"
        case entryHash = "entry_hash"
    }
    var id: String { entryHash }
}

struct AIProposal: Codable, Equatable, Identifiable {
    var xPx: Int
    var yPx: Int
    var model: String
    var confidence: Double
    var proposalId: String

    enum CodingKeys: String, CodingKey {
        case xPx = "x_px", yPx = "y_px", model, confidence
        case proposalId = "proposal_id"
    }
    var id: String { proposalId }
}

/// Full multi-judge assessment record (JSON interchangeable with the Python
/// reference implementation).
struct Assessment: Codable, Identifiable {
    var assessmentId: String
    var competitionId: String
    var imageId: String
    var consensusMethod: String
    var tolerancePx: Double
    var judges: [JudgeSubmission]
    var consensus: [String: AnyCodableValue]?
    var approval: ApprovalRecord
    var aiProposals: [AIProposal]
    var audit: [AuditEntry]
    var engineVersion: String
    var assessmentHash: String

    enum CodingKeys: String, CodingKey {
        case assessmentId = "assessment_id"
        case competitionId = "competition_id"
        case imageId = "image_id"
        case consensusMethod = "consensus_method"
        case tolerancePx = "tolerance_px"
        case judges, consensus, approval
        case aiProposals = "ai_proposals"
        case audit
        case engineVersion = "engine_version"
        case assessmentHash = "assessment_hash"
    }
    var id: String { assessmentId }
}

/// Minimal dynamic JSON value used for the consensus block.
enum AnyCodableValue: Codable, Equatable {
    case string(String), double(Double), int(Int), null

    init(_ any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let d as Double: self = .double(d)
        case let i as Int: self = .int(i)
        default: self = .null
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .double(let d): try c.encode(d)
        case .int(let i): try c.encode(i)
        case .null: try c.encodeNil()
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var doubleValue: Double? {
        if case .double(let d) = self { return d }
        if case .int(let i) = self { return Double(i) }
        return nil
    }
}
