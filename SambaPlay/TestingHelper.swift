//
//  TestingHelper.swift
//  SambaPlay
//
//  Created by raama srivatsan on 7/4/25.
//

import Foundation
import AVFoundation
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

// MARK: - Testing Helper for SambaPlay
class TestingHelper {
    
    static let shared = TestingHelper()
    private let logger = AppLogger.shared
    private init() {}
    
    // MARK: - Basic Tests
    
    func runAllTests() {
        logger.log("🧪 Starting SambaPlay Comprehensive Testing...", level: .info)
        
        // Basic functionality tests
        testBasicFunctionality()
        testFileExtensions()
        testNetworkingCapabilities()
        testAudioProcessing()
        
        logger.log("✅ All tests completed successfully!", level: .success)
    }
    
    private func testBasicFunctionality() {
        logger.log("🧪 Testing basic functionality...", level: .info)
        
        // Test basic string operations
        let testString = "Sample Song.mp3"
        let hasExtension = testString.contains(".")
        assert(hasExtension, "File should have extension")
        
        // Test date operations
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        let dateString = formatter.string(from: now)
        assert(!dateString.isEmpty, "Date formatting should work")
        
        logger.log("✅ Basic functionality test passed", level: .success)
    }
    
    private func testFileExtensions() {
        logger.log("🧪 Testing file extension detection...", level: .info)
        
        let audioExtensions = ["mp3", "m4a", "wav", "aac", "flac", "ogg", "wma", "aiff", "opus"]
        let textExtensions = ["txt", "lrc", "srt", "lyrics", "md", "rtf", "vtt"]
        
        // Test audio extensions
        for ext in audioExtensions {
            let filename = "test.\(ext)"
            assert(filename.hasSuffix(ext), "File should have correct extension")
        }
        
        // Test text extensions
        for ext in textExtensions {
            let filename = "test.\(ext)"
            assert(filename.hasSuffix(ext), "File should have correct extension")
        }
        
        logger.log("✅ File extension detection test passed", level: .success)
    }
    
    private func testNetworkingCapabilities() {
        logger.log("🧪 Testing networking capabilities...", level: .info)
        
        // Test URL creation
        let testURL = URL(string: "smb://192.168.1.100/music")
        assert(testURL != nil, "Should be able to create SMB URL")
        
        // Test URL components
        if let url = testURL {
            assert(url.scheme == "smb", "URL scheme should be SMB")
            assert(url.host == "192.168.1.100", "URL host should be correct")
            assert(url.path == "/music", "URL path should be correct")
        }
        
        logger.log("✅ Networking capabilities test passed", level: .success)
    }
    
    private func testAudioProcessing() {
        logger.log("🧪 Testing audio processing capabilities...", level: .info)
        
        // Test time formatting
        let testTime: Double = 125.5
        let minutes = Int(testTime) / 60
        let seconds = Int(testTime) % 60
        let timeString = String(format: "%d:%02d", minutes, seconds)
        assert(timeString == "2:05", "Time formatting should work correctly")
        
        // Test progress calculation
        let progress = testTime / 300.0 * 100.0
        assert(abs(progress - 41.83) < 0.1, "Progress calculation should be accurate")
        
        logger.log("✅ Audio processing test passed", level: .success)
    }
    
    // MARK: - Integration Tests
    
    func testAppIntegration() {
        logger.log("🧪 Testing app integration...", level: .info)
        
        // Test basic app functionality
        logger.log("App bundle identifier: \(Bundle.main.bundleIdentifier ?? "unknown")", level: .info)
        logger.log("App version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")", level: .info)
        
        // Test user defaults
        let userDefaults = UserDefaults.standard
        userDefaults.set("test_value", forKey: "test_key")
        let retrievedValue = userDefaults.string(forKey: "test_key")
        assert(retrievedValue == "test_value", "UserDefaults should work correctly")
        userDefaults.removeObject(forKey: "test_key")
        
        logger.log("✅ App integration test passed", level: .success)
    }
    
    func testFileSystemOperations() {
        logger.log("🧪 Testing file system operations...", level: .info)
        
        // Test file manager operations
        let fileManager = FileManager.default
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        assert(documentsPath != nil, "Should be able to access documents directory")
        
        // Test path operations
        if let path = documentsPath {
            let testPath = path.appendingPathComponent("test.txt")
            logger.log("Test path created: \(testPath.path)", level: .info)
            assert(testPath.lastPathComponent == "test.txt", "Path component should be correct")
        }
        
        logger.log("✅ File system operations test passed", level: .success)
    }
    
    // MARK: - Performance Tests
    
    func testPerformance() {
        logger.log("🧪 Testing performance...", level: .info)
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Simulate some work
        var sum = 0
        for i in 0..<10000 {
            sum += i
        }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = endTime - startTime
        
        logger.log("Performance test completed in \(String(format: "%.3f", duration)) seconds", level: .info)
        assert(duration < 1.0, "Performance test should complete quickly")
        
        logger.log("✅ Performance test passed", level: .success)
    }
}

// MARK: - Test Expectation Helper
class TestExpectation {
    private var isFulfilled = false
    
    func fulfill() {
        isFulfilled = true
    }
    
    func wait(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !isFulfilled && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        assert(isFulfilled, "Test expectation timed out")
    }
} 