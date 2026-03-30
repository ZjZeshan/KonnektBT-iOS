// KonnektBT/KonnektApp.swift
import SwiftUI
import os.log

@main
struct KonnektBTApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    
    // Logging for crash debugging
    private let logger = Logger(subsystem: "com.konnekt.ios", category: "App")

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .onAppear {
                    logger.info("KonnektBT App appeared")
                }
        }
        .onChange(of: scenePhase) { phase in
            logger.info("Scene phase changed to: \(phase.rawValue)")
            switch phase {
            case .background:
                appState.handleBackground()
            case .active:
                appState.handleForeground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
