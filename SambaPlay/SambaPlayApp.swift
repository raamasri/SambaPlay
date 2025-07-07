import UIKit
import AVFoundation
import Combine
import MediaPlayer
import CoreData
import UniformTypeIdentifiers
import AudioToolbox

// MARK: - Data Models

enum AudioFormat: String, CaseIterable {
    case mp3 = "mp3"
    case aac = "aac"
    case flac = "flac"
    case ogg = "ogg"
    case wav = "wav"
    case aiff = "aiff"
    case opus = "opus"
    case wma = "wma"
    case caf = "caf"
    case threegp = "3gp"
    case amr = "amr"
    case unknown = "unknown"
    
    var displayName: String {
        switch self {
        case .mp3: return "MP3"
        case .aac: return "AAC"
        case .flac: return "FLAC"
        case .ogg: return "OGG Vorbis"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .opus: return "Opus"
        case .wma: return "WMA"
        case .caf: return "Core Audio"
        case .threegp: return "3GP"
        case .amr: return "AMR"
        case .unknown: return "Unknown"
        }
    }
    
    var isLossless: Bool {
        switch self {
        case .flac, .wav, .aiff, .caf: return true
        default: return false
        }
    }
    
    var supportsMetadata: Bool {
        switch self {
        case .mp3, .aac, .flac, .ogg, .wma: return true
        default: return false
        }
    }
}

struct MediaFile: Identifiable, Hashable, Codable {
    let id: UUID
    let name: String
    let path: String
    let size: Int64
    let modificationDate: Date
    let isDirectory: Bool
    let fileExtension: String?
    
    init(name: String, path: String, size: Int64, modificationDate: Date, isDirectory: Bool, fileExtension: String? = nil) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.size = size
        self.modificationDate = modificationDate
        self.isDirectory = isDirectory
        self.fileExtension = fileExtension
    }
    
    var isAudioFile: Bool {
        guard let ext = fileExtension?.lowercased() else { return false }
        return ["mp3", "m4a", "wav", "aac", "flac", "ogg", "wma", "aiff", "opus", "mp4", "m4b", "caf", "3gp", "amr"].contains(ext)
    }
    
    var audioFormat: AudioFormat {
        guard let ext = fileExtension?.lowercased() else { return .unknown }
        switch ext {
        case "mp3": return .mp3
        case "m4a", "mp4", "m4b": return .aac
        case "flac": return .flac
        case "ogg": return .ogg
        case "wav": return .wav
        case "aiff": return .aiff
        case "opus": return .opus
        case "wma": return .wma
        case "caf": return .caf
        case "3gp": return .threegp
        case "amr": return .amr
        default: return .unknown
        }
    }
    
    var isTextFile: Bool {
        guard let ext = fileExtension?.lowercased() else { return false }
        return ["txt", "lrc", "srt", "lyrics", "md"].contains(ext)
    }
    
    var associatedTextFile: String? {
        guard let ext = fileExtension else { return nil }
        let baseName = name.replacingOccurrences(of: ".\(ext)", with: "")
        return "\(baseName).txt"
    }
}

enum NetworkConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
    
    static func == (lhs: NetworkConnectionState, rhs: NetworkConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.connected, .connected):
            return true
        case (.error(let lhsMessage), .error(let rhsMessage)):
            return lhsMessage == rhsMessage
        default:
            return false
        }
    }
}

enum AudioPlayerState: Equatable {
    case stopped
    case playing
    case paused
    case buffering
    case error(String)
}

// MARK: - Folder History Model
class LocalFolder: Codable {
    let id: UUID
    var name: String
    var bookmarkData: Data
    var dateAdded: Date
    var lastAccessed: Date
    
    init(name: String, bookmarkData: Data) {
        self.id = UUID()
        self.name = name
        self.bookmarkData = bookmarkData
        self.dateAdded = Date()
        self.lastAccessed = Date()
    }
    
    func updateLastAccessed() {
        lastAccessed = Date()
    }
    
    // MARK: - Codable
    private enum CodingKeys: String, CodingKey {
        case id, name, bookmarkData, dateAdded, lastAccessed
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        bookmarkData = try container.decode(Data.self, forKey: .bookmarkData)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        lastAccessed = try container.decode(Date.self, forKey: .lastAccessed)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(bookmarkData, forKey: .bookmarkData)
        try container.encode(dateAdded, forKey: .dateAdded)
        try container.encode(lastAccessed, forKey: .lastAccessed)
    }
}

// MARK: - Playback Position Memory Model
struct PlaybackPosition: Codable {
    let filePath: String
    let fileName: String
    let position: TimeInterval
    let duration: TimeInterval
    let lastPlayed: Date
    
    init(file: MediaFile, position: TimeInterval, duration: TimeInterval) {
        self.filePath = file.path
        self.fileName = file.name
        self.position = position
        self.duration = duration
        self.lastPlayed = Date()
    }
    
    // Only remember position if we're not at the very beginning or end
    var shouldRememberPosition: Bool {
        return position > 5.0 && position < (duration - 10.0)
    }
    
    // Progress as percentage for UI display
    var progressPercentage: Double {
        guard duration > 0 else { return 0 }
        return (position / duration) * 100
    }
}

// MARK: - Memory Management Models
class MemoryManager: ObservableObject {
    static let shared = MemoryManager()
    
    @Published var memoryUsage: Double = 0.0
    @Published var cacheSize: Int64 = 0
    @Published var isMemoryWarning = false
    
    private let maxCacheSize: Int64 = 100 * 1024 * 1024 // 100MB
    private let memoryWarningThreshold: Double = 0.8 // 80%
    private var memoryTimer: Timer?
    
    private init() {
        startMemoryMonitoring()
        setupMemoryWarningNotification()
    }
    
    private func startMemoryMonitoring() {
        memoryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateMemoryUsage()
        }
    }
    
    private func updateMemoryUsage() {
        let usage = getCurrentMemoryUsage()
        DispatchQueue.main.async {
            self.memoryUsage = usage
            self.isMemoryWarning = usage > self.memoryWarningThreshold
            
            if self.isMemoryWarning {
                self.performMemoryCleanup()
            }
        }
    }
    
    private func getCurrentMemoryUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let usedMemory = Double(info.resident_size)
            let totalMemory = Double(ProcessInfo.processInfo.physicalMemory)
            return usedMemory / totalMemory
        }
        
        return 0.0
    }
    
    private func setupMemoryWarningNotification() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }
    }
    
    private func handleMemoryWarning() {
        print("⚠️ [MemoryManager] Memory warning received - performing aggressive cleanup")
        performMemoryCleanup()
        ImageCacheManager.shared.clearCache()
        
        DispatchQueue.main.async {
            self.isMemoryWarning = true
        }
    }
    
    func performMemoryCleanup() {
        // Trigger garbage collection
        autoreleasepool {
            // Force cleanup of autoreleased objects
        }
        
        // Clear URL cache
        URLCache.shared.removeAllCachedResponses()
        
        // Notify other components to clean up
        NotificationCenter.default.post(name: .memoryCleanupRequested, object: nil)
    }
    
    func updateCacheSize(_ size: Int64) {
        DispatchQueue.main.async {
            self.cacheSize = size
        }
    }
    
    func shouldEvictCache() -> Bool {
        return cacheSize > maxCacheSize || isMemoryWarning
    }
    
    deinit {
        memoryTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Image Cache Manager
class ImageCacheManager: NSObject, ObservableObject {
    static let shared = ImageCacheManager()
    
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let maxMemoryCount = 50
    private let maxMemorySize = 50 * 1024 * 1024 // 50MB
    
    @Published var cacheHitRate: Double = 0.0
    private var cacheHits = 0
    private var cacheMisses = 0
    
    private override init() {
        // Setup cache directory
        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cacheDir.appendingPathComponent("ImageCache")
        
        super.init()
        
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Configure NSCache
        cache.countLimit = maxMemoryCount
        cache.totalCostLimit = maxMemorySize
        cache.delegate = self
        
        // Setup memory cleanup notification
        NotificationCenter.default.addObserver(
            forName: .memoryCleanupRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearMemoryCache()
        }
        
        // Update memory manager with cache size
        updateCacheSize()
    }
    
    func image(for key: String) -> UIImage? {
        let cacheKey = NSString(string: key)
        
        // Check memory cache first
        if let image = cache.object(forKey: cacheKey) {
            cacheHits += 1
            updateCacheHitRate()
            return image
        }
        
        // Check disk cache
        let fileURL = cacheDirectory.appendingPathComponent(key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key)
        if let data = try? Data(contentsOf: fileURL),
           let image = UIImage(data: data) {
            
            // Store in memory cache for future access
            cache.setObject(image, forKey: cacheKey, cost: estimateImageSize(image))
            cacheHits += 1
            updateCacheHitRate()
            return image
        }
        
        cacheMisses += 1
        updateCacheHitRate()
        return nil
    }
    
    func setImage(_ image: UIImage, for key: String) {
        let cacheKey = NSString(string: key)
        let cost = estimateImageSize(image)
        
        // Store in memory cache
        cache.setObject(image, forKey: cacheKey, cost: cost)
        
        // Store in disk cache asynchronously
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.storeToDisk(image: image, key: key)
        }
        
        updateCacheSize()
    }
    
    private func storeToDisk(image: UIImage, key: String) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        
        let fileName = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let fileURL = cacheDirectory.appendingPathComponent(fileName)
        
        try? data.write(to: fileURL)
    }
    
    private func estimateImageSize(_ image: UIImage) -> Int {
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        return width * height * 4 // 4 bytes per pixel for RGBA
    }
    
    func clearCache() {
        clearMemoryCache()
        clearDiskCache()
        updateCacheSize()
    }
    
    func clearMemoryCache() {
        cache.removeAllObjects()
        print("🗑️ [ImageCache] Memory cache cleared")
    }
    
    private func clearDiskCache() {
        do {
            let files = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            for file in files {
                try fileManager.removeItem(at: file)
            }
            print("🗑️ [ImageCache] Disk cache cleared")
        } catch {
            print("❌ [ImageCache] Failed to clear disk cache: \(error)")
        }
    }
    
    private func updateCacheSize() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            
            let diskSize = self.calculateDiskCacheSize()
            let memorySize = Int64(self.cache.totalCostLimit)
            let totalSize = diskSize + memorySize
            
            MemoryManager.shared.updateCacheSize(totalSize)
        }
    }
    
    private func calculateDiskCacheSize() -> Int64 {
        do {
            let files = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])
            return files.compactMap { url in
                try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            }.reduce(0) { Int64($0) + Int64($1) }
        } catch {
            return 0
        }
    }
    
    private func updateCacheHitRate() {
        let total = cacheHits + cacheMisses
        if total > 0 {
            DispatchQueue.main.async {
                self.cacheHitRate = Double(self.cacheHits) / Double(total)
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

extension ImageCacheManager: NSCacheDelegate {
    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        print("🗑️ [ImageCache] Evicting object from memory cache")
    }
}

// MARK: - Background Processing Manager
class BackgroundProcessingManager: ObservableObject {
    static let shared = BackgroundProcessingManager()
    
    private let fileOperationQueue = DispatchQueue(label: "com.sambaplay.fileops", qos: .utility, attributes: .concurrent)
    private let imageProcessingQueue = DispatchQueue(label: "com.sambaplay.imageprocessing", qos: .userInitiated)
    private let networkQueue = DispatchQueue(label: "com.sambaplay.network", qos: .userInitiated, attributes: .concurrent)
    
    @Published var activeOperations = 0
    @Published var queuedOperations = 0
    
    private let operationQueue = OperationQueue()
    private var operationCount = 0
    
    private init() {
        operationQueue.maxConcurrentOperationCount = 4
        operationQueue.qualityOfService = .utility
    }
    
    func performFileOperation<T>(_ operation: @escaping () throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        incrementOperationCount()
        
        fileOperationQueue.async { [weak self] in
            do {
                let result = try operation()
                DispatchQueue.main.async {
                    completion(.success(result))
                    self?.decrementOperationCount()
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                    self?.decrementOperationCount()
                }
            }
        }
    }
    
    func processImageAsync(_ image: UIImage, for key: String, completion: @escaping (UIImage?) -> Void) {
        incrementOperationCount()
        
        imageProcessingQueue.async { [weak self] in
            let processedImage = self?.processImage(image)
            
            DispatchQueue.main.async {
                completion(processedImage)
                self?.decrementOperationCount()
            }
        }
    }
    
    func performNetworkOperation<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            incrementOperationCount()
            
            Task {
                do {
                    let result = try await operation()
                    decrementOperationCount()
                    continuation.resume(returning: result)
                } catch {
                    decrementOperationCount()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func processImage(_ image: UIImage) -> UIImage? {
        // Resize image for thumbnail if needed
        let maxSize: CGFloat = 300
        let size = image.size
        
        if size.width <= maxSize && size.height <= maxSize {
            return image
        }
        
        let ratio = min(maxSize / size.width, maxSize / size.height)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        
        UIGraphicsBeginImageContextWithOptions(newSize, false, 0.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return resizedImage
    }
    
    private func incrementOperationCount() {
        DispatchQueue.main.async {
            self.operationCount += 1
            self.activeOperations = self.operationCount
        }
    }
    
    private func decrementOperationCount() {
        DispatchQueue.main.async {
            self.operationCount = max(0, self.operationCount - 1)
            self.activeOperations = self.operationCount
        }
    }
    
    func cancelAllOperations() {
        operationQueue.cancelAllOperations()
        DispatchQueue.main.async {
            self.operationCount = 0
            self.activeOperations = 0
        }
    }
}

// MARK: - Virtual Scrolling Manager
class VirtualScrollingManager: ObservableObject {
    @Published var visibleRange: Range<Int> = 0..<0
    @Published var totalItems = 0
    
    private let bufferSize = 10
    private let itemHeight: CGFloat = 60
    
    func updateVisibleRange(for scrollView: UIScrollView) {
        let contentOffset = scrollView.contentOffset.y
        let visibleHeight = scrollView.bounds.height
        
        let startIndex = max(0, Int(contentOffset / itemHeight) - bufferSize)
        let endIndex = min(totalItems, Int((contentOffset + visibleHeight) / itemHeight) + bufferSize)
        
        let newRange = startIndex..<endIndex
        
        if newRange != visibleRange {
            visibleRange = newRange
        }
    }
    
    func setTotalItems(_ count: Int) {
        totalItems = count
    }
    
    func shouldLoadItem(at index: Int) -> Bool {
        return visibleRange.contains(index)
    }
}

// MARK: - Performance Metrics
class PerformanceMetrics: ObservableObject {
    static let shared = PerformanceMetrics()
    
    @Published var averageLoadTime: TimeInterval = 0
    @Published var memoryEfficiency: Double = 0
    @Published var cacheEffectiveness: Double = 0
    
    private var loadTimes: [TimeInterval] = []
    private let maxSamples = 100
    
    private init() {}
    
    func recordLoadTime(_ time: TimeInterval) {
        loadTimes.append(time)
        if loadTimes.count > maxSamples {
            loadTimes.removeFirst()
        }
        
        DispatchQueue.main.async {
            self.averageLoadTime = self.loadTimes.reduce(0, +) / Double(self.loadTimes.count)
        }
    }
    
    func updateMemoryEfficiency(_ efficiency: Double) {
        DispatchQueue.main.async {
            self.memoryEfficiency = efficiency
        }
    }
    
    func updateCacheEffectiveness(_ effectiveness: Double) {
        DispatchQueue.main.async {
            self.cacheEffectiveness = effectiveness
        }
    }
}

// MARK: - Notification Extensions
extension Notification.Name {
    static let memoryCleanupRequested = Notification.Name("memoryCleanupRequested")
}

// MARK: - Playback Queue Models
enum PlaybackMode: String, CaseIterable, Codable {
    case normal = "normal"
    case repeatOne = "repeatOne"
    case repeatAll = "repeatAll"
    case shuffle = "shuffle"
    
    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .repeatOne: return "Repeat One"
        case .repeatAll: return "Repeat All"
        case .shuffle: return "Shuffle"
        }
    }
    
    var systemImage: String {
        switch self {
        case .normal: return "arrow.right"
        case .repeatOne: return "repeat.1"
        case .repeatAll: return "repeat"
        case .shuffle: return "shuffle"
        }
    }
    
    var accessibilityLabel: String {
        switch self {
        case .normal: return "Normal playback mode"
        case .repeatOne: return "Repeat current track"
        case .repeatAll: return "Repeat all tracks"
        case .shuffle: return "Shuffle playback"
        }
    }
}

class PlaybackQueue: ObservableObject {
    @Published var tracks: [MediaFile] = []
    @Published var currentIndex: Int = 0
    @Published var playbackMode: PlaybackMode = .normal
    @Published var shuffledIndices: [Int] = []
    @Published var currentShuffleIndex: Int = 0
    
    var currentTrack: MediaFile? {
        guard !tracks.isEmpty else { return nil }
        
        if playbackMode == .shuffle && !shuffledIndices.isEmpty {
            let shuffleIndex = min(currentShuffleIndex, shuffledIndices.count - 1)
            let trackIndex = shuffledIndices[shuffleIndex]
            return trackIndex < tracks.count ? tracks[trackIndex] : nil
        } else {
            return currentIndex < tracks.count ? tracks[currentIndex] : nil
        }
    }
    
    var hasNext: Bool {
        guard !tracks.isEmpty else { return false }
        
        switch playbackMode {
        case .normal:
            return currentIndex < tracks.count - 1
        case .repeatOne, .repeatAll:
            return true
        case .shuffle:
            return currentShuffleIndex < shuffledIndices.count - 1 || playbackMode == .repeatAll
        }
    }
    
    var hasPrevious: Bool {
        guard !tracks.isEmpty else { return false }
        
        switch playbackMode {
        case .normal:
            return currentIndex > 0
        case .repeatOne, .repeatAll:
            return true
        case .shuffle:
            return currentShuffleIndex > 0 || playbackMode == .repeatAll
        }
    }
    
    var nextTrack: MediaFile? {
        guard !tracks.isEmpty else { return nil }
        
        switch playbackMode {
        case .normal:
            let nextIndex = currentIndex + 1
            return nextIndex < tracks.count ? tracks[nextIndex] : nil
        case .repeatOne:
            return currentTrack
        case .repeatAll:
            let nextIndex = (currentIndex + 1) % tracks.count
            return tracks[nextIndex]
        case .shuffle:
            if !shuffledIndices.isEmpty {
                let nextShuffleIndex = currentShuffleIndex + 1
                if nextShuffleIndex < shuffledIndices.count {
                    let trackIndex = shuffledIndices[nextShuffleIndex]
                    return trackIndex < tracks.count ? tracks[trackIndex] : nil
                } else if playbackMode == .repeatAll {
                    let trackIndex = shuffledIndices[0]
                    return trackIndex < tracks.count ? tracks[trackIndex] : nil
                }
            }
            return nil
        }
    }
    
    var previousTrack: MediaFile? {
        guard !tracks.isEmpty else { return nil }
        
        switch playbackMode {
        case .normal:
            let prevIndex = currentIndex - 1
            return prevIndex >= 0 ? tracks[prevIndex] : nil
        case .repeatOne:
            return currentTrack
        case .repeatAll:
            let prevIndex = currentIndex - 1 >= 0 ? currentIndex - 1 : tracks.count - 1
            return tracks[prevIndex]
        case .shuffle:
            if !shuffledIndices.isEmpty {
                let prevShuffleIndex = currentShuffleIndex - 1
                if prevShuffleIndex >= 0 {
                    let trackIndex = shuffledIndices[prevShuffleIndex]
                    return trackIndex < tracks.count ? tracks[trackIndex] : nil
                } else if playbackMode == .repeatAll {
                    let trackIndex = shuffledIndices[shuffledIndices.count - 1]
                    return trackIndex < tracks.count ? tracks[trackIndex] : nil
                }
            }
            return nil
        }
    }
    
    // MARK: - Queue Management
    func addTrack(_ track: MediaFile) {
        tracks.append(track)
        updateShuffleIndices()
    }
    
    func addTracks(_ newTracks: [MediaFile]) {
        tracks.append(contentsOf: newTracks)
        updateShuffleIndices()
    }
    
    func insertTrack(_ track: MediaFile, at index: Int) {
        let insertIndex = min(max(0, index), tracks.count)
        tracks.insert(track, at: insertIndex)
        
        // Adjust current index if needed
        if insertIndex <= currentIndex {
            currentIndex += 1
        }
        
        updateShuffleIndices()
    }
    
    func removeTrack(at index: Int) {
        guard index >= 0 && index < tracks.count else { return }
        
        tracks.remove(at: index)
        
        // Adjust current index
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex && currentIndex >= tracks.count {
            currentIndex = max(0, tracks.count - 1)
        }
        
        updateShuffleIndices()
    }
    
    func moveTrack(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0 && sourceIndex < tracks.count &&
              destinationIndex >= 0 && destinationIndex < tracks.count else { return }
        
        let track = tracks.remove(at: sourceIndex)
        tracks.insert(track, at: destinationIndex)
        
        // Adjust current index
        if sourceIndex == currentIndex {
            currentIndex = destinationIndex
        } else if sourceIndex < currentIndex && destinationIndex >= currentIndex {
            currentIndex -= 1
        } else if sourceIndex > currentIndex && destinationIndex <= currentIndex {
            currentIndex += 1
        }
        
        updateShuffleIndices()
    }
    
    func clearQueue() {
        tracks.removeAll()
        currentIndex = 0
        shuffledIndices.removeAll()
        currentShuffleIndex = 0
    }
    
    func playTrack(at index: Int) {
        guard index >= 0 && index < tracks.count else { return }
        
        if playbackMode == .shuffle {
            // Find the shuffle index for this track
            if let shuffleIndex = shuffledIndices.firstIndex(of: index) {
                currentShuffleIndex = shuffleIndex
            }
        } else {
            currentIndex = index
        }
    }
    
    // MARK: - Playback Mode Management
    func setPlaybackMode(_ mode: PlaybackMode) {
        playbackMode = mode
        
        if mode == .shuffle {
            generateShuffleOrder()
        }
    }
    
    func togglePlaybackMode() {
        switch playbackMode {
        case .normal:
            setPlaybackMode(.repeatAll)
        case .repeatAll:
            setPlaybackMode(.repeatOne)
        case .repeatOne:
            setPlaybackMode(.normal)
        case .shuffle:
            setPlaybackMode(.normal)
        }
    }
    
    func toggleShuffle() {
        if playbackMode == .shuffle {
            setPlaybackMode(.normal)
        } else {
            setPlaybackMode(.shuffle)
        }
    }
    
    // MARK: - Navigation
    func advanceToNext() -> MediaFile? {
        guard !tracks.isEmpty else { return nil }
        
        switch playbackMode {
        case .normal:
            if currentIndex < tracks.count - 1 {
                currentIndex += 1
                return tracks[currentIndex]
            }
        case .repeatOne:
            return currentTrack
        case .repeatAll:
            currentIndex = (currentIndex + 1) % tracks.count
            return tracks[currentIndex]
        case .shuffle:
            if currentShuffleIndex < shuffledIndices.count - 1 {
                currentShuffleIndex += 1
            } else {
                // Generate new shuffle order for repeat all
                generateShuffleOrder()
                currentShuffleIndex = 0
            }
            
            if !shuffledIndices.isEmpty {
                let trackIndex = shuffledIndices[currentShuffleIndex]
                if trackIndex < tracks.count {
                    return tracks[trackIndex]
                }
            }
        }
        
        return nil
    }
    
    func goToPrevious() -> MediaFile? {
        guard !tracks.isEmpty else { return nil }
        
        switch playbackMode {
        case .normal:
            if currentIndex > 0 {
                currentIndex -= 1
                return tracks[currentIndex]
            }
        case .repeatOne:
            return currentTrack
        case .repeatAll:
            currentIndex = currentIndex - 1 >= 0 ? currentIndex - 1 : tracks.count - 1
            return tracks[currentIndex]
        case .shuffle:
            if currentShuffleIndex > 0 {
                currentShuffleIndex -= 1
            } else {
                currentShuffleIndex = shuffledIndices.count - 1
            }
            
            if !shuffledIndices.isEmpty && currentShuffleIndex < shuffledIndices.count {
                let trackIndex = shuffledIndices[currentShuffleIndex]
                if trackIndex < tracks.count {
                    return tracks[trackIndex]
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Shuffle Management
    private func generateShuffleOrder() {
        shuffledIndices = Array(0..<tracks.count).shuffled()
        
        // Ensure current track stays as first in shuffle if we have a current track
        if currentIndex < tracks.count && !shuffledIndices.isEmpty {
            if let currentTrackShuffleIndex = shuffledIndices.firstIndex(of: currentIndex) {
                shuffledIndices.swapAt(0, currentTrackShuffleIndex)
                currentShuffleIndex = 0
            }
        }
    }
    
    private func updateShuffleIndices() {
        if playbackMode == .shuffle {
            generateShuffleOrder()
        }
    }
    
    // MARK: - Persistence
    func saveToUserDefaults() {
        let encoder = JSONEncoder()
        
        if let tracksData = try? encoder.encode(tracks) {
            UserDefaults.standard.set(tracksData, forKey: "playbackQueue_tracks")
        }
        
        UserDefaults.standard.set(currentIndex, forKey: "playbackQueue_currentIndex")
        UserDefaults.standard.set(playbackMode.rawValue, forKey: "playbackQueue_mode")
        UserDefaults.standard.set(shuffledIndices, forKey: "playbackQueue_shuffledIndices")
        UserDefaults.standard.set(currentShuffleIndex, forKey: "playbackQueue_currentShuffleIndex")
    }
    
    func loadFromUserDefaults() {
        let decoder = JSONDecoder()
        
        if let tracksData = UserDefaults.standard.data(forKey: "playbackQueue_tracks"),
           let savedTracks = try? decoder.decode([MediaFile].self, from: tracksData) {
            tracks = savedTracks
        }
        
        currentIndex = UserDefaults.standard.integer(forKey: "playbackQueue_currentIndex")
        
        if let modeString = UserDefaults.standard.string(forKey: "playbackQueue_mode"),
           let mode = PlaybackMode(rawValue: modeString) {
            playbackMode = mode
        }
        
        shuffledIndices = UserDefaults.standard.array(forKey: "playbackQueue_shuffledIndices") as? [Int] ?? []
        currentShuffleIndex = UserDefaults.standard.integer(forKey: "playbackQueue_currentShuffleIndex")
        
        // Validate indices
        if currentIndex >= tracks.count {
            currentIndex = max(0, tracks.count - 1)
        }
        
        if currentShuffleIndex >= shuffledIndices.count {
            currentShuffleIndex = max(0, shuffledIndices.count - 1)
        }
    }
}

// MARK: - App Settings Model
class AppSettings: ObservableObject, Codable {
    @Published var isDarkModeEnabled: Bool = false // System follows device setting
    @Published var isAccessibilityEnhanced: Bool = true
    @Published var isSearchEnabled: Bool = true
    @Published var isDragDropEnabled: Bool = true
    @Published var isVoiceOverOptimized: Bool = true
    @Published var isDynamicTextEnabled: Bool = true
    @Published var isHapticsEnabled: Bool = true
    @Published var isAutoPlayEnabled: Bool = true
    @Published var isLyricsSearchEnabled: Bool = false // New lyrics search toggle
    @Published var searchScopeIncludes: SearchScope = .all
    @Published var dragDropFileTypes: DragDropScope = .audioOnly
    @Published var accessibilityVerbosity: AccessibilityVerbosity = .standard
    @Published var interfaceStyle: InterfaceStyle = .system
    
    enum SearchScope: String, CaseIterable, Codable {
        case all = "All Files"
        case audioOnly = "Audio Files Only"
        case textOnly = "Text Files Only"
        
        var description: String { rawValue }
    }
    
    enum DragDropScope: String, CaseIterable, Codable {
        case audioOnly = "Audio Files Only"
        case allSupported = "All Supported Files"
        case disabled = "Disabled"
        
        var description: String { rawValue }
    }
    
    enum AccessibilityVerbosity: String, CaseIterable, Codable {
        case minimal = "Minimal"
        case standard = "Standard"
        case detailed = "Detailed"
        
        var description: String { rawValue }
    }
    
    enum InterfaceStyle: String, CaseIterable, Codable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"
        
        var description: String { rawValue }
    }
    
    static let shared = AppSettings()
    
    private init() {
        loadSettings()
    }
    
    // MARK: - Persistence
    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "AppSettings"),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.isDarkModeEnabled = settings.isDarkModeEnabled
            self.isAccessibilityEnhanced = settings.isAccessibilityEnhanced
            self.isSearchEnabled = settings.isSearchEnabled
            self.isDragDropEnabled = settings.isDragDropEnabled
            self.isVoiceOverOptimized = settings.isVoiceOverOptimized
            self.isDynamicTextEnabled = settings.isDynamicTextEnabled
            self.isHapticsEnabled = settings.isHapticsEnabled
            self.isAutoPlayEnabled = settings.isAutoPlayEnabled
            self.isLyricsSearchEnabled = settings.isLyricsSearchEnabled
            self.searchScopeIncludes = settings.searchScopeIncludes
            self.dragDropFileTypes = settings.dragDropFileTypes
            self.accessibilityVerbosity = settings.accessibilityVerbosity
            self.interfaceStyle = settings.interfaceStyle
        }
    }
    
    func saveSettings() {
        print("🔧 [Settings] Saving all settings to UserDefaults")
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "AppSettings")
            print("✅ [Settings] Settings saved successfully")
        } else {
            print("❌ [Settings] Failed to encode settings for saving")
        }
    }
    
    // MARK: - Settings Change Handlers with Logging
    func setSearchEnabled(_ enabled: Bool) {
        print("🔍 [Settings] Search functionality \(enabled ? "ENABLED" : "DISABLED")")
        isSearchEnabled = enabled
        saveSettings()
    }
    
    func setLyricsSearchEnabled(_ enabled: Bool) {
        print("🎵 [Settings] Lyrics search \(enabled ? "ENABLED" : "DISABLED")")
        isLyricsSearchEnabled = enabled
        saveSettings()
    }
    
    func setDragDropEnabled(_ enabled: Bool) {
        print("📥 [Settings] Drag & Drop functionality \(enabled ? "ENABLED" : "DISABLED")")
        isDragDropEnabled = enabled
        saveSettings()
    }
    
    func setAccessibilityEnhanced(_ enabled: Bool) {
        print("♿ [Settings] Enhanced Accessibility \(enabled ? "ENABLED" : "DISABLED")")
        isAccessibilityEnhanced = enabled
        saveSettings()
    }
    
    func setVoiceOverOptimized(_ enabled: Bool) {
        print("🗣️ [Settings] VoiceOver Optimization \(enabled ? "ENABLED" : "DISABLED")")
        isVoiceOverOptimized = enabled
        saveSettings()
    }
    
    func setDynamicTextEnabled(_ enabled: Bool) {
        print("📝 [Settings] Dynamic Text Sizing \(enabled ? "ENABLED" : "DISABLED")")
        isDynamicTextEnabled = enabled
        saveSettings()
    }
    
    func setHapticsEnabled(_ enabled: Bool) {
        print("📳 [Settings] Haptic Feedback \(enabled ? "ENABLED" : "DISABLED")")
        isHapticsEnabled = enabled
        saveSettings()
    }
    
    func setAutoPlayEnabled(_ enabled: Bool) {
        print("▶️ [Settings] Auto-Play \(enabled ? "ENABLED" : "DISABLED")")
        isAutoPlayEnabled = enabled
        saveSettings()
    }
    
    func setSearchScope(_ scope: SearchScope) {
        print("🔍 [Settings] Search scope changed to: \(scope.description)")
        searchScopeIncludes = scope
        saveSettings()
    }
    
    func setDragDropScope(_ scope: DragDropScope) {
        print("📥 [Settings] Drag & Drop scope changed to: \(scope.description)")
        dragDropFileTypes = scope
        saveSettings()
    }
    
    func setAccessibilityVerbosity(_ verbosity: AccessibilityVerbosity) {
        print("♿ [Settings] Accessibility verbosity changed to: \(verbosity.description)")
        accessibilityVerbosity = verbosity
        saveSettings()
    }
    
    func setInterfaceStyle(_ style: InterfaceStyle) {
        print("🎨 [Settings] Interface style changed to: \(style.description)")
        interfaceStyle = style
        saveSettings()
        
        // Apply interface style immediately
        DispatchQueue.main.async {
            self.applyInterfaceStyle()
        }
    }
    
    private func applyInterfaceStyle() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first else {
            print("❌ [Settings] Could not find window to apply interface style")
            return
        }
        
        switch interfaceStyle {
        case .system:
            print("🎨 [Settings] Applying SYSTEM interface style")
            window.overrideUserInterfaceStyle = .unspecified
        case .light:
            print("🎨 [Settings] Applying LIGHT interface style")
            window.overrideUserInterfaceStyle = .light
        case .dark:
            print("🎨 [Settings] Applying DARK interface style")
            window.overrideUserInterfaceStyle = .dark
        }
    }
    
    // MARK: - Codable Implementation
    enum CodingKeys: String, CodingKey {
        case isDarkModeEnabled, isAccessibilityEnhanced, isSearchEnabled, isDragDropEnabled
        case isVoiceOverOptimized, isDynamicTextEnabled, isHapticsEnabled, isAutoPlayEnabled
        case isLyricsSearchEnabled, searchScopeIncludes, dragDropFileTypes, accessibilityVerbosity, interfaceStyle
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isDarkModeEnabled = try container.decode(Bool.self, forKey: .isDarkModeEnabled)
        isAccessibilityEnhanced = try container.decode(Bool.self, forKey: .isAccessibilityEnhanced)
        isSearchEnabled = try container.decode(Bool.self, forKey: .isSearchEnabled)
        isDragDropEnabled = try container.decode(Bool.self, forKey: .isDragDropEnabled)
        isVoiceOverOptimized = try container.decode(Bool.self, forKey: .isVoiceOverOptimized)
        isDynamicTextEnabled = try container.decode(Bool.self, forKey: .isDynamicTextEnabled)
        isHapticsEnabled = try container.decode(Bool.self, forKey: .isHapticsEnabled)
        isAutoPlayEnabled = try container.decode(Bool.self, forKey: .isAutoPlayEnabled)
        isLyricsSearchEnabled = try container.decodeIfPresent(Bool.self, forKey: .isLyricsSearchEnabled) ?? false
        searchScopeIncludes = try container.decode(SearchScope.self, forKey: .searchScopeIncludes)
        dragDropFileTypes = try container.decode(DragDropScope.self, forKey: .dragDropFileTypes)
        accessibilityVerbosity = try container.decode(AccessibilityVerbosity.self, forKey: .accessibilityVerbosity)
        interfaceStyle = try container.decode(InterfaceStyle.self, forKey: .interfaceStyle)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isDarkModeEnabled, forKey: .isDarkModeEnabled)
        try container.encode(isAccessibilityEnhanced, forKey: .isAccessibilityEnhanced)
        try container.encode(isSearchEnabled, forKey: .isSearchEnabled)
        try container.encode(isDragDropEnabled, forKey: .isDragDropEnabled)
        try container.encode(isVoiceOverOptimized, forKey: .isVoiceOverOptimized)
        try container.encode(isDynamicTextEnabled, forKey: .isDynamicTextEnabled)
        try container.encode(isHapticsEnabled, forKey: .isHapticsEnabled)
        try container.encode(isAutoPlayEnabled, forKey: .isAutoPlayEnabled)
        try container.encode(isLyricsSearchEnabled, forKey: .isLyricsSearchEnabled)
        try container.encode(searchScopeIncludes, forKey: .searchScopeIncludes)
        try container.encode(dragDropFileTypes, forKey: .dragDropFileTypes)
        try container.encode(accessibilityVerbosity, forKey: .accessibilityVerbosity)
        try container.encode(interfaceStyle, forKey: .interfaceStyle)
    }
}

