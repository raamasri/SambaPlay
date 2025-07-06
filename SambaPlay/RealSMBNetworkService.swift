//
//  RealSMBNetworkService.swift
//  SambaPlay
//
//  Created by raama srivatsan on 7/6/25.
//

import Foundation
import Combine
import AVFoundation

// MARK: - Real SMB Network Service
class RealSMBNetworkService: ObservableObject {
    @Published var connectionState: NetworkConnectionState = .disconnected
    @Published var currentFiles: [MediaFile] = []
    @Published var currentPath: String = ""
    @Published var savedServers: [SambaServer] = []
    @Published var savedFolders: [LocalFolder] = []
    @Published var currentServer: SambaServer?
    @Published var currentFolder: LocalFolder?
    @Published var pathHistory: [String] = []
    @Published var isLocalMode: Bool = false
    @Published var recentSources: [RecentSource] = []
    @Published var isOfflineMode: Bool = false
    
    // Network components
    private let smbConnection = SMBConnectionManager.shared
    private let networkErrorHandler = NetworkErrorHandler.shared
    private let offlineManager = OfflineModeManager.shared
    private let keychainManager = KeychainManager.shared
    
    // Playback position memory
    private var savedPositions: [String: PlaybackPosition] = [:]
    
    // Combine cancellables
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupBindings()
        loadSavedData()
    }
    
    // MARK: - Setup and Bindings
    private func setupBindings() {
        // Bind SMB connection state to our connection state
        smbConnection.$connectionStatus
            .map { status in
                switch status {
                case .disconnected:
                    return .disconnected
                case .connecting, .authenticating:
                    return .connecting
                case .connected:
                    return .connected
                case .failed(let error):
                    return .error(error.localizedDescription)
                case .offline:
                    return .error("Network offline")
                }
            }
            .assign(to: \.connectionState, on: self)
            .store(in: &cancellables)
        
        // Bind offline mode
        offlineManager.$isOfflineMode
            .assign(to: \.isOfflineMode, on: self)
            .store(in: &cancellables)
        
        // Monitor network status
        networkErrorHandler.$isOnline
            .sink { [weak self] isOnline in
                if !isOnline && self?.connectionState == .connected {
                    self?.handleNetworkLoss()
                }
            }
            .store(in: &cancellables)
    }
    
    private func loadSavedData() {
        loadSavedServers()
        loadSavedFolders()
        loadRecentSources()
        loadSavedPositions()
    }
    
    // MARK: - Server Management
    private func loadSavedServers() {
        guard let data = UserDefaults.standard.data(forKey: "SavedSMBServers") else { return }
        
        do {
            savedServers = try PropertyListDecoder().decode([SambaServer].self, from: data)
        } catch {
            print("Failed to load saved servers: \(error)")
            savedServers = []
        }
    }
    
    private func saveSavedServers() {
        do {
            let data = try PropertyListEncoder().encode(savedServers)
            UserDefaults.standard.set(data, forKey: "SavedSMBServers")
        } catch {
            print("Failed to save servers: \(error)")
        }
    }
    
    func addServer(_ server: SambaServer) {
        savedServers.removeAll { $0.id == server.id }
        savedServers.append(server)
        saveSavedServers()
    }
    
    func removeServer(_ server: SambaServer) {
        savedServers.removeAll { $0.id == server.id }
        saveSavedServers()
        
        // Also remove stored credentials
        try? keychainManager.deleteCredentials(for: server.host, port: server.port)
    }
    
    // MARK: - Folder Management
    private func loadSavedFolders() {
        guard let data = UserDefaults.standard.data(forKey: "SavedFolders") else { return }
        
        do {
            savedFolders = try PropertyListDecoder().decode([LocalFolder].self, from: data)
        } catch {
            print("Failed to load saved folders: \(error)")
            savedFolders = []
        }
    }
    
    private func saveFolders() {
        do {
            let data = try PropertyListEncoder().encode(savedFolders)
            UserDefaults.standard.set(data, forKey: "SavedFolders")
        } catch {
            print("Failed to save folders: \(error)")
        }
    }
    
    func addFolder(_ folder: LocalFolder) {
        savedFolders.removeAll { $0.bookmarkData == folder.bookmarkData }
        savedFolders.append(folder)
        saveFolders()
    }
    
    func removeFolder(_ folder: LocalFolder) {
        savedFolders.removeAll { $0.id == folder.id }
        saveFolders()
    }
    
    // MARK: - Recent Sources Management
    private func loadRecentSources() {
        guard let data = UserDefaults.standard.data(forKey: "RecentSources") else { return }
        
        do {
            let loadedSources = try PropertyListDecoder().decode([RecentSource].self, from: data)
            recentSources = Array(loadedSources.prefix(5))
        } catch {
            print("Failed to load recent sources: \(error)")
            recentSources = []
        }
    }
    
    private func saveRecentSources() {
        do {
            let data = try PropertyListEncoder().encode(recentSources)
            UserDefaults.standard.set(data, forKey: "RecentSources")
        } catch {
            print("Failed to save recent sources: \(error)")
        }
    }
    
    private func addRecentSource(_ source: RecentSource) {
        recentSources.removeAll { existing in
            if source.type == .server, let serverID = source.serverID {
                return existing.serverID == serverID || existing.name == source.name
            } else if source.type == .folder, let folderID = source.folderID {
                return existing.folderID == folderID || existing.name == source.name
            }
            return false
        }
        
        recentSources.insert(source, at: 0)
        recentSources = Array(recentSources.prefix(5))
        saveRecentSources()
    }
    
    // MARK: - Playback Position Management
    private func loadSavedPositions() {
        guard let data = UserDefaults.standard.data(forKey: "SavedPlaybackPositions") else { return }
        
        do {
            let positions = try PropertyListDecoder().decode([PlaybackPosition].self, from: data)
            savedPositions = Dictionary(uniqueKeysWithValues: positions.map { ($0.filePath, $0) })
            
            // Clean up old positions (older than 30 days)
            let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
            savedPositions = savedPositions.filter { $0.value.lastPlayed > thirtyDaysAgo }
        } catch {
            print("Failed to load saved positions: \(error)")
            savedPositions = [:]
        }
    }
    
    private func saveSavedPositions() {
        let positions = Array(savedPositions.values)
        do {
            let data = try PropertyListEncoder().encode(positions)
            UserDefaults.standard.set(data, forKey: "SavedPlaybackPositions")
        } catch {
            print("Failed to save positions: \(error)")
        }
    }
    
    func savePlaybackPosition(for file: MediaFile, position: TimeInterval, duration: TimeInterval) {
        let playbackPosition = PlaybackPosition(file: file, position: position, duration: duration)
        
        if playbackPosition.shouldRememberPosition {
            savedPositions[file.path] = playbackPosition
            saveSavedPositions()
        } else {
            savedPositions.removeValue(forKey: file.path)
            saveSavedPositions()
        }
    }
    
    func getSavedPosition(for file: MediaFile) -> PlaybackPosition? {
        return savedPositions[file.path]
    }
    
    func clearSavedPosition(for file: MediaFile) {
        savedPositions.removeValue(forKey: file.path)
        saveSavedPositions()
    }
    
    func clearAllSavedPositions() {
        savedPositions.removeAll()
        saveSavedPositions()
    }
    
    // MARK: - Connection Management
    func connect(to server: SambaServer) async {
        isLocalMode = false
        currentServer = server
        
        // Add to recent sources
        let recentSource = RecentSource(server: server)
        addRecentSource(recentSource)
        
        do {
            try await networkErrorHandler.executeWithRetry {
                try await self.smbConnection.connect(to: server.host, port: server.port)
            }
            
            // Navigate to root path on successful connection
            await navigateToPath("/")
            
        } catch {
            connectionState = .error(error.localizedDescription)
        }
    }
    
    func connect(to server: SambaServer, username: String, password: String, domain: String? = nil) async {
        isLocalMode = false
        currentServer = server
        
        // Add to recent sources
        let recentSource = RecentSource(server: server)
        addRecentSource(recentSource)
        
        do {
            try await networkErrorHandler.executeWithRetry {
                try await self.smbConnection.connect(
                    to: server.host,
                    port: server.port,
                    username: username,
                    password: password,
                    domain: domain
                )
            }
            
            // Navigate to root path on successful connection
            await navigateToPath("/")
            
        } catch {
            connectionState = .error(error.localizedDescription)
        }
    }
    
    func connectToLocalFiles() {
        isLocalMode = true
        currentServer = nil
        currentFolder = nil
        connectionState = .connected
        currentPath = "Local Files"
        pathHistory = []
        currentFiles = []
    }
    
    func connectToFolder(_ folder: LocalFolder) {
        isLocalMode = true
        currentServer = nil
        currentFolder = folder
        folder.updateLastAccessed()
        saveFolders()
        
        // Add to recent sources
        let recentSource = RecentSource(folder: folder)
        addRecentSource(recentSource)
        
        connectionState = .connecting
        
        // Try to access the bookmarked folder
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: folder.bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
            
            if isStale {
                connectionState = .error("Folder bookmark is outdated. Please re-select the folder.")
                return
            }
            
            loadFilesFromURL(url)
            connectionState = .connected
            currentPath = folder.name
            pathHistory = []
            
        } catch {
            connectionState = .error("Unable to access folder: \(error.localizedDescription)")
        }
    }
    
    func disconnect() {
        smbConnection.disconnect()
        currentServer = nil
        currentFolder = nil
        isLocalMode = false
        currentPath = ""
        pathHistory = []
        currentFiles = []
    }
    
    // MARK: - File Navigation
    func navigateToPath(_ path: String) async {
        if path != currentPath && !pathHistory.contains(currentPath) && !currentPath.isEmpty {
            pathHistory.append(currentPath)
        }
        
        currentPath = path
        
        if isLocalMode {
            // Local files handled separately
            return
        }
        
        // Check offline mode first
        if isOfflineMode || !networkErrorHandler.isOnline {
            await loadOfflineFiles(for: path)
            return
        }
        
        // Load files from SMB server
        await loadSMBFiles(for: path)
    }
    
    private func loadSMBFiles(for path: String) async {
        do {
            let smbItems = try await networkErrorHandler.executeWithRetry {
                try await self.smbConnection.listDirectory(at: path)
            }
            
            // Convert SMB items to MediaFile objects
            let mediaFiles = smbItems.map { item in
                MediaFile(
                    name: item.name,
                    path: item.path,
                    size: item.size ?? 0,
                    modificationDate: item.modifiedDate ?? Date(),
                    isDirectory: item.isDirectory,
                    fileExtension: item.isDirectory ? nil : URL(fileURLWithPath: item.name).pathExtension.lowercased()
                )
            }
            
            // Sort files: directories first, then by name
            let sortedFiles = mediaFiles.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            
            DispatchQueue.main.async {
                self.currentFiles = sortedFiles
            }
            
            // Cache directory listing for offline use
            offlineManager.cacheDirectoryListing(smbItems, for: path)
            
        } catch {
            // Handle error with fallback to offline mode
            await handleConnectionError(error, for: path)
        }
    }
    
    private func loadOfflineFiles(for path: String) async {
        if let cachedItems = offlineManager.getCachedDirectoryListing(for: path) {
            let mediaFiles = cachedItems.map { item in
                MediaFile(
                    name: item.name,
                    path: item.path,
                    size: item.size ?? 0,
                    modificationDate: item.modifiedDate ?? Date(),
                    isDirectory: item.isDirectory,
                    fileExtension: item.isDirectory ? nil : URL(fileURLWithPath: item.name).pathExtension.lowercased()
                )
            }
            
            DispatchQueue.main.async {
                self.currentFiles = mediaFiles
            }
        } else {
            DispatchQueue.main.async {
                self.currentFiles = []
                self.connectionState = .error("No offline data available for this directory")
            }
        }
    }
    
    private func loadFilesFromURL(_ url: URL) {
        do {
            let fileManager = FileManager.default
            let contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            
            var files: [MediaFile] = []
            
            for fileURL in contents {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isDirectory = resourceValues.isDirectory ?? false
                let fileSize = resourceValues.fileSize ?? 0
                let modificationDate = resourceValues.contentModificationDate ?? Date()
                
                let mediaFile = MediaFile(
                    name: fileURL.lastPathComponent,
                    path: fileURL.path,
                    size: Int64(fileSize),
                    modificationDate: modificationDate,
                    isDirectory: isDirectory,
                    fileExtension: isDirectory ? nil : fileURL.pathExtension.lowercased()
                )
                
                files.append(mediaFile)
            }
            
            // Sort files: directories first, then by name
            files.sort { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            
            currentFiles = files
            
        } catch {
            connectionState = .error("Unable to read folder contents: \(error.localizedDescription)")
            currentFiles = []
        }
    }
    
    func navigateBack() {
        guard !pathHistory.isEmpty else { return }
        
        let previousPath = pathHistory.removeLast()
        Task {
            await navigateToPath(previousPath)
        }
    }
    
    func canNavigateBack() -> Bool {
        return !pathHistory.isEmpty
    }
    
    // MARK: - File Operations
    func getStreamingURL(for file: MediaFile) async -> URL? {
        // Check if file is cached for offline playback
        if let offlineURL = offlineManager.getOfflinePlayableURL(for: file.path) {
            return offlineURL
        }
        
        // If not cached and we're offline, return nil
        if isOfflineMode || !networkErrorHandler.isOnline {
            return nil
        }
        
        // Get streaming URL from SMB connection
        do {
            let streamingURL = try await smbConnection.streamFile(at: file.path)
            return streamingURL
        } catch {
            return nil
        }
    }
    
    func cacheFile(_ file: MediaFile) async {
        guard let server = currentServer else { return }
        
        do {
            try await offlineManager.cacheFile(
                from: file.path,
                serverHost: server.host,
                serverPort: server.port
            )
        } catch {
            print("Failed to cache file: \(error)")
        }
    }
    
    func readTextFile(at path: String) async -> Result<String, Error> {
        // Check if file is cached
        if let cachedFile = offlineManager.getCachedFile(for: path) {
            do {
                let content = try String(contentsOf: cachedFile.localURL)
                return .success(content)
            } catch {
                return .failure(error)
            }
        }
        
        // If not cached and we're offline, return error
        if isOfflineMode || !networkErrorHandler.isOnline {
            return .failure(NSError(domain: "OfflineError", code: -1, userInfo: [NSLocalizedDescriptionKey: "File not available offline"]))
        }
        
        // Read from SMB server
        do {
            let streamingURL = try await smbConnection.streamFile(at: path)
            let content = try String(contentsOf: streamingURL)
            return .success(content)
        } catch {
            return .failure(error)
        }
    }
    
    // MARK: - Error Handling
    private func handleConnectionError(_ error: Error, for path: String) async {
        let networkError = networkErrorHandler.handleError(error)
        let recoveryAction = networkErrorHandler.suggestRecoveryAction(for: networkError)
        
        switch recoveryAction {
        case .retry:
            // Retry with exponential backoff
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            await loadSMBFiles(for: path)
            
        case .checkConnection:
            // Fall back to offline mode
            await loadOfflineFiles(for: path)
            
        default:
            DispatchQueue.main.async {
                self.connectionState = .error(networkError.localizedDescription)
            }
        }
    }
    
    private func handleNetworkLoss() {
        // Automatically switch to offline mode when network is lost
        if !offlineManager.isOfflineMode {
            offlineManager.enableOfflineMode()
        }
        
        // Try to load cached files for current path
        Task {
            await loadOfflineFiles(for: currentPath)
        }
    }
    
    // MARK: - Offline Mode Support
    func toggleOfflineMode() {
        offlineManager.toggleOfflineMode()
    }
    
    func getCachedFiles() -> [OfflineModeManager.CachedFile] {
        return offlineManager.cachedFiles
    }
    
    func getDownloadQueue() -> [OfflineModeManager.DownloadTask] {
        return offlineManager.downloadQueue
    }
    
    // MARK: - Authentication Support
    func hasStoredCredentials(for server: SambaServer) -> Bool {
        return keychainManager.hasCredentials(for: server.host, port: server.port)
    }
    
    func storeCredentials(for server: SambaServer, username: String, password: String, domain: String? = nil) throws {
        try keychainManager.storeServer(
            name: server.name,
            host: server.host,
            port: server.port,
            username: username,
            password: password,
            domain: domain
        )
    }
    
    func removeStoredCredentials(for server: SambaServer) throws {
        try keychainManager.deleteCredentials(for: server.host, port: server.port)
    }
} 