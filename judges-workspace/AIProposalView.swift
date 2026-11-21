// AIProposalView.swift
// BOTB Judges Edition - AI proposal intake, STRICTLY SEPARATE from judge
// submissions. Proposals are stored in ai_proposals[] and never influence the
// consensus computation; the separation is enforced by the reference
// implementation (engine/multi_judge.py refuses "ai*" judge ids).

import SwiftUI

struct AIProposalView: View {
    @State private var assessmentId = ""
    @State private var xText = ""
    @State private var yText = ""
    @State private var model = "reference-proposal-v0"
    @State private var confidenceText = "0.80"
    @State private var statusMessage: String?

    private let assessmentStore = AssessmentStore()

    var body: some View {
        Form {
            Section("Target assessment") {
                TextField("Assessment ID", text: $assessmentId).autocorrectionDisabled()
            }
            Section("Proposal (canonical pixel coordinates)") {
                TextField("x_px", text: $xText).keyboardType(.numberPad)
                TextField("y_px", text: $yText).keyboardType(.numberPad)
                TextField("Model identifier", text: $model)
                TextField("Confidence 0...1", text: $confidenceText)
            }
            Section {
                Button("Register AI proposal") { register() }
                    .disabled(!valid)
                if let msg = statusMessage {
                    Text(msg).font(.footnote).foregroundStyle(statusMessage == "Proposal registered (separate from judge submissions)." ? .green : .red)
                }
                Text("Proposals are advisory only. They are never counted as judge submissions and never change the consensus.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("AI proposal")
    }

    private var valid: Bool {
        guard let x = Int(xText), let y = Int(yText), x >= 0, y >= 0,
              let conf = Double(confidenceText), (0.0...1.0).contains(conf) else { return false }
        return !assessmentId.isEmpty
    }

    private func register() {
        guard let a = try? assessmentStore.load(assessmentId: assessmentId) else {
            statusMessage = "Assessment not found."; return
        }
        var updated = a
        let proposalDict: [String: Any] = [
            "x_px": Int(xText) ?? 0, "y_px": Int(yText) ?? 0,
            "model": model, "confidence": Double(confidenceText) ?? 0]
        if let data = try? JSONSerialization.data(withJSONObject: proposalDict,
                                                  options: [.sortedKeys]) {
            let proposalId = CoordinateEngine.imageSHA256(data)
            updated.aiProposals.append(AIProposal(
                xPx: Int(xText) ?? 0, yPx: Int(yText) ?? 0,
                model: model, confidence: Double(confidenceText) ?? 0,
                proposalId: proposalId))
            try? assessmentStore.save(assessment: updated)
            statusMessage = "Proposal registered (separate from judge submissions)."
        } else {
            statusMessage = "Proposal serialization failed."
        }
    }
}