// MARK: - Recent Source Model
enum RecentSourceType: String, Codable {
    case server
    case folder
}

struct RecentSource: Identifiable, Codable {
    let id = UUID()
    let name: String
    let type: RecentSourceType
    let lastAccessed: Date
    let serverID: UUID? // For server sources
    let folderID: UUID? // For folder sources
    
    init(server: SambaServer) {
        self.name = server.name
        self.type = .server
        self.lastAccessed = Date()
        self.serverID = server.id
        self.folderID = nil
    }
    
    init(folder: LocalFolder) {
        self.name = folder.name
        self.type = .folder
        self.lastAccessed = Date()
        self.serverID = nil
        self.folderID = folder.id
    }
}

// MARK: - Samba Server Model
class SambaServer: Codable {
    let id: UUID
    var name: String
    var host: String
    var port: Int16
    var username: String?
    var password: String?
    
    init(name: String, host: String, port: Int16 = 445, username: String? = nil, password: String? = nil, id: UUID? = nil) {
        self.id = id ?? UUID()
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
    
    // Static UUID for demo server to prevent duplicates
    static let demoServerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    
    // MARK: - Codable
    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, password
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int16.self, forKey: .port)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        password = try container.decodeIfPresent(String.self, forKey: .password)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(password, forKey: .password)
    }
}

// MARK: - Enhanced Network Service
class SimpleNetworkService: ObservableObject {
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
    
    // Playback position memory
    private var savedPositions: [String: PlaybackPosition] = [:]
    
    private var demoDirectories: [String: [MediaFile]] = [:]
    
    init() {
        setupDemoData()
        loadSavedServers()
        loadSavedFolders()
        loadRecentSources()
        loadSavedPositions()
        
        // Clear all saved positions as requested to reset playback behavior
        clearAllSavedPositions()
    }
    
    private func setupDemoData() {
        // Root directory
        demoDirectories["/"] = [
            MediaFile(name: "Music", path: "/Music", size: 0, modificationDate: Date(), isDirectory: true, fileExtension: nil),
            MediaFile(name: "Podcasts", path: "/Podcasts", size: 0, modificationDate: Date(), isDirectory: true, fileExtension: nil),
            MediaFile(name: "Documents", path: "/Documents", size: 0, modificationDate: Date(), isDirectory: true, fileExtension: nil),
            MediaFile(name: "Sample Song.mp3", path: "/Sample Song.mp3", size: 3932160, modificationDate: Date(), isDirectory: false, fileExtension: "mp3"), // Updated to actual file size
            MediaFile(name: "Sample Song.txt", path: "/Sample Song.txt", size: 1024, modificationDate: Date(), isDirectory: false, fileExtension: "txt")
        ]
        
        // Music directory
        demoDirectories["/Music"] = [
            MediaFile(name: "Rock", path: "/Music/Rock", size: 0, modificationDate: Date(), isDirectory: true, fileExtension: nil),
            MediaFile(name: "Jazz", path: "/Music/Jazz", size: 0, modificationDate: Date(), isDirectory: true, fileExtension: nil),
            MediaFile(name: "Favorite Song.mp3", path: "/Music/Favorite Song.mp3", size: 4567890, modificationDate: Date(), isDirectory: false, fileExtension: "mp3"),
            MediaFile(name: "Favorite Song.txt", path: "/Music/Favorite Song.txt", size: 892, modificationDate: Date(), isDirectory: false, fileExtension: "txt")
        ]
        
        // Podcasts directory
        demoDirectories["/Podcasts"] = [
            MediaFile(name: "Tech Talk Episode 1.mp3", path: "/Podcasts/Tech Talk Episode 1.mp3", size: 25000000, modificationDate: Date(), isDirectory: false, fileExtension: "mp3"),
            MediaFile(name: "Tech Talk Episode 1.txt", path: "/Podcasts/Tech Talk Episode 1.txt", size: 2048, modificationDate: Date(), isDirectory: false, fileExtension: "txt"),
            MediaFile(name: "Music Podcast.m4a", path: "/Podcasts/Music Podcast.m4a", size: 30000000, modificationDate: Date(), isDirectory: false, fileExtension: "m4a"),
            MediaFile(name: "Podcast Notes.txt", path: "/Podcasts/Podcast Notes.txt", size: 1536, modificationDate: Date(), isDirectory: false, fileExtension: "txt")
        ]
        
        // Rock directory
        demoDirectories["/Music/Rock"] = [
            MediaFile(name: "Rock Anthem.mp3", path: "/Music/Rock/Rock Anthem.mp3", size: 6000000, modificationDate: Date(), isDirectory: false, fileExtension: "mp3"),
            MediaFile(name: "Guitar Solo.wav", path: "/Music/Rock/Guitar Solo.wav", size: 12000000, modificationDate: Date(), isDirectory: false, fileExtension: "wav")
        ]
        
        // Jazz directory
        demoDirectories["/Music/Jazz"] = [
            MediaFile(name: "Smooth Jazz.mp3", path: "/Music/Jazz/Smooth Jazz.mp3", size: 7500000, modificationDate: Date(), isDirectory: false, fileExtension: "mp3"),
            MediaFile(name: "Piano Improvisation.flac", path: "/Music/Jazz/Piano Improvisation.flac", size: 45000000, modificationDate: Date(), isDirectory: false, fileExtension: "flac")
        ]
        
        // Documents directory
        demoDirectories["/Documents"] = [
            MediaFile(name: "README.txt", path: "/Documents/README.txt", size: 3072, modificationDate: Date(), isDirectory: false, fileExtension: "txt"),
            MediaFile(name: "Song List.txt", path: "/Documents/Song List.txt", size: 2560, modificationDate: Date(), isDirectory: false, fileExtension: "txt"),
            MediaFile(name: "Album Notes.md", path: "/Documents/Album Notes.md", size: 4096, modificationDate: Date(), isDirectory: false, fileExtension: "md")
        ]
    }
    
    private func loadSavedServers() {
        // In a real app, this would load from UserDefaults or Core Data
        // For demo, add a sample server with consistent UUID to prevent duplicates in recent sources
        let demoServer = SambaServer(name: "Demo Server", host: "192.168.1.100", id: SambaServer.demoServerID)
        savedServers = [demoServer]
    }
    
    func addServer(_ server: SambaServer) {
        savedServers.append(server)
        // In a real app, save to UserDefaults or Core Data
    }
    
    func removeServer(_ server: SambaServer) {
        savedServers.removeAll { $0.id == server.id }
        // In a real app, remove from UserDefaults or Core Data
    }
    
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
        // Remove any existing folder with the same bookmark data to avoid duplicates
        savedFolders.removeAll { existingFolder in
            existingFolder.bookmarkData == folder.bookmarkData
        }
        
        savedFolders.append(folder)
        saveFolders()
    }
    
    func removeFolder(_ folder: LocalFolder) {
        savedFolders.removeAll { $0.id == folder.id }
        saveFolders()
    }
    
    private func loadRecentSources() {
        guard let data = UserDefaults.standard.data(forKey: "RecentSources") else { return }
        
        do {
            let loadedSources = try PropertyListDecoder().decode([RecentSource].self, from: data)
            
            // Enhanced deduplication by keeping only the most recent entry for each server/folder
            // This also handles duplicates by name for additional protection
            var uniqueSources: [RecentSource] = []
            var seenServerIDs: Set<UUID> = []
            var seenFolderIDs: Set<UUID> = []
            var seenServerNames: Set<String> = []
            var seenFolderNames: Set<String> = []
            
            for source in loadedSources.sorted { $0.lastAccessed > $1.lastAccessed } {
                var shouldAdd = false
                
                if source.type == .server, let serverID = source.serverID {
                    if !seenServerIDs.contains(serverID) && !seenServerNames.contains(source.name) {
                        seenServerIDs.insert(serverID)
                        seenServerNames.insert(source.name)
                        shouldAdd = true
                    }
                } else if source.type == .folder, let folderID = source.folderID {
                    if !seenFolderIDs.contains(folderID) && !seenFolderNames.contains(source.name) {
                        seenFolderIDs.insert(folderID)
                        seenFolderNames.insert(source.name)
                        shouldAdd = true
                    }
                }
                
                if shouldAdd {
                    uniqueSources.append(source)
                }
            }
            
            // Keep only the 5 most recent unique sources
            recentSources = Array(uniqueSources.prefix(5))
            
            // Save the cleaned up sources back to UserDefaults
            saveRecentSources()
            
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
        // Enhanced deduplication: Remove any existing source with the same server/folder ID OR name
        if source.type == .server, let serverID = source.serverID {
            recentSources.removeAll { existing in
                if existing.type == .server {
                    // Remove if same ID OR same name (for additional protection)
                    return existing.serverID == serverID || existing.name == source.name
                }
                return false
            }
        } else if source.type == .folder, let folderID = source.folderID {
            recentSources.removeAll { existing in
                if existing.type == .folder {
                    // Remove if same ID OR same name
                    return existing.folderID == folderID || existing.name == source.name
                }
                return false
            }
        }
        
        // Add the new source at the beginning
        recentSources.insert(source, at: 0)
        
        // Keep only the 5 most recent
        recentSources = Array(recentSources.prefix(5))
        
        saveRecentSources()
    }
    
    // MARK: - Playback Position Memory
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
        
        // Only save position if it's worth remembering (not at start/end)
        if playbackPosition.shouldRememberPosition {
            savedPositions[file.path] = playbackPosition
            saveSavedPositions()
        } else {
            // Remove saved position if user played to end or restarted from beginning
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
    

    
    func connect(to server: SambaServer) {
        isLocalMode = false
        currentServer = server
        connectionState = .connecting
        
        // Add to recent sources
        let recentSource = RecentSource(server: server)
        addRecentSource(recentSource)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.connectionState = .connected
            self.navigateToPath("/")
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
                // Bookmark is stale, we'll need the user to re-select the folder
                connectionState = .error("Folder bookmark is outdated. Please re-select the folder.")
                return
            }
            
            // iOS doesn't support security-scoped resources in the same way as macOS
            // We'll rely on the document picker's granted access
            
            // Load files from the folder
            loadFilesFromURL(url)
            
            connectionState = .connected
            currentPath = folder.name
            pathHistory = []
            
            // Stop accessing the security-scoped resource (not needed on iOS)
            // url.stopAccessingSecurityScopedResource()
            
        } catch {
            connectionState = .error("Unable to access folder: \(error.localizedDescription)")
        }
    }
    
    private func loadFilesFromURL(_ url: URL) {
        do {
            let fileManager = FileManager.default
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
            
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
    
    func navigateToPath(_ path: String) {
        if path != currentPath && !pathHistory.contains(currentPath) && !currentPath.isEmpty {
            pathHistory.append(currentPath)
        }
        
        currentPath = path
        
        if isLocalMode {
            // Local files will be handled by document picker
            return
        }
        
        // Load files for the given path
        if let files = demoDirectories[path] {
            currentFiles = files
        } else {
            currentFiles = []
        }
    }
    
    func navigateBack() {
        guard !pathHistory.isEmpty else { return }
        
        let previousPath = pathHistory.removeLast()
        currentPath = previousPath
        
        if let files = demoDirectories[previousPath] {
            currentFiles = files
        }
    }
    
    func canNavigateBack() -> Bool {
        return !pathHistory.isEmpty
    }
    
    func readTextFile(at path: String, completion: @escaping (Result<String, Error>) -> Void) {
        // Simulate different text content based on file name
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        
        let sampleTexts = [
            "Sample Song.txt": """
            🎵 Sample Song Lyrics 🎵
            
            Verse 1:
            This is just a sample song
            Playing in our media app
            With independent speed control
            And pitch that stays intact
            
            Chorus:
            Samba networks all around
            Music flowing, crystal sound
            Browse folders, save your servers
            Like KODI but much better
            """,
            
            "Favorite Song.txt": """
            🎶 My Favorite Song 🎶
            
            This song means everything to me
            Every note, every harmony
            When I'm feeling down and blue
            This melody will see me through
            
            Bridge:
            Music has the power to heal
            Every emotion that I feel
            In this digital age we live
            Apps like this help music give
            """,
            
            "Tech Talk Episode 1.txt": """
            📻 Tech Talk Episode 1 - Transcript
            
            Host: Welcome to Tech Talk, the podcast where we dive deep into the latest technology trends.
            
            Today we're discussing audio streaming protocols and how modern apps handle network file systems.
            
            Guest: Thanks for having me. SMB/CIFS has been around since the 80s, but it's still incredibly relevant for home and enterprise file sharing.
            
            Host: Absolutely. What makes it particularly interesting for media streaming?
            
            Guest: Well, unlike HTTP streaming, SMB allows you to browse entire directory structures and access files as if they were local. This is perfect for apps like SambaPlay that need to navigate music libraries.
            
            [Conversation continues...]
            
            Key Points:
            - SMB protocol advantages for media streaming
            - Directory browsing capabilities
            - Authentication and security considerations
            - Performance optimizations for audio
            """,
            
            "Podcast Notes.txt": """
            📝 Podcast Production Notes
            
            Episode Planning:
            
            1. Research Topics
               - Audio codec comparisons
               - Network streaming protocols
               - Mobile app development
            
            2. Guest List
               - Audio engineers
               - iOS developers
               - Network specialists
            
            3. Equipment Setup
               - Professional microphones
               - Audio interface
               - Recording software
               - Backup systems
            
            4. Post-Production
               - Noise reduction
               - Level adjustment
               - Export formats
               - Distribution
            
            Recording Tips:
            - Test audio levels before starting
            - Record room tone for editing
            - Use consistent microphone distance
            - Monitor for background noise
            """,
            
            "README.txt": """
            📋 SambaPlay Documentation
            
            Welcome to SambaPlay - Advanced Audio Streaming for iOS
            
            FEATURES:
            =========
            ✓ Independent speed control (0.5x - 3.0x)
            ✓ Independent pitch adjustment (±6 semitones)
            ✓ Samba/SMB network file browsing
            ✓ Local file support via document picker
            ✓ Lyrics and subtitle display
            ✓ Professional audio processing
            
            SETUP:
            ======
            1. Connect to your Samba server
            2. Browse to your audio files
            3. Tap to play and enjoy advanced controls
            
            NETWORK SETUP:
            ==============
            - Server: Your NAS or computer IP
            - Port: Usually 445 (SMB) or 139 (NetBIOS)
            - Credentials: Username/password if required
            
            SUPPORTED FORMATS:
            ==================
            Audio: MP3, M4A, WAV, AAC, FLAC, OGG, WMA, AIFF, OPUS
            Text: TXT, LRC, SRT, LYRICS, MD
            
            For more information, visit the project repository.
            """,
            
            "Song List.txt": """
            🎵 Current Playlist
            
            ROCK COLLECTION:
            ================
            1. Rock Anthem.mp3 (4:32)
            2. Guitar Solo.wav (3:45)
            3. Heavy Metal Thunder.mp3 (5:12)
            4. Classic Rock Ballad.flac (6:23)
            
            JAZZ COLLECTION:
            ================
            1. Smooth Jazz.mp3 (4:15)
            2. Piano Improvisation.flac (7:45)
            3. Saxophone Dreams.mp3 (5:33)
            4. Late Night Blues.wav (4:58)
            
            PODCAST EPISODES:
            =================
            1. Tech Talk Episode 1.mp3 (45:12)
            2. Music Podcast.m4a (38:45)
            3. Developer Stories.mp3 (52:33)
            4. Audio Engineering Tips.m4a (41:18)
            
            FAVORITES:
            ==========
            ⭐ Sample Song.mp3 (3:42)
            ⭐ Favorite Song.mp3 (4:18)
            ⭐ Best of Jazz Collection.flac (Multiple)
            
            Total: 47 tracks, 4.2 GB
            """,
            
            "Album Notes.md": """
            # 🎼 Album Production Notes
            
            ## Recording Session Details
            
            **Studio:** Abbey Road Studios, London  
            **Producer:** John Smith  
            **Engineer:** Sarah Johnson  
            **Dates:** March 15-25, 2024  
            
            ## Track Information
            
            ### Track 1: Opening Theme
            - **Duration:** 3:42
            - **Key:** C Major
            - **BPM:** 120
            - **Instruments:** Piano, Strings, Light Percussion
            
            ### Track 2: Melodic Journey
            - **Duration:** 4:18
            - **Key:** G Minor
            - **BPM:** 95
            - **Instruments:** Guitar, Bass, Drums, Vocals
            
            ## Technical Notes
            
            - **Sample Rate:** 96kHz/24-bit
            - **Microphones:** Neumann U87, AKG C414
            - **Preamps:** Neve 1073, API 512c
            - **DAW:** Pro Tools 2024
            
            ## Post-Production
            
            1. **Editing:** Logic Pro X
            2. **Mixing:** Analog console + plugins
            3. **Mastering:** Ozone 10 Advanced
            4. **Final Format:** Multiple (FLAC, MP3, AAC)
            
            ## Credits
            
            - Lead Vocals: Artist Name
            - Guitar: Session Musician 1
            - Bass: Session Musician 2
            - Drums: Session Musician 3
            - Strings arranged by: Orchestra Conductor
            
            *Special thanks to the entire production team.*
            """,
            
            "default": """
            📝 Text File Content
            
            This is a sample text file that can be viewed in SambaPlay's built-in text viewer.
            
            Features of the text viewer:
            - Full-screen reading experience
            - Adjustable text size
            - Support for various text formats
            - Independent of audio playback
            
            You can view lyrics, notes, documentation, or any other text content while your music continues playing in the background.
            
            The text viewer supports:
            - Plain text files (.txt)
            - Markdown files (.md)
            - Lyrics files (.lrc)
            - Subtitle files (.srt)
            - And other text formats
            """
        ]
        
        let text = sampleTexts[fileName] ?? sampleTexts["default"]!
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            completion(.success(text))
        }
    }
    
    // MARK: - Lyrics Search Support
    func searchInTextFiles(query: String, completion: @escaping (Result<[MediaFile], Error>) -> Void) {
        print("🎵 [NetworkService] Searching for '\(query)' in text files...")
        
        // Get all text files from current directory
        let textFiles = currentFiles.filter { $0.isTextFile }
        print("🎵 [NetworkService] Found \(textFiles.count) text files to search")
        
        var matchingFiles: [MediaFile] = []
        let dispatchGroup = DispatchGroup()
        
        for file in textFiles {
            dispatchGroup.enter()
            readTextFile(at: file.path) { result in
                switch result {
                case .success(let content):
                    if content.localizedCaseInsensitiveContains(query) {
                        print("🎵 [NetworkService] Found match in: \(file.name)")
                        matchingFiles.append(file)
                    }
                case .failure(let error):
                    print("❌ [NetworkService] Failed to read \(file.name): \(error)")
                }
                dispatchGroup.leave()
            }
        }
        
        dispatchGroup.notify(queue: .main) {
            print("🎵 [NetworkService] Lyrics search completed - found \(matchingFiles.count) matches")
            completion(.success(matchingFiles))
        }
    }
}

