// MultiJudgeCompareView.swift
// BOTB Judges Edition - cross-judge comparison, consensus and human approval.
//
// Loads all crosshair records for (competition_id, image_id), computes the
// authoritative consensus via CoordinateEngine, enforces the approval gate
// (agreement_ratio == 1.0 for APPROVED) and appends hash-chained audit
// entries. AI proposals are displayed separately and excluded from consensus.

import SwiftUI

struct MultiJudgeCompareView: View {
    @State private var competitionId = ""
    @State private var assessments: [Assessment] = []
    @State private var statusMessage: String?

    private let assessmentStore = AssessmentStore()
    private let recordsStore = RecordsStore()

    var body: some View {
        NavigationStack {
            List {
                Section("Competition") {
                    TextField("Competition ID", text: $competitionId)
                        .autocorrectionDisabled()
                    Button("Reload assessments") { reload() }
                        .disabled(competitionId.isEmpty)
                }
                Section("Assessments") {
                    if assessments.isEmpty {
                        Text("No assessments recorded for this competition.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(assessments) { a in
                        NavigationLink(value: a.id) {
                            AssessmentRow(assessment: a)
                        }
                    }
                }
                if let msg = statusMessage {
                    Text(msg).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("Multi-judge comparison")
            .navigationDestination(for: String.self) { assessmentId in
                if let a = assessments.first(where: { $0.id == assessmentId }) {
                    AssessmentDetailView(assessment: a) { reload() }
                }
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        guard !competitionId.isEmpty else { return }
        let all = assessmentStore.listAssessmentIds().compactMap { try? assessmentStore.load(assessmentId: $0) }
        assessments = all.filter { $0.competitionId == competitionId }
    }
}

struct AssessmentRow: View {
    let assessment: Assessment

    private var consensusText: String {
        guard let c = assessment.consensus else { return "no consensus" }
        let x = c["x_px"]?.doubleValue.map { String($0) } ?? "?"
        let y = c["y_px"]?.doubleValue.map { String($0) } ?? "?"
        let ratio = c["agreement_ratio"]?.doubleValue ?? 0
        return "consensus (\(x), \(y)) px  |  agreement \(String(format: "%.0f%%", ratio * 100))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(assessment.assessmentId).font(.headline)
            Text("image \(assessment.imageId.prefix(12))... | \(assessment.judges.count) judges")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(consensusText).font(.caption)
            HStack {
                Image(systemName: assessment.approval.status == "APPROVED"
                        ? "checkmark.seal.fill" : "hourglass")
                Text(assessment.approval.status)
            }
            .font(.caption.bold())
            .foregroundStyle(assessment.approval.status == "APPROVED" ? .green : .orange)
        }
    }
}

struct AssessmentDetailView: View {
    @State var assessment: Assessment
    var onUpdated: () -> Void

    var body: some View {
        List {
            Section("Judge submissions") {
                ForEach(assessment.judges) { j in
                    HStack {
                        Image(systemName: "target")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading) {
                            Text(j.judgeId).font(.headline)
                            Text("(\(j.crosshair.xPx), \(j.crosshair.yPx)) px | \(j.note)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("AI proposals (not counted in consensus)") {
                if assessment.aiProposals.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(assessment.aiProposals) { p in
                    Text("\(p.model): (\(p.xPx), \(p.yPx)) px, confidence \(String(format: "%.2f", p.confidence))")
                        .font(.caption.monospaced())
                }
            }
            Section("Decision") {
                Button("Approve consensus") { decide("APPROVED") }
                    .disabled(assessment.consensus?["agreement_ratio"]?.doubleValue != 1.0)
                Button("Reject", role: .destructive) { decide("REJECTED") }
                if let approver = assessment.approval.approver,
                   let decided = assessment.approval.decidedAt {
                    Text("\(assessment.approval.status) by \(approver) at \(decided)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Export") {
                if let text = assessmentJSON {
                    ShareLink("Export assessment JSON", item: text)
                    Text("Contains judge submissions, consensus, AI proposals (separate) and the hash-chained audit.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Section("Audit history (hash-chained)") {
                ForEach(assessment.audit) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(e.timestamp) | \(e.actor) | \(e.action)").font(.caption.monospaced())
                        Text(e.entryHash.prefix(12) + "...").font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(assessment.assessmentId)
    }

    private var assessmentJSON: String? {
        guard let data = try? JSONEncoder().encode(assessment) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decide(_ status: String) {
        // Approval gate mirrors engine/multi_judge.py.
        if status == "APPROVED",
           assessment.consensus?["agreement_ratio"]?.doubleValue != 1.0 { return }
        let entryPayload: [String: Any] = [
            "timestamp": JudgeSubmission.nowISO(),
            "actor": "project-owner",
            "action": status == "APPROVED" ? "approval_approved" : "approval_rejected",
            "details": ["approver": "project-owner"],
            "prev_entry_hash": assessment.audit.last?.entryHash ?? "GENESIS"]
        guard let payloadData = try? JSONSerialization.data(
            withJSONObject: entryPayload, options: [.sortedKeys]) else { return }
        let entryHash = CoordinateEngine.imageSHA256(payloadData)
        assessment.audit.append(AuditEntry(
            timestamp: entryPayload["timestamp"] as! String,
            actor: "project-owner",
            action: entryPayload["action"] as! String,
            details: ["approver": "project-owner"],
            prevEntryHash: entryPayload["prev_entry_hash"] as! String,
            entryHash: entryHash))
        assessment.approval = ApprovalRecord(
            status: status, approver: "project-owner",
            decidedAt: JudgeSubmission.nowISO())
        try? AssessmentStore().save(assessment: assessment)
        onUpdated()
    }
}
