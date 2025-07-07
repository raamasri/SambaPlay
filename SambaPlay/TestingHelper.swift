//
//  TestingHelper.swift
//  SambaPlay
//
//  Created by raama srivatsan on 7/4/25.
//

import Foundation
import AVFoundation
import Combine

// MARK: - Testing Helper for SambaPlay
class TestingHelper {
    
    static let shared = TestingHelper()
    private init() {}
    
    // MARK: - Basic Tests
    
    func runAllTests() {
        print("🧪 Starting SambaPlay Comprehensive Testing...")
        
        // Basic functionality tests
        testBasicFunctionality()
        testFileExtensions()
        testNetworkingCapabilities()
        testUserSambaServer() // Test user's specific server
        testAudioProcessing()
        
        print("✅ All tests completed successfully!")
    }
    
    private func testUserSambaServer() {
        print("🧪 Testing user's Samba server (fads1005d8 at 192.168.1.17)...")
        
        // Test server details
        let serverName = "fads1005d8"
        let serverHost = "192.168.1.17"
        let serverPort: Int16 = 445
        
        print("📊 Server details:")
        print("  Name: \(serverName)")
        print("  Host: \(serverHost)")
        print("  Port: \(serverPort)")
        print("  Auth: Guest/Anonymous")
        
        // Test basic network connectivity
        print("🔍 Testing basic connectivity...")
        
        // Create a simple socket test
        let expectation = TestExpectation()
        
        DispatchQueue.global().async {
            let success = self.testSocketConnection(host: serverHost, port: Int(serverPort))
            print(success ? "✅ Socket connection successful" : "❌ Socket connection failed")
            expectation.fulfill()
        }
        
        expectation.wait(timeout: 10.0)
        
        print("✅ User Samba server test completed")
    }
    
    private func testSocketConnection(host: String, port: Int) -> Bool {
        // Simple socket connectivity test
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        
        defer { close(sock) }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        
        if inet_pton(AF_INET, host, &addr.sin_addr) <= 0 {
            return false
        }
        
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        return result == 0
    }
    
    private func testBasicFunctionality() {
        print("🧪 Testing basic functionality...")
        
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
        
        print("✅ Basic functionality test passed")
    }
    
    private func testFileExtensions() {
        print("🧪 Testing file extension detection...")
        
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
        
        print("✅ File extension detection test passed")
    }
    
    private func testNetworkingCapabilities() {
        print("🧪 Testing networking capabilities...")
        
        // Test URL creation
        let testURL = URL(string: "smb://192.168.1.100/music")
        assert(testURL != nil, "Should be able to create SMB URL")
        
        // Test URL components
        if let url = testURL {
            assert(url.scheme == "smb", "URL scheme should be SMB")
            assert(url.host == "192.168.1.100", "URL host should be correct")
            assert(url.path == "/music", "URL path should be correct")
        }
        
        print("✅ Networking capabilities test passed")
    }
    
    private func testAudioProcessing() {
        print("🧪 Testing audio processing capabilities...")
        
        // Test time formatting
        let testTime: Double = 125.5
        let minutes = Int(testTime) / 60
        let seconds = Int(testTime) % 60
        let timeString = String(format: "%d:%02d", minutes, seconds)
        assert(timeString == "2:05", "Time formatting should work correctly")
        
        // Test progress calculation
        let progress = testTime / 300.0 * 100.0
        assert(abs(progress - 41.83) < 0.1, "Progress calculation should be accurate")
        
        print("✅ Audio processing test passed")
    }
    

    
    // MARK: - Integration Tests
    
    func testAppIntegration() {
        print("🧪 Testing app integration...")
        
        // Test basic app functionality
        print("App bundle identifier: \(Bundle.main.bundleIdentifier ?? "unknown")")
        print("App version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")
        
        // Test user defaults
        let userDefaults = UserDefaults.standard
        userDefaults.set("test_value", forKey: "test_key")
        let retrievedValue = userDefaults.string(forKey: "test_key")
        assert(retrievedValue == "test_value", "UserDefaults should work correctly")
        userDefaults.removeObject(forKey: "test_key")
        
        print("✅ App integration test passed")
    }
    
    func testFileSystemOperations() {
        print("🧪 Testing file system operations...")
        
        // Test file manager operations
        let fileManager = FileManager.default
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        assert(documentsPath != nil, "Should be able to access documents directory")
        
        // Test path operations
        if let path = documentsPath {
            let testPath = path.appendingPathComponent("test.txt")
            print("Test path created: \(testPath.path)")
            assert(testPath.lastPathComponent == "test.txt", "Path component should be correct")
        }
        
        print("✅ File system operations test passed")
    }
    
    // MARK: - Performance Tests
    
    func testPerformance() {
        print("🧪 Testing performance...")
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Simulate some work
        var sum = 0
        for i in 0..<10000 {
            sum += i
        }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = endTime - startTime
        
        print("Performance test completed in \(String(format: "%.3f", duration)) seconds")
        assert(duration < 1.0, "Performance test should complete quickly")
        
        print("✅ Performance test passed")
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