// MARK: - Enhanced Audio Player  
class SimpleAudioPlayer: NSObject, ObservableObject {
    @Published var playerState: AudioPlayerState = .stopped
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 180 // Demo duration
    @Published var speed: Float = 1.0
    @Published var pitch: Float = 1.0
    @Published var currentFile: MediaFile?
    @Published var subtitle: String?
    @Published var hasRestoredPosition: Bool = false // Indicates if position was restored from memory
    @Published var audioFormat: AudioFormat = .unknown
    @Published var isLossless: Bool = false
    @Published var downloadProgress: Float = 0.0
    
    private var audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var timePitchNode = AVAudioUnitTimePitch()
    private var variableSpeedNode = AVAudioUnitVarispeed()
    private var displayLink: CADisplayLink?
    private var startTime: Date?
    private weak var networkService: SimpleNetworkService?
    private weak var coordinator: SambaPlayCoordinator?
    
    // Progressive download support
    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    private var tempFileURL: URL?
    private var expectedContentLength: Int64 = 0
    
    // Gapless playback support
    private var nextPlayerNode: AVAudioPlayerNode?
    private var nextAudioFile: AVAudioFile?
    private var crossfadeEnabled: Bool = true
    private var crossfadeDuration: TimeInterval = 2.0
    
    // Real audio file tracking - REBUILT FOR PROPER SEEKING
    private var audioFile: AVAudioFile?
    private var seekPosition: TimeInterval = 0  // Current seek position
    private var playbackStartTime: Date?        // When playback started
    private var lastKnownTime: TimeInterval = 0 // Last accurate time measurement
    private var isSeekPending: Bool = false     // Flag to prevent time updates during seek
    
    func setNetworkService(_ service: SimpleNetworkService) {
        self.networkService = service
    }
    
    func setCoordinator(_ coordinator: SambaPlayCoordinator) {
        self.coordinator = coordinator
    }
    
    // MARK: - Haptic Feedback
    private func triggerHapticFeedback(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard coordinator?.settings.isHapticsEnabled == true else {
            print("📳 [Haptics] Haptic feedback disabled in settings")
            return
        }
        
        print("📳 [Haptics] Triggering \(style) haptic feedback")
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
    
    override init() {
        super.init()
        setupAudioEngine()
        setupDisplayLink()
    }
    
    private func setupAudioEngine() {
        audioEngine.attach(playerNode)
        audioEngine.attach(timePitchNode)
        audioEngine.attach(variableSpeedNode)
        
        audioEngine.connect(playerNode, to: timePitchNode, format: nil)
        audioEngine.connect(timePitchNode, to: variableSpeedNode, format: nil)
        audioEngine.connect(variableSpeedNode, to: audioEngine.mainMixerNode, format: nil)
        
        do {
            try audioEngine.start()
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }
    
    private func setupDisplayLink() {
        displayLink = CADisplayLink(target: self, selector: #selector(updateTime))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    @objc private func updateTime() {
        guard playerState == .playing, !isSeekPending else { 
            print("🔄 [AudioPlayer] Skipping time update - state: \(playerState), seekPending: \(isSeekPending)")
            return 
        }
        
        print("⏱️ [AudioPlayer] Updating time - file: \(currentFile?.name ?? "none")")
        
        if let file = currentFile, file.name == "Sample Song.mp3" {
            // For real audio files, use enhanced time tracking
            updateRealAudioTime()
        } else {
            // For demo files, use timing-based approach
            guard let startTime = startTime else { 
                print("⚠️ [AudioPlayer] No start time set for demo file")
                return 
            }
            let elapsed = Date().timeIntervalSince(startTime) * Double(speed)
            let newTime = min(elapsed, duration)
            currentTime = newTime
            print("📊 [AudioPlayer] Demo file time: \(currentTime)s / \(duration)s")
        }
        
        // Periodically save position every 10 seconds during playback
        if Int(currentTime) % 10 == 0 && Int(currentTime) > 0 {
            saveCurrentPosition()
        }
        
        if currentTime >= duration {
            print("🏁 [AudioPlayer] Reached end of track")
            // When reaching the end, clear the saved position
            if let file = currentFile {
                networkService?.clearSavedPosition(for: file)
            }
            
            // Handle track completion with queue advancement
            handleTrackCompletion()
        }
    }
    
    private func updateRealAudioTime() {
        guard let audioFile = audioFile,
              let playbackStartTime = playbackStartTime,
              playerNode.isPlaying else { 
            print("⚠️ [AudioPlayer] Cannot update real audio time - missing components")
            return 
        }
        
        // Calculate elapsed time since playback started
        let elapsedTime = Date().timeIntervalSince(playbackStartTime) * Double(speed)
        
        // Add elapsed time to our seek position
        let newCurrentTime = seekPosition + elapsedTime
        
        // Ensure we don't exceed the duration
        currentTime = min(newCurrentTime, duration)
        
        // Update last known time for accuracy
        lastKnownTime = currentTime
        
        // Debug logging every 5 seconds
        let currentTimeInt = Int(currentTime)
        if currentTimeInt % 5 == 0 && currentTimeInt != Int(lastKnownTime) {
            print("📊 [AudioPlayer] Real audio time: \(String(format: "%.2f", currentTime))s (seek: \(String(format: "%.2f", seekPosition))s, elapsed: \(String(format: "%.2f", elapsedTime))s)")
        }
    }
    
    private func saveCurrentPosition() {
        guard let file = currentFile, let networkService = networkService else { return }
        networkService.savePlaybackPosition(for: file, position: currentTime, duration: duration)
    }
    
    func loadFile(_ file: MediaFile, completion: @escaping (Result<Void, Error>) -> Void) {
        print("📂 [AudioPlayer] Loading file: \(file.name)")
        currentFile = file
        playerState = .stopped
        hasRestoredPosition = false
        audioFormat = file.audioFormat
        isLossless = file.audioFormat.isLossless
        downloadProgress = 0.0
        
        // Cancel any existing download
        downloadTask?.cancel()
        
        // Always start from beginning - no automatic position restoration
        currentTime = 0
        seekPosition = 0
        lastKnownTime = 0
        playbackStartTime = nil
        isSeekPending = false
        
        // If this is the Sample Song, load the actual bundled audio file
        if file.name == "Sample Song.mp3" {
            loadLocalAudioFile(file: file) { [weak self] result in
                completion(result)
                
                // Auto-play if enabled in settings
                if case .success = result, self?.coordinator?.settings.isAutoPlayEnabled == true {
                    print("▶️ [AudioPlayer] Auto-play enabled, starting playback")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self?.play()
                    }
                }
            }
        } else {
            // For demo files, simulate different audio formats
            simulateAudioFormat(for: file)
            completion(.success(()))
            
            // Auto-play if enabled in settings
            if coordinator?.settings.isAutoPlayEnabled == true {
                print("▶️ [AudioPlayer] Auto-play enabled, starting playback")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.play()
                }
            }
        }
        
        // Check for saved position and offer to restore it manually
        if let savedPosition = networkService?.getSavedPosition(for: file) {
            DispatchQueue.main.async { [weak self] in
                self?.promptForPositionRestore(savedPosition: savedPosition)
            }
        }
    }
    
    private func loadLocalAudioFile(file: MediaFile, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let audioURL = Bundle.main.url(forResource: "Sample Song", withExtension: "mp3") else {
            completion(.failure(NSError(domain: "AudioPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sample audio file not found in bundle"])))
            return
        }
        
        do {
            let newAudioFile = try AVAudioFile(forReading: audioURL)
            duration = Double(newAudioFile.length) / newAudioFile.fileFormat.sampleRate
            
            // Store the audio file for tracking
            self.audioFile = newAudioFile
            
            // Detect actual format from file
            detectAudioFormat(from: newAudioFile)
            
            // Initialize tracking variables - always start from beginning
            seekPosition = 0
            playbackStartTime = nil
            
            completion(.success(()))
            
        } catch {
            completion(.failure(error))
        }
    }
    
    
    private func detectAudioFormat(from audioFile: AVAudioFile) {
        let format = audioFile.fileFormat
        
        // Update UI with actual format information
        if format.sampleRate >= 96000 {
            isLossless = true
        }
        
        print("Audio format detected: \(format.sampleRate)Hz, \(format.channelCount) channels, \(format.commonFormat.rawValue)")
    }
    
    private func simulateAudioFormat(for file: MediaFile) {
        // Simulate different durations and characteristics for different formats
        switch file.audioFormat {
        case .flac:
            duration = 240 // FLAC files tend to be longer
            isLossless = true
        case .mp3:
            duration = 180 // Standard MP3 duration
            isLossless = false
        case .aac:
            duration = 200 // AAC files
            isLossless = false
        case .ogg:
            duration = 190 // OGG files
            isLossless = false
        case .wav:
            duration = 220 // WAV files
            isLossless = true
        default:
            duration = 180
            isLossless = false
        }
    }
    
    func loadFileWithProgressiveDownload(_ file: MediaFile, from url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        currentFile = file
        playerState = .buffering
        audioFormat = file.audioFormat
        isLossless = file.audioFormat.isLossless
        downloadProgress = 0.0
        
        // Setup download session
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        config.waitsForConnectivity = true
        downloadSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        // Start progressive download
        downloadTask = downloadSession?.downloadTask(with: url)
        downloadTask?.resume()
        
        completion(.success(()))
    }
    
    func play() {
        guard let file = currentFile else { 
            print("❌ [AudioPlayer] Cannot play - no file loaded")
            return 
        }
        
        print("▶️ [AudioPlayer] Starting playback for: \(file.name) at position \(String(format: "%.2f", currentTime))s")
        triggerHapticFeedback(style: .light)
        
        do {
            if !audioEngine.isRunning {
                print("🔧 [AudioPlayer] Starting audio engine")
                try audioEngine.start()
            }
            
            if file.name == "Sample Song.mp3" {
                // For real audio file, use enhanced AVAudioPlayerNode
                playRealAudioFile()
            } else {
                // For demo files, use timing-based playback
                if playerState == .paused {
                    print("▶️ [AudioPlayer] Resuming demo file from \(String(format: "%.2f", currentTime))s")
                    // Resume from current time
                    startTime = Date().addingTimeInterval(-currentTime / Double(speed))
                } else {
                    print("▶️ [AudioPlayer] Starting demo file from \(String(format: "%.2f", currentTime))s")
                    // Start from beginning or current seek position
                    startTime = Date().addingTimeInterval(-currentTime / Double(speed))
                }
            }
            
            playerState = .playing
            print("✅ [AudioPlayer] Playback started successfully - state: \(playerState)")
        } catch {
            print("❌ [AudioPlayer] Failed to start audio engine: \(error)")
            playerState = .error(error.localizedDescription)
        }
    }
    
    private func playRealAudioFile() {
        guard let audioURL = Bundle.main.url(forResource: "Sample Song", withExtension: "mp3") else { 
            print("❌ [AudioPlayer] Sample Song.mp3 not found in bundle")
            return 
        }
        
        print("🎵 [AudioPlayer] Playing real audio file from position \(String(format: "%.2f", currentTime))s")
        
        do {
            // Always stop current playback first
            if playerNode.isPlaying {
                print("🛑 [AudioPlayer] Stopping current playback")
                playerNode.stop()
            }
            
            // Create new audio file instance for clean state
            let newAudioFile = try AVAudioFile(forReading: audioURL)
            let sampleRate = newAudioFile.fileFormat.sampleRate
            let totalFrames = newAudioFile.length
            
            // Calculate the frame position to start from
            let startFrame = AVAudioFramePosition(currentTime * sampleRate)
            
            print("📊 [AudioPlayer] Audio file info - sampleRate: \(sampleRate), totalFrames: \(totalFrames), startFrame: \(startFrame)")
            
            if startFrame >= 0 && startFrame < totalFrames {
                // Store the audio file and seek position
                self.audioFile = newAudioFile
                self.seekPosition = currentTime
                self.playbackStartTime = Date()
                
                // Create a segment of the audio file from the current position
                let framesToPlay = totalFrames - startFrame
                
                // Read the audio buffer from the desired position
                let frameCount = AVAudioFrameCount(min(framesToPlay, 1024 * 1024)) // Read in chunks
                guard let buffer = AVAudioPCMBuffer(pcmFormat: newAudioFile.processingFormat, frameCapacity: frameCount) else {
                    print("❌ [AudioPlayer] Failed to create audio buffer")
                    return
                }
                
                // Set file position and read
                newAudioFile.framePosition = startFrame
                try newAudioFile.read(into: buffer)
                
                print("📖 [AudioPlayer] Read \(buffer.frameLength) frames from position \(startFrame)")
                
                // Schedule the buffer for playback
                playerNode.scheduleBuffer(buffer, at: nil) { [weak self] in
                    DispatchQueue.main.async {
                        print("🔚 [AudioPlayer] Audio buffer finished playing")
                        if self?.playerState == .playing {
                            // Schedule next buffer if still playing
                            self?.scheduleNextBuffer()
                        }
                    }
                }
                
                // Start playback
                playerNode.play()
                print("✅ [AudioPlayer] Started real audio playback from \(String(format: "%.2f", currentTime))s")
                
            } else {
                print("❌ [AudioPlayer] Invalid start frame: \(startFrame) (total: \(totalFrames))")
            }
        } catch {
            print("❌ [AudioPlayer] Failed to play real audio file: \(error)")
            // Fallback to timing-based playback
            startTime = Date().addingTimeInterval(-currentTime / Double(speed))
        }
    }
    
    private func scheduleNextBuffer() {
        guard let audioFile = audioFile,
              playerState == .playing,
              currentTime < duration else { 
            print("🔚 [AudioPlayer] No more buffers to schedule")
            return 
        }
        
        do {
            let sampleRate = audioFile.fileFormat.sampleRate
            let currentFrame = AVAudioFramePosition(currentTime * sampleRate)
            let totalFrames = audioFile.length
            let framesToPlay = totalFrames - currentFrame
            
            if framesToPlay > 0 {
                let frameCount = AVAudioFrameCount(min(framesToPlay, 1024 * 1024))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else { return }
                
                audioFile.framePosition = currentFrame
                try audioFile.read(into: buffer)
                
                playerNode.scheduleBuffer(buffer, at: nil) { [weak self] in
                    DispatchQueue.main.async {
                        if self?.playerState == .playing {
                            self?.scheduleNextBuffer()
                        }
                    }
                }
                
                print("📖 [AudioPlayer] Scheduled next buffer: \(buffer.frameLength) frames from \(currentFrame)")
            }
        } catch {
            print("❌ [AudioPlayer] Failed to schedule next buffer: \(error)")
        }
    }
    
    func pause() {
        print("⏸️ [AudioPlayer] Pausing playback at \(String(format: "%.2f", currentTime))s")
        triggerHapticFeedback(style: .light)
        
        if let file = currentFile, file.name == "Sample Song.mp3" {
            if playerNode.isPlaying {
                playerNode.pause()
                print("⏸️ [AudioPlayer] Paused real audio node")
            } else {
                print("⚠️ [AudioPlayer] Player node was not playing")
            }
        }
        
        playerState = .paused
        
        // Save current position when pausing
        saveCurrentPosition()
        print("✅ [AudioPlayer] Audio paused at \(String(format: "%.2f", currentTime))s, state: \(playerState)")
    }
    
    func stop() {
        if let file = currentFile, file.name == "Sample Song.mp3" {
            playerNode.stop()
        }
        
        // Save current position before stopping (unless user manually stopped at beginning)
        if currentTime > 5.0 {
            saveCurrentPosition()
        }
        
        playerState = .stopped
        currentTime = 0
        startTime = nil
        hasRestoredPosition = false
    }
    
    func seek(to time: TimeInterval) {
        let clampedTime = max(0, min(time, duration))
        print("🔄 [AudioPlayer] SEEKING from \(String(format: "%.2f", currentTime))s to \(String(format: "%.2f", clampedTime))s")
        triggerHapticFeedback(style: .medium)
        
        // Set seek pending flag to prevent time updates during seek
        isSeekPending = true
        
        // Store the previous state
        let wasPlaying = playerState == .playing
        
        // Update current time immediately
        currentTime = clampedTime
        lastKnownTime = clampedTime
        
        // Handle real audio file seeking
        if let file = currentFile, file.name == "Sample Song.mp3" {
            seekRealAudioFile(to: clampedTime, wasPlaying: wasPlaying)
        } else {
            // For demo files, just update the timing
            if wasPlaying {
                print("🔄 [AudioPlayer] Updating demo file timing for seek")
                startTime = Date().addingTimeInterval(-clampedTime / Double(speed))
            }
        }
        
        // Clear seek pending flag
        isSeekPending = false
        
        print("✅ [AudioPlayer] Seek completed to \(String(format: "%.2f", clampedTime))s, wasPlaying: \(wasPlaying)")
    }
    
    private func seekRealAudioFile(to time: TimeInterval, wasPlaying: Bool) {
        guard let audioURL = Bundle.main.url(forResource: "Sample Song", withExtension: "mp3") else { 
            print("❌ [AudioPlayer] Sample Song.mp3 not found for seeking")
            return 
        }
        
        print("🎯 [AudioPlayer] Seeking real audio file to \(String(format: "%.2f", time))s, wasPlaying: \(wasPlaying)")
        
        do {
            // Always stop current playback first
            if playerNode.isPlaying {
                print("🛑 [AudioPlayer] Stopping playback for seek")
                playerNode.stop()
            }
            
            // Create fresh audio file instance
            let newAudioFile = try AVAudioFile(forReading: audioURL)
            let sampleRate = newAudioFile.fileFormat.sampleRate
            let totalFrames = newAudioFile.length
            
            // Calculate the frame position to seek to
            let targetFrame = AVAudioFramePosition(time * sampleRate)
            
            print("🎯 [AudioPlayer] Seek calculation - time: \(String(format: "%.2f", time))s, targetFrame: \(targetFrame), totalFrames: \(totalFrames)")
            
            if targetFrame >= 0 && targetFrame < totalFrames {
                // Store the new audio file and seek position
                self.audioFile = newAudioFile
                self.seekPosition = time
                
                // If we were playing, restart playback from the new position
                if wasPlaying {
                    print("▶️ [AudioPlayer] Restarting playback from seek position")
                    self.playbackStartTime = Date()
                    
                    // Schedule buffer from new position
                    let framesToPlay = totalFrames - targetFrame
                    let frameCount = AVAudioFrameCount(min(framesToPlay, 1024 * 1024))
                    
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: newAudioFile.processingFormat, frameCapacity: frameCount) else {
                        print("❌ [AudioPlayer] Failed to create seek buffer")
                        return
                    }
                    
                    // Read from the target position
                    newAudioFile.framePosition = targetFrame
                    try newAudioFile.read(into: buffer)
                    
                    // Schedule and play the buffer
                    playerNode.scheduleBuffer(buffer, at: nil) { [weak self] in
                        DispatchQueue.main.async {
                            if self?.playerState == .playing {
                                self?.scheduleNextBuffer()
                            }
                        }
                    }
                    
                    playerNode.play()
                    playerState = .playing
                    print("✅ [AudioPlayer] Resumed playback from \(String(format: "%.2f", time))s after seeking")
                } else {
                    // Just update position, don't start playback
                    self.playbackStartTime = nil
                    playerState = .paused
                    print("✅ [AudioPlayer] Seeked to \(String(format: "%.2f", time))s, ready for play")
                }
            } else {
                print("❌ [AudioPlayer] Invalid seek frame: \(targetFrame) (total: \(totalFrames))")
            }
        } catch {
            print("❌ [AudioPlayer] Failed to seek audio file: \(error)")
            // Fallback to time-based seeking for demo files
            if wasPlaying {
                startTime = Date().addingTimeInterval(-currentTime / Double(speed))
            }
        }
    }
    
    func setSpeed(_ speed: Float) {
        self.speed = speed
        if let file = currentFile, file.name == "Sample Song.mp3" {
            // For real audio file, update variableSpeedNode
            variableSpeedNode.rate = speed
        }
    }
    
    func setPitch(_ pitch: Float) {
        self.pitch = pitch
        if let file = currentFile, file.name == "Sample Song.mp3" {
            // For real audio file, update timePitchNode pitch (in semitones)
            let semitones = (pitch - 1.0) * 12.0
            timePitchNode.pitch = semitones * 100.0 // AVAudioUnitTimePitch expects cents (1/100th of semitone)
        }
    }
    
    // MARK: - Gapless Playback
    func prepareNextFile(_ file: MediaFile) {
        guard crossfadeEnabled else { return }
        
        // Prepare next audio file for gapless playback
        if file.name == "Sample Song.mp3" {
            guard let audioURL = Bundle.main.url(forResource: "Sample Song", withExtension: "mp3") else { return }
            
            do {
                nextAudioFile = try AVAudioFile(forReading: audioURL)
                
                // Create and configure next player node
                nextPlayerNode = AVAudioPlayerNode()
                guard let nextNode = nextPlayerNode, let nextFile = nextAudioFile else { return }
                
                audioEngine.attach(nextNode)
                audioEngine.connect(nextNode, to: audioEngine.mainMixerNode, format: nextFile.processingFormat)
                
                // Schedule the next file
                nextNode.scheduleFile(nextFile, at: nil)
                
            } catch {
                print("Failed to prepare next file: \(error)")
            }
        }
    }
    
    func crossfadeToNextFile() {
        guard crossfadeEnabled,
              let nextNode = nextPlayerNode,
              let nextFile = nextAudioFile else { return }
        
        // Start crossfade
        let fadeOutTime = AVAudioTime(hostTime: mach_absolute_time() + UInt64(0.1 * Double(NSEC_PER_SEC)))
        let fadeInTime = AVAudioTime(hostTime: mach_absolute_time() + UInt64(0.1 * Double(NSEC_PER_SEC)))
        
        // Fade out current player
        playerNode.volume = 0.0
        
        // Fade in next player
        nextNode.volume = 1.0
        nextNode.play(at: fadeInTime)
        
        // Swap nodes
        let tempNode = playerNode
        playerNode = nextNode
        nextPlayerNode = tempNode
        
        // Update duration for new file
        duration = Double(nextFile.length) / nextFile.fileFormat.sampleRate
        currentTime = 0
        
        // Clean up old node
        tempNode.stop()
        audioEngine.detach(tempNode)
    }
    
    func setCrossfadeEnabled(_ enabled: Bool) {
        crossfadeEnabled = enabled
    }
    
    func setCrossfadeDuration(_ duration: TimeInterval) {
        crossfadeDuration = max(0.5, min(5.0, duration)) // Limit between 0.5 and 5 seconds
    }
    
    // Method to prompt user for position restoration
    private func promptForPositionRestore(savedPosition: PlaybackPosition) {
        let currentMinutes = Int(savedPosition.position) / 60
        let currentSeconds = Int(savedPosition.position) % 60
        let progressPercent = Int(savedPosition.progressPercentage)
        
        let alert = UIAlertController(
            title: "Resume Playback",
            message: "You previously stopped at \(currentMinutes):\(String(format: "%02d", currentSeconds)) (\(progressPercent)% complete). Would you like to resume from that position?",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Resume", style: .default) { [weak self] _ in
            self?.restorePosition(savedPosition.position)
        })
        
        alert.addAction(UIAlertAction(title: "Start Over", style: .cancel) { [weak self] _ in
            // Clear the saved position since user chose to start over
            if let file = self?.currentFile {
                self?.networkService?.clearSavedPosition(for: file)
            }
        })
        
        // Present the alert from the main view controller
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {
            rootViewController.present(alert, animated: true)
        }
    }
    
    private func restorePosition(_ position: TimeInterval) {
        print("🔄 [AudioPlayer] Manually restoring position to \(String(format: "%.2f", position))s")
        currentTime = position
        seekPosition = position
        lastKnownTime = position
        hasRestoredPosition = true
        
        print("✅ [AudioPlayer] Position restored to \(String(format: "%.2f", position))s")
    }
    
    // MARK: - Queue Integration
    private func handleTrackCompletion() {
        print("🎵 [AudioPlayer] Handling track completion")
        
        guard let coordinator = coordinator else {
            print("⚠️ [AudioPlayer] No coordinator available for queue advancement")
            stop()
            return
        }
        
        // Check if there's a next track in the queue
        if let nextTrack = coordinator.playbackQueue.advanceToNext() {
            print("🎵 [AudioPlayer] Advancing to next track: \(nextTrack.name)")
            
            // Load and play the next track
            loadFile(nextTrack) { [weak self] result in
                switch result {
                case .success:
                    print("✅ [AudioPlayer] Next track loaded successfully")
                    self?.play()
                    
                    // Save queue state
                    coordinator.playbackQueue.saveToUserDefaults()
                    
                case .failure(let error):
                    print("❌ [AudioPlayer] Failed to load next track: \(error.localizedDescription)")
                    self?.stop()
                }
            }
        } else {
            print("🏁 [AudioPlayer] No more tracks in queue, stopping playback")
            stop()
        }
    }
    
    func playNext() {
        guard let coordinator = coordinator else { return }
        
        if let nextTrack = coordinator.playbackQueue.advanceToNext() {
            print("⏭️ [AudioPlayer] Manually skipping to next track: \(nextTrack.name)")
            
            loadFile(nextTrack) { [weak self] result in
                switch result {
                case .success:
                    self?.play()
                    coordinator.playbackQueue.saveToUserDefaults()
                case .failure(let error):
                    print("❌ [AudioPlayer] Failed to load next track: \(error.localizedDescription)")
                }
            }
        } else {
            print("⚠️ [AudioPlayer] No next track available")
        }
    }
    
    func playPrevious() {
        guard let coordinator = coordinator else { return }
        
        // If we're more than 3 seconds into the track, restart current track
        if currentTime > 3.0 {
            print("🔄 [AudioPlayer] Restarting current track")
            seek(to: 0)
            return
        }
        
        if let previousTrack = coordinator.playbackQueue.goToPrevious() {
            print("⏮️ [AudioPlayer] Going to previous track: \(previousTrack.name)")
            
            loadFile(previousTrack) { [weak self] result in
                switch result {
                case .success:
                    self?.play()
                    coordinator.playbackQueue.saveToUserDefaults()
                case .failure(let error):
                    print("❌ [AudioPlayer] Failed to load previous track: \(error.localizedDescription)")
                }
            }
        } else {
            print("🔄 [AudioPlayer] No previous track, restarting current track")
            seek(to: 0)
        }
    }
}

// MARK: - URLSession Download Delegate
extension SimpleAudioPlayer: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Move downloaded file to temp location
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        do {
            try FileManager.default.moveItem(at: location, to: tempURL)
            tempFileURL = tempURL
            
            DispatchQueue.main.async { [weak self] in
                self?.downloadProgress = 1.0
                self?.loadDownloadedFile()
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.playerState = .error("Download failed: \(error.localizedDescription)")
            }
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        expectedContentLength = totalBytesExpectedToWrite
        let progress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
        
        DispatchQueue.main.async { [weak self] in
            self?.downloadProgress = progress
            
            // Start playback when we have enough data (e.g., 25%)
            if progress >= 0.25 && self?.playerState == .buffering {
                self?.startProgressivePlayback()
            }
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didCompleteWithError error: Error?) {
        if let error = error {
            DispatchQueue.main.async { [weak self] in
                self?.playerState = .error("Download error: \(error.localizedDescription)")
            }
        }
    }
    
    private func loadDownloadedFile() {
        guard let tempURL = tempFileURL else { return }
        
        do {
            let audioFile = try AVAudioFile(forReading: tempURL)
            duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
            
            // Detect format from downloaded file
            detectAudioFormat(from: audioFile)
            
            // Store audio file for real audio playback
            self.audioFile = audioFile
            self.seekPosition = 0
            
            playerState = .stopped
        } catch {
            playerState = .error("Failed to read downloaded file: \(error.localizedDescription)")
        }
    }
    
    private func loadAudioFileIntoEngine(_ audioFile: AVAudioFile, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            // Store audio file for real audio playback
            self.audioFile = audioFile
            self.seekPosition = 0
            
            // Schedule the file on the player node
            playerNode.scheduleFile(audioFile, at: nil) {
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            }
        } catch {
            DispatchQueue.main.async {
                completion(.failure(error))
            }
        }
    }
    
    private func startProgressivePlayback() {
        guard let tempURL = tempFileURL else { return }
        
        // Start playback with partial file
        do {
            let audioFile = try AVAudioFile(forReading: tempURL)
            playerNode.scheduleFile(audioFile, at: nil)
            playerState = .playing
            startTime = Date()
        } catch {
            playerState = .error("Failed to start progressive playback: \(error.localizedDescription)")
        }
    }
}

