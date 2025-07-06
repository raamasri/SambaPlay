//
//  NetworkErrorHandler.swift
//  SambaPlay
//
//  Created by raama srivatsan on 7/6/25.
//

import Foundation
import Network

// MARK: - Network Error Handler
class NetworkErrorHandler: ObservableObject {
    static let shared = NetworkErrorHandler()
    
    @Published var isOnline = true
    @Published var connectionQuality: ConnectionQuality = .good
    @Published var lastNetworkError: NetworkError?
    @Published var retryCount = 0
    
    private var networkMonitor: NWPathMonitor?
    private var monitorQueue = DispatchQueue(label: "NetworkErrorHandler")
    
    private init() {
        setupNetworkMonitoring()
    }
    
    // MARK: - Connection Quality
    enum ConnectionQuality {
        case excellent
        case good
        case poor
        case offline
        
        var description: String {
            switch self {
            case .excellent: return "Excellent"
            case .good: return "Good"
            case .poor: return "Poor"
            case .offline: return "Offline"
            }
        }
        
        var maxRetries: Int {
            switch self {
            case .excellent: return 2
            case .good: return 3
            case .poor: return 5
            case .offline: return 0
            }
        }
        
        var retryDelay: TimeInterval {
            switch self {
            case .excellent: return 1.0
            case .good: return 2.0
            case .poor: return 5.0
            case .offline: return 0.0
            }
        }
    }
    
    // MARK: - Network Error Types
    enum NetworkError: Error, LocalizedError {
        case noConnection
        case timeout
        case serverError(Int)
        case authenticationFailed
        case badRequest
        case notFound
        case forbidden
        case tooManyRequests
        case serverUnavailable
        case unknown(Error)
        
        var errorDescription: String? {
            switch self {
            case .noConnection:
                return "No internet connection"
            case .timeout:
                return "Request timed out"
            case .serverError(let code):
                return "Server error (\(code))"
            case .authenticationFailed:
                return "Authentication failed"
            case .badRequest:
                return "Bad request"
            case .notFound:
                return "Resource not found"
            case .forbidden:
                return "Access forbidden"
            case .tooManyRequests:
                return "Too many requests"
            case .serverUnavailable:
                return "Server unavailable"
            case .unknown(let error):
                return error.localizedDescription
            }
        }
        
        var isRetryable: Bool {
            switch self {
            case .noConnection, .timeout, .serverError, .tooManyRequests, .serverUnavailable:
                return true
            case .authenticationFailed, .badRequest, .notFound, .forbidden, .unknown:
                return false
            }
        }
        
        var httpStatusCode: Int? {
            switch self {
            case .authenticationFailed: return 401
            case .forbidden: return 403
            case .notFound: return 404
            case .tooManyRequests: return 429
            case .serverError(let code): return code
            case .serverUnavailable: return 503
            default: return nil
            }
        }
    }
    
    // MARK: - Retry Configuration
    struct RetryConfiguration {
        let maxRetries: Int
        let baseDelay: TimeInterval
        let maxDelay: TimeInterval
        let backoffMultiplier: Double
        let jitter: Bool
        
        static let `default` = RetryConfiguration(
            maxRetries: 3,
            baseDelay: 1.0,
            maxDelay: 30.0,
            backoffMultiplier: 2.0,
            jitter: true
        )
        
        static let aggressive = RetryConfiguration(
            maxRetries: 5,
            baseDelay: 0.5,
            maxDelay: 60.0,
            backoffMultiplier: 1.5,
            jitter: true
        )
        
        static let conservative = RetryConfiguration(
            maxRetries: 2,
            baseDelay: 2.0,
            maxDelay: 15.0,
            backoffMultiplier: 3.0,
            jitter: false
        )
    }
    
