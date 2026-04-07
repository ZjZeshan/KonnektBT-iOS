// KonnektBT/KonnektApp.swift
import SwiftUI
import os.log

@main
struct KonnektBTApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    
    // File-based logger for crash debugging
    private let fileLogger = Logger.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .onAppear {
                    fileLogger.log("KonnektBT App appeared", category: "APP")
                }
        }
        .onChange(of: scenePhase) { _ in
            switch scenePhase {
            case .background:
                fileLogger.log("App entering background", category: "APP")
                appState.handleBackground()
            case .active:
                fileLogger.log("App entering foreground", category: "APP")
                appState.handleForeground()
            case .inactive:
                fileLogger.log("App inactive", category: "APP")
                break
            @unknown default:
                break
            }
        }
    }
}