// MARK: - Main App Coordinator
class SambaPlayCoordinator {
    static let shared = SambaPlayCoordinator()
    
    let networkService = SimpleNetworkService()
    let audioPlayer = SimpleAudioPlayer()
    let settings = AppSettings.shared
    let playbackQueue = PlaybackQueue()
    let memoryManager = MemoryManager.shared
    let imageCache = ImageCacheManager.shared
    let backgroundProcessor = BackgroundProcessingManager.shared
    let virtualScrollManager = VirtualScrollingManager()
    let performanceMetrics = PerformanceMetrics.shared
    
    private init() {
        // Connect the audio player with the network service for position memory
        audioPlayer.setNetworkService(networkService)
        audioPlayer.setCoordinator(self)
        
        // Load saved queue on startup
        playbackQueue.loadFromUserDefaults()
        
        // Setup memory management
        setupMemoryManagement()
    }
    
    private func setupMemoryManagement() {
        // Monitor cache effectiveness
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.updatePerformanceMetrics()
        }
    }
    
    private func updatePerformanceMetrics() {
        let cacheEffectiveness = imageCache.cacheHitRate
        let memoryEfficiency = 1.0 - memoryManager.memoryUsage
        
        performanceMetrics.updateCacheEffectiveness(cacheEffectiveness)
        performanceMetrics.updateMemoryEfficiency(memoryEfficiency)
    }
    
    func createMainViewController() -> UIViewController {
        return MainViewController(coordinator: self)
    }
}

// MARK: - Main View Controller
class MainViewController: UIViewController {
    private let coordinator: SambaPlayCoordinator
    private var cancellables = Set<AnyCancellable>()
    
    // UI Components
    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.delegate = self
        table.dataSource = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "FileCell")
        return table
    }()
    
    private lazy var connectionStatusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .systemBlue
        label.accessibilityLabel = "Connection status"
        label.accessibilityTraits = .staticText
        return label
    }()
    
    private lazy var pathLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.accessibilityLabel = "Current directory path"
        label.accessibilityTraits = .staticText
        return label
    }()
    
    private lazy var backButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("← Back", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addTarget(self, action: #selector(navigateBack), for: .touchUpInside)
        button.isHidden = true
        button.accessibilityLabel = "Navigate back to previous directory"
        button.accessibilityTraits = .button
        button.accessibilityHint = "Double tap to go back one level in the directory structure"
        return button
    }()
    
    private lazy var sourceHistoryContainerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 12
        view.isHidden = true // Initially hidden until we have recent sources
        return view
    }()
    
    private lazy var sourceHistoryLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Recent Sources"
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabel
        return label
    }()
    
    private lazy var sourceHistoryScrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        return scrollView
    }()
    
    private lazy var sourceHistoryStackView: UIStackView = {
        let stackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.spacing = 12
        stackView.alignment = .fill
        stackView.distribution = .fillProportionally
        return stackView
    }()
    
    // MARK: - Enhanced Now Playing Section
    
    private lazy var nowPlayingContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 12
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.separator.cgColor
        view.isHidden = true // Initially hidden
        return view
    }()
    
    private lazy var nowPlayingContentView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    private lazy var trackTitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .label
        label.text = "No Track"
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()
    
    private lazy var nowPlayingSkipBackButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "gobackward.15", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)), for: .normal)
        button.addTarget(self, action: #selector(nowPlayingSkipBackTapped), for: .touchUpInside)
        button.accessibilityLabel = "Skip back 15 seconds"
        button.accessibilityTraits = .button
        button.tintColor = .systemBlue
        return button
    }()
    
    private lazy var nowPlayingPlayPauseButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), for: .normal)
        button.addTarget(self, action: #selector(nowPlayingPlayPauseTapped), for: .touchUpInside)
        button.accessibilityLabel = "Play"
        button.accessibilityTraits = .button
        button.tintColor = .systemBlue
        return button
    }()
    
    private lazy var nowPlayingSkipForwardButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "goforward.30", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)), for: .normal)
        button.addTarget(self, action: #selector(nowPlayingSkipForwardTapped), for: .touchUpInside)
        button.accessibilityLabel = "Skip forward 30 seconds"
        button.accessibilityTraits = .button
        button.tintColor = .systemBlue
        return button
    }()
    
    private lazy var nowPlayingChevronButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "chevron.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)), for: .normal)
        button.addTarget(self, action: #selector(showNowPlaying), for: .touchUpInside)
        button.accessibilityLabel = "Show full now playing"
        button.accessibilityTraits = .button
        button.tintColor = .systemGray
        return button
    }()
    
    private lazy var nowPlayingProgressView: UIProgressView = {
        let progressView = UIProgressView(progressViewStyle: .default)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = .systemBlue
        progressView.trackTintColor = .systemGray4
        progressView.progress = 0.0
        return progressView
    }()
    
    private lazy var nowPlayingTimeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabel
        label.text = "0:00 / 0:00"
        label.textAlignment = .center
        return label
    }()
    
    private var currentFiles: [MediaFile] = []
    private var allFiles: [MediaFile] = [] // Store all files for search filtering
    private var isSearching = false
    private var isLyricsSearching = false // Track if currently searching lyrics
    private var loadedCells: Set<Int> = [] // Track which cells have been loaded for virtual scrolling
    private var cellImageCache: [String: UIImage] = [:] // Local image cache for cells
    
    init(coordinator: SambaPlayCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupBindings()
        setupDragAndDrop()
        setupSettingsObserver()
        setupMemoryMonitoring()
        connectToDemo()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Update virtual scrolling when view appears
        coordinator.virtualScrollManager.setTotalItems(currentFiles.count)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        // Clean up memory when view disappears
        cleanupMemory()
    }
    
    private func setupMemoryMonitoring() {
        // Monitor memory warnings
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }
        
        // Monitor memory cleanup requests
        NotificationCenter.default.addObserver(
            forName: .memoryCleanupRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cleanupMemory()
        }
    }
    
    private func handleMemoryWarning() {
        print("⚠️ [MainVC] Memory warning received - performing cleanup")
        cleanupMemory()
        
        // Cancel any ongoing background operations
        coordinator.backgroundProcessor.cancelAllOperations()
    }
    
    private func cleanupMemory() {
        // Clear local caches
        cellImageCache.removeAll()
        loadedCells.removeAll()
        
        // Clear global image cache
        coordinator.imageCache.clearMemoryCache()
        
        // Reload visible cells only
        if let visiblePaths = tableView.indexPathsForVisibleRows {
            tableView.reloadRows(at: visiblePaths, with: .none)
        }
        
        print("🧹 [MainVC] Memory cleanup completed")
    }
    
    private func setupSettingsObserver() {
        // Listen for settings changes to update UI dynamically
        coordinator.settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                print("⚙️ [MainVC] Settings changed, updating UI...")
                self?.updateUIForSettingsChange()
            }
            .store(in: &cancellables)
    }
    
    private func updateUIForSettingsChange() {
        // Update search controller
        if coordinator.settings.isSearchEnabled && navigationItem.searchController == nil {
            print("🔍 [MainVC] Enabling search controller")
            setupSearchController()
        } else if !coordinator.settings.isSearchEnabled && navigationItem.searchController != nil {
            print("🔍 [MainVC] Disabling search controller")
            navigationItem.searchController = nil
        } else if coordinator.settings.isSearchEnabled && navigationItem.searchController != nil {
            // Update existing search controller for lyrics search mode
            updateSearchControllerPlaceholder()
        }
        
        // Update drag and drop
        setupDragAndDrop()
        
        // Refresh search results if currently searching
        if isSearching {
            if let searchController = navigationItem.searchController {
                updateSearchResults(for: searchController)
            }
        }
    }
    
    private func setupSearchController() {
        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        updateSearchControllerPlaceholder()
        searchController.searchBar.accessibilityTraits = .searchField
        navigationItem.searchController = searchController
        definesPresentationContext = true
    }
    
    private func updateSearchControllerPlaceholder() {
        guard let searchController = navigationItem.searchController else { return }
        
        if coordinator.settings.isLyricsSearchEnabled {
            searchController.searchBar.placeholder = "Search lyrics and text content"
            searchController.searchBar.accessibilityLabel = "Search lyrics and text content"
            print("🎵 [MainVC] Search mode: LYRICS SEARCH")
        } else {
            searchController.searchBar.placeholder = "Search files and folders"
            searchController.searchBar.accessibilityLabel = "Search files and folders"
            print("🔍 [MainVC] Search mode: FILE SEARCH")
        }
    }
    
    private func setupUI() {
        title = "SambaPlay"
        view.backgroundColor = .systemBackground
        
        navigationController?.navigationBar.prefersLargeTitles = true
        
        // Setup search controller (if enabled in settings)
        if coordinator.settings.isSearchEnabled {
            print("🔍 [MainVC] Setting up search controller - search is ENABLED")
            setupSearchController()
        } else {
            print("🔍 [MainVC] Search controller disabled in settings")
            navigationItem.searchController = nil
        }
        
        // Navigation bar buttons
        let serversButton = UIBarButtonItem(
            image: UIImage(systemName: "server.rack"),
            style: .plain,
            target: self,
            action: #selector(showServers)
        )
        
        let settingsButton = UIBarButtonItem(
            image: UIImage(systemName: "gear"),
            style: .plain,
            target: self,
            action: #selector(showSettings)
        )
        
        navigationItem.rightBarButtonItems = [settingsButton, serversButton]
        
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "folder"),
            style: .plain,
            target: self,
            action: #selector(showLocalFiles)
        )
        
        view.addSubview(connectionStatusLabel)
        view.addSubview(pathLabel)
        view.addSubview(sourceHistoryContainerView)
        view.addSubview(backButton)
        view.addSubview(tableView)
        view.addSubview(nowPlayingContainer)
        
        // Setup now playing container
        nowPlayingContainer.addSubview(nowPlayingContentView)
        nowPlayingContentView.addSubview(trackTitleLabel)
        nowPlayingContentView.addSubview(nowPlayingSkipBackButton)
        nowPlayingContentView.addSubview(nowPlayingPlayPauseButton)
        nowPlayingContentView.addSubview(nowPlayingSkipForwardButton)
        nowPlayingContentView.addSubview(nowPlayingChevronButton)
        nowPlayingContainer.addSubview(nowPlayingProgressView)
        nowPlayingContainer.addSubview(nowPlayingTimeLabel)
        
        // Setup source history container
        sourceHistoryContainerView.addSubview(sourceHistoryLabel)
        sourceHistoryContainerView.addSubview(sourceHistoryScrollView)
        sourceHistoryScrollView.addSubview(sourceHistoryStackView)
        
        NSLayoutConstraint.activate([
            connectionStatusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            connectionStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            connectionStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            
            pathLabel.topAnchor.constraint(equalTo: connectionStatusLabel.bottomAnchor, constant: 4),
            pathLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            pathLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            
            sourceHistoryContainerView.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 12),
            sourceHistoryContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            sourceHistoryContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            sourceHistoryContainerView.heightAnchor.constraint(equalToConstant: 80),
            
            sourceHistoryLabel.topAnchor.constraint(equalTo: sourceHistoryContainerView.topAnchor, constant: 8),
            sourceHistoryLabel.leadingAnchor.constraint(equalTo: sourceHistoryContainerView.leadingAnchor, constant: 12),
            sourceHistoryLabel.trailingAnchor.constraint(equalTo: sourceHistoryContainerView.trailingAnchor, constant: -12),
            
            sourceHistoryScrollView.topAnchor.constraint(equalTo: sourceHistoryLabel.bottomAnchor, constant: 4),
            sourceHistoryScrollView.leadingAnchor.constraint(equalTo: sourceHistoryContainerView.leadingAnchor, constant: 12),
            sourceHistoryScrollView.trailingAnchor.constraint(equalTo: sourceHistoryContainerView.trailingAnchor, constant: -12),
            sourceHistoryScrollView.bottomAnchor.constraint(equalTo: sourceHistoryContainerView.bottomAnchor, constant: -8),
            
            sourceHistoryStackView.topAnchor.constraint(equalTo: sourceHistoryScrollView.topAnchor),
            sourceHistoryStackView.leadingAnchor.constraint(equalTo: sourceHistoryScrollView.leadingAnchor),
            sourceHistoryStackView.trailingAnchor.constraint(equalTo: sourceHistoryScrollView.trailingAnchor),
            sourceHistoryStackView.bottomAnchor.constraint(equalTo: sourceHistoryScrollView.bottomAnchor),
            sourceHistoryStackView.heightAnchor.constraint(equalTo: sourceHistoryScrollView.heightAnchor),
            
            backButton.topAnchor.constraint(equalTo: sourceHistoryContainerView.bottomAnchor, constant: 8),
            backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            backButton.heightAnchor.constraint(equalToConstant: 32),
            
            tableView.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: nowPlayingContainer.topAnchor, constant: -8),
            
            // Now Playing Container
            nowPlayingContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            nowPlayingContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            nowPlayingContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            nowPlayingContainer.heightAnchor.constraint(equalToConstant: 80),
            
            // Now Playing Content View
            nowPlayingContentView.topAnchor.constraint(equalTo: nowPlayingContainer.topAnchor, constant: 12),
            nowPlayingContentView.leadingAnchor.constraint(equalTo: nowPlayingContainer.leadingAnchor, constant: 16),
            nowPlayingContentView.trailingAnchor.constraint(equalTo: nowPlayingContainer.trailingAnchor, constant: -16),
            nowPlayingContentView.heightAnchor.constraint(equalToConstant: 32),
            
            // Track Title Label
            trackTitleLabel.leadingAnchor.constraint(equalTo: nowPlayingContentView.leadingAnchor),
            trackTitleLabel.centerYAnchor.constraint(equalTo: nowPlayingContentView.centerYAnchor),
            trackTitleLabel.trailingAnchor.constraint(equalTo: nowPlayingSkipBackButton.leadingAnchor, constant: -12),
            
            // Skip Back Button
            nowPlayingSkipBackButton.centerYAnchor.constraint(equalTo: nowPlayingContentView.centerYAnchor),
            nowPlayingSkipBackButton.trailingAnchor.constraint(equalTo: nowPlayingPlayPauseButton.leadingAnchor, constant: -8),
            nowPlayingSkipBackButton.widthAnchor.constraint(equalToConstant: 28),
            nowPlayingSkipBackButton.heightAnchor.constraint(equalToConstant: 28),
            
            // Play/Pause Button
            nowPlayingPlayPauseButton.centerYAnchor.constraint(equalTo: nowPlayingContentView.centerYAnchor),
            nowPlayingPlayPauseButton.trailingAnchor.constraint(equalTo: nowPlayingSkipForwardButton.leadingAnchor, constant: -8),
            nowPlayingPlayPauseButton.widthAnchor.constraint(equalToConstant: 32),
            nowPlayingPlayPauseButton.heightAnchor.constraint(equalToConstant: 32),
            
            // Skip Forward Button
            nowPlayingSkipForwardButton.centerYAnchor.constraint(equalTo: nowPlayingContentView.centerYAnchor),
            nowPlayingSkipForwardButton.trailingAnchor.constraint(equalTo: nowPlayingChevronButton.leadingAnchor, constant: -8),
            nowPlayingSkipForwardButton.widthAnchor.constraint(equalToConstant: 28),
            nowPlayingSkipForwardButton.heightAnchor.constraint(equalToConstant: 28),
            
            // Chevron Button
            nowPlayingChevronButton.centerYAnchor.constraint(equalTo: nowPlayingContentView.centerYAnchor),
            nowPlayingChevronButton.trailingAnchor.constraint(equalTo: nowPlayingContentView.trailingAnchor),
            nowPlayingChevronButton.widthAnchor.constraint(equalToConstant: 24),
            nowPlayingChevronButton.heightAnchor.constraint(equalToConstant: 24),
            
            // Progress View
            nowPlayingProgressView.topAnchor.constraint(equalTo: nowPlayingContentView.bottomAnchor, constant: 8),
            nowPlayingProgressView.leadingAnchor.constraint(equalTo: nowPlayingContainer.leadingAnchor, constant: 16),
            nowPlayingProgressView.trailingAnchor.constraint(equalTo: nowPlayingContainer.trailingAnchor, constant: -16),
            nowPlayingProgressView.heightAnchor.constraint(equalToConstant: 4),
            
            // Time Label
            nowPlayingTimeLabel.topAnchor.constraint(equalTo: nowPlayingProgressView.bottomAnchor, constant: 4),
            nowPlayingTimeLabel.leadingAnchor.constraint(equalTo: nowPlayingContainer.leadingAnchor, constant: 16),
            nowPlayingTimeLabel.trailingAnchor.constraint(equalTo: nowPlayingContainer.trailingAnchor, constant: -16),
            nowPlayingTimeLabel.bottomAnchor.constraint(equalTo: nowPlayingContainer.bottomAnchor, constant: -8)
        ])
    }
    
    private func setupBindings() {
        coordinator.networkService.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateConnectionStatus(state)
            }
            .store(in: &cancellables)
        
        coordinator.networkService.$currentFiles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] files in
                guard let self = self else { return }
                
                self.allFiles = files
                if self.isSearching == false {
                    self.currentFiles = files
                }
                
                // Update virtual scrolling manager
                self.coordinator.virtualScrollManager.setTotalItems(files.count)
                self.loadedCells.removeAll()
                self.cellImageCache.removeAll()
                
                // Clean up memory if needed
                if self.coordinator.memoryManager.shouldEvictCache() {
                    self.coordinator.imageCache.clearMemoryCache()
                }
                
                self.tableView.reloadData()
            }
            .store(in: &cancellables)
        
        coordinator.networkService.$currentPath
            .receive(on: DispatchQueue.main)
            .sink { [weak self] path in
                self?.pathLabel.text = path.isEmpty ? "No path" : path
            }
            .store(in: &cancellables)
        
        coordinator.networkService.$pathHistory
            .receive(on: DispatchQueue.main)
            .sink { [weak self] history in
                self?.backButton.isHidden = !(self?.coordinator.networkService.canNavigateBack() ?? false)
            }
            .store(in: &cancellables)
        
        coordinator.networkService.$recentSources
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recentSources in
                self?.updateSourceHistory(recentSources)
            }
            .store(in: &cancellables)
        
        // Now Playing bindings
        coordinator.audioPlayer.$playerState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateNowPlayingSection(state)
            }
            .store(in: &cancellables)
        
        coordinator.audioPlayer.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.updateNowPlayingProgress(time)
            }
            .store(in: &cancellables)
        
        coordinator.audioPlayer.$currentFile
            .receive(on: DispatchQueue.main)
            .sink { [weak self] file in
                self?.updateNowPlayingTrackInfo(file)
            }
            .store(in: &cancellables)
    }
    
    private func updateConnectionStatus(_ state: NetworkConnectionState) {
        switch state {
        case .disconnected:
            connectionStatusLabel.text = "Disconnected"
            connectionStatusLabel.textColor = .systemRed
        case .connecting:
            connectionStatusLabel.text = "Connecting..."
            connectionStatusLabel.textColor = .systemOrange
        case .connected:
            connectionStatusLabel.text = "Connected"
            connectionStatusLabel.textColor = .systemGreen
        case .error(let message):
            connectionStatusLabel.text = "Error: \(message)"
            connectionStatusLabel.textColor = .systemRed
        }
    }
    
    private func updateSourceHistory(_ recentSources: [RecentSource]) {
        // Clear existing source buttons
        sourceHistoryStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        
        // Show/hide the container based on whether we have recent sources
        sourceHistoryContainerView.isHidden = recentSources.isEmpty
        
        // Add buttons for each recent source
        for source in recentSources {
            let button = createSourceHistoryButton(for: source)
            sourceHistoryStackView.addArrangedSubview(button)
        }
    }
    
    private func createSourceHistoryButton(for source: RecentSource) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(source.name, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        button.backgroundColor = .systemBlue.withAlphaComponent(0.1)
        button.setTitleColor(.systemBlue, for: .normal)
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        
        // Set icon based on source type
        let iconName = source.type == .server ? "server.rack" : "folder.fill"
        let icon = UIImage(systemName: iconName)
        button.setImage(icon, for: .normal)
        button.imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
        
        // Add target for tap
        button.addTarget(self, action: #selector(sourceHistoryButtonTapped(_:)), for: .touchUpInside)
        button.tag = sourceHistoryStackView.arrangedSubviews.count
        
        // Set width constraint
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        
        return button
    }
    
    @objc private func sourceHistoryButtonTapped(_ sender: UIButton) {
        let recentSources = coordinator.networkService.recentSources
        guard sender.tag < recentSources.count else { return }
        
        let source = recentSources[sender.tag]
        
        switch source.type {
        case .server:
            if let serverID = source.serverID,
               let server = coordinator.networkService.savedServers.first(where: { $0.id == serverID }) {
                coordinator.networkService.connect(to: server)
            }
        case .folder:
            if let folderID = source.folderID,
               let folder = coordinator.networkService.savedFolders.first(where: { $0.id == folderID }) {
                coordinator.networkService.connectToFolder(folder)
            }
        }
    }
    
    private func connectToDemo() {
        if let demoServer = coordinator.networkService.savedServers.first {
            coordinator.networkService.connect(to: demoServer)
        }
    }
    
    private func setupDragAndDrop() {
        // Enable drag and drop only if enabled in settings
        if coordinator.settings.isDragDropEnabled && coordinator.settings.dragDropFileTypes != .disabled {
            print("📥 [MainVC] Setting up drag & drop - ENABLED with scope: \(coordinator.settings.dragDropFileTypes.description)")
            tableView.dragInteractionEnabled = true
            tableView.dropDelegate = self
            
            // Enable drag and drop on the main view for importing files
            view.addInteraction(UIDropInteraction(delegate: self))
        } else {
            print("📥 [MainVC] Drag & drop disabled in settings")
            tableView.dragInteractionEnabled = false
            tableView.dropDelegate = nil
            
            // Remove existing drop interactions
            view.interactions.forEach { interaction in
                if interaction is UIDropInteraction {
                    view.removeInteraction(interaction)
                }
            }
        }
    }
    
    @objc private func navigateBack() {
        coordinator.networkService.navigateBack()
    }
    
    @objc private func showLocalFiles() {
        coordinator.networkService.connectToLocalFiles()
        showDocumentPicker()
    }
    
    @objc private func showServers() {
        let alert = UIAlertController(title: "Servers", message: "Connect to a Samba server", preferredStyle: .actionSheet)
        
        // Add existing servers
        for server in coordinator.networkService.savedServers {
            alert.addAction(UIAlertAction(title: server.name, style: .default) { _ in
                self.coordinator.networkService.connect(to: server)
            })
        }
        
        alert.addAction(UIAlertAction(title: "Add New Server", style: .default) { _ in
            self.showAddServerDialog()
        })
        
        alert.addAction(UIAlertAction(title: "Manage Servers", style: .default) { _ in
            self.showServerManagement()
        })
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        
        present(alert, animated: true)
    }
    
    @objc private func showSettings() {
        let settingsVC = SettingsViewController(coordinator: coordinator)
        let navController = UINavigationController(rootViewController: settingsVC)
        present(navController, animated: true)
    }
    
    private func showAddServerDialog() {
        let alert = UIAlertController(title: "Add Samba Server", message: "Enter server details", preferredStyle: .alert)
        
        alert.addTextField { textField in
            textField.placeholder = "Server Name"
        }
        
        alert.addTextField { textField in
            textField.placeholder = "Host (IP or hostname)"
        }
        
        alert.addTextField { textField in
            textField.placeholder = "Port (optional, default 445)"
            textField.keyboardType = .numberPad
        }
        
        alert.addTextField { textField in
            textField.placeholder = "Username (optional)"
        }
        
        alert.addTextField { textField in
            textField.placeholder = "Password (optional)"
            textField.isSecureTextEntry = true
        }
        
        alert.addAction(UIAlertAction(title: "Add", style: .default) { _ in
            guard let nameField = alert.textFields?[0],
                  let hostField = alert.textFields?[1],
                  let name = nameField.text, !name.isEmpty,
                  let host = hostField.text, !host.isEmpty else {
                let errorAlert = UIAlertController(title: "Error", message: "Please enter server name and host", preferredStyle: .alert)
                errorAlert.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(errorAlert, animated: true)
                return
            }
            
            let portText = alert.textFields?[2].text ?? ""
            let port = Int16(portText) ?? 445
            let username = alert.textFields?[3].text
            let password = alert.textFields?[4].text
            
            let server = SambaServer(
                name: name,
                host: host,
                port: port,
                username: username?.isEmpty == false ? username : nil,
                password: password?.isEmpty == false ? password : nil
            )
            
            self.coordinator.networkService.addServer(server)
        })
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        present(alert, animated: true)
    }
    
    private func showServerManagement() {
        let serverListVC = ServerManagementViewController(networkService: coordinator.networkService)
        let nav = UINavigationController(rootViewController: serverListVC)
        present(nav, animated: true)
    }
    
    private func showDocumentPicker() {
        let alert = UIAlertController(title: "Select Files", message: "Choose how you want to select files", preferredStyle: .actionSheet)
        
        alert.addAction(UIAlertAction(title: "Select Individual Files", style: .default) { _ in
            self.showFileDocumentPicker()
        })
        
        alert.addAction(UIAlertAction(title: "Select Folder", style: .default) { _ in
            self.showFolderDocumentPicker()
        })
        
        if !coordinator.networkService.savedFolders.isEmpty {
            alert.addAction(UIAlertAction(title: "Open Saved Folder", style: .default) { _ in
                self.showSavedFolders()
            })
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        
        present(alert, animated: true)
    }
    
    private func showFileDocumentPicker() {
        let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [
            UTType.audio,
            UTType.mp3,
            UTType.mpeg4Audio,
            UTType.wav,
            UTType.aiff
        ])
        documentPicker.delegate = self
        documentPicker.allowsMultipleSelection = true
        present(documentPicker, animated: true)
    }
    
    private func showFolderDocumentPicker() {
        let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
        documentPicker.delegate = self
        documentPicker.allowsMultipleSelection = false
        present(documentPicker, animated: true)
    }
    
    private func showSavedFolders() {
        let folderListVC = FolderHistoryViewController(networkService: coordinator.networkService)
        let nav = UINavigationController(rootViewController: folderListVC)
        present(nav, animated: true)
    }
    
    @objc private func showNowPlaying() {
        let nowPlayingVC = SimpleNowPlayingViewController(coordinator: coordinator)
        let nav = UINavigationController(rootViewController: nowPlayingVC)
        present(nav, animated: true)
    }
    
    @objc private func nowPlayingPlayPauseTapped() {
        print("🎮 [MainVC] Now Playing Play/Pause button tapped - current state: \(coordinator.audioPlayer.playerState)")
        switch coordinator.audioPlayer.playerState {
        case .playing:
            print("🎮 [MainVC] Pausing playback")
            coordinator.audioPlayer.pause()
        case .paused, .stopped:
            print("🎮 [MainVC] Starting playback")
            coordinator.audioPlayer.play()
        default:
            print("🎮 [MainVC] Cannot play/pause in current state: \(coordinator.audioPlayer.playerState)")
            break
        }
    }
    
    @objc private func nowPlayingSkipBackTapped() {
        print("⏪ [MainVC] Now Playing Skip Back button tapped")
        let currentTime = coordinator.audioPlayer.currentTime
        let newTime = max(0, currentTime - 15.0)
        coordinator.audioPlayer.seek(to: newTime)
        
        // Haptic feedback if enabled
        if coordinator.settings.isHapticsEnabled {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
    }
    
    @objc private func nowPlayingSkipForwardTapped() {
        print("⏩ [MainVC] Now Playing Skip Forward button tapped")
        let currentTime = coordinator.audioPlayer.currentTime
        let duration = coordinator.audioPlayer.duration
        let newTime = min(duration, currentTime + 30.0)
        coordinator.audioPlayer.seek(to: newTime)
        
        // Haptic feedback if enabled
        if coordinator.settings.isHapticsEnabled {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
    }
    
    // MARK: - Now Playing Section Updates
    
    private func updateNowPlayingSection(_ state: AudioPlayerState) {
        let shouldShow = (state == .playing || state == .paused)
        
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseInOut) {
            self.nowPlayingContainer.isHidden = !shouldShow
            self.nowPlayingContainer.alpha = shouldShow ? 1.0 : 0.0
        }
        
        // Update play/pause button
        switch state {
        case .playing:
            nowPlayingPlayPauseButton.setImage(UIImage(systemName: "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), for: .normal)
            nowPlayingPlayPauseButton.accessibilityLabel = "Pause"
        case .paused, .stopped:
            nowPlayingPlayPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), for: .normal)
            nowPlayingPlayPauseButton.accessibilityLabel = "Play"
        default:
            nowPlayingPlayPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), for: .normal)
            nowPlayingPlayPauseButton.accessibilityLabel = "Play"
        }
    }
    
    private func updateNowPlayingProgress(_ time: TimeInterval) {
        let duration = coordinator.audioPlayer.duration
        
        // Update progress bar
        if duration > 0 {
            let progress = Float(time / duration)
            nowPlayingProgressView.progress = progress
        } else {
            nowPlayingProgressView.progress = 0.0
        }
        
        // Update time label
        let currentMinutes = Int(time) / 60
        let currentSeconds = Int(time) % 60
        let totalMinutes = Int(duration) / 60
        let totalSeconds = Int(duration) % 60
        
        nowPlayingTimeLabel.text = String(format: "%d:%02d / %d:%02d", currentMinutes, currentSeconds, totalMinutes, totalSeconds)
    }
    
    private func updateNowPlayingTrackInfo(_ file: MediaFile?) {
        if let file = file {
            trackTitleLabel.text = file.name
        } else {
            trackTitleLabel.text = "No Track"
        }
    }
}

