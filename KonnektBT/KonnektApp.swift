// KonnektBT/KonnektApp.swift
import SwiftUI
import os.log
import UIKit

@main
struct KonnektBTApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    
    // File-based logger for crash debugging
    private let fileLogger = Logger.shared

    init() {
        // Register background tasks to keep connection alive
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.zjzeshan.konnektbt.refresh", using: nil) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
        fileLogger.log("BGTaskScheduler registered", category: "APP")
    }
    
    private func handleAppRefresh(task: BGAppRefreshTask) {
        fileLogger.log("BGAppRefreshTask fired", category: "APP")
        // Schedule next refresh
        scheduleAppRefresh()
        
        task.expirationHandler = {
            fileLogger.log("BGTask expired", category: "APP")
        }
        
        // Try to keep connection alive
        fileLogger.log("BGTask: ensuring connection", category: "APP")
        task.setTaskCompleted(success: true)
    }
    
    private func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "com.zjzeshan.konnektbt.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        
        do {
            try BGTaskScheduler.shared.submit(request)
            fileLogger.log("BGAppRefreshTask scheduled", category: "APP")
        } catch {
            fileLogger.error("Could not schedule BGTask: \(error)")
        }
    }

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
