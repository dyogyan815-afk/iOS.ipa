import Foundation
import CryptoKit

enum PanelError: Error { case invalidInput, duplicateJudge, incomplete, disagreement, integrity }

struct PanelVote: Codable, Equatable {
    let judge: Int
    let x: Int
    let y: Int
}

struct PanelEvent: Codable {
    let action: String
    let time: String
    let previous: String
    let digest: String
}

struct SevenJudgePanel: Codable, Identifiable {
    let id: UUID
    let competition: String
    let image: Data
    let width: Int
    let height: Int
    let tolerance: Double
    private(set) var votes: [PanelVote] = []
    private(set) var approved = false
    private(set) var audit: [PanelEvent] = []

    init(competition: String, image: Data, width: Int, height: Int, tolerance: Double) throws {
        guard !competition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !image.isEmpty, width >= 2, height >= 2, width <= 100000, height <= 100000,
              tolerance.isFinite, tolerance >= 0, tolerance <= 100000 else { throw PanelError.invalidInput }
        self.id = UUID(); self.competition = competition; self.image = image
        self.width = width; self.height = height; self.tolerance = tolerance
        appendEvent("created")
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var imageID: String { Self.digest(image) }
    var complete: Bool { Set(votes.map(\.judge)) == Set(1...7) && votes.count == 7 }
    var nextJudge: Int? { (1...7).first { n in !votes.contains { $0.judge == n } } }

    mutating func submit(judge: Int, x: Int, y: Int) throws {
        guard (1...7).contains(judge), (0..<width).contains(x), (0..<height).contains(y) else { throw PanelError.invalidInput }
        guard !votes.contains(where: { $0.judge == judge }) else { throw PanelError.duplicateJudge }
        votes.append(PanelVote(judge: judge, x: x, y: y))
        approved = false
        appendEvent("submitted:\(judge)")
    }

    func result() throws -> CoordinateEngine.Consensus {
        guard complete else { throw PanelError.incomplete }
        return try CoordinateEngine.evaluateConsensus(votes.map { .init(x: $0.x, y: $0.y) }, tolerancePx: tolerance)
    }

    mutating func approve() throws {
        guard try result().agreementRatio == 1 else { throw PanelError.disagreement }
        approved = true; appendEvent("approved")
    }

    mutating func restart() {
        votes = []; approved = false; appendEvent("all_votes_reset")
    }

    private mutating func appendEvent(_ action: String) {
        let time = ISO8601DateFormatter().string(from: Date())
        let previous = audit.last?.digest ?? "GENESIS"
        let digest = Self.digest(Data("\(previous)\n\(action)\n\(time)".utf8))
        audit.append(PanelEvent(action: action, time: time, previous: previous, digest: digest))
    }

    func validate() throws {
        guard !competition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !image.isEmpty,
              width >= 2, height >= 2, width <= 100000, height <= 100000,
              tolerance.isFinite, tolerance >= 0, tolerance <= 100000,
              votes.count <= 7, Set(votes.map(\.judge)).count == votes.count, !audit.isEmpty else { throw PanelError.integrity }
        for v in votes {
            guard (1...7).contains(v.judge), (0..<width).contains(v.x), (0..<height).contains(v.y) else { throw PanelError.integrity }
        }
        var previous = "GENESIS"
        for event in audit {
            guard event.previous == previous,
                  event.digest == Self.digest(Data("\(previous)\n\(event.action)\n\(event.time)".utf8)) else { throw PanelError.integrity }
            previous = event.digest
        }
        if approved {
            guard complete else { throw PanelError.integrity }
            guard try result().agreementRatio == 1 else { throw PanelError.integrity }
        }
    }
}

struct PanelEnvelope: Codable { let payload: Data; let sha256: String }

struct SevenPanelStore {
    let directory: URL
    init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SevenJudgePanels", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }
    func save(_ panel: SevenJudgePanel) throws {
        try panel.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(panel)
        let envelope = PanelEnvelope(payload: payload, sha256: SevenJudgePanel.digest(payload))
        try encoder.encode(envelope).write(to: directory.appendingPathComponent(panel.id.uuidString + ".json"), options: .atomic)
    }
    func load(_ id: UUID) throws -> SevenJudgePanel {
        let data = try Data(contentsOf: directory.appendingPathComponent(id.uuidString + ".json"))
        let envelope = try JSONDecoder().decode(PanelEnvelope.self, from: data)
        guard SevenJudgePanel.digest(envelope.payload) == envelope.sha256 else { throw PanelError.integrity }
        let panel = try JSONDecoder().decode(SevenJudgePanel.self, from: envelope.payload)
        guard panel.id == id else { throw PanelError.integrity }
        try panel.validate(); return panel
    }
    func ids() throws -> [UUID] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.uuidString < $1.uuidString }
    }
}
