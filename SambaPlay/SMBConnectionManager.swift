//
//  SMBConnectionManager.swift
//  SambaPlay
//
//  Created by raama srivatsan on 7/6/25.
//

import Foundation
import Network

// MARK: - SMB Connection Manager
class SMBConnectionManager: ObservableObject {
    static let shared = SMBConnectionManager()
    
    @Published var isConnected = false
    @Published var currentServer: String?
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var lastError: SMBError?
    
    private var currentSession: URLSession?
    private var networkMonitor: NWPathMonitor?
    private var monitorQueue = DispatchQueue(label: "NetworkMonitor")
    
    private init() {
        setupNetworkMonitoring()
    }
    
    // MARK: - Connection Status
    enum ConnectionStatus: Equatable {
        case disconnected
        case connecting
        case connected
        case authenticating
        case failed(SMBError)
        case offline
        
        var description: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting..."
            case .connected: return "Connected"
            case .authenticating: return "Authenticating..."
            case .failed(let error): return "Failed: \(error.localizedDescription)"
            case .offline: return "Offline"
            }
        }
        
        static func == (lhs: ConnectionStatus, rhs: ConnectionStatus) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected),
                 (.connecting, .connecting),
                 (.connected, .connected),
                 (.authenticating, .authenticating),
                 (.offline, .offline):
                return true
            case (.failed(let lhsError), .failed(let rhsError)):
                return lhsError.localizedDescription == rhsError.localizedDescription
            default:
                return false
            }
        }
    }
    
    // MARK: - SMB Error Types
    enum SMBError: Error, LocalizedError {
        case invalidCredentials
        case connectionTimeout
        case networkUnavailable
        case serverUnreachable
        case authenticationFailed
        case permissionDenied
        case fileNotFound
        case invalidPath
        case unknown(Error)
        
        var errorDescription: String? {
            switch self {
            case .invalidCredentials:
                return "Invalid username or password"
            case .connectionTimeout:
                return "Connection timed out"
            case .networkUnavailable:
                return "Network unavailable"
            case .serverUnreachable:
                return "Server unreachable"
            case .authenticationFailed:
                return "Authentication failed"
            case .permissionDenied:
                return "Permission denied"
            case .fileNotFound:
                return "File not found"
            case .invalidPath:
                return "Invalid path"
            case .unknown(let error):
                return "Unknown error: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - Network Monitoring
    private func setupNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                if path.status == .satisfied {
                    if self?.connectionStatus == .offline {
                        self?.connectionStatus = .disconnected
                    }
                } else {
                    self?.connectionStatus = .offline
                    self?.isConnected = false
                }
            }
        }
        networkMonitor?.start(queue: monitorQueue)
    }
    
    // MARK: - Connection Management
    func connect(to host: String, port: Int16 = 445) async throws {
        guard connectionStatus != .offline else {
            throw SMBError.networkUnavailable
        }
        
        DispatchQueue.main.async {
            self.connectionStatus = .connecting
            self.currentServer = host
        }
        
        do {
            // Try to get stored credentials
            let credentials = try KeychainManager.shared.retrieveCredentials(for: host, port: port)
            try await authenticate(with: credentials)
        } catch KeychainManager.KeychainError.itemNotFound {
            // No stored credentials, need to prompt user
            DispatchQueue.main.async {
                self.connectionStatus = .failed(.invalidCredentials)
            }
            throw SMBError.invalidCredentials
        } catch {
            DispatchQueue.main.async {
                self.connectionStatus = .failed(.unknown(error))
            }
            throw SMBError.unknown(error)
        }
    }
    
    func connect(to host: String, port: Int16 = 445, username: String, password: String, domain: String? = nil) async throws {
        guard connectionStatus != .offline else {
            throw SMBError.networkUnavailable
        }
        
        DispatchQueue.main.async {
            self.connectionStatus = .connecting
            self.currentServer = host
        }
        
        let credentials = KeychainManager.ServerCredentials(
            username: username,
            password: password,
            domain: domain,
            serverName: host,
            host: host,
            port: port
        )
        
        do {
            try await authenticate(with: credentials)
            
            // Store credentials on successful connection
            try KeychainManager.shared.storeCredentials(credentials)
        } catch {
            DispatchQueue.main.async {
                self.connectionStatus = .failed(.unknown(error))
            }
            throw error
        }
    }
    
    private func authenticate(with credentials: KeychainManager.ServerCredentials) async throws {
        DispatchQueue.main.async {
            self.connectionStatus = .authenticating
        }
        
        // Create authenticated URL session
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        
        // Create authentication challenge handler
        let session = URLSession(configuration: config, delegate: SMBURLSessionDelegate(credentials: credentials), delegateQueue: nil)
        
        // Test connection with a simple request
        let testURL = URL(string: "smb://\(credentials.host):\(credentials.port)/")!
        
        do {
            let (_, response) = try await session.data(from: testURL)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 401 {
                    throw SMBError.authenticationFailed
                } else if httpResponse.statusCode >= 400 {
                    throw SMBError.serverUnreachable
                }
            }
            
            // Connection successful
            DispatchQueue.main.async {
                self.currentSession = session
                self.isConnected = true
                self.connectionStatus = .connected
                self.lastError = nil
            }
            
        } catch {
            DispatchQueue.main.async {
                self.connectionStatus = .failed(.unknown(error))
            }
            throw SMBError.unknown(error)
        }
    }
    
    func disconnect() {
        currentSession?.invalidateAndCancel()
        currentSession = nil
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionStatus = .disconnected
            self.currentServer = nil
            self.lastError = nil
        }
    }
    
    // MARK: - File Operations
    func listDirectory(at path: String) async throws -> [SMBFileItem] {
        guard isConnected, let session = currentSession, let server = currentServer else {
            throw SMBError.serverUnreachable
        }
        
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let url = URL(string: "smb://\(server)/\(encodedPath)")!
        
        do {
            let (data, response) = try await session.data(from: url)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 404 {
                    throw SMBError.fileNotFound
                } else if httpResponse.statusCode == 403 {
                    throw SMBError.permissionDenied
                } else if httpResponse.statusCode >= 400 {
                    throw SMBError.serverUnreachable
                }
            }
            
            // Parse directory listing (simplified - would need proper SMB protocol parsing)
            return try parseDirectoryListing(data)
            
        } catch {
            throw SMBError.unknown(error)
        }
    }
    
    func downloadFile(at path: String, to localURL: URL, progress: @escaping (Double) -> Void) async throws {
        guard isConnected, let session = currentSession, let server = currentServer else {
            throw SMBError.serverUnreachable
        }
        
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let url = URL(string: "smb://\(server)/\(encodedPath)")!
        
        do {
            let (data, response) = try await session.data(from: url)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 404 {
                    throw SMBError.fileNotFound
                } else if httpResponse.statusCode == 403 {
                    throw SMBError.permissionDenied
                } else if httpResponse.statusCode >= 400 {
                    throw SMBError.serverUnreachable
                }
            }
            
            // Write data to local file
            try data.write(to: localURL)
            progress(1.0)
            
        } catch {
            throw SMBError.unknown(error)
        }
    }
    
    func streamFile(at path: String) async throws -> URL {
        guard isConnected, let server = currentServer else {
            throw SMBError.serverUnreachable
        }
        
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let url = URL(string: "smb://\(server)/\(encodedPath)")!
        
        // For streaming, we return the SMB URL directly
        // The audio player should handle SMB URLs with authentication
        return url
    }
    
    // MARK: - Helper Methods
    private func parseDirectoryListing(_ data: Data) throws -> [SMBFileItem] {
        // This is a simplified parser - real SMB would need proper protocol parsing
        // For now, return mock data structure
        
        var items: [SMBFileItem] = []
        
        // Parse HTML directory listing (many SMB servers provide HTML listings)
        if let html = String(data: data, encoding: .utf8) {
            let lines = html.components(separatedBy: .newlines)
            
            for line in lines {
                if line.contains("href=") && !line.contains("..") {
                    if let name = extractFileName(from: line) {
                        let isDirectory = line.contains("DIR") || line.contains("/")
                        let item = SMBFileItem(
                            name: name,
                            path: name,
                            isDirectory: isDirectory,
                            size: extractFileSize(from: line),
                            modifiedDate: extractModifiedDate(from: line)
                        )
                        items.append(item)
                    }
                }
            }
        }
        
        return items
    }
    
    private func extractFileName(from line: String) -> String? {
        // Extract filename from HTML href attribute
        let pattern = #"href="([^"]+)""#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: line.utf16.count)
        
        if let match = regex?.firstMatch(in: line, options: [], range: range) {
            if let swiftRange = Range(match.range(at: 1), in: line) {
                return String(line[swiftRange])
            }
        }
        
        return nil
    }
    
    private func extractFileSize(from line: String) -> Int64? {
        // Extract file size from HTML listing
        let pattern = #"(\d+)\s+bytes"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: line.utf16.count)
        
        if let match = regex?.firstMatch(in: line, options: [], range: range) {
            if let swiftRange = Range(match.range(at: 1), in: line) {
                return Int64(String(line[swiftRange]))
            }
        }
        
        return nil
    }
    
    private func extractModifiedDate(from line: String) -> Date? {
        // Extract modification date from HTML listing
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        
        let pattern = #"(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: line.utf16.count)
        
        if let match = regex?.firstMatch(in: line, options: [], range: range) {
            if let swiftRange = Range(match.range(at: 1), in: line) {
                return formatter.date(from: String(line[swiftRange]))
            }
        }
        
        return nil
    }
}