    // MARK: - Network Monitoring
    private func setupNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.updateConnectionStatus(path)
            }
        }
        networkMonitor?.start(queue: monitorQueue)
    }
    
    private func updateConnectionStatus(_ path: NWPath) {
        isOnline = path.status == .satisfied
        
        if !isOnline {
            connectionQuality = .offline
            return
        }
        
        // Determine connection quality based on available interfaces
        if path.usesInterfaceType(.wifi) {
            connectionQuality = .excellent
        } else if path.usesInterfaceType(.cellular) {
            connectionQuality = .good
        } else if path.usesInterfaceType(.wiredEthernet) {
            connectionQuality = .excellent
        } else {
            connectionQuality = .poor
        }
    }
    
    // MARK: - Error Handling
    func handleError(_ error: Error) -> NetworkError {
        let networkError: NetworkError
        
        if let urlError = error as? URLError {
            networkError = mapURLError(urlError)
        } else if let httpError = error as? HTTPError {
            networkError = mapHTTPError(httpError)
        } else {
            networkError = .unknown(error)
        }
        
        DispatchQueue.main.async {
            self.lastNetworkError = networkError
        }
        
        return networkError
    }
    
    private func mapURLError(_ error: URLError) -> NetworkError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return .noConnection
        case .timedOut:
            return .timeout
        case .userAuthenticationRequired:
            return .authenticationFailed
        case .badURL, .badServerResponse:
            return .badRequest
        case .fileDoesNotExist:
            return .notFound
        case .noPermissionsToReadFile:
            return .forbidden
        case .cannotConnectToHost, .cannotFindHost:
            return .serverUnavailable
        default:
            return .unknown(error)
        }
    }
    
    private func mapHTTPError(_ error: HTTPError) -> NetworkError {
        switch error.statusCode {
        case 400:
            return .badRequest
        case 401:
            return .authenticationFailed
        case 403:
            return .forbidden
        case 404:
            return .notFound
        case 429:
            return .tooManyRequests
        case 500...599:
            return .serverError(error.statusCode)
        default:
            return .unknown(error)
        }
    }
    
    // MARK: - Retry Logic
    func executeWithRetry<T>(
        operation: @escaping () async throws -> T,
        configuration: RetryConfiguration = .default
    ) async throws -> T {
        var lastError: NetworkError?
        
        for attempt in 0...configuration.maxRetries {
            do {
                let result = try await operation()
                
                // Reset retry count on success
                DispatchQueue.main.async {
                    self.retryCount = 0
                }
                
                return result
            } catch {
                let networkError = handleError(error)
                lastError = networkError
                
                DispatchQueue.main.async {
                    self.retryCount = attempt + 1
                }
                
                // Don't retry on last attempt or non-retryable errors
                if attempt == configuration.maxRetries || !networkError.isRetryable {
                    break
                }
                
                // Wait before retry
                let delay = calculateRetryDelay(
                    attempt: attempt,
                    configuration: configuration
                )
                
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        
        // All retries failed
        throw lastError ?? NetworkError.unknown(NSError(domain: "RetryFailed", code: -1))
    }
    
    private func calculateRetryDelay(attempt: Int, configuration: RetryConfiguration) -> TimeInterval {
        var delay = configuration.baseDelay * pow(configuration.backoffMultiplier, Double(attempt))
        delay = min(delay, configuration.maxDelay)
        
        if configuration.jitter {
            // Add random jitter (±25%)
            let jitterRange = delay * 0.25
            let jitter = Double.random(in: -jitterRange...jitterRange)
            delay += jitter
        }
        
        return max(delay, 0.1) // Minimum 100ms delay
    }
    
    // MARK: - Timeout Handling
    func executeWithTimeout<T>(
        operation: @escaping () async throws -> T,
        timeout: TimeInterval
    ) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            // Add the main operation
            group.addTask {
                try await operation()
            }
            
            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NetworkError.timeout
            }
            
            // Return the first completed task
            guard let result = try await group.next() else {
                throw NetworkError.timeout
            }
            
            // Cancel remaining tasks
            group.cancelAll()
            
            return result
        }
    }
    
    // MARK: - Connection Testing
    func testConnection(to host: String, port: Int = 80, timeout: TimeInterval = 10) async -> Bool {
        do {
            let result = try await executeWithTimeout(
                operation: {
                    try await self.performConnectionTest(to: host, port: port)
                },
                timeout: timeout
            )
            return result
        } catch {
            return false
        }
    }
    
    private func performConnectionTest(to host: String, port: Int) async throws -> Bool {
        let url = URL(string: "http://\(host):\(port)")!
        let request = URLRequest(url: url, timeoutInterval: 5.0)
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode < 500
            }
            
            return true
        } catch {
            throw handleError(error)
        }
    }
    
    // MARK: - Bandwidth Estimation
    func estimateBandwidth() async -> Double? {
        guard isOnline else { return nil }
        
        let testURL = URL(string: "https://httpbin.org/bytes/1024")! // 1KB test
        let startTime = CFAbsoluteTimeGetCurrent()
        
        do {
            let (data, _) = try await URLSession.shared.data(from: testURL)
            let endTime = CFAbsoluteTimeGetCurrent()
            let duration = endTime - startTime
            
            let bytesPerSecond = Double(data.count) / duration
            return bytesPerSecond * 8 // Convert to bits per second
        } catch {
            return nil
        }
    }
    
    // MARK: - Recovery Strategies
    func suggestRecoveryAction(for error: NetworkError) -> RecoveryAction {
        switch error {
        case .noConnection:
            return .checkConnection
        case .timeout:
            return .retry
        case .authenticationFailed:
            return .reAuthenticate
        case .serverError, .serverUnavailable:
            return .waitAndRetry
        case .tooManyRequests:
            return .backOff
        case .notFound:
            return .checkPath
        case .forbidden:
            return .checkPermissions
        case .badRequest:
            return .checkRequest
        case .unknown:
            return .contactSupport
        }
    }
    
    enum RecoveryAction {
        case checkConnection
        case retry
        case reAuthenticate
        case waitAndRetry
        case backOff
        case checkPath
        case checkPermissions
        case checkRequest
        case contactSupport
        
        var description: String {
            switch self {
            case .checkConnection:
                return "Check your internet connection"
            case .retry:
                return "Try again"
            case .reAuthenticate:
                return "Please sign in again"
            case .waitAndRetry:
                return "Server is busy, please wait and try again"
            case .backOff:
                return "Too many requests, please wait before trying again"
            case .checkPath:
                return "Check the file path"
            case .checkPermissions:
                return "Check access permissions"
            case .checkRequest:
                return "Check your request"
            case .contactSupport:
                return "Contact support if the problem persists"
            }
        }
    }
}

