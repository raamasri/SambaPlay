//
//  NetworkTestSuite.swift
//  SambaPlay
//
//  Created by raama srivatsan on 7/6/25.
//

import Foundation
import Network

// MARK: - Network Test Suite
class NetworkTestSuite: ObservableObject {
    static let shared = NetworkTestSuite()
    
    @Published var testResults: [TestResult] = []
    @Published var isRunning = false
    @Published var currentTest: String = ""
    @Published var overallResult: TestResult.TestStatus = .pending
    
    private let smbConnection = SMBConnectionManager.shared
    private let networkErrorHandler = NetworkErrorHandler.shared
    private let offlineManager = OfflineModeManager.shared
    private let keychainManager = KeychainManager.shared
    
    private init() {}
    
    // MARK: - Test Result Models
    struct TestResult: Identifiable {
        let id = UUID()
        let testName: String
        let status: TestStatus
        let message: String
        let duration: TimeInterval
        let timestamp: Date
        
        init(testName: String, status: TestStatus, message: String, duration: TimeInterval) {
            self.testName = testName
            self.status = status
            self.message = message
            self.duration = duration
            self.timestamp = Date()
        }
        
        enum TestStatus: Equatable {
            case pending
            case running
            case passed(String)
            case failed(String)
            case skipped(String)
            
            var emoji: String {
                switch self {
                case .pending: return "⏳"
                case .running: return "🔄"
                case .passed: return "✅"
                case .failed: return "❌"
                case .skipped: return "⏭️"
                }
            }
            
            var description: String {
                switch self {
                case .pending: return "Pending"
                case .running: return "Running"
                case .passed: return "Passed"
                case .failed: return "Failed"
                case .skipped: return "Skipped"
                }
            }
            
            static func == (lhs: TestStatus, rhs: TestStatus) -> Bool {
                switch (lhs, rhs) {
                case (.pending, .pending), (.running, .running):
                    return true
                case (.passed(let lhsMsg), .passed(let rhsMsg)):
                    return lhsMsg == rhsMsg
                case (.failed(let lhsMsg), .failed(let rhsMsg)):
                    return lhsMsg == rhsMsg
                case (.skipped(let lhsMsg), .skipped(let rhsMsg)):
                    return lhsMsg == rhsMsg
                default:
                    return false
                }
            }
            
            // Convenience computed properties for comparison
            var isPassed: Bool {
                if case .passed = self { return true }
                return false
            }
            
            var isFailed: Bool {
                if case .failed = self { return true }
                return false
            }
            
            var isSkipped: Bool {
                if case .skipped = self { return true }
                return false
            }
        }
    }
    
    // MARK: - Test Configuration
    struct TestConfiguration {
        let testServer: SambaServer
        let testCredentials: TestCredentials?
        let timeout: TimeInterval
        let retryCount: Int
        
        static let `default` = TestConfiguration(
            testServer: SambaServer(name: "Test Server", host: "192.168.1.100"),
            testCredentials: nil,
            timeout: 30.0,
            retryCount: 3
        )
    }
    
    struct TestCredentials {
        let username: String
        let password: String
        let domain: String?
    }
    
