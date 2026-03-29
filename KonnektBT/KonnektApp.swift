// KonnektBT/KonnektApp.swift
import SwiftUI
import AVFoundation
import BackgroundTasks

@main
struct KonnektBTApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    
    // Background task identifier
    static let backgroundTaskId = "com.zjzeshan.konnektbt.refresh"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                // Request background execution time
                appState.handleBackground()
            case .active:
                appState.handleForeground()
                // End any background task
                UIApplication.shared.endBackgroundTask(appState.backgroundTaskId)
                appState.backgroundTaskId = .invalid
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        // Register background task
        .backgroundTask(.appRefresh(KonnektBTApp.backgroundTaskId)) {
            // Keep connection alive in background
            appState.refreshInBackground()
        }
    }
}
