//
//  OfflineModeManager.swift
//  SambaPlay
//
//  Created by raama srivatsan on 7/6/25.
//

import Foundation
import AVFoundation

// MARK: - Offline Mode Manager
class OfflineModeManager: ObservableObject {
    static let shared = OfflineModeManager()
    
    @Published var isOfflineMode = false
    @Published var cachedFiles: [CachedFile] = []
    @Published var cachedDirectories: [String: [SMBFileItem]] = [:]
    @Published var downloadQueue: [DownloadTask] = []
    @Published var availableOfflineSpace: Int64 = 0
    @Published var usedOfflineSpace: Int64 = 0
    
    private let fileManager = FileManager.default
    private let userDefaults = UserDefaults.standard
    private let maxCacheSize: Int64 = 2 * 1024 * 1024 * 1024 // 2GB
    private let cacheDirectory: URL
    private let metadataFile: URL
    
    private init() {
        // Setup cache directory
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        cacheDirectory = documentsURL.appendingPathComponent("OfflineCache")
        metadataFile = cacheDirectory.appendingPathComponent("metadata.json")
        
        setupCacheDirectory()
        loadCachedData()
        updateStorageInfo()
    }
    
    // MARK: - Cached File Structure
    struct CachedFile: Codable, Identifiable {
        let id = UUID()
        let originalPath: String
        let localPath: String
        let fileName: String
        let fileSize: Int64
        let downloadDate: Date
        let lastAccessDate: Date
        let serverHost: String
        let serverPort: Int16
        let isAudioFile: Bool
        
        var localURL: URL {
            return URL(fileURLWithPath: localPath)
        }
        
        var isExpired: Bool {
            let expirationTime: TimeInterval = 7 * 24 * 60 * 60 // 7 days
            return Date().timeIntervalSince(lastAccessDate) > expirationTime
        }
        