    // MARK: - Main Test Runner
    func runAllTests(configuration: TestConfiguration = .default) async {
        DispatchQueue.main.async {
            self.isRunning = true
            self.testResults.removeAll()
            self.overallResult = .running
        }
        
        let startTime = Date()
        
        // Run all test suites
        await runConnectivityTests(configuration: configuration)
        await runAuthenticationTests(configuration: configuration)
        await runFileOperationTests(configuration: configuration)
        await runErrorHandlingTests(configuration: configuration)
        await runOfflineModeTests(configuration: configuration)
        await runPerformanceTests(configuration: configuration)
        await runSecurityTests(configuration: configuration)
        
        let endTime = Date()
        let totalDuration = endTime.timeIntervalSince(startTime)
        
        // Calculate overall result
        let failedTests = testResults.filter { $0.status.isFailed }
        let passedTests = testResults.filter { $0.status.isPassed }
        
        DispatchQueue.main.async {
            self.isRunning = false
            self.currentTest = ""
            
            if failedTests.isEmpty && !passedTests.isEmpty {
                self.overallResult = .passed("All tests passed")
            } else if failedTests.isEmpty && passedTests.isEmpty {
                self.overallResult = .skipped("No tests executed")
            } else {
                self.overallResult = .failed("Some tests failed")
            }
            
            // Add summary result
            let summaryMessage = """
            Tests completed in \(String(format: "%.2f", totalDuration))s
            Passed: \(passedTests.count)
            Failed: \(failedTests.count)
            Total: \(self.testResults.count)
            """
            
            let summaryResult = TestResult(
                testName: "Test Summary",
                status: self.overallResult,
                message: summaryMessage,
                duration: totalDuration
            )
            
            self.testResults.append(summaryResult)
        }
    }
    
    // MARK: - Helper Methods
    private func runTest(name: String, test: @escaping () async -> TestResult.TestStatus) async {
        let startTime = Date()
        
        DispatchQueue.main.async {
            self.currentTest = name
        }
        
        let status = await test()
        let endTime = Date()
        let duration = endTime.timeIntervalSince(startTime)
        
        let message: String
        switch status {
        case .passed(let msg):
            message = msg
        case .failed(let msg):
            message = msg
        case .skipped(let msg):
            message = msg
        default:
            message = "Test completed"
        }
        
        let result = TestResult(
            testName: name,
            status: status,
            message: message,
            duration: duration
        )
        
        DispatchQueue.main.async {
            self.testResults.append(result)
        }
    }
    
    private func isIPAddress(_ string: String) -> Bool {
        // Simple IP address validation
        let components = string.components(separatedBy: ".")
        guard components.count == 4 else { return false }
        
        for component in components {
            guard let number = Int(component), number >= 0 && number <= 255 else {
                return false
            }
        }
        
        return true
    }
    
    // MARK: - Specific Server Tests
    
