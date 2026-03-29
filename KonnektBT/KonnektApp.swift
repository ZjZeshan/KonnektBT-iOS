// KonnektBT/KonnektApp.swift
import SwiftUI

@main
struct KonnektBTApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                appState.handleBackground()
            case .active:
                appState.handleForeground()
            default:
                break
            }
        }
    }
}