// MARK: - Table View Data Source & Delegate
extension MainViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return currentFiles.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let startTime = CFAbsoluteTimeGetCurrent()
        let cell = tableView.dequeueReusableCell(withIdentifier: "FileCell", for: indexPath)
        let file = currentFiles[indexPath.row]
        
        // Virtual scrolling optimization - only load visible cells
        let shouldLoadCell = coordinator.virtualScrollManager.shouldLoadItem(at: indexPath.row)
        
        if shouldLoadCell {
            configureCellContent(cell, for: file, at: indexPath)
            loadedCells.insert(indexPath.row)
        } else {
            // Placeholder for non-visible cells
            cell.textLabel?.text = file.name
            cell.detailTextLabel?.text = "Loading..."
            cell.imageView?.image = UIImage(systemName: "doc")
        }
        
        let loadTime = CFAbsoluteTimeGetCurrent() - startTime
        coordinator.performanceMetrics.recordLoadTime(loadTime)
        
        return cell
    }
    
    private func configureCellContent(_ cell: UITableViewCell, for file: MediaFile, at indexPath: IndexPath) {
        cell.textLabel?.text = file.name
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        
        cell.detailTextLabel?.text = file.isDirectory ? "Folder" : ByteCountFormatter().string(fromByteCount: file.size)
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .caption1)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        
        if file.isDirectory {
            cell.imageView?.image = UIImage(systemName: "folder.fill")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = "Folder: \(file.name)"
            cell.accessibilityTraits = .button
            cell.accessibilityHint = "Double tap to open folder"
        } else if file.isAudioFile {
            // Load album art with caching
            loadAlbumArt(for: file, cell: cell, indexPath: indexPath)
            cell.accessoryType = .none
            cell.accessibilityLabel = "Audio file: \(file.name), \(ByteCountFormatter().string(fromByteCount: file.size))"
            cell.accessibilityTraits = .button
            cell.accessibilityHint = "Double tap to play audio file"
        } else if file.isTextFile {
            cell.imageView?.image = UIImage(systemName: "doc.text.fill")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityLabel = "Text file: \(file.name), \(ByteCountFormatter().string(fromByteCount: file.size))"
            cell.accessibilityTraits = .button
            cell.accessibilityHint = "Double tap to view text file"
        } else {
            cell.imageView?.image = UIImage(systemName: "doc.fill")
            cell.accessoryType = .none
            cell.accessibilityLabel = "File: \(file.name), \(ByteCountFormatter().string(fromByteCount: file.size))"
            cell.accessibilityTraits = .staticText
        }
    }
    
    private func loadAlbumArt(for file: MediaFile, cell: UITableViewCell, indexPath: IndexPath) {
        let cacheKey = "\(file.path)_thumbnail"
        
        // Check local cache first
        if let cachedImage = cellImageCache[cacheKey] {
            cell.imageView?.image = cachedImage
            return
        }
        
        // Check global image cache
        if let cachedImage = coordinator.imageCache.image(for: cacheKey) {
            cell.imageView?.image = cachedImage
            cellImageCache[cacheKey] = cachedImage
            return
        }
        
        // Set default image while loading
        cell.imageView?.image = UIImage(systemName: "music.note")
        
        // Load album art in background
        coordinator.backgroundProcessor.performFileOperation({
            // Simulate album art extraction (in real app, this would extract from audio file metadata)
            return self.generateThumbnailForAudioFile(file)
        }) { [weak self, weak cell] result in
            guard let self = self, let cell = cell else { return }
            
            switch result {
            case .success(let image):
                // Process image for thumbnail
                self.coordinator.backgroundProcessor.processImageAsync(image, for: cacheKey) { [weak self] processedImage in
                    guard let self = self, let processedImage = processedImage else { return }
                    
                    // Cache the processed image
                    self.coordinator.imageCache.setImage(processedImage, for: cacheKey)
                    self.cellImageCache[cacheKey] = processedImage
                    
                    // Update cell if still visible
                    if let currentIndexPath = self.tableView.indexPath(for: cell),
                       currentIndexPath == indexPath {
                        cell.imageView?.image = processedImage
                        cell.setNeedsLayout()
                    }
                }
            case .failure:
                // Keep default music note icon
                break
            }
        }
    }
    
    private func generateThumbnailForAudioFile(_ file: MediaFile) -> UIImage {
        // In a real implementation, this would extract album art from audio file metadata
        // For now, return a styled music note icon
        let config = UIImage.SymbolConfiguration(pointSize: 30, weight: .medium)
        return UIImage(systemName: "music.note", withConfiguration: config) ?? UIImage(systemName: "music.note")!
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let file = currentFiles[indexPath.row]
        print("📁 [MainVC] File selected: \(file.name) (type: \(file.isDirectory ? "directory" : file.isAudioFile ? "audio" : file.isTextFile ? "text" : "unknown"))")
        
        if file.isDirectory {
            print("📁 [MainVC] Navigating to directory: \(file.path)")
            coordinator.networkService.navigateToPath(file.path)
        } else if file.isAudioFile {
            print("🎵 [MainVC] Playing audio file: \(file.name)")
            playFile(file)
        } else if file.isTextFile {
            print("📄 [MainVC] Opening text file: \(file.name)")
            showTextViewer(for: file)
        }
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Update virtual scrolling manager
        coordinator.virtualScrollManager.updateVisibleRange(for: scrollView)
        
        // Load cells that became visible
        let visibleIndexPaths = tableView.indexPathsForVisibleRows ?? []
        for indexPath in visibleIndexPaths {
            if !loadedCells.contains(indexPath.row) {
                // Reload this cell with full content
                tableView.reloadRows(at: [indexPath], with: .none)
            }
        }
        
        // Clean up memory if needed
        if coordinator.memoryManager.shouldEvictCache() {
            cleanupOffscreenCells()
        }
    }
    
    private func cleanupOffscreenCells() {
        let visibleRows = Set(tableView.indexPathsForVisibleRows?.map { $0.row } ?? [])
        
        // Remove cached images for non-visible cells
        let keysToRemove = cellImageCache.keys.filter { key in
            // Extract row index from cache key if possible
            return !visibleRows.contains(where: { row in
                key.contains("\(currentFiles[row].path)")
            })
        }
        
        for key in keysToRemove {
            cellImageCache.removeValue(forKey: key)
        }
        
        // Update loaded cells set
        loadedCells = loadedCells.intersection(visibleRows)
        
        print("🧹 [MainVC] Cleaned up \(keysToRemove.count) cached images")
    }
    
    private func playFile(_ file: MediaFile) {
        print("🎵 [MainVC] Loading file for playback: \(file.name)")
        
        // Clear current queue and add this file
        coordinator.playbackQueue.clearQueue()
        coordinator.playbackQueue.addTrack(file)
        coordinator.playbackQueue.saveToUserDefaults()
        
        coordinator.audioPlayer.loadFile(file) { [weak self] result in
            switch result {
            case .success:
                print("✅ [MainVC] File loaded successfully, starting playback")
                self?.coordinator.audioPlayer.play()
                
                // Load subtitle if available
                if let textFile = file.associatedTextFile {
                    print("📄 [MainVC] Loading associated text file: \(textFile)")
                    self?.coordinator.networkService.readTextFile(at: textFile) { textResult in
                        if case .success(let subtitle) = textResult {
                            print("✅ [MainVC] Subtitle loaded successfully")
                            DispatchQueue.main.async {
                                self?.coordinator.audioPlayer.subtitle = subtitle
                            }
                        } else {
                            print("⚠️ [MainVC] Failed to load subtitle")
                        }
                    }
                }
                
                print("🎵 [MainVC] Showing now playing interface")
                self?.showNowPlaying()
                
            case .failure(let error):
                print("❌ [MainVC] Failed to load file: \(error.localizedDescription)")
                let alert = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(alert, animated: true)
            }
        }
    }
    
    private func showTextViewer(for file: MediaFile) {
        let textViewerVC = TextViewerViewController(file: file, networkService: coordinator.networkService)
        let nav = UINavigationController(rootViewController: textViewerVC)
        present(nav, animated: true)
    }
    
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let file = currentFiles[indexPath.row]
        
        // Only show context menu for audio files
        guard file.isAudioFile else { return nil }
        
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let playAction = UIAction(
                title: "Play Now",
                image: UIImage(systemName: "play.fill"),
                attributes: []
            ) { [weak self] _ in
                self?.playFile(file)
            }
            
            let addToQueueAction = UIAction(
                title: "Add to Queue",
                image: UIImage(systemName: "plus"),
                attributes: []
            ) { [weak self] _ in
                self?.coordinator.playbackQueue.addTrack(file)
                self?.coordinator.playbackQueue.saveToUserDefaults()
                
                // Show confirmation with haptic feedback
                if self?.coordinator.settings.isHapticsEnabled == true {
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                }
                
                let alert = UIAlertController(
                    title: "Added to Queue",
                    message: "\(file.name) has been added to the queue",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(alert, animated: true)
            }
            
            let playNextAction = UIAction(
                title: "Play Next",
                image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward"),
                attributes: []
            ) { [weak self] _ in
                let insertIndex = (self?.coordinator.playbackQueue.currentIndex ?? -1) + 1
                self?.coordinator.playbackQueue.insertTrack(file, at: insertIndex)
                self?.coordinator.playbackQueue.saveToUserDefaults()
                
                // Show confirmation with haptic feedback
                if self?.coordinator.settings.isHapticsEnabled == true {
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                }
                
                let alert = UIAlertController(
                    title: "Added to Queue",
                    message: "\(file.name) will play next",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(alert, animated: true)
            }
            
            return UIMenu(title: file.name, children: [playAction, playNextAction, addToQueueAction])
        }
    }
}

// MARK: - Search Results Updating
extension MainViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let searchText = searchController.searchBar.text ?? ""
        
        if searchText.isEmpty {
            isSearching = false
            isLyricsSearching = false
            currentFiles = allFiles
            tableView.reloadData()
        } else {
            isSearching = true
            
            if coordinator.settings.isLyricsSearchEnabled {
                // Lyrics search mode - search within text file contents
                performLyricsSearch(searchText)
            } else {
                // Regular file name search
                performFileNameSearch(searchText)
            }
        }
    }
    
    private func performFileNameSearch(_ searchText: String) {
        isLyricsSearching = false
        let filteredFiles = allFiles.filter { file in
            file.name.localizedCaseInsensitiveContains(searchText)
        }
        
        // Apply search scope filter based on settings
        switch coordinator.settings.searchScopeIncludes {
        case .all:
            print("🔍 [Search] Applying ALL FILES scope - showing \(filteredFiles.count) results")
            currentFiles = filteredFiles
        case .audioOnly:
            let audioFiles = filteredFiles.filter { $0.isAudioFile }
            print("🔍 [Search] Applying AUDIO ONLY scope - showing \(audioFiles.count) results")
            currentFiles = audioFiles
        case .textOnly:
            let textFiles = filteredFiles.filter { $0.isTextFile }
            print("🔍 [Search] Applying TEXT ONLY scope - showing \(textFiles.count) results")
            currentFiles = textFiles
        }
        
        tableView.reloadData()
    }
    
    private func performLyricsSearch(_ searchText: String) {
        isLyricsSearching = true
        print("🎵 [Search] Performing lyrics search for: '\(searchText)'")
        
        coordinator.networkService.searchInTextFiles(query: searchText) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                switch result {
                case .success(let matchingFiles):
                    print("🎵 [Search] Lyrics search completed - found \(matchingFiles.count) matches")
                    self.currentFiles = matchingFiles
                    self.tableView.reloadData()
                    
                case .failure(let error):
                    print("❌ [Search] Lyrics search failed: \(error)")
                    self.currentFiles = []
                    self.tableView.reloadData()
                }
                
                self.isLyricsSearching = false
            }
        }
    }
}

// MARK: - Drag and Drop Support
extension MainViewController: UITableViewDropDelegate, UIDropInteractionDelegate {
    
    // MARK: - Table View Drop Delegate
    func tableView(_ tableView: UITableView, canHandle session: UIDropSession) -> Bool {
        return session.canLoadObjects(ofClass: URL.self)
    }
    
    func tableView(_ tableView: UITableView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UITableViewDropProposal {
        return UITableViewDropProposal(operation: .copy, intent: .insertIntoDestinationIndexPath)
    }
    
    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        for item in coordinator.session.items {
            item.itemProvider.loadObject(ofClass: URL.self) { [weak self] (url, error) in
                guard let url = url, error == nil else { return }
                
                DispatchQueue.main.async {
                    self?.handleDroppedFile(url: url)
                }
            }
        }
    }
    
    // MARK: - Drop Interaction Delegate (for main view)
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        return session.canLoadObjects(ofClass: URL.self)
    }
    
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        return UIDropProposal(operation: .copy)
    }
    
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        for item in session.items {
            item.itemProvider.loadObject(ofClass: URL.self) { [weak self] (url, error) in
                guard let url = url, error == nil else { return }
                
                DispatchQueue.main.async {
                    self?.handleDroppedFile(url: url)
                }
            }
        }
    }
    
    // MARK: - Drop Handling
    private func handleDroppedFile(url: URL) {
        // Check file type based on settings
        let audioExtensions = ["mp3", "m4a", "wav", "aiff", "flac", "ogg", "wma", "aac"]
        let textExtensions = ["txt"]
        let fileExtension = url.pathExtension.lowercased()
        
        let isAudioFile = audioExtensions.contains(fileExtension)
        let isTextFile = textExtensions.contains(fileExtension)
        
        switch coordinator.settings.dragDropFileTypes {
        case .audioOnly:
            print("📥 [DragDrop] Audio-only mode: \(fileExtension) -> \(isAudioFile ? "ACCEPTED" : "REJECTED")")
            guard isAudioFile else {
                showAlert(title: "Unsupported File", message: "Only audio files can be imported via drag and drop.")
                return
            }
        case .allSupported:
            print("📥 [DragDrop] All-supported mode: \(fileExtension) -> \(isAudioFile || isTextFile ? "ACCEPTED" : "REJECTED")")
            guard isAudioFile || isTextFile else {
                showAlert(title: "Unsupported File", message: "Only audio and text files can be imported via drag and drop.")
                return
            }
        case .disabled:
            print("📥 [DragDrop] Drag & drop disabled in settings -> REJECTED")
            showAlert(title: "Drag & Drop Disabled", message: "Drag and drop is currently disabled in settings.")
            return
        }
        
        // Start accessing security-scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            showAlert(title: "Access Denied", message: "Cannot access the dropped file.")
            return
        }
        
        defer {
            url.stopAccessingSecurityScopedResource()
        }
        
        // Create a MediaFile from the dropped URL
        let fileName = url.lastPathComponent
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        
        let mediaFile = MediaFile(
            name: fileName,
            path: url.path,
            size: Int64(fileSize),
            modificationDate: modificationDate,
            isDirectory: false,
            fileExtension: url.pathExtension
        )
        
        // Play the dropped file
        coordinator.audioPlayer.loadFile(mediaFile) { [weak self] result in
            switch result {
            case .success:
                self?.coordinator.audioPlayer.play()
                self?.showNowPlaying()
                
                // Show success message
                self?.showAlert(title: "File Imported", message: "Successfully imported and playing: \(fileName)")
                
            case .failure(let error):
                self?.showAlert(title: "Import Error", message: "Failed to import file: \(error.localizedDescription)")
            }
        }
    }
    
    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Text Viewer View Controller
class TextViewerViewController: UIViewController {
    private let file: MediaFile
    private let networkService: SimpleNetworkService
    
    private lazy var textView: UITextView = {
        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .systemBackground
        textView.font = .systemFont(ofSize: 16)
        textView.isEditable = false
        textView.contentInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.showsVerticalScrollIndicator = true
        return textView
    }()
    
    private lazy var loadingLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Loading..."
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 18, weight: .medium)
        label.textColor = .secondaryLabel
        return label
    }()
    
    private lazy var errorLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16)
        label.textColor = .systemRed
        label.numberOfLines = 0
        label.isHidden = true
        return label
    }()
    
    init(file: MediaFile, networkService: SimpleNetworkService) {
        self.file = file
        self.networkService = networkService
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadTextContent()
    }
    
    private func setupUI() {
        title = file.name
        view.backgroundColor = .systemBackground
        
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissViewer)
        )
        
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "textformat.size"),
            style: .plain,
            target: self,
            action: #selector(adjustTextSize)
        )
        
        view.addSubview(textView)
        view.addSubview(loadingLabel)
        view.addSubview(errorLabel)
        
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            loadingLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
    }
    
    private func loadTextContent() {
        networkService.readTextFile(at: file.path) { [weak self] result in
            DispatchQueue.main.async {
                self?.loadingLabel.isHidden = true
                
                switch result {
                case .success(let content):
                    self?.textView.text = content
                    self?.textView.isHidden = false
                    self?.errorLabel.isHidden = true
                    
                case .failure(let error):
                    self?.textView.isHidden = true
                    self?.errorLabel.text = "Failed to load text file:\n\(error.localizedDescription)"
                    self?.errorLabel.isHidden = false
                }
            }
        }
    }
    
    @objc private func dismissViewer() {
        dismiss(animated: true)
    }
    
    @objc private func adjustTextSize() {
        let alert = UIAlertController(title: "Text Size", message: "Choose text size", preferredStyle: .actionSheet)
        
        let sizes: [(String, CGFloat)] = [
            ("Small", 14),
            ("Medium", 16),
            ("Large", 18),
            ("Extra Large", 20),
            ("Huge", 24)
        ]
        
        for (title, size) in sizes {
            let action = UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.textView.font = .systemFont(ofSize: size)
            }
            
            // Mark current size
            if textView.font?.pointSize == size {
                action.setValue(true, forKey: "checked")
            }
            
            alert.addAction(action)
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        if let popover = alert.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        
        present(alert, animated: true)
    }
}

// MARK: - Enhanced Now Playing View Controller
class SimpleNowPlayingViewController: UIViewController {
    private let coordinator: SambaPlayCoordinator
    private var cancellables = Set<AnyCancellable>()
    
