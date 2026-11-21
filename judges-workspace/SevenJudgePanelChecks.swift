import Foundation

@main enum SevenJudgePanelChecks {
    static func mustFail(_ operation: () throws -> Void) {
        do { try operation() } catch { return }
        fatalError("Expected failure was not raised")
    }
    static func main() throws {
        var p = try SevenJudgePanel(competition: "TEST", image: Data([1, 2, 3]), width: 100, height: 100, tolerance: 2)
        mustFail { _ = try p.result() }
        mustFail { try p.submit(judge: 8, x: 50, y: 50) }
        mustFail { try p.submit(judge: 1, x: -1, y: 50) }
        mustFail { try p.submit(judge: 1, x: 100, y: 50) }
        for n in 1...6 { try p.submit(judge: n, x: 50, y: 50) }
        mustFail { try p.approve() }
        mustFail { try p.submit(judge: 1, x: 50, y: 50) }
        try p.submit(judge: 7, x: 50, y: 50)
        let c = try p.result(); precondition(c.xPx == 50 && c.yPx == 50 && c.agreementRatio == 1)
        try p.approve(); precondition(p.approved)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SevenPanelStore(directory: directory)
        try store.save(p)
        let restored = try store.load(p.id)
        precondition(restored.votes == p.votes && restored.approved && restored.image == p.image)
        let path = directory.appendingPathComponent(p.id.uuidString + ".json")
        let original = try Data(contentsOf: path)
        let envelope = try JSONDecoder().decode(PanelEnvelope.self, from: original)
        let broken = PanelEnvelope(payload: envelope.payload + Data([32]), sha256: envelope.sha256)
        try JSONEncoder().encode(broken).write(to: path)
        mustFail { _ = try store.load(p.id) }
        p.restart(); precondition(p.votes.isEmpty && !p.approved && p.nextJudge == 1)
        try p.validate(); mustFail { try p.approve() }
        var spread = try SevenJudgePanel(competition: "TEST", image: Data([1]), width: 100, height: 100, tolerance: 1)
        for n in 1...7 { try spread.submit(judge: n, x: n * 10, y: 50) }
        mustFail { try spread.approve() }
        mustFail { _ = try SevenJudgePanel(competition: " ", image: Data([1]), width: 100, height: 100, tolerance: 2) }
        print("Seven-judge core regression checks passed")
    }
}