// MARK: - SMB File Item
struct SMBFileItem: Identifiable, Codable {
    let id: UUID
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modifiedDate: Date?
    
    init(name: String, path: String, isDirectory: Bool, size: Int64?, modifiedDate: Date?) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedDate = modifiedDate
    }
    
    var isAudioFile: Bool {
        let audioExtensions = ["mp3", "m4a", "wav", "aac", "flac", "ogg", "wma", "aiff", "opus"]
        let fileExtension = URL(fileURLWithPath: name).pathExtension.lowercased()
        return audioExtensions.contains(fileExtension)
    }
    
    var formattedSize: String {
        guard let size = size else { return "Unknown" }
        
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

// MARK: - SMB URL Session Delegate
class SMBURLSessionDelegate: NSObject, URLSessionDelegate {
    private let credentials: KeychainManager.ServerCredentials
    
    init(credentials: KeychainManager.ServerCredentials) {
        self.credentials = credentials
    }
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        
        let credential = URLCredential(
            user: credentials.username,
            password: credentials.password,
            persistence: .forSession
        )
        
        completionHandler(.useCredential, credential)
    }
}

// MARK: - Connection Manager Extensions
extension SMBConnectionManager {
    
    // MARK: - Retry Logic
    func connectWithRetry(to host: String, port: Int16 = 445, maxRetries: Int = 3) async throws {
        var lastError: Error?
        
        for attempt in 1...maxRetries {
            do {
                try await connect(to: host, port: port)
                return // Success
            } catch {
                lastError = error
                
                if attempt < maxRetries {
                    // Wait before retry (exponential backoff)
                    let delay = Double(attempt * attempt) // 1s, 4s, 9s...
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        // All retries failed
        throw lastError ?? SMBError.serverUnreachable
    }
    
    // MARK: - Connection Health Check
    func checkConnection() async -> Bool {
        guard isConnected, let server = currentServer else {
            return false
        }
        
        do {
            _ = try await listDirectory(at: "")
            return true
        } catch {
            DispatchQueue.main.async {
                self.isConnected = false
                self.connectionStatus = .failed(.serverUnreachable)
            }
            return false
        }
    }
    
    // MARK: - Auto-reconnect
    func autoReconnect() async {
        guard !isConnected, let server = currentServer else { return }
        
        do {
            try await connectWithRetry(to: server)
        } catch {
            // Auto-reconnect failed, user intervention needed
            DispatchQueue.main.async {
                self.lastError = .serverUnreachable
            }
        }
    }
} 