    // UI Components
    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .title1)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.numberOfLines = 2
        label.accessibilityLabel = "Currently playing track"
        label.accessibilityTraits = .header
        return label
    }()
    
    private lazy var positionRestoredLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textAlignment = .center
        label.textColor = .systemBlue
        label.text = "📍 Resumed from saved position"
        label.alpha = 0.0
        label.isHidden = true
        return label
    }()
    
    private lazy var audioFormatLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.text = "Unknown Format"
        return label
    }()
    
    private lazy var timeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 16, weight: .medium)
        label.textAlignment = .center
        return label
    }()
    
    private lazy var progressSlider: UISlider = {
        let slider = UISlider()
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.addTarget(self, action: #selector(progressChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderTouchUp), for: [.touchUpInside, .touchUpOutside])
        slider.accessibilityLabel = "Playback progress"
        slider.accessibilityTraits = .adjustable
        slider.accessibilityHint = "Swipe up or down to adjust playback position"
        return slider
    }()
    
    private var isUserDraggingSlider = false
    
    // Speed and Pitch Indicators
    private lazy var speedPitchContainer: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .secondarySystemBackground
        container.layer.cornerRadius = 12
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.separator.cgColor
        container.alpha = 0.0 // Initially hidden
        
        // Add tap gesture to open audio settings
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(showSettings))
        container.addGestureRecognizer(tapGesture)
        container.isUserInteractionEnabled = true
        
        return container
    }()
    
    private lazy var speedIndicatorLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textAlignment = .center
        label.textColor = .systemBlue
        label.text = "1.00×"
        return label
    }()
    
    private lazy var pitchIndicatorLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textAlignment = .center
        label.textColor = .systemPurple
        label.text = "0♭♯"
        return label
    }()
    
    private lazy var speedPitchStackView: UIStackView = {
        let speedContainer = UIView()
        speedContainer.translatesAutoresizingMaskIntoConstraints = false
        
        let speedIcon = UIImageView(image: UIImage(systemName: "speedometer"))
        speedIcon.translatesAutoresizingMaskIntoConstraints = false
        speedIcon.tintColor = .systemBlue
        speedIcon.contentMode = .scaleAspectFit
        
        speedContainer.addSubview(speedIcon)
        speedContainer.addSubview(speedIndicatorLabel)
        
        NSLayoutConstraint.activate([
            speedIcon.leadingAnchor.constraint(equalTo: speedContainer.leadingAnchor),
            speedIcon.centerYAnchor.constraint(equalTo: speedContainer.centerYAnchor),
            speedIcon.widthAnchor.constraint(equalToConstant: 16),
            speedIcon.heightAnchor.constraint(equalToConstant: 16),
            
            speedIndicatorLabel.leadingAnchor.constraint(equalTo: speedIcon.trailingAnchor, constant: 4),
            speedIndicatorLabel.trailingAnchor.constraint(equalTo: speedContainer.trailingAnchor),
            speedIndicatorLabel.centerYAnchor.constraint(equalTo: speedContainer.centerYAnchor)
        ])
        
        let pitchContainer = UIView()
        pitchContainer.translatesAutoresizingMaskIntoConstraints = false
        
        let pitchIcon = UIImageView(image: UIImage(systemName: "tuningfork"))
        pitchIcon.translatesAutoresizingMaskIntoConstraints = false
        pitchIcon.tintColor = .systemPurple
        pitchIcon.contentMode = .scaleAspectFit
        
        pitchContainer.addSubview(pitchIcon)
        pitchContainer.addSubview(pitchIndicatorLabel)
        
        NSLayoutConstraint.activate([
            pitchIcon.leadingAnchor.constraint(equalTo: pitchContainer.leadingAnchor),
            pitchIcon.centerYAnchor.constraint(equalTo: pitchContainer.centerYAnchor),
            pitchIcon.widthAnchor.constraint(equalToConstant: 16),
            pitchIcon.heightAnchor.constraint(equalToConstant: 16),
            
            pitchIndicatorLabel.leadingAnchor.constraint(equalTo: pitchIcon.trailingAnchor, constant: 4),
            pitchIndicatorLabel.trailingAnchor.constraint(equalTo: pitchContainer.trailingAnchor),
            pitchIndicatorLabel.centerYAnchor.constraint(equalTo: pitchContainer.centerYAnchor)
        ])
        
        let stack = UIStackView(arrangedSubviews: [speedContainer, pitchContainer])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 16
        return stack
    }()
    
    // Media Control Buttons
    private lazy var previousTrackButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "backward.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)), for: .normal)
        button.addTarget(self, action: #selector(previousTrackTapped), for: .touchUpInside)
        button.accessibilityLabel = "Previous track"
        button.accessibilityTraits = .button
        button.accessibilityHint = "Double tap to go to previous track"
        return button
    }()
    
    private lazy var skipBackButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "gobackward.15", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), for: .normal)
        button.addTarget(self, action: #selector(skipBackTapped), for: .touchUpInside)
        button.accessibilityLabel = "Skip back 15 seconds"
        button.accessibilityTraits = .button
        button.accessibilityHint = "Double tap to go back 15 seconds"
        return button
    }()
    
    private lazy var playPauseButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)), for: .normal)
        button.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        button.accessibilityLabel = "Play"
        button.accessibilityTraits = .button
        button.accessibilityHint = "Double tap to play or pause audio"
        return button
    }()
    
    private lazy var skipForwardButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "goforward.30", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), for: .normal)
        button.addTarget(self, action: #selector(skipForwardTapped), for: .touchUpInside)
        button.accessibilityLabel = "Skip forward 30 seconds"
        button.accessibilityTraits = .button
        button.accessibilityHint = "Double tap to go forward 30 seconds"
        return button
    }()
    
    private lazy var nextTrackButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "forward.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)), for: .normal)
        button.addTarget(self, action: #selector(nextTrackTapped), for: .touchUpInside)
        button.accessibilityLabel = "Next track"
        button.accessibilityTraits = .button
        button.accessibilityHint = "Double tap to go to next track"
        return button
    }()
    
    private lazy var controlsStackView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [previousTrackButton, skipBackButton, playPauseButton, skipForwardButton, nextTrackButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        stack.alignment = .center
        stack.spacing = 16
        return stack
    }()
    
    private lazy var shuffleButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "shuffle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        button.addTarget(self, action: #selector(shuffleTapped), for: .touchUpInside)
        button.accessibilityLabel = "Shuffle"
        button.accessibilityTraits = .button
        button.accessibilityHint = "Double tap to toggle shuffle mode"
        return button
    }()
    
    private lazy var repeatButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "repeat", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        button.addTarget(self, action: #selector(repeatTapped), for: .touchUpInside)
        button.accessibilityLabel = "Repeat"
        button.accessibilityTraits = .button
        button.accessibilityHint = "Double tap to toggle repeat mode"
        return button
    }()
    
    private lazy var playbackModeStackView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [shuffleButton, repeatButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        stack.alignment = .center
        stack.spacing = 24
        return stack
    }()
    
    private lazy var settingsButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "slider.horizontal.3", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), for: .normal)
        button.addTarget(self, action: #selector(showSettings), for: .touchUpInside)
        return button
    }()
    
    private lazy var queueButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "list.bullet", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), for: .normal)
        button.addTarget(self, action: #selector(showQueue), for: .touchUpInside)
        button.accessibilityLabel = "Show queue"
        button.accessibilityTraits = .button
        button.accessibilityHint = "Double tap to view and manage playback queue"
        return button
    }()
    
    private lazy var topButtonsStackView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [queueButton, settingsButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        stack.alignment = .center
        stack.spacing = 16
        return stack
    }()
    
    private lazy var subtitleTextView: UITextView = {
        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 12
        textView.font = .systemFont(ofSize: 16)
        textView.isEditable = false
        textView.contentInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.separator.cgColor
        return textView
    }()
    
    private lazy var subtitleHeaderLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "🎵 Lyrics"
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textColor = .label
        return label
    }()
    
    init(coordinator: SambaPlayCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupBindings()
        updateUI()
    }
    
    private func setupUI() {
        title = "Now Playing"
        view.backgroundColor = .systemBackground
        
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissViewController))
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: topButtonsStackView)
        
        view.addSubview(titleLabel)
        view.addSubview(audioFormatLabel)
        view.addSubview(positionRestoredLabel)
        view.addSubview(timeLabel)
        view.addSubview(speedPitchContainer)
        speedPitchContainer.addSubview(speedPitchStackView)
        view.addSubview(progressSlider)
        view.addSubview(playbackModeStackView)
        view.addSubview(controlsStackView)
        view.addSubview(subtitleHeaderLabel)
        view.addSubview(subtitleTextView)
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            audioFormatLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            audioFormatLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            audioFormatLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            positionRestoredLabel.topAnchor.constraint(equalTo: audioFormatLabel.bottomAnchor, constant: 8),
            positionRestoredLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            positionRestoredLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            timeLabel.topAnchor.constraint(equalTo: positionRestoredLabel.bottomAnchor, constant: 16),
            timeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            timeLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            speedPitchContainer.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 12),
            speedPitchContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            speedPitchContainer.widthAnchor.constraint(equalToConstant: 200),
            speedPitchContainer.heightAnchor.constraint(equalToConstant: 36),
            
            speedPitchStackView.topAnchor.constraint(equalTo: speedPitchContainer.topAnchor, constant: 8),
            speedPitchStackView.leadingAnchor.constraint(equalTo: speedPitchContainer.leadingAnchor, constant: 16),
            speedPitchStackView.trailingAnchor.constraint(equalTo: speedPitchContainer.trailingAnchor, constant: -16),
            speedPitchStackView.bottomAnchor.constraint(equalTo: speedPitchContainer.bottomAnchor, constant: -8),
            
            progressSlider.topAnchor.constraint(equalTo: speedPitchContainer.bottomAnchor, constant: 16),
            progressSlider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            progressSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            playbackModeStackView.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: 20),
            playbackModeStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playbackModeStackView.heightAnchor.constraint(equalToConstant: 36),
            
            controlsStackView.topAnchor.constraint(equalTo: playbackModeStackView.bottomAnchor, constant: 20),
            controlsStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controlsStackView.widthAnchor.constraint(equalToConstant: 280),
            controlsStackView.heightAnchor.constraint(equalToConstant: 60),
            
            subtitleHeaderLabel.topAnchor.constraint(equalTo: controlsStackView.bottomAnchor, constant: 32),
            subtitleHeaderLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            subtitleHeaderLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            subtitleTextView.topAnchor.constraint(equalTo: subtitleHeaderLabel.bottomAnchor, constant: 12),
            subtitleTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            subtitleTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            subtitleTextView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
    }
    
    private func setupBindings() {
        coordinator.audioPlayer.$playerState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updatePlayButton(state)
            }
            .store(in: &cancellables)
        
        coordinator.audioPlayer.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.updateTime(time)
            }
            .store(in: &cancellables)
        
        coordinator.audioPlayer.$currentFile
            .receive(on: DispatchQueue.main)
            .sink { [weak self] file in
                self?.titleLabel.text = file?.name ?? "No Track"
            }
            .store(in: &cancellables)
        
        coordinator.audioPlayer.$subtitle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] subtitle in
                self?.subtitleTextView.text = subtitle ?? "No subtitle available"
            }
            .store(in: &cancellables)
        
        coordinator.audioPlayer.$speed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] speed in
                self?.updateSpeedIndicator(speed)
            }
            .store(in: &cancellables)
        
        coordinator.audioPlayer.$pitch
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pitch in
                self?.updatePitchIndicator(pitch)
            }
            .store(in: &cancellables)
        
        coordinator.audioPlayer.$hasRestoredPosition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasRestored in
                self?.showPositionRestoredIndicator(hasRestored)
            }
            .store(in: &cancellables)
        
        coordinator.playbackQueue.$playbackMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePlaybackModeButtons()
            }
            .store(in: &cancellables)
    }
    
    private func updateUI() {
        titleLabel.text = coordinator.audioPlayer.currentFile?.name ?? "No Track"
        updateTime(coordinator.audioPlayer.currentTime)
        updatePlayButton(coordinator.audioPlayer.playerState)
        updateSpeedIndicator(coordinator.audioPlayer.speed)
        updatePitchIndicator(coordinator.audioPlayer.pitch)
        subtitleTextView.text = coordinator.audioPlayer.subtitle ?? "No subtitle available"
        showPositionRestoredIndicator(coordinator.audioPlayer.hasRestoredPosition)
        updatePlaybackModeButtons()
    }
    
    private func showPositionRestoredIndicator(_ hasRestored: Bool) {
        if hasRestored {
            positionRestoredLabel.isHidden = false
            UIView.animate(withDuration: 0.3) {
                self.positionRestoredLabel.alpha = 1.0
            }
            
            // Hide the indicator after 4 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                UIView.animate(withDuration: 0.3) {
                    self.positionRestoredLabel.alpha = 0.0
                } completion: { _ in
                    self.positionRestoredLabel.isHidden = true
                }
            }
        } else {
            positionRestoredLabel.isHidden = true
            positionRestoredLabel.alpha = 0.0
        }
    }
    
    private func updatePlayButton(_ state: AudioPlayerState) {
        switch state {
        case .playing:
            playPauseButton.setImage(UIImage(systemName: "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)), for: .normal)
            playPauseButton.accessibilityLabel = "Pause"
            playPauseButton.accessibilityValue = "Currently playing"
        case .paused, .stopped:
            playPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)), for: .normal)
            playPauseButton.accessibilityLabel = "Play"
            playPauseButton.accessibilityValue = state == .paused ? "Paused" : "Stopped"
        default:
            playPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)), for: .normal)
            playPauseButton.accessibilityLabel = "Play"
            playPauseButton.accessibilityValue = "Ready to play"
        }
    }
    
    private func updateTime(_ time: TimeInterval) {
        let currentMinutes = Int(time) / 60
        let currentSeconds = Int(time) % 60
        let totalMinutes = Int(coordinator.audioPlayer.duration) / 60
        let totalSeconds = Int(coordinator.audioPlayer.duration) % 60
        
        timeLabel.text = String(format: "%d:%02d / %d:%02d", currentMinutes, currentSeconds, totalMinutes, totalSeconds)
        
        // Only update slider if user is not currently dragging it
        if !isUserDraggingSlider && coordinator.audioPlayer.duration > 0 {
            progressSlider.value = Float(time / coordinator.audioPlayer.duration)
        }
    }
    
    private func updateSpeedIndicator(_ speed: Float) {
        speedIndicatorLabel.text = String(format: "%.2f×", speed)
        
        // Show visual feedback for non-default values
        let isSpeedDefault = abs(speed - 1.0) < 0.01
        let isPitchDefault = abs(coordinator.audioPlayer.pitch - 1.0) < 0.01
        let bothDefault = isSpeedDefault && isPitchDefault
        
        speedIndicatorLabel.textColor = isSpeedDefault ? .systemBlue : .systemOrange
        updateContainerAppearance(bothDefault: bothDefault)
    }
    
    private func updatePitchIndicator(_ pitch: Float) {
        let semitones = (pitch - 1.0) * 12.0
        let roundedSemitones = round(semitones)
        
        if abs(roundedSemitones) < 0.1 {
            pitchIndicatorLabel.text = "0♭♯"
        } else if roundedSemitones > 0 {
            pitchIndicatorLabel.text = "+\(Int(roundedSemitones))♯"
        } else {
            pitchIndicatorLabel.text = "\(Int(roundedSemitones))♭"
        }
        
        // Show visual feedback for non-default values
        let isSpeedDefault = abs(coordinator.audioPlayer.speed - 1.0) < 0.01
        let isPitchDefault = abs(pitch - 1.0) < 0.01
        let bothDefault = isSpeedDefault && isPitchDefault
        
        pitchIndicatorLabel.textColor = isPitchDefault ? .systemPurple : .systemOrange
        updateContainerAppearance(bothDefault: bothDefault)
    }
    
    private func updateContainerAppearance(bothDefault: Bool) {
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseInOut) {
            if bothDefault {
                // Hide when both are default
                self.speedPitchContainer.alpha = 0.0
                self.speedPitchContainer.backgroundColor = .secondarySystemBackground
                self.speedPitchContainer.layer.borderColor = UIColor.separator.cgColor
            } else {
                // Show with highlighted appearance when modified
                self.speedPitchContainer.alpha = 1.0
                self.speedPitchContainer.backgroundColor = .systemYellow.withAlphaComponent(0.1)
                self.speedPitchContainer.layer.borderColor = UIColor.systemYellow.cgColor
            }
        }
    }
    
    @objc private func dismissViewController() {
        dismiss(animated: true)
    }
    
    @objc private func playPauseTapped() {
        print("🎮 [MainVC] Play/Pause button tapped - current state: \(coordinator.audioPlayer.playerState)")
        switch coordinator.audioPlayer.playerState {
        case .playing:
            print("🎮 [MainVC] Pausing playback")
            coordinator.audioPlayer.pause()
        case .paused, .stopped:
            print("🎮 [MainVC] Starting playback")
            coordinator.audioPlayer.play()
        default:
            print("🎮 [MainVC] Cannot play/pause in current state: \(coordinator.audioPlayer.playerState)")
            break
        }
    }
    
    @objc private func sliderTouchDown() {
        isUserDraggingSlider = true
    }
    
    @objc private func sliderTouchUp() {
        print("🎚️ [MainVC] Progress slider touch up")
        isUserDraggingSlider = false
        // Perform the seek when user releases the slider
        let newTime = Double(progressSlider.value) * coordinator.audioPlayer.duration
        print("🎚️ [MainVC] Seeking to \(String(format: "%.2f", newTime))s via slider")
        coordinator.audioPlayer.seek(to: newTime)
    }
    
    @objc private func progressChanged() {
        // Update time display while dragging, but don't seek until touch up
        if isUserDraggingSlider {
            let newTime = Double(progressSlider.value) * coordinator.audioPlayer.duration
            let currentMinutes = Int(newTime) / 60
            let currentSeconds = Int(newTime) % 60
            let totalMinutes = Int(coordinator.audioPlayer.duration) / 60
            let totalSeconds = Int(coordinator.audioPlayer.duration) % 60
            timeLabel.text = String(format: "%d:%02d / %d:%02d", currentMinutes, currentSeconds, totalMinutes, totalSeconds)
        }
    }
    
    @objc private func skipBackTapped() {
        let currentTime = coordinator.audioPlayer.currentTime
        let newTime = max(0, currentTime - 15.0)
        print("⏪ [MainVC] Skip back 15s: \(String(format: "%.2f", currentTime))s -> \(String(format: "%.2f", newTime))s")
        coordinator.audioPlayer.seek(to: newTime)
    }
    
    @objc private func skipForwardTapped() {
        let currentTime = coordinator.audioPlayer.currentTime
        let duration = coordinator.audioPlayer.duration
        let newTime = min(duration, currentTime + 30.0)
        print("⏩ [MainVC] Skip forward 30s: \(String(format: "%.2f", currentTime))s -> \(String(format: "%.2f", newTime))s")
        coordinator.audioPlayer.seek(to: newTime)
    }
    
    @objc private func previousTrackTapped() {
        print("⏮️ [NowPlaying] Previous track button tapped")
        coordinator.audioPlayer.playPrevious()
        
        // Haptic feedback
        if coordinator.settings.isHapticsEnabled {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }
    }
    
    @objc private func nextTrackTapped() {
        print("⏭️ [NowPlaying] Next track button tapped")
        coordinator.audioPlayer.playNext()
        
        // Haptic feedback
        if coordinator.settings.isHapticsEnabled {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }
    }
    
    @objc private func shuffleTapped() {
        print("🔀 [NowPlaying] Shuffle button tapped")
        coordinator.playbackQueue.toggleShuffle()
        updatePlaybackModeButtons()
        
        // Haptic feedback
        if coordinator.settings.isHapticsEnabled {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
    }
    
    @objc private func repeatTapped() {
        print("🔁 [NowPlaying] Repeat button tapped")
        coordinator.playbackQueue.togglePlaybackMode()
        updatePlaybackModeButtons()
        
        // Haptic feedback
        if coordinator.settings.isHapticsEnabled {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
    }
    
    @objc private func showQueue() {
        print("📋 [NowPlaying] Queue button tapped")
        let queueVC = QueueViewController(coordinator: coordinator)
        let nav = UINavigationController(rootViewController: queueVC)
        present(nav, animated: true)
    }
    
    private func updatePlaybackModeButtons() {
        let mode = coordinator.playbackQueue.playbackMode
        
        // Update shuffle button
        let shuffleColor: UIColor = mode == .shuffle ? .systemOrange : .label
        shuffleButton.tintColor = shuffleColor
        shuffleButton.accessibilityValue = mode == .shuffle ? "On" : "Off"
        
        // Update repeat button
        let repeatColor: UIColor = (mode == .repeatAll || mode == .repeatOne) ? .systemOrange : .label
        repeatButton.tintColor = repeatColor
        
        switch mode {
        case .normal:
            repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
            repeatButton.accessibilityValue = "Off"
        case .repeatAll:
            repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
            repeatButton.accessibilityValue = "Repeat all"
        case .repeatOne:
            repeatButton.setImage(UIImage(systemName: "repeat.1", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
            repeatButton.accessibilityValue = "Repeat one"
        case .shuffle:
            repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
            repeatButton.accessibilityValue = "Off"
        }
    }
    
    @objc private func showSettings() {
        let settingsVC = AudioSettingsViewController(coordinator: coordinator)
        let nav = UINavigationController(rootViewController: settingsVC)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }
}

// MARK: - Audio Settings View Controller
class AudioSettingsViewController: UIViewController {
    private let coordinator: SambaPlayCoordinator
    private var cancellables = Set<AnyCancellable>()
    
    // Speed Controls
    private lazy var speedValueLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "1.00x"
        label.font = .monospacedSystemFont(ofSize: 24, weight: .bold)
        label.textAlignment = .center
        label.textColor = .systemBlue
        return label
    }()
    
    private lazy var speedSlider: UISlider = {
        let slider = UISlider()
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumValue = 0.5
        slider.maximumValue = 3.0
        slider.value = 1.0
        slider.tintColor = .systemBlue
        slider.addTarget(self, action: #selector(speedSliderChanged), for: .valueChanged)
        return slider
    }()
    
    private lazy var speedTextField: UITextField = {
        let textField = UITextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.borderStyle = .roundedRect
        textField.backgroundColor = .systemBackground
        textField.keyboardType = .decimalPad
        textField.text = "1.00"
        textField.textAlignment = .center
        textField.placeholder = "1.00"
        textField.font = .monospacedSystemFont(ofSize: 18, weight: .semibold)
        textField.addTarget(self, action: #selector(speedTextChanged), for: .editingChanged)
        return textField
    }()
    
    // Pitch Controls
    private lazy var pitchValueLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "0 semitones"
        label.font = .monospacedSystemFont(ofSize: 20, weight: .bold)
        label.textAlignment = .center
        label.textColor = .systemPurple
        return label
    }()
    
    private lazy var pitchSlider: UISlider = {
        let slider = UISlider()
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumValue = 0.5
        slider.maximumValue = 1.5
        slider.value = 1.0
        slider.tintColor = .systemPurple
        slider.addTarget(self, action: #selector(pitchSliderChanged), for: .valueChanged)
        return slider
    }()
    
    private lazy var resetButton: UIButton = {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = "Reset to Defaults"
        config.baseBackgroundColor = .systemRed
        config.baseForegroundColor = .white
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 32, bottom: 16, trailing: 32)
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(resetDefaults), for: .touchUpInside)
        return button
    }()
    
    init(coordinator: SambaPlayCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        updateFromAudioPlayer()
    }
    
    private func setupUI() {
        title = "Audio Settings"
        view.backgroundColor = .systemBackground
        
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissSettings))
        
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentInsetAdjustmentBehavior = .automatic
        scrollView.showsVerticalScrollIndicator = true
        view.addSubview(scrollView)
        
        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        
        // MARK: - Header Section
        let headerContainer = UIView()
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        
        let titleLabel = UILabel()
        titleLabel.text = "⚙️ Audio Controls"
        titleLabel.font = .systemFont(ofSize: 32, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.textColor = .label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        let subtitleLabel = UILabel()
        subtitleLabel.text = "Adjust playback speed and pitch independently"
        subtitleLabel.font = .systemFont(ofSize: 17, weight: .medium)
        subtitleLabel.textAlignment = .center
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        headerContainer.addSubview(titleLabel)
        headerContainer.addSubview(subtitleLabel)
        
        // MARK: - Speed Control Section
        let speedContainer = createSpeedControlSection()
        
        // MARK: - Pitch Control Section  
        let pitchContainer = createPitchControlSection()
        
        // MARK: - Additional Controls Section
        let additionalContainer = createAdditionalControlsSection()
        
        // MARK: - Reset Section
        let resetContainer = UIView()
        resetContainer.translatesAutoresizingMaskIntoConstraints = false
        resetContainer.addSubview(resetButton)
        
        // Add all sections to content view
        contentView.addSubview(headerContainer)
        contentView.addSubview(speedContainer)
        contentView.addSubview(pitchContainer)
        contentView.addSubview(additionalContainer)
        contentView.addSubview(resetContainer)
        
        // MARK: - Layout Constraints
        NSLayoutConstraint.activate([
            // Scroll View
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            // Content View
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            
            // Header Container
            headerContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            headerContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            headerContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            headerContainer.heightAnchor.constraint(equalToConstant: 120),
            
            titleLabel.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            subtitleLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: headerContainer.bottomAnchor, constant: -10),
            
            // Speed Container
            speedContainer.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 30),
            speedContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            speedContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            
            // Pitch Container
            pitchContainer.topAnchor.constraint(equalTo: speedContainer.bottomAnchor, constant: 30),
            pitchContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            pitchContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            
            // Additional Controls Container
            additionalContainer.topAnchor.constraint(equalTo: pitchContainer.bottomAnchor, constant: 30),
            additionalContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            additionalContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            
            // Reset Container
            resetContainer.topAnchor.constraint(equalTo: additionalContainer.bottomAnchor, constant: 40),
            resetContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            resetContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            resetContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -60),
            resetContainer.heightAnchor.constraint(equalToConstant: 80),
            
            resetButton.centerXAnchor.constraint(equalTo: resetContainer.centerXAnchor),
            resetButton.centerYAnchor.constraint(equalTo: resetContainer.centerYAnchor),
            resetButton.widthAnchor.constraint(equalToConstant: 240),
            resetButton.heightAnchor.constraint(equalToConstant: 56)
        ])
    }
    
    private func createSpeedControlSection() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .secondarySystemBackground
        container.layer.cornerRadius = 16
        container.layer.shadowColor = UIColor.label.cgColor
        container.layer.shadowOffset = CGSize(width: 0, height: 2)
        container.layer.shadowOpacity = 0.1
        container.layer.shadowRadius = 4
        
        // Title
        let titleLabel = UILabel()
        titleLabel.text = "🏃‍♂️ Playback Speed"
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        // Current value display
        let valueContainer = UIView()
        valueContainer.translatesAutoresizingMaskIntoConstraints = false
        valueContainer.backgroundColor = .tertiarySystemBackground
        valueContainer.layer.cornerRadius = 12
        valueContainer.addSubview(speedValueLabel)
        
        // Slider
        speedSlider.translatesAutoresizingMaskIntoConstraints = false
        
        // Range labels
        let minLabel = UILabel()
        minLabel.text = "0.5×"
        minLabel.font = .systemFont(ofSize: 14, weight: .medium)
        minLabel.textColor = .secondaryLabel
        minLabel.translatesAutoresizingMaskIntoConstraints = false
        
        let maxLabel = UILabel()
        maxLabel.text = "3.0×"
        maxLabel.font = .systemFont(ofSize: 14, weight: .medium)
        maxLabel.textColor = .secondaryLabel
        maxLabel.translatesAutoresizingMaskIntoConstraints = false
        
        // Control buttons and text field
        let controlsContainer = createSpeedControlsContainer()
        
        // Preset buttons
        let presetsContainer = createSpeedPresetsContainer()
        
        container.addSubview(titleLabel)
        container.addSubview(valueContainer)
        container.addSubview(speedSlider)
        container.addSubview(minLabel)
        container.addSubview(maxLabel)
        container.addSubview(controlsContainer)
        container.addSubview(presetsContainer)
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            
            valueContainer.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            valueContainer.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            valueContainer.widthAnchor.constraint(equalToConstant: 120),
            valueContainer.heightAnchor.constraint(equalToConstant: 50),
            
            speedValueLabel.centerXAnchor.constraint(equalTo: valueContainer.centerXAnchor),
            speedValueLabel.centerYAnchor.constraint(equalTo: valueContainer.centerYAnchor),
            
            speedSlider.topAnchor.constraint(equalTo: valueContainer.bottomAnchor, constant: 20),
            speedSlider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 40),
            speedSlider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -40),
            speedSlider.heightAnchor.constraint(equalToConstant: 44),
            
            minLabel.topAnchor.constraint(equalTo: speedSlider.bottomAnchor, constant: 8),
            minLabel.leadingAnchor.constraint(equalTo: speedSlider.leadingAnchor),
            
            maxLabel.topAnchor.constraint(equalTo: speedSlider.bottomAnchor, constant: 8),
            maxLabel.trailingAnchor.constraint(equalTo: speedSlider.trailingAnchor),
            
            controlsContainer.topAnchor.constraint(equalTo: minLabel.bottomAnchor, constant: 20),
            controlsContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            controlsContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            controlsContainer.heightAnchor.constraint(equalToConstant: 50),
            
            presetsContainer.topAnchor.constraint(equalTo: controlsContainer.bottomAnchor, constant: 16),
            presetsContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            presetsContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            presetsContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            presetsContainer.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        return container
    }
    
    private func createSpeedControlsContainer() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        
        // Decrease button
        let decreaseButton = UIButton(type: .system)
        var decreaseConfig = UIButton.Configuration.filled()
        decreaseConfig.title = "-1%"
        decreaseConfig.baseBackgroundColor = .systemRed
        decreaseConfig.baseForegroundColor = .white
        decreaseConfig.cornerStyle = .medium
        decreaseConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        decreaseButton.configuration = decreaseConfig
        decreaseButton.translatesAutoresizingMaskIntoConstraints = false
        decreaseButton.addTarget(self, action: #selector(decreaseSpeed), for: .touchUpInside)
        
        // Increase button
        let increaseButton = UIButton(type: .system)
        var increaseConfig = UIButton.Configuration.filled()
        increaseConfig.title = "+1%"
        increaseConfig.baseBackgroundColor = .systemGreen
        increaseConfig.baseForegroundColor = .white
        increaseConfig.cornerStyle = .medium
        increaseConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        increaseButton.configuration = increaseConfig
        increaseButton.translatesAutoresizingMaskIntoConstraints = false
        increaseButton.addTarget(self, action: #selector(increaseSpeed), for: .touchUpInside)
        
        container.addSubview(decreaseButton)
        container.addSubview(speedTextField)
        container.addSubview(increaseButton)
        
        NSLayoutConstraint.activate([
            decreaseButton.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            decreaseButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            decreaseButton.widthAnchor.constraint(equalToConstant: 70),
            decreaseButton.heightAnchor.constraint(equalToConstant: 44),
            
            speedTextField.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            speedTextField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            speedTextField.widthAnchor.constraint(equalToConstant: 100),
            speedTextField.heightAnchor.constraint(equalToConstant: 44),
            
            increaseButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            increaseButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            increaseButton.widthAnchor.constraint(equalToConstant: 70),
            increaseButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        return container
    }
    
    private func createSpeedPresetsContainer() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        
        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.distribution = .fillEqually
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        let presets = [0.75, 1.0, 1.25, 1.5, 2.0]
        
        for preset in presets {
            let button = UIButton(type: .system)
            var config = UIButton.Configuration.gray()
            config.title = "\(preset)×"
            config.cornerStyle = .medium
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
            button.configuration = config
            button.tag = Int(preset * 100) // Store preset value
            button.addTarget(self, action: #selector(speedPresetTapped(_:)), for: .touchUpInside)
            stackView.addArrangedSubview(button)
        }
        
        container.addSubview(stackView)
        
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: container.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        
        return container
    }
    
    private func createPitchControlSection() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .secondarySystemBackground
        container.layer.cornerRadius = 16
        container.layer.shadowColor = UIColor.label.cgColor
        container.layer.shadowOffset = CGSize(width: 0, height: 2)
        container.layer.shadowOpacity = 0.1
        container.layer.shadowRadius = 4
        
        // Title
        let titleLabel = UILabel()
        titleLabel.text = "🎵 Pitch Adjustment"
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        // Current value display
        let valueContainer = UIView()
        valueContainer.translatesAutoresizingMaskIntoConstraints = false
        valueContainer.backgroundColor = .tertiarySystemBackground
        valueContainer.layer.cornerRadius = 12
        valueContainer.addSubview(pitchValueLabel)
        
        // Range labels
        let minLabel = UILabel()
        minLabel.text = "-6 semitones"
        minLabel.font = .systemFont(ofSize: 14, weight: .medium)
        minLabel.textColor = .secondaryLabel
        minLabel.translatesAutoresizingMaskIntoConstraints = false
        
        let maxLabel = UILabel()
        maxLabel.text = "+6 semitones"
        maxLabel.font = .systemFont(ofSize: 14, weight: .medium)
        maxLabel.textColor = .secondaryLabel
        maxLabel.translatesAutoresizingMaskIntoConstraints = false
        
        // Preset buttons
        let presetsContainer = createPitchPresetsContainer()
        
        container.addSubview(titleLabel)
        container.addSubview(valueContainer)
        container.addSubview(pitchSlider)
        container.addSubview(minLabel)
        container.addSubview(maxLabel)
        container.addSubview(presetsContainer)
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            
            valueContainer.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            valueContainer.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            valueContainer.widthAnchor.constraint(equalToConstant: 160),
            valueContainer.heightAnchor.constraint(equalToConstant: 50),
            
            pitchValueLabel.centerXAnchor.constraint(equalTo: valueContainer.centerXAnchor),
            pitchValueLabel.centerYAnchor.constraint(equalTo: valueContainer.centerYAnchor),
            
            pitchSlider.topAnchor.constraint(equalTo: valueContainer.bottomAnchor, constant: 20),
            pitchSlider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 40),
            pitchSlider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -40),
            pitchSlider.heightAnchor.constraint(equalToConstant: 44),
            
            minLabel.topAnchor.constraint(equalTo: pitchSlider.bottomAnchor, constant: 8),
            minLabel.leadingAnchor.constraint(equalTo: pitchSlider.leadingAnchor),
            
            maxLabel.topAnchor.constraint(equalTo: pitchSlider.bottomAnchor, constant: 8),
            maxLabel.trailingAnchor.constraint(equalTo: pitchSlider.trailingAnchor),
            
            presetsContainer.topAnchor.constraint(equalTo: minLabel.bottomAnchor, constant: 20),
            presetsContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            presetsContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            presetsContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            presetsContainer.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        return container
    }
    
    private func createPitchPresetsContainer() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        
        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.distribution = .fillEqually
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        let presets: [(Float, String)] = [
            (0.5, "-6♭"),
            (0.75, "-3♭"),
            (1.0, "0"),
            (1.25, "+3♯"),
            (1.5, "+6♯")
        ]
        
        for (value, title) in presets {
            let button = UIButton(type: .system)
            var config = UIButton.Configuration.gray()
            config.title = title
            config.cornerStyle = .medium
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
            button.configuration = config
            button.tag = Int(value * 100) // Store preset value
            button.addTarget(self, action: #selector(pitchPresetTapped(_:)), for: .touchUpInside)
            stackView.addArrangedSubview(button)
        }
        
        container.addSubview(stackView)
        
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: container.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        
        return container
    }
    
    private func createAdditionalControlsSection() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .secondarySystemBackground
        container.layer.cornerRadius = 16
        container.layer.shadowColor = UIColor.label.cgColor
        container.layer.shadowOffset = CGSize(width: 0, height: 2)
        container.layer.shadowOpacity = 0.1
        container.layer.shadowRadius = 4
        
        let titleLabel = UILabel()
        titleLabel.text = "🔧 Additional Controls"
        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        let stackView = UIStackView()
        stackView.axis = .horizontal
        stackView.distribution = .fillEqually
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        // Test Audio button
        let testButton = UIButton(type: .system)
        var testConfig = UIButton.Configuration.filled()
        testConfig.title = "🔊 Test Audio"
        testConfig.baseBackgroundColor = .systemBlue
        testConfig.baseForegroundColor = .white
        testConfig.cornerStyle = .medium
        testButton.configuration = testConfig
        testButton.addTarget(self, action: #selector(testAudio), for: .touchUpInside)
        
        // Sync to BPM button
        let bpmButton = UIButton(type: .system)
        var bpmConfig = UIButton.Configuration.filled()
        bpmConfig.title = "🎵 Sync BPM"
        bpmConfig.baseBackgroundColor = .systemOrange
        bpmConfig.baseForegroundColor = .white
        bpmConfig.cornerStyle = .medium
        bpmButton.configuration = bpmConfig
        bpmButton.addTarget(self, action: #selector(syncToBPM), for: .touchUpInside)
        
        stackView.addArrangedSubview(testButton)
        stackView.addArrangedSubview(bpmButton)
        
        container.addSubview(titleLabel)
        container.addSubview(stackView)
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            
            stackView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            stackView.heightAnchor.constraint(equalToConstant: 50)
        ])
        
        return container
    }
    
    private func updateFromAudioPlayer() {
        let speed = coordinator.audioPlayer.speed
        let pitch = coordinator.audioPlayer.pitch
        
        speedSlider.value = speed
        speedValueLabel.text = String(format: "%.2fx", speed)
        speedTextField.text = String(format: "%.2f", speed)
        
        pitchSlider.value = pitch
        let semitones = (pitch - 1.0) * 12.0
        pitchValueLabel.text = String(format: "%.1f semitones", semitones)
    }
    
    @objc private func dismissSettings() {
        dismiss(animated: true)
    }
    
    @objc private func speedSliderChanged() {
        let speed = speedSlider.value
        speedValueLabel.text = String(format: "%.2fx", speed)
        speedTextField.text = String(format: "%.2f", speed)
        coordinator.audioPlayer.setSpeed(speed)
    }
    
    @objc private func speedTextChanged() {
        guard let text = speedTextField.text, let speed = Float(text) else { return }
        let clampedSpeed = max(0.5, min(3.0, speed))
        speedSlider.value = clampedSpeed
        speedValueLabel.text = String(format: "%.2fx", clampedSpeed)
        coordinator.audioPlayer.setSpeed(clampedSpeed)
    }
    
    @objc private func decreaseSpeed() {
        let currentSpeed = speedSlider.value
        let newSpeed = max(0.5, currentSpeed - 0.01)
        speedSlider.value = newSpeed
        speedValueLabel.text = String(format: "%.2fx", newSpeed)
        speedTextField.text = String(format: "%.2f", newSpeed)
        coordinator.audioPlayer.setSpeed(newSpeed)
    }
    
    @objc private func increaseSpeed() {
        let currentSpeed = speedSlider.value
        let newSpeed = min(3.0, currentSpeed + 0.01)
        speedSlider.value = newSpeed
        speedValueLabel.text = String(format: "%.2fx", newSpeed)
        speedTextField.text = String(format: "%.2f", newSpeed)
        coordinator.audioPlayer.setSpeed(newSpeed)
    }
    
    @objc private func speedPresetTapped(_ sender: UIButton) {
        let speed = Float(sender.tag) / 100.0
        speedSlider.value = speed
        speedValueLabel.text = String(format: "%.2fx", speed)
        speedTextField.text = String(format: "%.2f", speed)
        coordinator.audioPlayer.setSpeed(speed)
        
        // Visual feedback
        UIView.animate(withDuration: 0.1, animations: {
            sender.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }) { _ in
            UIView.animate(withDuration: 0.1) {
                sender.transform = CGAffineTransform.identity
            }
        }
    }
    
    @objc private func pitchSliderChanged() {
        let pitch = pitchSlider.value
        let semitones = (pitch - 1.0) * 12.0
        pitchValueLabel.text = String(format: "%.1f semitones", semitones)
        coordinator.audioPlayer.setPitch(pitch)
    }
    
    @objc private func pitchPresetTapped(_ sender: UIButton) {
        let pitch = Float(sender.tag) / 100.0
        pitchSlider.value = pitch
        let semitones = (pitch - 1.0) * 12.0
        pitchValueLabel.text = String(format: "%.1f semitones", semitones)
        coordinator.audioPlayer.setPitch(pitch)
        
        // Visual feedback
        UIView.animate(withDuration: 0.1, animations: {
            sender.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }) { _ in
            UIView.animate(withDuration: 0.1) {
                sender.transform = CGAffineTransform.identity
            }
        }
    }
    
    @objc private func testAudio() {
        // Load and play the sample song for testing
        let sampleFile = MediaFile(
            name: "Sample Song.mp3",
            path: "/Sample Song.mp3",
            size: 3932160,
            modificationDate: Date(),
            isDirectory: false,
            fileExtension: "mp3"
        )
        
        coordinator.audioPlayer.loadFile(sampleFile) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.coordinator.audioPlayer.play()
                    self?.showAlert(title: "Test Audio", message: "Playing sample song with current settings")
                case .failure(let error):
                    self?.showAlert(title: "Test Failed", message: "Could not load sample audio: \(error.localizedDescription)")
                }
            }
        }
    }
    
    @objc private func syncToBPM() {
        let alert = UIAlertController(title: "Sync to BPM", message: "Enter the target BPM to automatically adjust playback speed", preferredStyle: .alert)
        
        alert.addTextField { textField in
            textField.placeholder = "120"
            textField.keyboardType = .numberPad
        }
        
        let syncAction = UIAlertAction(title: "Sync", style: .default) { [weak self] _ in
            guard let bpmText = alert.textFields?.first?.text,
                  let targetBPM = Float(bpmText),
                  targetBPM > 0 else {
                self?.showAlert(title: "Invalid BPM", message: "Please enter a valid BPM value")
                return
            }
            
            // Assume original track is 120 BPM (could be made configurable)
            let originalBPM: Float = 120
            let speedMultiplier = targetBPM / originalBPM
            let clampedSpeed = max(0.5, min(3.0, speedMultiplier))
            
            self?.speedSlider.value = clampedSpeed
            self?.speedValueLabel.text = String(format: "%.2fx", clampedSpeed)
            self?.speedTextField.text = String(format: "%.2f", clampedSpeed)
            self?.coordinator.audioPlayer.setSpeed(clampedSpeed)
            
            self?.showAlert(title: "BPM Synced", message: "Speed adjusted to \(String(format: "%.2f", clampedSpeed))× for \(Int(targetBPM)) BPM")
        }
        
        alert.addAction(syncAction)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        present(alert, animated: true)
    }
    
    @objc private func resetDefaults() {
        speedSlider.value = 1.0
        speedValueLabel.text = "1.00x"
        speedTextField.text = "1.00"
        coordinator.audioPlayer.setSpeed(1.0)
        
        pitchSlider.value = 1.0
        pitchValueLabel.text = "0.0 semitones"
        coordinator.audioPlayer.setPitch(1.0)
        
        showAlert(title: "Reset Complete", message: "Speed and pitch have been reset to default values")
    }
    
    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}



