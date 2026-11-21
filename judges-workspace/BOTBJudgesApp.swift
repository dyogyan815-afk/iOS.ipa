// BOTBJudgesApp.swift
// BOTB Judges Edition - app entry point.
//
// First-launch authentication gates the entire UI (AuthGate).
// Tabs: Judge submission / Local seven-judge panel / Multi-judge comparison /
// AI proposals (stored separately, never part of the consensus).
//
// PROVENANCE NOTE: independent Judges Edition implementation; it is not the
// original BOTB application and makes no such claim. See BUILD_REPORT.md.

import SwiftUI

@main
struct BOTBJudgesApp: App {
    var body: some Scene {
        WindowGroup {
            AuthGate {
                MainTabView()
            }
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack { JudgeSubmissionView() }
                .tabItem { Label("Judge", systemImage: "target") }
            NavigationStack { SevenJudgePanelView() }
                .tabItem { Label("Seven judges", systemImage: "person.3") }
            MultiJudgeCompareView()
                .tabItem { Label("Compare", systemImage: "square.3.layers.3d.down.left") }
            NavigationStack { AIProposalView() }
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
    }
}