        var formattedSize: String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: fileSize)
        }
    }
    
    // MARK: - Download Task
    struct DownloadTask: Identifiable {
        let id = UUID()
        let remotePath: String
        let fileName: String
        let serverHost: String
        let serverPort: Int16
        var progress: Double = 0.0
        var status: DownloadStatus = .queued
        var error: Error?
        
        enum DownloadStatus {
            case queued
            case downloading
            case completed
            case failed
            case cancelled
        }
    }
    
    // MARK: - Setup
    private func setupCacheDirectory() {
        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create cache directory: \(error)")
        }
    }
    
    private func loadCachedData() {
        // Load cached files metadata
        if let data = try? Data(contentsOf: metadataFile),
           let cached = try? JSONDecoder().decode([CachedFile].self, from: data) {
            cachedFiles = cached.filter { fileManager.fileExists(atPath: $0.localPath) }
        }
        
        // Load cached directory listings
        let directoriesFile = cacheDirectory.appendingPathComponent("directories.json")
        if let data = try? Data(contentsOf: directoriesFile),
           let directories = try? JSONDecoder().decode([String: [SMBFileItem]].self, from: data) {
            cachedDirectories = directories
        }
    }
    
    private func saveCachedData() {
        // Save cached files metadata
        do {
            let data = try JSONEncoder().encode(cachedFiles)
            try data.write(to: metadataFile)
        } catch {
            print("Failed to save cached files metadata: \(error)")
        }
        
        // Save cached directory listings
        let directoriesFile = cacheDirectory.appendingPathComponent("directories.json")
        do {
            let data = try JSONEncoder().encode(cachedDirectories)
            try data.write(to: directoriesFile)
        } catch {
            print("Failed to save cached directories: \(error)")
        }
    }
    
    // MARK: - Offline Mode Control
    func enableOfflineMode() {
        isOfflineMode = true
        userDefaults.set(true, forKey: "OfflineMode")
    }
    
    func disableOfflineMode() {
        isOfflineMode = false
        userDefaults.set(false, forKey: "OfflineMode")
    }
    
    func toggleOfflineMode() {
        if isOfflineMode {
            disableOfflineMode()
        } else {
            enableOfflineMode()
        }
    }
    
    // MARK: - File Caching
    func cacheFile(from remotePath: String, serverHost: String, serverPort: Int16 = 445) async throws {
        let fileName = URL(fileURLWithPath: remotePath).lastPathComponent
        let localFileName = "\(UUID().uuidString)_\(fileName)"
        let localURL = cacheDirectory.appendingPathComponent(localFileName)
        
        // Create download task
        let task = DownloadTask(
            remotePath: remotePath,
            fileName: fileName,
            serverHost: serverHost,
            serverPort: serverPort
        )
        
        DispatchQueue.main.async {
            self.downloadQueue.append(task)
        }
        
        do {
            // Download file using SMB connection
            let connectionManager = SMBConnectionManager.shared
            try await connectionManager.downloadFile(
                at: remotePath,
                to: localURL
            ) { progress in
                DispatchQueue.main.async {
                    if let index = self.downloadQueue.firstIndex(where: { $0.id == task.id }) {
                        self.downloadQueue[index].progress = progress
                        self.downloadQueue[index].status = .downloading
                    }
                }
            }
            
            // Get file size
            let attributes = try fileManager.attributesOfItem(atPath: localURL.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            
            // Create cached file entry
            let cachedFile = CachedFile(
                originalPath: remotePath,
                localPath: localURL.path,
                fileName: fileName,
                fileSize: fileSize,
                downloadDate: Date(),
                lastAccessDate: Date(),
                serverHost: serverHost,
                serverPort: serverPort,
                isAudioFile: isAudioFile(fileName)
            )
            
            DispatchQueue.main.async {
                self.cachedFiles.append(cachedFile)
                
                // Update download task status
                if let index = self.downloadQueue.firstIndex(where: { $0.id == task.id }) {
                    self.downloadQueue[index].status = .completed
                }
                
                self.updateStorageInfo()
                self.saveCachedData()
            }
            
        } catch {
            DispatchQueue.main.async {
                if let index = self.downloadQueue.firstIndex(where: { $0.id == task.id }) {
                    self.downloadQueue[index].status = .failed
                    self.downloadQueue[index].error = error
                }
            }
            throw error
        }
    }
    
    func removeCachedFile(_ cachedFile: CachedFile) {
        do {
            try fileManager.removeItem(at: cachedFile.localURL)
            
            DispatchQueue.main.async {
                self.cachedFiles.removeAll { $0.id == cachedFile.id }
                self.updateStorageInfo()
                self.saveCachedData()
            }
        } catch {
            print("Failed to remove cached file: \(error)")
        }
    }
    
    func getCachedFile(for remotePath: String) -> CachedFile? {
        return cachedFiles.first { $0.originalPath == remotePath }
    }
    
    func isCached(_ remotePath: String) -> Bool {
        return getCachedFile(for: remotePath) != nil
    }
    
    // MARK: - Directory Caching
    func cacheDirectoryListing(_ items: [SMBFileItem], for path: String) {
        DispatchQueue.main.async {
            self.cachedDirectories[path] = items
            self.saveCachedData()
        }
    }
    
    func getCachedDirectoryListing(for path: String) -> [SMBFileItem]? {
        return cachedDirectories[path]
    }
    
    func clearCachedDirectoryListing(for path: String) {
        DispatchQueue.main.async {
            self.cachedDirectories.removeValue(forKey: path)
            self.saveCachedData()
        }
    }
    
    // MARK: - Cache Management
    func cleanupExpiredFiles() {
        let expiredFiles = cachedFiles.filter { $0.isExpired }
        
        for file in expiredFiles {
            removeCachedFile(file)
        }
    }
    
    func clearAllCache() {
        do {
            try fileManager.removeItem(at: cacheDirectory)
            setupCacheDirectory()
            
            DispatchQueue.main.async {
                self.cachedFiles.removeAll()
                self.cachedDirectories.removeAll()
                self.updateStorageInfo()
                self.saveCachedData()
            }
        } catch {
            print("Failed to clear cache: \(error)")
        }
    }
    
    func enforceStorageLimit() {
        guard usedOfflineSpace > maxCacheSize else { return }
        
        // Sort files by last access date (oldest first)
        let sortedFiles = cachedFiles.sorted { $0.lastAccessDate < $1.lastAccessDate }
        
        var spaceToFree = usedOfflineSpace - maxCacheSize
        
        for file in sortedFiles {
            if spaceToFree <= 0 { break }
            
            removeCachedFile(file)
            spaceToFree -= file.fileSize
        }
    }
    
    private func updateStorageInfo() {
        do {
            _ = try fileManager.attributesOfItem(atPath: cacheDirectory.path)
            usedOfflineSpace = cachedFiles.reduce(0) { $0 + $1.fileSize }
            availableOfflineSpace = maxCacheSize - usedOfflineSpace
        } catch {
            print("Failed to update storage info: \(error)")
        }
    }
    
    // MARK: - Offline Playback
    func getOfflinePlayableURL(for remotePath: String) -> URL? {
        guard let cachedFile = getCachedFile(for: remotePath) else {
            return nil
        }
        
        // Update last access date
        if let index = cachedFiles.firstIndex(where: { $0.id == cachedFile.id }) {
            let updatedFile = CachedFile(
                originalPath: cachedFile.originalPath,
                localPath: cachedFile.localPath,
                fileName: cachedFile.fileName,
                fileSize: cachedFile.fileSize,
                downloadDate: cachedFile.downloadDate,
                lastAccessDate: Date(),
                serverHost: cachedFile.serverHost,
                serverPort: cachedFile.serverPort,
                isAudioFile: cachedFile.isAudioFile
            )
            
            cachedFiles[index] = updatedFile
            saveCachedData()
        }
        
        return cachedFile.localURL
    }
    
    func getOfflineAudioFiles() -> [CachedFile] {
        return cachedFiles.filter { $0.isAudioFile }
    }
    
    // MARK: - Utility Methods
    private func isAudioFile(_ fileName: String) -> Bool {
        let audioExtensions = ["mp3", "m4a", "wav", "aac", "flac", "ogg", "wma", "aiff", "opus"]
        let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return audioExtensions.contains(fileExtension)
    }
    
    func getFormattedStorageInfo() -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        
        let usedString = formatter.string(fromByteCount: usedOfflineSpace)
        let totalString = formatter.string(fromByteCount: maxCacheSize)
        
        return "\(usedString) / \(totalString)"
    }
    
    func getStorageUsagePercentage() -> Double {
        guard maxCacheSize > 0 else { return 0.0 }
        return Double(usedOfflineSpace) / Double(maxCacheSize) * 100.0
    }
    
    // MARK: - Batch Operations
    func cacheMultipleFiles(_ remotePaths: [String], serverHost: String, serverPort: Int16 = 445) async {
        for remotePath in remotePaths {
            do {
                try await cacheFile(from: remotePath, serverHost: serverHost, serverPort: serverPort)
            } catch {
                print("Failed to cache file \(remotePath): \(error)")
            }
        }
    }
    
    func cancelDownload(_ taskId: UUID) {
        DispatchQueue.main.async {
            if let index = self.downloadQueue.firstIndex(where: { $0.id == taskId }) {
                self.downloadQueue[index].status = .cancelled
            }
        }
    }
    
    func cancelAllDownloads() {
        DispatchQueue.main.async {
            for index in self.downloadQueue.indices {
                if self.downloadQueue[index].status == .downloading || self.downloadQueue[index].status == .queued {
                    self.downloadQueue[index].status = .cancelled
                }
            }
        }
    }
    
    func clearCompletedDownloads() {
        DispatchQueue.main.async {
            self.downloadQueue.removeAll { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }
        }
    }
}