// MARK: - HTTP Error
struct HTTPError: Error {
    let statusCode: Int
    let data: Data?
    
    var localizedDescription: String {
        return "HTTP Error \(statusCode)"
    }
}

// MARK: - Network Error Handler Extensions
extension NetworkErrorHandler {
    
    // MARK: - Convenience Methods
    func isRetryableError(_ error: Error) -> Bool {
        let networkError = handleError(error)
        return networkError.isRetryable
    }
    
    func shouldRetry(after error: Error, attempt: Int, maxAttempts: Int) -> Bool {
        guard attempt < maxAttempts else { return false }
        
        let networkError = handleError(error)
        return networkError.isRetryable && isOnline
    }
    
    func getRetryDelay(for attempt: Int) -> TimeInterval {
        return calculateRetryDelay(attempt: attempt, configuration: .default)
    }
    
    // MARK: - Error Reporting
    func reportError(_ error: NetworkError, context: String) {
        // Log error for debugging
        print("Network Error in \(context): \(error.localizedDescription)")
        
        // Could integrate with crash reporting services here
        // Crashlytics.recordError(error)
    }
    
    // MARK: - Offline Mode Support
    func enterOfflineMode() {
        DispatchQueue.main.async {
            self.isOnline = false
            self.connectionQuality = .offline
        }
    }
    
    func exitOfflineMode() {
        // Re-check network status
        if let monitor = networkMonitor {
            monitor.cancel()
            setupNetworkMonitoring()
        }
    }
} 