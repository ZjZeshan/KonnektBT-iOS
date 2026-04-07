// KonnektBT/Services/Logger.swift
// File-based logger for crash debugging (no Mac needed)

import Foundation
import UIKit

class Logger {
    static let shared = Logger()
    
    private let fileManager = FileManager.default
    private let logQueue = DispatchQueue(label: "com.konnekt.logger", qos: .utility)
    private var logFilePath: URL
    
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
    
    private init() {
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFilePath = documentsPath.appendingPathComponent("konnekt_logs.txt")
        
        // Start fresh each launch (or keep appending based on preference)
        clearLogs()
        log("=== KONNEKT APP LAUNCHED ===")
        log("iOS Version: \(UIDevice.current.systemVersion)")
        log("App Version: 2.8")
    }
    
    func log(_ message: String, category: String = "APP") {
        let timestamp = dateFormatter.string(from: Date())
        let entry = "[\(timestamp)] [\(category)] \(message)"
        
        logQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Print to console
            print(entry)
            
            // Write to file
            if let data = (entry + "\n").data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: self.logFilePath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                } else {
                    // File doesn't exist, create it
                    try? data.write(to: self.logFilePath)
                }
            }
        }
    }
    
    func error(_ message: String) {
        log("ERROR: \(message)", category: "ERROR")
    }
    
    func getLogContents() -> String {
        var contents = ""
        logQueue.sync {
            contents = (try? String(contentsOf: logFilePath, encoding: .utf8)) ?? ""
        }
        return contents
    }
    
    func getLogFileURL() -> URL {
        return logFilePath
    }
    
    func clearLogs() {
        logQueue.async { [weak self] in
            guard let self = self else { return }
            try? "".write(to: self.logFilePath, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Global print redirect
// Redirects all print() calls to our file logger
extension Logger {
    static func setupPrintRedirection() {
        // Store original print function
        let originalPrint = { (items: [Any], separator: String, terminator: String) in
            let output = items.map { "\($0)" }.joined(separator: separator)
            Logger.shared.log(output, category: "PRINT")
        }
    }
}
