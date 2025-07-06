//
//  AppLogger.swift
//  SambaPlay
//
//  Created by raama srivatsan on 7/6/25.
//

import Foundation
import Combine

// MARK: - App Logging System
class AppLogger: ObservableObject {
    static let shared = AppLogger()
    
    @Published var logs: [LogEntry] = []
    private let maxLogs = 1000 // Keep last 1000 log entries
    
    private init() {}
    
    func log(_ message: String, level: LogLevel = .info) {
        let entry = LogEntry(message: message, level: level, timestamp: Date())
        
        DispatchQueue.main.async {
            self.logs.append(entry)
            
            // Keep only the most recent logs
            if self.logs.count > self.maxLogs {
                self.logs.removeFirst(self.logs.count - self.maxLogs)
            }
        }
        
        // Also print to console for debugging
        print("[\(level.emoji) \(level.rawValue.uppercased())] \(message)")
    }
    
    func clearLogs() {
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
    }
    
    func exportLogs() -> String {
        return logs.map { entry in
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            return "[\(formatter.string(from: entry.timestamp))] [\(entry.level.rawValue.uppercased())] \(entry.message)"
        }.joined(separator: "\n")
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let message: String
    let level: LogLevel
    let timestamp: Date
}

enum LogLevel: String, CaseIterable {
    case debug = "debug"
    case info = "info"
    case warning = "warning"
    case error = "error"
    case success = "success"
    
    var emoji: String {
        switch self {
        case .debug: return "🔍"
        case .info: return "ℹ️"
        case .warning: return "⚠️"
        case .error: return "❌"
        case .success: return "✅"
        }
    }
} 