// MARK: - UIDocumentPickerDelegate Extension
extension MainViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        
        // Check if this is a folder selection
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        
        if isFolder {
            // Handle folder selection - create security-scoped bookmark
            handleFolderSelection(url)
        } else {
            // Handle individual file selection
            handleFileSelection(urls)
        }
    }
    
    private func handleFolderSelection(_ url: URL) {
        do {
            // Create security-scoped bookmark for the folder
            let bookmarkData = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            
            // Create LocalFolder object
            let folder = LocalFolder(name: url.lastPathComponent, bookmarkData: bookmarkData)
            
            // Add to network service
            coordinator.networkService.addFolder(folder)
            
            // Connect to the folder
            coordinator.networkService.connectToFolder(folder)
            
            // Update UI
            DispatchQueue.main.async {
                self.updateConnectionStatus(.connected)
            }
            
        } catch {
            DispatchQueue.main.async {
                let alert = UIAlertController(title: "Error", message: "Failed to bookmark folder: \(error.localizedDescription)", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(alert, animated: true)
            }
        }
    }
    
    private func handleFileSelection(_ urls: [URL]) {
        var localFiles: [MediaFile] = []
        
        for url in urls {
            // Start accessing security-scoped resource
            guard url.startAccessingSecurityScopedResource() else { continue }
            
            defer { url.stopAccessingSecurityScopedResource() }
            
            let fileExtension = url.pathExtension.lowercased()
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            
            let mediaFile = MediaFile(
                name: url.lastPathComponent,
                path: url.path,
                size: Int64(fileSize),
                modificationDate: modificationDate,
                isDirectory: false,
                fileExtension: fileExtension
            )
            
            localFiles.append(mediaFile)
        }
        
        coordinator.networkService.currentFiles = localFiles
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // User cancelled, stay in local mode but show empty list
        coordinator.networkService.currentFiles = []
    }
}

// MARK: - Server Management View Controller
class ServerManagementViewController: UIViewController {
    private let networkService: SimpleNetworkService
    private var cancellables = Set<AnyCancellable>()
    
    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.delegate = self
        table.dataSource = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "ServerCell")
        return table
    }()
    
    init(networkService: SimpleNetworkService) {
        self.networkService = networkService
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupBindings()
    }
    
    private func setupUI() {
        title = "Manage Servers"
        view.backgroundColor = .systemBackground
        
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissController)
        )
        
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addServer)
        )
        
        view.addSubview(tableView)
        
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    private func setupBindings() {
        networkService.$savedServers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.tableView.reloadData()
            }
            .store(in: &cancellables)
    }
    
    @objc private func dismissController() {
        dismiss(animated: true)
    }
    
    @objc private func addServer() {
        showAddServerDialog()
    }
    
    private func showAddServerDialog() {
        let alert = UIAlertController(title: "Add Samba Server", message: "Enter server details", preferredStyle: .alert)
        
        alert.addTextField { textField in
            textField.placeholder = "Server Name"
        }
        
        alert.addTextField { textField in
            textField.placeholder = "Host (IP or hostname)"
        }
        
        alert.addTextField { textField in
            textField.placeholder = "Port (optional, default 445)"
            textField.keyboardType = .numberPad
        }
        
        alert.addTextField { textField in
            textField.placeholder = "Username (optional)"
        }
        
        alert.addTextField { textField in
            textField.placeholder = "Password (optional)"
            textField.isSecureTextEntry = true
        }
        
        alert.addAction(UIAlertAction(title: "Add", style: .default) { _ in
            guard let nameField = alert.textFields?[0],
                  let hostField = alert.textFields?[1],
                  let name = nameField.text, !name.isEmpty,
                  let host = hostField.text, !host.isEmpty else {
                let errorAlert = UIAlertController(title: "Error", message: "Please enter server name and host", preferredStyle: .alert)
                errorAlert.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(errorAlert, animated: true)
                return
            }
            
            let portText = alert.textFields?[2].text ?? ""
            let port = Int16(portText) ?? 445
            let username = alert.textFields?[3].text
            let password = alert.textFields?[4].text
            
            let server = SambaServer(
                name: name,
                host: host,
                port: port,
                username: username?.isEmpty == false ? username : nil,
                password: password?.isEmpty == false ? password : nil
            )
            
            self.networkService.addServer(server)
        })
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        present(alert, animated: true)
    }
}

// MARK: - Server Management Table View
extension ServerManagementViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return networkService.savedServers.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ServerCell", for: indexPath)
        let server = networkService.savedServers[indexPath.row]
        
        cell.textLabel?.text = server.name
        cell.detailTextLabel?.text = "\(server.host):\(server.port)"
        cell.imageView?.image = UIImage(systemName: "server.rack")
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let server = networkService.savedServers[indexPath.row]
        networkService.connect(to: server)
        dismiss(animated: true)
    }
    
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let server = networkService.savedServers[indexPath.row]
            networkService.removeServer(server)
        }
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }
}

// MARK: - Folder History View Controller
class FolderHistoryViewController: UIViewController {
    private let networkService: SimpleNetworkService
    private var cancellables = Set<AnyCancellable>()
    
    private lazy var tableView: UITableView = {
        let tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "FolderCell")
        return tableView
    }()
    
    init(networkService: SimpleNetworkService) {
        self.networkService = networkService
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "Saved Folders"
        view.backgroundColor = .systemBackground
        
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(dismissViewController))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addFolder))
        
        setupUI()
        setupBindings()
    }
    
    private func setupUI() {
        view.addSubview(tableView)
        
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    private func setupBindings() {
        networkService.$savedFolders
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.tableView.reloadData()
            }
            .store(in: &cancellables)
    }
    
    @objc private func dismissViewController() {
        dismiss(animated: true)
    }
    
    @objc private func addFolder() {
        let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
        documentPicker.delegate = self
        documentPicker.allowsMultipleSelection = false
        present(documentPicker, animated: true)
    }
}

// MARK: - Folder History Table View
extension FolderHistoryViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return networkService.savedFolders.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FolderCell", for: indexPath)
        let folder = networkService.savedFolders[indexPath.row]
        
        cell.textLabel?.text = folder.name
        cell.detailTextLabel?.text = "Added: \(DateFormatter.localizedString(from: folder.dateAdded, dateStyle: .short, timeStyle: .short))"
        cell.imageView?.image = UIImage(systemName: "folder.fill")
        cell.accessoryType = .disclosureIndicator
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let folder = networkService.savedFolders[indexPath.row]
        networkService.connectToFolder(folder)
        dismiss(animated: true)
    }
    
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let folder = networkService.savedFolders[indexPath.row]
            networkService.removeFolder(folder)
        }
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }
}

// MARK: - Folder History Document Picker
extension FolderHistoryViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        
        do {
            let bookmarkData = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let folder = LocalFolder(name: url.lastPathComponent, bookmarkData: bookmarkData)
            networkService.addFolder(folder)
        } catch {
            let alert = UIAlertController(title: "Error", message: "Failed to bookmark folder: \(error.localizedDescription)", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // User cancelled, do nothing
    }
}

// MARK: - Settings View Controller
class SettingsViewController: UIViewController {
    private let coordinator: SambaPlayCoordinator
    private var cancellables = Set<AnyCancellable>()
    
    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.delegate = self
        table.dataSource = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "SettingCell")
        table.register(SwitchTableViewCell.self, forCellReuseIdentifier: "SwitchCell")
        table.register(SegmentedTableViewCell.self, forCellReuseIdentifier: "SegmentedCell")
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 80 // Increased for segmented cells
        table.sectionHeaderHeight = UITableView.automaticDimension
        table.estimatedSectionHeaderHeight = 30
        table.sectionFooterHeight = UITableView.automaticDimension
        table.estimatedSectionFooterHeight = 20
        return table
    }()
    
    // Settings sections
    private enum SettingsSection: Int, CaseIterable {
        case interface = 0
        case accessibility = 1
        case functionality = 2
        case playback = 3
        case performance = 4
        case about = 5
        case logs = 6
        
        var title: String {
            switch self {
            case .interface: return "Interface"
            case .accessibility: return "Accessibility"
            case .functionality: return "Functionality"
            case .playback: return "Playback"
            case .performance: return "Performance"
            case .about: return "About"
            case .logs: return "Debug Logs"
            }
        }
        
        var footer: String? {
            switch self {
            case .interface: return "Customize the app's appearance and behavior"
            case .accessibility: return "Enhance accessibility features for better usability"
            case .functionality: return "Configure search, drag & drop, and file handling"
            case .playback: return "Control audio playback behavior"
            case .performance: return "Monitor memory usage and performance metrics"
            case .about: return nil
            case .logs: return "View live test output and debug information"
            }
        }
    }
    
    private enum InterfaceRow: Int, CaseIterable {
        case interfaceStyle = 0
        case haptics = 1
        
        var title: String {
            switch self {
            case .interfaceStyle: return "Interface Style"
            case .haptics: return "Haptic Feedback"
            }
        }
        
        var subtitle: String? {
            switch self {
            case .interfaceStyle: return "Choose light, dark, or system"
            case .haptics: return "Vibration feedback for interactions"
            }
        }
    }
    
    private enum AccessibilityRow: Int, CaseIterable {
        case enhancedAccessibility = 0
        case voiceOverOptimization = 1
        case dynamicText = 2
        case verbosity = 3
        
        var title: String {
            switch self {
            case .enhancedAccessibility: return "Enhanced Accessibility"
            case .voiceOverOptimization: return "VoiceOver Optimization"
            case .dynamicText: return "Dynamic Text Sizing"
            case .verbosity: return "Accessibility Verbosity"
            }
        }
        
        var subtitle: String? {
            switch self {
            case .enhancedAccessibility: return "Enable comprehensive accessibility features"
            case .voiceOverOptimization: return "Optimize interface for VoiceOver users"
            case .dynamicText: return "Respect system text size preferences"
            case .verbosity: return "Control amount of accessibility information"
            }
        }
    }
    
    private enum FunctionalityRow: Int, CaseIterable {
        case search = 0
        case lyricsSearch = 1
        case searchScope = 2
        case dragDrop = 3
        case dragDropScope = 4
        
        var title: String {
            switch self {
            case .search: return "File Search"
            case .lyricsSearch: return "Lyrics Search"
            case .searchScope: return "Search Scope"
            case .dragDrop: return "Drag & Drop"
            case .dragDropScope: return "Drag & Drop Files"
            }
        }
        
        var subtitle: String? {
            switch self {
            case .search: return "Enable real-time file search"
            case .lyricsSearch: return "Search within text files instead of filenames"
            case .searchScope: return "What files to include in search"
            case .dragDrop: return "Import files via drag and drop"
            case .dragDropScope: return "Which file types to accept"
            }
        }
    }
    
    private enum PlaybackRow: Int, CaseIterable {
        case autoPlay = 0
        
        var title: String {
            switch self {
            case .autoPlay: return "Auto-Play"
            }
        }
        
        var subtitle: String? {
            switch self {
            case .autoPlay: return "Automatically start playback when loading files"
            }
        }
    }
    
    private enum PerformanceRow: Int, CaseIterable {
        case memoryUsage = 0
        case cacheSize = 1
        case cacheHitRate = 2
        case averageLoadTime = 3
        case memoryEfficiency = 4
        case clearCache = 5
        
        var title: String {
            switch self {
            case .memoryUsage: return "Memory Usage"
            case .cacheSize: return "Cache Size"
            case .cacheHitRate: return "Cache Hit Rate"
            case .averageLoadTime: return "Average Load Time"
            case .memoryEfficiency: return "Memory Efficiency"
            case .clearCache: return "Clear Cache"
            }
        }
        
        var subtitle: String? {
            switch self {
            case .memoryUsage: return "Current memory usage percentage"
            case .cacheSize: return "Total size of cached data"
            case .cacheHitRate: return "Percentage of cache hits vs misses"
            case .averageLoadTime: return "Average time to load content"
            case .memoryEfficiency: return "Overall memory efficiency score"
            case .clearCache: return "Clear all cached images and data"
            }
        }
    }
    
    private enum AboutRow: Int, CaseIterable {
        case version = 0
        case resetSettings = 1
        case runTests = 2
        
        var title: String {
            switch self {
            case .version: return "Version"
            case .resetSettings: return "Reset All Settings"
            case .runTests: return "Run Tests"
            }
        }
        
        var subtitle: String? {
            switch self {
            case .version: return "SambaPlay v0.33.0"
            case .resetSettings: return "Restore default settings"
            case .runTests: return "Run comprehensive test suite"
            }
        }
    }
    
    private enum LogsRow: Int, CaseIterable {
        case viewLogs = 0
        case clearLogs = 1
        case exportLogs = 2
        
        var title: String {
            switch self {
            case .viewLogs: return "View Live Logs"
            case .clearLogs: return "Clear Logs"
            case .exportLogs: return "Export Logs"
            }
        }
        
        var subtitle: String? {
            switch self {
            case .viewLogs: return "View real-time test output and debug information"
            case .clearLogs: return "Clear all stored log entries"
            case .exportLogs: return "Export logs to share or save"
            }
        }
    }
    
    init(coordinator: SambaPlayCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupBindings()
    }
    
    private func setupUI() {
        title = "Settings"
        view.backgroundColor = .systemBackground
        
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(dismissSettings)
        )
        
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .save,
            target: self,
            action: #selector(saveSettings)
        )
        
        view.addSubview(tableView)
        
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    private func setupBindings() {
        // Listen for settings changes and update UI accordingly
        coordinator.settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.tableView.reloadData()
            }
            .store(in: &cancellables)
        
        // Setup performance metrics refresh timer
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshPerformanceMetrics()
        }
    }
    
    private func refreshPerformanceMetrics() {
        guard let performanceSection = SettingsSection.allCases.firstIndex(of: .performance) else { return }
        
        // Only refresh if the performance section is visible
        let visibleSections = tableView.indexPathsForVisibleRows?.map { $0.section } ?? []
        if visibleSections.contains(performanceSection) {
            DispatchQueue.main.async {
                self.tableView.reloadSections(IndexSet(integer: performanceSection), with: .none)
            }
        }
    }
    
    @objc private func dismissSettings() {
        dismiss(animated: true)
    }
    
    @objc private func saveSettings() {
        coordinator.settings.saveSettings()
        
        // Show confirmation
        let alert = UIAlertController(title: "Settings Saved", message: "Your preferences have been saved successfully.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            self.dismiss(animated: true)
        })
        present(alert, animated: true)
    }
    
    private func showResetConfirmation() {
        let alert = UIAlertController(
            title: "Reset All Settings",
            message: "Are you sure you want to reset all settings to their default values? This action cannot be undone.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { _ in
            self.resetAllSettings()
        })
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        present(alert, animated: true)
    }
    
    private func resetAllSettings() {
        // Reset all settings to defaults
        coordinator.settings.isDarkModeEnabled = false
        coordinator.settings.isAccessibilityEnhanced = true
        coordinator.settings.isSearchEnabled = true
        coordinator.settings.isLyricsSearchEnabled = false
        coordinator.settings.isDragDropEnabled = true
        coordinator.settings.isVoiceOverOptimized = true
        coordinator.settings.isDynamicTextEnabled = true
        coordinator.settings.isHapticsEnabled = true
        coordinator.settings.isAutoPlayEnabled = true
        coordinator.settings.searchScopeIncludes = .all
        coordinator.settings.dragDropFileTypes = .audioOnly
        coordinator.settings.accessibilityVerbosity = .standard
        coordinator.settings.interfaceStyle = .system
        
        coordinator.settings.saveSettings()
        tableView.reloadData()
        
        // Show confirmation
        let alert = UIAlertController(title: "Settings Reset", message: "All settings have been reset to their default values.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
    
    private func runComprehensiveTests() {
        let alert = UIAlertController(
            title: "Run Tests",
            message: "This will run a comprehensive test suite to verify all app functionality. The results will be logged and can be viewed in the Debug Logs section.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Run Tests", style: .default) { _ in
            self.executeTestSuite()
        })
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        present(alert, animated: true)
    }
    
    private func executeTestSuite() {
        // Show loading indicator
        let loadingAlert = UIAlertController(title: "Running Tests", message: "Please wait while tests are executed...", preferredStyle: .alert)
        present(loadingAlert, animated: true)
        
        // Run tests on background queue
        DispatchQueue.global(qos: .userInitiated).async {
            let testHelper = TestingHelper.shared
            
            // Run all tests
            testHelper.runAllTests()
            testHelper.testAppIntegration()
            testHelper.testFileSystemOperations()
            testHelper.testPerformance()
            
            // Return to main queue for UI updates
            DispatchQueue.main.async {
                loadingAlert.dismiss(animated: true) {
                    let alert = UIAlertController(
                        title: "Tests Completed",
                        message: "All tests have been executed successfully! View the results in Debug Logs → View Live Logs.",
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "View Logs", style: .default) { _ in
                        self.showLiveLogsViewer()
                    })
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(alert, animated: true)
                }
            }
        }
    }
}