// MARK: - Offline Mode Manager Extensions
extension OfflineModeManager {
    
    // MARK: - Smart Caching
    func suggestFilesForCaching(from items: [SMBFileItem]) -> [SMBFileItem] {
        // Suggest audio files for caching
        let audioFiles = items.filter { $0.isAudioFile }
        
        // Sort by file size (smaller files first for better user experience)
        return audioFiles.sorted { $0.size ?? 0 < $1.size ?? 0 }
    }
    
    func estimateDownloadTime(for fileSize: Int64, bandwidth: Double) -> TimeInterval {
        guard bandwidth > 0 else { return 0 }
        
        let bitsPerSecond = bandwidth
        let bytesPerSecond = bitsPerSecond / 8
        
        return Double(fileSize) / bytesPerSecond
    }
    
    // MARK: - Cache Statistics
    func getCacheStatistics() -> CacheStatistics {
        let totalFiles = cachedFiles.count
        let audioFiles = cachedFiles.filter { $0.isAudioFile }.count
        let totalSize = usedOfflineSpace
        let oldestFile = cachedFiles.min { $0.downloadDate < $1.downloadDate }
        let newestFile = cachedFiles.max { $0.downloadDate < $1.downloadDate }
        
        return CacheStatistics(
            totalFiles: totalFiles,
            audioFiles: audioFiles,
            totalSize: totalSize,
            oldestFileDate: oldestFile?.downloadDate,
            newestFileDate: newestFile?.downloadDate,
            storageUsagePercentage: getStorageUsagePercentage()
        )
    }
    
    struct CacheStatistics {
        let totalFiles: Int
        let audioFiles: Int
        let totalSize: Int64
        let oldestFileDate: Date?
        let newestFileDate: Date?
        let storageUsagePercentage: Double
    }
    
    // MARK: - Offline Mode Validation
    func validateOfflineMode() -> OfflineValidationResult {
        var issues: [String] = []
        
        // Check storage space
        if availableOfflineSpace < 100 * 1024 * 1024 { // Less than 100MB
            issues.append("Low storage space available")
        }
        
        // Check for expired files
        let expiredCount = cachedFiles.filter { $0.isExpired }.count
        if expiredCount > 0 {
            issues.append("\(expiredCount) expired files need cleanup")
        }
        
        // Check for missing files
        let missingFiles = cachedFiles.filter { !fileManager.fileExists(atPath: $0.localPath) }
        if !missingFiles.isEmpty {
            issues.append("\(missingFiles.count) cached files are missing")
        }
        
        return OfflineValidationResult(
            isValid: issues.isEmpty,
            issues: issues,
            cachedFileCount: cachedFiles.count,
            availableSpace: availableOfflineSpace
        )
    }
    
    struct OfflineValidationResult {
        let isValid: Bool
        let issues: [String]
        let cachedFileCount: Int
        let availableSpace: Int64
    }
} 