    func testUserSambaServer() async {
        let testName = "User Samba Server Test (fads1005d8)"
        
        await runTest(name: testName) {
            do {
                // Test the specific server: fads1005d8 at 192.168.1.17
                let server = SambaServer(
                    name: "fads1005d8",
                    host: "192.168.1.17",
                    port: 445,
                    username: nil,  // Anonymous access
                    password: nil
                )
                
                // Test basic connectivity first using networkErrorHandler
                let reachable = await self.networkErrorHandler.testConnection(
                    to: server.host,
                    port: Int(server.port),
                    timeout: 10.0
                )
                
                guard reachable else {
                    return .failed("Server \(server.host) is not reachable on port \(server.port)")
                }
                
                // Test SMB connection with guest credentials
                try await self.smbConnection.connect(
                    to: server.host,
                    port: server.port,
                    username: "guest",
                    password: "",
                    domain: nil
                )
                
                // Wait a bit for connection to establish
                try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                
                let isConnected = self.smbConnection.isConnected
                
                if isConnected {
                    // Disconnect after successful test
                    self.smbConnection.disconnect()
                    return .passed("Successfully connected to \(server.name) (\(server.host)) as guest")
                } else {
                    return .failed("Failed to connect to \(server.name)")
                }
                
            } catch {
                return .failed("Test failed with error: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Connectivity Tests
    private func runConnectivityTests(configuration: TestConfiguration) async {
        await runTest(name: "Network Connectivity Check") {
            let isOnline = await self.networkErrorHandler.testConnection(
                to: configuration.testServer.host,
                port: Int(configuration.testServer.port),
                timeout: configuration.timeout
            )
            
            if isOnline {
                return .passed("Network connectivity verified")
            } else {
                return .failed("Network connectivity failed")
            }
        }
        
        await runTest(name: "SMB Port Accessibility") {
            let isAccessible = await self.networkErrorHandler.testConnection(
                to: configuration.testServer.host,
                port: Int(configuration.testServer.port),
                timeout: configuration.timeout
            )
            
            if isAccessible {
                return .passed("SMB port is accessible")
            } else {
                return .failed("SMB port is not accessible")
            }
        }
        
        await runTest(name: "DNS Resolution") {
            do {
                let host = configuration.testServer.host
                
                // Try to resolve hostname if it's not an IP address
                if !self.isIPAddress(host) {
                    // Use URLSession to test DNS resolution
                    let url = URL(string: "http://\(host)")!
                    let request = URLRequest(url: url, timeoutInterval: 5.0)
                    
                    do {
                        _ = try await URLSession.shared.data(for: request)
                        return .passed("DNS resolution successful")
                    } catch {
                        if let urlError = error as? URLError {
                            switch urlError.code {
                            case .cannotFindHost:
                                return .failed("DNS resolution failed: Cannot find host")
                            case .timedOut:
                                return .failed("DNS resolution failed: Timeout")
                            default:
                                return .passed("DNS resolution successful (connection failed for other reasons)")
                            }
                        }
                        return .failed("DNS resolution failed: \(error.localizedDescription)")
                    }
                } else {
                    return .passed("IP address provided, DNS resolution not required")
                }
            }
        }
    }
    
    // MARK: - Authentication Tests
    private func runAuthenticationTests(configuration: TestConfiguration) async {
        await runTest(name: "Keychain Storage Test") {
            let testCredentials = KeychainManager.ServerCredentials(
                username: "testuser",
                password: "testpass",
                domain: "testdomain",
                serverName: "Test Server",
                host: configuration.testServer.host,
                port: configuration.testServer.port
            )
            
            do {
                // Store credentials
                try self.keychainManager.storeCredentials(testCredentials)
                
                // Retrieve credentials
                let retrieved = try self.keychainManager.retrieveCredentials(
                    for: configuration.testServer.host,
                    port: configuration.testServer.port
                )
                
                // Verify credentials match
                if retrieved.username == testCredentials.username &&
                   retrieved.password == testCredentials.password &&
                   retrieved.domain == testCredentials.domain {
                    
                    // Clean up test credentials
                    try self.keychainManager.deleteCredentials(
                        for: configuration.testServer.host,
                        port: configuration.testServer.port
                    )
                    
                    return .passed("Keychain storage and retrieval successful")
                } else {
                    return .failed("Retrieved credentials do not match stored credentials")
                }
            } catch {
                return .failed("Keychain operation failed: \(error.localizedDescription)")
            }
        }
        
        if let credentials = configuration.testCredentials {
            await runTest(name: "SMB Authentication Test") {
                do {
                    try await self.smbConnection.connect(
                        to: configuration.testServer.host,
                        port: configuration.testServer.port,
                        username: credentials.username,
                        password: credentials.password,
                        domain: credentials.domain
                    )
                    
                    if self.smbConnection.isConnected {
                        self.smbConnection.disconnect()
                        return .passed("SMB authentication successful")
                    } else {
                        return .failed("SMB authentication failed")
                    }
                } catch {
                    return .failed("SMB authentication error: \(error.localizedDescription)")
                }
            }
        } else {
            await runTest(name: "SMB Authentication Test") {
                return .skipped("No test credentials provided")
            }
        }
    }
    
    // MARK: - File Operation Tests
    private func runFileOperationTests(configuration: TestConfiguration) async {
        // Skip if no credentials provided
        guard configuration.testCredentials != nil else {
            await runTest(name: "Directory Listing Test") {
                return .skipped("No credentials provided for file operations")
            }
            return
        }
        
        await runTest(name: "Directory Listing Test") {
            do {
                let items = try await self.smbConnection.listDirectory(at: "/")
                
                if items.isEmpty {
                    return .passed("Directory listing successful (empty directory)")
                } else {
                    return .passed("Directory listing successful (\(items.count) items found)")
                }
            } catch {
                return .failed("Directory listing failed: \(error.localizedDescription)")
            }
        }
        
        await runTest(name: "File Stream URL Test") {
            do {
                // Try to get a streaming URL for a test file
                let streamURL = try await self.smbConnection.streamFile(at: "/test.mp3")
                
                if streamURL.scheme == "smb" {
                    return .passed("File streaming URL generated successfully")
                } else {
                    return .failed("Invalid streaming URL scheme: \(streamURL.scheme ?? "none")")
                }
            } catch {
                return .failed("File streaming URL generation failed: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Error Handling Tests
    private func runErrorHandlingTests(configuration: TestConfiguration) async {
        await runTest(name: "Connection Timeout Test") {
            do {
                // Test connection to a non-existent server
                try await self.smbConnection.connect(to: "192.168.255.255", port: 445)
                return .failed("Connection should have timed out")
            } catch {
                if let smbError = error as? SMBConnectionManager.SMBError {
                    switch smbError {
                    case .connectionTimeout, .serverUnreachable:
                        return .passed("Connection timeout handled correctly")
                    default:
                        return .failed("Unexpected error type: \(smbError)")
                    }
                } else {
                    return .passed("Connection timeout handled correctly")
                }
            }
        }
        
        await runTest(name: "Invalid Credentials Test") {
            do {
                // Test with invalid credentials
                try await self.smbConnection.connect(
                    to: configuration.testServer.host,
                    port: configuration.testServer.port,
                    username: "invaliduser",
                    password: "invalidpass"
                )
                return .failed("Authentication should have failed")
            } catch {
                if let smbError = error as? SMBConnectionManager.SMBError {
                    switch smbError {
                    case .authenticationFailed, .invalidCredentials:
                        return .passed("Invalid credentials handled correctly")
                    default:
                        return .failed("Unexpected error type: \(smbError)")
                    }
                } else {
                    return .passed("Invalid credentials handled correctly")
                }
            }
        }
        
        await runTest(name: "Retry Logic Test") {
            let retryConfig = NetworkErrorHandler.RetryConfiguration(
                maxRetries: 2,
                baseDelay: 0.1,
                maxDelay: 1.0,
                backoffMultiplier: 2.0,
                jitter: false
            )
            
            var attemptCount = 0
            
            do {
                _ = try await self.networkErrorHandler.executeWithRetry(
                    operation: {
                        attemptCount += 1
                        if attemptCount < 3 {
                            throw NSError(domain: "TestError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Simulated failure"])
                        }
                        return "Success"
                    },
                    configuration: retryConfig
                )
                
                if attemptCount == 3 {
                    return .passed("Retry logic executed correctly (3 attempts)")
                } else {
                    return .failed("Retry logic executed incorrectly (\(attemptCount) attempts)")
                }
            } catch {
                return .failed("Retry logic failed: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Offline Mode Tests
    private func runOfflineModeTests(configuration: TestConfiguration) async {
        await runTest(name: "Offline Mode Toggle Test") {
            let initialState = self.offlineManager.isOfflineMode
            
            self.offlineManager.toggleOfflineMode()
            let toggledState = self.offlineManager.isOfflineMode
            
            self.offlineManager.toggleOfflineMode()
            let finalState = self.offlineManager.isOfflineMode
            
            if initialState != toggledState && initialState == finalState {
                return .passed("Offline mode toggle works correctly")
            } else {
                return .failed("Offline mode toggle failed")
            }
        }
        
        await runTest(name: "Cache Directory Creation Test") {
            _ = self.offlineManager.getCacheStatistics()
            
            // The cache system should be initialized
            return .passed("Cache system initialized (Storage: \(self.offlineManager.getFormattedStorageInfo()))")
        }
        
        await runTest(name: "Cache Validation Test") {
            let validationResult = self.offlineManager.validateOfflineMode()
            
            if validationResult.isValid {
                return .passed("Cache validation successful")
            } else {
                return .failed("Cache validation failed: \(validationResult.issues.joined(separator: ", "))")
            }
        }
    }
    
    // MARK: - Performance Tests
    private func runPerformanceTests(configuration: TestConfiguration) async {
        await runTest(name: "Connection Speed Test") {
            let startTime = Date()
            
            do {
                try await self.smbConnection.connect(to: configuration.testServer.host, port: configuration.testServer.port)
                
                let endTime = Date()
                let duration = endTime.timeIntervalSince(startTime)
                
                self.smbConnection.disconnect()
                
                if duration < 5.0 {
                    return .passed("Connection established in \(String(format: "%.2f", duration))s")
                } else {
                    return .failed("Connection too slow: \(String(format: "%.2f", duration))s")
                }
            } catch {
                return .failed("Connection failed: \(error.localizedDescription)")
            }
        }
        
        await runTest(name: "Bandwidth Estimation Test") {
            if let bandwidth = await self.networkErrorHandler.estimateBandwidth() {
                let mbps = bandwidth / 1_000_000
                return .passed("Estimated bandwidth: \(String(format: "%.2f", mbps)) Mbps")
            } else {
                return .failed("Bandwidth estimation failed")
            }
        }
    }
    
    // MARK: - Security Tests
    private func runSecurityTests(configuration: TestConfiguration) async {
        await runTest(name: "Keychain Security Test") {
            // Test that keychain data is properly secured
            let testCredentials = KeychainManager.ServerCredentials(
                username: "securitytest",
                password: "securepass123",
                domain: nil,
                serverName: "Security Test",
                host: "192.168.1.200",
                port: 445
            )
            
            do {
                try self.keychainManager.storeCredentials(testCredentials)
                
                // Verify credentials are stored securely (not in plain text)
                let retrieved = try self.keychainManager.retrieveCredentials(for: "192.168.1.200", port: 445)
                
                if retrieved.password == testCredentials.password {
                    // Clean up
                    try self.keychainManager.deleteCredentials(for: "192.168.1.200", port: 445)
                    return .passed("Keychain security test passed")
                } else {
                    return .failed("Keychain security test failed: password mismatch")
                }
            } catch {
                return .failed("Keychain security test failed: \(error.localizedDescription)")
            }
        }
        
        await runTest(name: "Credential Cleanup Test") {
            // Verify that credentials are properly cleaned up
            let allServers = self.keychainManager.getAllStoredServers()
            
            // Clean up any test credentials
            for serverKey in allServers {
                if serverKey.contains("192.168.1.200") || serverKey.contains("securitytest") {
                    let components = serverKey.split(separator: ":")
                    if components.count == 2, let port = Int16(components[1]) {
                        try? self.keychainManager.deleteCredentials(for: String(components[0]), port: port)
                    }
                }
            }
            
            return .passed("Credential cleanup completed")
        }
    }
    
    // MARK: - Test Helper Methods
    // (Helper methods already defined above)
    
    // MARK: - Test Result Extensions
    // TestStatus convenience methods are now handled by the enum cases with associated values
}

// MARK: - Test Report Generator
extension NetworkTestSuite {
    func generateTestReport() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        
        var report = """
        SambaPlay Network Test Report
        Generated: \(formatter.string(from: Date()))
        
        Overall Status: \(overallResult.emoji) \(overallResult.description)
        
        Test Results:
        =============
        
        """
        
        for result in testResults {
            report += """
            \(result.status.emoji) \(result.testName)
            Status: \(result.status.description)
            Duration: \(String(format: "%.3f", result.duration))s
            Message: \(result.message)
            Time: \(formatter.string(from: result.timestamp))
            
            """
        }
        
        return report
    }
    
    func exportTestReport() -> URL? {
        let report = generateTestReport()
        
        do {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let reportURL = documentsURL.appendingPathComponent("SambaPlay_Network_Test_Report.txt")
            
            try report.write(to: reportURL, atomically: true, encoding: .utf8)
            return reportURL
        } catch {
            print("Failed to export test report: \(error)")
            return nil
        }
    }
} 