// MARK: - Settings Table View Data Source & Delegate
extension SettingsViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        return SettingsSection.allCases.count
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let settingsSection = SettingsSection(rawValue: section) else { return 0 }
        
        switch settingsSection {
        case .interface:
            return InterfaceRow.allCases.count
        case .accessibility:
            return AccessibilityRow.allCases.count
        case .functionality:
            return FunctionalityRow.allCases.count
        case .playback:
            return PlaybackRow.allCases.count
        case .performance:
            return PerformanceRow.allCases.count
        case .about:
            return AboutRow.allCases.count
        case .logs:
            return LogsRow.allCases.count
        }
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return SettingsSection(rawValue: section)?.title
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return SettingsSection(rawValue: section)?.footer
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let settingsSection = SettingsSection(rawValue: indexPath.section) else {
            return UITableViewCell()
        }
        
        switch settingsSection {
        case .interface:
            return configureInterfaceCell(for: indexPath)
        case .accessibility:
            return configureAccessibilityCell(for: indexPath)
        case .functionality:
            return configureFunctionalityCell(for: indexPath)
        case .playback:
            return configurePlaybackCell(for: indexPath)
        case .performance:
            return configurePerformanceCell(for: indexPath)
        case .about:
            return configureAboutCell(for: indexPath)
        case .logs:
            return configureLogsCell(for: indexPath)
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        guard let settingsSection = SettingsSection(rawValue: indexPath.section) else { return }
        
        switch settingsSection {
        case .performance:
            if indexPath.row == PerformanceRow.clearCache.rawValue {
                clearAllCaches()
            }
        case .about:
            if indexPath.row == AboutRow.resetSettings.rawValue {
                showResetConfirmation()
            } else if indexPath.row == AboutRow.runTests.rawValue {
                runComprehensiveTests()
            }
        case .logs:
            if indexPath.row == LogsRow.viewLogs.rawValue {
                showLiveLogsViewer()
            } else if indexPath.row == LogsRow.clearLogs.rawValue {
                clearAllLogs()
            } else if indexPath.row == LogsRow.exportLogs.rawValue {
                exportLogs()
            }
        default:
            break
        }
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let settingsSection = SettingsSection(rawValue: indexPath.section) else {
            return UITableView.automaticDimension
        }
        
        // Return specific heights for segmented control cells
        switch settingsSection {
        case .interface:
            if let row = InterfaceRow(rawValue: indexPath.row), row == .interfaceStyle {
                return 100 // Extra height for segmented control
            }
        case .accessibility:
            if let row = AccessibilityRow(rawValue: indexPath.row), row == .verbosity {
                return 100 // Extra height for segmented control
            }
        case .functionality:
            if let row = FunctionalityRow(rawValue: indexPath.row), 
               row == .searchScope || row == .dragDropScope {
                return 100 // Extra height for segmented control
            }
        default:
            break
        }
        
        return UITableView.automaticDimension
    }
    
    private func configureInterfaceCell(for indexPath: IndexPath) -> UITableViewCell {
        guard let row = InterfaceRow(rawValue: indexPath.row) else {
            return UITableViewCell()
        }
        
        switch row {
        case .interfaceStyle:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SegmentedCell", for: indexPath) as! SegmentedTableViewCell
            cell.configure(
                title: row.title,
                subtitle: row.subtitle,
                options: AppSettings.InterfaceStyle.allCases.map { $0.description },
                selectedIndex: AppSettings.InterfaceStyle.allCases.firstIndex(of: coordinator.settings.interfaceStyle) ?? 0
            ) { [weak self] selectedIndex in
                if let style = AppSettings.InterfaceStyle.allCases[safe: selectedIndex] {
                    self?.coordinator.settings.setInterfaceStyle(style)
                }
            }
            return cell
            
        case .haptics:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SwitchCell", for: indexPath) as! SwitchTableViewCell
            cell.configure(
                title: row.title,
                subtitle: row.subtitle,
                isOn: coordinator.settings.isHapticsEnabled
            ) { [weak self] isOn in
                self?.coordinator.settings.setHapticsEnabled(isOn)
            }
            return cell
        }
    }
    
    private func configureAccessibilityCell(for indexPath: IndexPath) -> UITableViewCell {
        guard let row = AccessibilityRow(rawValue: indexPath.row) else {
            return UITableViewCell()
        }
        
        switch row {
        case .enhancedAccessibility:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SwitchCell", for: indexPath) as! SwitchTableViewCell
            cell.configure(
                title: row.title,
                subtitle: row.subtitle,
                isOn: coordinator.settings.isAccessibilityEnhanced
            ) { [weak self] isOn in
                self?.coordinator.settings.setAccessibilityEnhanced(isOn)
            }
            return cell
            
        case .voiceOverOptimization:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SwitchCell", for: indexPath) as! SwitchTableViewCell
            cell.configure(
                title: row.title,
                subtitle: row.subtitle,
                isOn: coordinator.settings.isVoiceOverOptimized
            ) { [weak self] isOn in
                self?.coordinator.settings.setVoiceOverOptimized(isOn)
            }
            return cell
            
        case .dynamicText:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SwitchCell", for: indexPath) as! SwitchTableViewCell
            cell.configure(
                title: row.title,
                subtitle: row.subtitle,
                isOn: coordinator.settings.isDynamicTextEnabled
            ) { [weak self] isOn in
                self?.coordinator.settings.setDynamicTextEnabled(isOn)
            }
            return cell
            
        case .verbosity:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SegmentedCell", for: indexPath) as! SegmentedTableViewCell
            cell.configure(
                title: row.title,
                subtitle: row.subtitle,
                options: AppSettings.AccessibilityVerbosity.allCases.map { $0.description },
                selectedIndex: AppSettings.AccessibilityVerbosity.allCases.firstIndex(of: coordinator.settings.accessibilityVerbosity) ?? 1
            ) { [weak self] selectedIndex in
                if let verbosity = AppSettings.AccessibilityVerbosity.allCases[safe: selectedIndex] {
                    self?.coordinator.settings.setAccessibilityVerbosity(verbosity)
                }
            }
            return cell
        }
    }
    
    private func configureFunctionalityCell(for indexPath: IndexPath) -> UITableViewCell {
        guard let row = FunctionalityRow(rawValue: indexPath.row) else {
            return UITableViewCell()
        }
        
        switch row {
        case .search:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SwitchCell", for: indexPath) as! SwitchTableViewCell
            cell.configure(
                title: row.title,
                subtitle: row.subtitle,
                isOn: coordinator.settings.isSearchEnabled
            ) { [weak self] isOn in
                self?.coordinator.settings.setSearchEnabled(isOn)
            }
            return cell
            
        case .lyricsSearch:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SwitchCell", for: indexPath) as! SwitchTableViewCell
            cell.configure(
                title: row.title,
                subtitle: row.subtitle,
                isOn: coordinator.settings.isLyricsSearchEnabled
            ) { [weak self] isOn in
                self?.coordinator.settings.setLyricsSearchEnabled(isOn)
            }
            return cell
            
        case .searchScope:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SegmentedCell", for: indexPath) as! SegmentedTableViewCell
            cell.configure(
                title: row.title,
                subtitle: row.subtitle,
                options: AppSettings.SearchScope.allCases.map { $0.description },
                selectedIndex: AppSettings.SearchScope.allCases.firstIndex(of: coordinator.settings.searchScopeIncludes) ?? 0
            ) { [weak self] selectedIndex in
                if let scope = AppSettings.SearchScope.allCases[safe: selectedIndex] {
                    self?.coordinator.settings.setSearchScope(scope)
                }
            }
            return cell
            
        case .dragDrop:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SwitchCell", for: indexPath) as! SwitchTableViewCell
            cell.configure(
                title: row.title,
                subtitle: row.subtitle,
                isOn: coordinator.settings.isDragDropEnabled
            ) { [weak self] isOn in
                self?.coordinator.settings.setDragDropEnabled(isOn)
            }
            return cell
            
        case .dragDropScope:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SegmentedCell", for: indexPath) as! SegmentedTableViewCell
            cell.configure(
                title: row.title,
                subtitle: row.subtitle,
                options: AppSettings.DragDropScope.allCases.map { $0.description },
                selectedIndex: AppSettings.DragDropScope.allCases.firstIndex(of: coordinator.settings.dragDropFileTypes) ?? 0
            ) { [weak self] selectedIndex in
                if let scope = AppSettings.DragDropScope.allCases[safe: selectedIndex] {
                    self?.coordinator.settings.setDragDropScope(scope)
                }
            }
            return cell
        }
    }
    
    private func configurePlaybackCell(for indexPath: IndexPath) -> UITableViewCell {
        guard let row = PlaybackRow(rawValue: indexPath.row) else {
            return UITableViewCell()
        }
        
        switch row {
        case .autoPlay:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SwitchCell", for: indexPath) as! SwitchTableViewCell
            cell.configure(
                title: row.title,
                subtitle: row.subtitle,
                isOn: coordinator.settings.isAutoPlayEnabled
            ) { [weak self] isOn in
                self?.coordinator.settings.setAutoPlayEnabled(isOn)
            }
            return cell
        }
    }
    
    private func configurePerformanceCell(for indexPath: IndexPath) -> UITableViewCell {
        guard let row = PerformanceRow(rawValue: indexPath.row) else {
            return UITableViewCell()
        }
        
        let cell = tableView.dequeueReusableCell(withIdentifier: "SettingCell", for: indexPath)
        cell.textLabel?.text = row.title
        cell.detailTextLabel?.text = row.subtitle
        
        switch row {
        case .memoryUsage:
            let usage = coordinator.memoryManager.memoryUsage
            cell.detailTextLabel?.text = String(format: "%.1f%%", usage * 100)
            cell.detailTextLabel?.textColor = usage > 0.8 ? .systemRed : usage > 0.6 ? .systemOrange : .systemGreen
            cell.accessoryType = .none
            cell.selectionStyle = .none
            
        case .cacheSize:
            let size = coordinator.memoryManager.cacheSize
            cell.detailTextLabel?.text = ByteCountFormatter().string(fromByteCount: size)
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.accessoryType = .none
            cell.selectionStyle = .none
            
        case .cacheHitRate:
            let hitRate = coordinator.imageCache.cacheHitRate
            cell.detailTextLabel?.text = String(format: "%.1f%%", hitRate * 100)
            cell.detailTextLabel?.textColor = hitRate > 0.8 ? .systemGreen : hitRate > 0.5 ? .systemOrange : .systemRed
            cell.accessoryType = .none
            cell.selectionStyle = .none
            
        case .averageLoadTime:
            let loadTime = coordinator.performanceMetrics.averageLoadTime
            cell.detailTextLabel?.text = String(format: "%.3fs", loadTime)
            cell.detailTextLabel?.textColor = loadTime < 0.1 ? .systemGreen : loadTime < 0.3 ? .systemOrange : .systemRed
            cell.accessoryType = .none
            cell.selectionStyle = .none
            
        case .memoryEfficiency:
            let efficiency = coordinator.performanceMetrics.memoryEfficiency
            cell.detailTextLabel?.text = String(format: "%.1f%%", efficiency * 100)
            cell.detailTextLabel?.textColor = efficiency > 0.8 ? .systemGreen : efficiency > 0.6 ? .systemOrange : .systemRed
            cell.accessoryType = .none
            cell.selectionStyle = .none
            
        case .clearCache:
            cell.detailTextLabel?.text = "Tap to clear all cached data"
            cell.accessoryType = .disclosureIndicator
            cell.textLabel?.textColor = .systemRed
        }
        
        return cell
    }
    
    private func clearAllCaches() {
        let alert = UIAlertController(
            title: "Clear All Caches",
            message: "This will clear all cached images and data. This action cannot be undone.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            self?.coordinator.imageCache.clearCache()
            self?.coordinator.memoryManager.performMemoryCleanup()
            
            // Show confirmation
            let confirmAlert = UIAlertController(
                title: "Cache Cleared",
                message: "All cached data has been cleared successfully.",
                preferredStyle: .alert
            )
            confirmAlert.addAction(UIAlertAction(title: "OK", style: .default))
            self?.present(confirmAlert, animated: true)
            
            // Refresh the performance section
            if let performanceSection = SettingsSection.allCases.firstIndex(of: .performance) {
                self?.tableView.reloadSections(IndexSet(integer: performanceSection), with: .none)
            }
        })
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
    
    private func configureAboutCell(for indexPath: IndexPath) -> UITableViewCell {
        guard let row = AboutRow(rawValue: indexPath.row) else {
            return UITableViewCell()
        }
        
        let cell = tableView.dequeueReusableCell(withIdentifier: "SettingCell", for: indexPath)
        cell.textLabel?.text = row.title
        cell.detailTextLabel?.text = row.subtitle
        
        switch row {
        case .version:
            cell.accessoryType = .none
            cell.selectionStyle = .none
        case .resetSettings:
            cell.accessoryType = .disclosureIndicator
            cell.textLabel?.textColor = .systemRed
        case .runTests:
            cell.accessoryType = .disclosureIndicator
            cell.textLabel?.textColor = .systemBlue
        }
        
        return cell
    }
    
    private func configureLogsCell(for indexPath: IndexPath) -> UITableViewCell {
        guard let row = LogsRow(rawValue: indexPath.row) else {
            return UITableViewCell()
        }
        
        let cell = tableView.dequeueReusableCell(withIdentifier: "SettingCell", for: indexPath)
        cell.textLabel?.text = row.title
        cell.detailTextLabel?.text = row.subtitle
        
        switch row {
        case .viewLogs:
            cell.accessoryType = .disclosureIndicator
            cell.textLabel?.textColor = .systemBlue
        case .clearLogs:
            cell.accessoryType = .disclosureIndicator
            cell.textLabel?.textColor = .systemOrange
        case .exportLogs:
            cell.accessoryType = .disclosureIndicator
            cell.textLabel?.textColor = .systemGreen
        }
        
        return cell
    }
    
    private func showLiveLogsViewer() {
        let logsViewController = LogsViewController()
        let navController = UINavigationController(rootViewController: logsViewController)
        present(navController, animated: true)
    }
    
    private func clearAllLogs() {
        let alert = UIAlertController(
            title: "Clear All Logs",
            message: "Are you sure you want to clear all stored log entries? This action cannot be undone.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            AppLogger.shared.clearLogs()
            
            let confirmAlert = UIAlertController(title: "Logs Cleared", message: "All log entries have been cleared.", preferredStyle: .alert)
            confirmAlert.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(confirmAlert, animated: true)
        })
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
    
    private func exportLogs() {
        let logs = AppLogger.shared.exportLogs()
        
        if logs.isEmpty {
            let alert = UIAlertController(title: "No Logs", message: "There are no logs to export.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        
        let activityViewController = UIActivityViewController(activityItems: [logs], applicationActivities: nil)
        
        // For iPad
        if let popover = activityViewController.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        
        present(activityViewController, animated: true)
    }
}

// MARK: - Custom Table View Cells
class SwitchTableViewCell: UITableViewCell {
    private let switchControl = UISwitch()
    private var onToggle: ((Bool) -> Void)?
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        accessoryView = switchControl
        switchControl.addTarget(self, action: #selector(switchToggled), for: .valueChanged)
        selectionStyle = .none
        
        // Ensure proper spacing for text labels
        textLabel?.numberOfLines = 0
        detailTextLabel?.numberOfLines = 0
        textLabel?.font = .preferredFont(forTextStyle: .body)
        detailTextLabel?.font = .preferredFont(forTextStyle: .caption1)
        textLabel?.adjustsFontForContentSizeCategory = true
        detailTextLabel?.adjustsFontForContentSizeCategory = true
    }
    
    func configure(title: String, subtitle: String?, isOn: Bool, onToggle: @escaping (Bool) -> Void) {
        textLabel?.text = title
        detailTextLabel?.text = subtitle
        switchControl.isOn = isOn
        self.onToggle = onToggle
        
        // Accessibility
        accessibilityLabel = title
        accessibilityValue = isOn ? "On" : "Off"
        accessibilityTraits = .button
        if let subtitle = subtitle {
            accessibilityHint = subtitle
        }
    }
    
    @objc private func switchToggled() {
        onToggle?(switchControl.isOn)
    }
}

class SegmentedTableViewCell: UITableViewCell {
    private let segmentedControl = UISegmentedControl()
    private var onSelectionChanged: ((Int) -> Void)?
    
    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 0
        return label
    }()
    
    private lazy var subtitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(segmentedControl)
        
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
        selectionStyle = .none
        
        NSLayoutConstraint.activate([
            // Title label
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            
            // Subtitle label
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            
            // Segmented control
            segmentedControl.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12),
            segmentedControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            segmentedControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            segmentedControl.heightAnchor.constraint(equalToConstant: 32),
            segmentedControl.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }
    
    func configure(title: String, subtitle: String?, options: [String], selectedIndex: Int, onSelectionChanged: @escaping (Int) -> Void) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true
        
        // Remove all segments and add new ones
        segmentedControl.removeAllSegments()
        for (index, option) in options.enumerated() {
            segmentedControl.insertSegment(withTitle: option, at: index, animated: false)
        }
        
        segmentedControl.selectedSegmentIndex = selectedIndex
        self.onSelectionChanged = onSelectionChanged
        
        // Accessibility
        accessibilityLabel = title
        accessibilityValue = options[safe: selectedIndex]
        accessibilityTraits = .button
        if let subtitle = subtitle {
            accessibilityHint = subtitle
        }
    }
    
    @objc private func segmentChanged() {
        onSelectionChanged?(segmentedControl.selectedSegmentIndex)
    }
}

// MARK: - Array Extension for Safe Access
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Live Logs Viewer
class LogsViewController: UIViewController {
    private let logger = AppLogger.shared
    private var cancellables = Set<AnyCancellable>()
    
    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .plain)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.delegate = self
        table.dataSource = self
        table.register(LogTableViewCell.self, forCellReuseIdentifier: "LogCell")
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 60
        table.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        return table
    }()
    
    private lazy var autoScrollButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Auto-Scroll", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = .systemBlue
        button.layer.cornerRadius = 20
        button.addTarget(self, action: #selector(toggleAutoScroll), for: .touchUpInside)
        return button
    }()
    
    private var autoScrollEnabled = true
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupBindings()
    }
    
    private func setupUI() {
        title = "Live Logs"
        view.backgroundColor = .systemBackground
        
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissLogs)
        )
        
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Clear",
            style: .plain,
            target: self,
            action: #selector(clearLogs)
        )
        
        view.addSubview(tableView)
        view.addSubview(autoScrollButton)
        
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            autoScrollButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            autoScrollButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            autoScrollButton.widthAnchor.constraint(equalToConstant: 100),
            autoScrollButton.heightAnchor.constraint(equalToConstant: 40)
        ])
    }
    
    private func setupBindings() {
        logger.$logs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.tableView.reloadData()
                if self?.autoScrollEnabled == true {
                    self?.scrollToBottom()
                }
            }
            .store(in: &cancellables)
    }
    
    private func scrollToBottom() {
        guard !logger.logs.isEmpty else { return }
        
        let lastIndexPath = IndexPath(row: logger.logs.count - 1, section: 0)
        tableView.scrollToRow(at: lastIndexPath, at: .bottom, animated: true)
    }
    
    @objc private func dismissLogs() {
        dismiss(animated: true)
    }
    
    @objc private func clearLogs() {
        logger.clearLogs()
    }
    
    @objc private func toggleAutoScroll() {
        autoScrollEnabled.toggle()
        
        let title = autoScrollEnabled ? "Auto-Scroll" : "Manual"
        let backgroundColor: UIColor = autoScrollEnabled ? .systemBlue : .systemGray
        
        autoScrollButton.setTitle(title, for: .normal)
        autoScrollButton.backgroundColor = backgroundColor
        
        if autoScrollEnabled {
            scrollToBottom()
        }
    }
}

// MARK: - LogsViewController Table View
extension LogsViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return logger.logs.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "LogCell", for: indexPath) as! LogTableViewCell
        let logEntry = logger.logs[indexPath.row]
        cell.configure(with: logEntry)
        return cell
    }
}

// MARK: - Custom Log Table View Cell
class LogTableViewCell: UITableViewCell {
    private let timestampLabel = UILabel()
    private let levelLabel = UILabel()
    private let messageLabel = UILabel()
    private let containerView = UIView()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        selectionStyle = .none
        
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.backgroundColor = .secondarySystemBackground
        containerView.layer.cornerRadius = 8
        containerView.layer.masksToBounds = true
        
        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        timestampLabel.font = .systemFont(ofSize: 12, weight: .medium)
        timestampLabel.textColor = .secondaryLabel
        
        levelLabel.translatesAutoresizingMaskIntoConstraints = false
        levelLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        levelLabel.textAlignment = .center
        levelLabel.layer.cornerRadius = 4
        levelLabel.layer.masksToBounds = true
        
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = .systemFont(ofSize: 14)
        messageLabel.textColor = .label
        messageLabel.numberOfLines = 0
        
        contentView.addSubview(containerView)
        containerView.addSubview(timestampLabel)
        containerView.addSubview(levelLabel)
        containerView.addSubview(messageLabel)
        
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            containerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            containerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            containerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            
            timestampLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            timestampLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            
            levelLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            levelLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            levelLabel.widthAnchor.constraint(equalToConstant: 80),
            levelLabel.heightAnchor.constraint(equalToConstant: 20),
            
            messageLabel.topAnchor.constraint(equalTo: timestampLabel.bottomAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            messageLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            messageLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -8)
        ])
    }
    
    func configure(with logEntry: LogEntry) {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        timestampLabel.text = formatter.string(from: logEntry.timestamp)
        
        levelLabel.text = logEntry.level.rawValue.uppercased()
        messageLabel.text = logEntry.message
        
        // Color coding based on log level
        switch logEntry.level {
        case .debug:
            levelLabel.backgroundColor = .systemGray
            levelLabel.textColor = .white
        case .info:
            levelLabel.backgroundColor = .systemBlue
            levelLabel.textColor = .white
        case .warning:
            levelLabel.backgroundColor = .systemOrange
            levelLabel.textColor = .white
        case .error:
            levelLabel.backgroundColor = .systemRed
            levelLabel.textColor = .white
        case .success:
            levelLabel.backgroundColor = .systemGreen
            levelLabel.textColor = .white
        }
    }
}

// MARK: - Queue View Controller
class QueueViewController: UIViewController {
    private let coordinator: SambaPlayCoordinator
    private var cancellables = Set<AnyCancellable>()
    
    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.delegate = self
        table.dataSource = self
        table.register(QueueTableViewCell.self, forCellReuseIdentifier: "QueueCell")
        table.dragInteractionEnabled = true
        table.dragDelegate = self
        table.dropDelegate = self
        return table
    }()
    
    private lazy var emptyStateView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        let imageView = UIImageView(image: UIImage(systemName: "music.note.list"))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = .systemGray3
        imageView.contentMode = .scaleAspectFit
        
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Queue is Empty"
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textColor = .systemGray2
        titleLabel.textAlignment = .center
        
        let subtitleLabel = UILabel()
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "Add songs to start building your queue"
        subtitleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        subtitleLabel.textColor = .systemGray3
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        
        view.addSubview(imageView)
        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            imageView.widthAnchor.constraint(equalToConstant: 80),
            imageView.heightAnchor.constraint(equalToConstant: 80),
            
            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
        
        return view
    }()
    
    init(coordinator: SambaPlayCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupBindings()
        updateEmptyState()
    }
    
    private func setupUI() {
        title = "Queue"
        view.backgroundColor = .systemBackground
        
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissQueue))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(clearQueue))
        
        view.addSubview(tableView)
        view.addSubview(emptyStateView)
        
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            emptyStateView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    private func setupBindings() {
        coordinator.playbackQueue.$tracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.tableView.reloadData()
                self?.updateEmptyState()
            }
            .store(in: &cancellables)
        
        coordinator.playbackQueue.$currentIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.tableView.reloadData()
            }
            .store(in: &cancellables)
    }
    
    private func updateEmptyState() {
        let isEmpty = coordinator.playbackQueue.tracks.isEmpty
        tableView.isHidden = isEmpty
        emptyStateView.isHidden = !isEmpty
    }
    
    @objc private func dismissQueue() {
        dismiss(animated: true)
    }
    
    @objc private func clearQueue() {
        let alert = UIAlertController(
            title: "Clear Queue",
            message: "Are you sure you want to remove all tracks from the queue?",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            self?.coordinator.playbackQueue.clearQueue()
            self?.coordinator.playbackQueue.saveToUserDefaults()
        })
        
        present(alert, animated: true)
    }
}

// MARK: - Queue Table View Data Source & Delegate
extension QueueViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return coordinator.playbackQueue.tracks.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "QueueCell", for: indexPath) as! QueueTableViewCell
        let track = coordinator.playbackQueue.tracks[indexPath.row]
        let isCurrentTrack = indexPath.row == coordinator.playbackQueue.currentIndex
        
        cell.configure(with: track, isCurrentTrack: isCurrentTrack, position: indexPath.row + 1)
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        // Play the selected track
        coordinator.playbackQueue.playTrack(at: indexPath.row)
        let track = coordinator.playbackQueue.tracks[indexPath.row]
        
        coordinator.audioPlayer.loadFile(track) { [weak self] result in
            switch result {
            case .success:
                self?.coordinator.audioPlayer.play()
                self?.coordinator.playbackQueue.saveToUserDefaults()
            case .failure(let error):
                print("❌ Failed to load selected track: \(error.localizedDescription)")
            }
        }
    }
    
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            coordinator.playbackQueue.removeTrack(at: indexPath.row)
            coordinator.playbackQueue.saveToUserDefaults()
        }
    }
    
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    
    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        coordinator.playbackQueue.moveTrack(from: sourceIndexPath.row, to: destinationIndexPath.row)
        coordinator.playbackQueue.saveToUserDefaults()
    }
}

// MARK: - Queue Drag & Drop
extension QueueViewController: UITableViewDragDelegate, UITableViewDropDelegate {
    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        let track = coordinator.playbackQueue.tracks[indexPath.row]
        let itemProvider = NSItemProvider(object: track.name as NSString)
        let dragItem = UIDragItem(itemProvider: itemProvider)
        dragItem.localObject = track
        return [dragItem]
    }
    
    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        // Handle drop operations if needed
    }
    
    func tableView(_ tableView: UITableView, canHandle session: UIDropSession) -> Bool {
        return session.hasItemsConforming(toTypeIdentifiers: [UTType.text.identifier])
    }
    
    func tableView(_ tableView: UITableView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?) -> UITableViewDropProposal {
        return UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }
}

// MARK: - Queue Table View Cell
class QueueTableViewCell: UITableViewCell {
    private let positionLabel = UILabel()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let currentTrackIndicator = UIView()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        selectionStyle = .default
        
        positionLabel.translatesAutoresizingMaskIntoConstraints = false
        positionLabel.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        positionLabel.textColor = .systemGray
        positionLabel.textAlignment = .center
        positionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 14, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1
        
        currentTrackIndicator.translatesAutoresizingMaskIntoConstraints = false
        currentTrackIndicator.backgroundColor = .systemBlue
        currentTrackIndicator.layer.cornerRadius = 2
        currentTrackIndicator.isHidden = true
        
        contentView.addSubview(positionLabel)
        contentView.addSubview(titleLabel)
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(currentTrackIndicator)
        
        NSLayoutConstraint.activate([
            positionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            positionLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            positionLabel.widthAnchor.constraint(equalToConstant: 32),
            
            currentTrackIndicator.leadingAnchor.constraint(equalTo: positionLabel.trailingAnchor, constant: 8),
            currentTrackIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            currentTrackIndicator.widthAnchor.constraint(equalToConstant: 4),
            currentTrackIndicator.heightAnchor.constraint(equalToConstant: 32),
            
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: currentTrackIndicator.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }
    
    func configure(with track: MediaFile, isCurrentTrack: Bool, position: Int) {
        positionLabel.text = "\(position)"
        titleLabel.text = track.name
        subtitleLabel.text = ByteCountFormatter().string(fromByteCount: track.size)
        
        currentTrackIndicator.isHidden = !isCurrentTrack
        
        if isCurrentTrack {
            titleLabel.textColor = .systemBlue
            positionLabel.textColor = .systemBlue
        } else {
            titleLabel.textColor = .label
            positionLabel.textColor = .systemGray
        }
    }
} 