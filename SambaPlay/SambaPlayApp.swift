import UIKit
import AVFoundation
import Combine
import MediaPlayer
import CoreData
import UniformTypeIdentifiers

// MARK: - Data Models

struct MediaFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let modificationDate: Date
    let isDirectory: Bool
    let fileExtension: String?
    
    var isAudioFile: Bool {
        guard let ext = fileExtension?.lowercased() else { return false }
        return ["mp3", "m4a", "wav", "aac", "flac", "ogg", "wma", "aiff", "opus"].contains(ext)
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

enum NetworkConnectionState {
    case disconnected
    case connecting
    case connected
    case error(String)
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
class SambaServer {
    let id = UUID()
    var name: String
    var host: String
    var port: Int16
    var username: String?
    var password: String?
    
    init(name: String, host: String, port: Int16 = 445, username: String? = nil, password: String? = nil) {
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
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
        // For demo, add a sample server
        let demoServer = SambaServer(name: "Demo Server", host: "192.168.1.100")
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
            
            // Remove duplicates by keeping only the most recent entry for each server/folder
            var uniqueSources: [RecentSource] = []
            var seenServerIDs: Set<UUID> = []
            var seenFolderIDs: Set<UUID> = []
            
            for source in loadedSources.sorted { $0.lastAccessed > $1.lastAccessed } {
                var shouldAdd = false
                
                if source.type == .server, let serverID = source.serverID {
                    if !seenServerIDs.contains(serverID) {
                        seenServerIDs.insert(serverID)
                        shouldAdd = true
                    }
                } else if source.type == .folder, let folderID = source.folderID {
                    if !seenFolderIDs.contains(folderID) {
                        seenFolderIDs.insert(folderID)
                        shouldAdd = true
                    }
                }
                
                if shouldAdd {
                    uniqueSources.append(source)
                }
            }
            
            // Keep only the 5 most recent unique sources
            recentSources = Array(uniqueSources.prefix(5))
            
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
        // Remove any existing source with the same server/folder ID to prevent duplicates
        if source.type == .server, let serverID = source.serverID {
            recentSources.removeAll { $0.type == .server && $0.serverID == serverID }
        } else if source.type == .folder, let folderID = source.folderID {
            recentSources.removeAll { $0.type == .folder && $0.folderID == folderID }
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
}

// MARK: - Simplified Audio Player
class SimpleAudioPlayer: NSObject, ObservableObject {
    @Published var playerState: AudioPlayerState = .stopped
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 180 // Demo duration
    @Published var speed: Float = 1.0
    @Published var pitch: Float = 1.0
    @Published var currentFile: MediaFile?
    @Published var subtitle: String?
    @Published var hasRestoredPosition: Bool = false // Indicates if position was restored from memory
    
    private var audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var timePitchNode = AVAudioUnitTimePitch()
    private var variableSpeedNode = AVAudioUnitVarispeed()
    private var displayLink: CADisplayLink?
    private var startTime: Date?
    private weak var networkService: SimpleNetworkService?
    
    func setNetworkService(_ service: SimpleNetworkService) {
        self.networkService = service
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
        guard playerState == .playing, let startTime = startTime else { return }
        
        let elapsed = Date().timeIntervalSince(startTime) * Double(speed)
        currentTime = min(elapsed, duration)
        
        // Periodically save position every 10 seconds during playback
        if Int(currentTime) % 10 == 0 && Int(currentTime) > 0 {
            saveCurrentPosition()
        }
        
        if currentTime >= duration {
            // When reaching the end, clear the saved position
            if let file = currentFile {
                networkService?.clearSavedPosition(for: file)
            }
            stop()
        }
    }
    
    private func saveCurrentPosition() {
        guard let file = currentFile, let networkService = networkService else { return }
        networkService.savePlaybackPosition(for: file, position: currentTime, duration: duration)
    }
    
    func loadFile(_ file: MediaFile, completion: @escaping (Result<Void, Error>) -> Void) {
        currentFile = file
        playerState = .stopped
        hasRestoredPosition = false
        
        // If this is the Sample Song, load the actual bundled audio file
        if file.name == "Sample Song.mp3" {
            guard let audioURL = Bundle.main.url(forResource: "Sample Song", withExtension: "mp3") else {
                completion(.failure(NSError(domain: "AudioPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sample audio file not found in bundle"])))
                return
            }
            
            do {
                let audioFile = try AVAudioFile(forReading: audioURL)
                duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
                
                // Check for saved position and restore it
                if let savedPosition = networkService?.getSavedPosition(for: file) {
                    currentTime = savedPosition.position
                    hasRestoredPosition = true
                    print("Restored position for \(file.name): \(savedPosition.position)s")
                } else {
                    currentTime = 0
                }
                
                // Load the file into the audio engine
                playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                    DispatchQueue.main.async {
                        self?.playerState = .stopped
                        // Don't reset currentTime here since we may have restored a position
                    }
                }
                
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        } else {
            // For other demo files, use simulated duration
            duration = 180 // 3 minutes demo
            
            // Check for saved position and restore it
            if let savedPosition = networkService?.getSavedPosition(for: file) {
                currentTime = savedPosition.position
                hasRestoredPosition = true
                print("Restored position for \(file.name): \(savedPosition.position)s")
            } else {
                currentTime = 0
            }
            
            completion(.success(()))
        }
    }
    
    func play() {
        guard let file = currentFile else { return }
        
        do {
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            
            if file.name == "Sample Song.mp3" {
                // For real audio file, use AVAudioPlayerNode
                if playerState != .paused {
                    // If not resuming, reload and schedule the file
                    if let audioURL = Bundle.main.url(forResource: "Sample Song", withExtension: "mp3") {
                        let audioFile = try AVAudioFile(forReading: audioURL)
                        playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                            DispatchQueue.main.async {
                                self?.playerState = .stopped
                                self?.currentTime = 0
                            }
                        }
                    }
                }
                playerNode.play()
            }
            
            if playerState == .paused {
                // Resume from current time
                startTime = Date().addingTimeInterval(-currentTime / Double(speed))
            } else {
                // Start from beginning
                startTime = Date()
                currentTime = 0
            }
            
            playerState = .playing
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }
    
    func pause() {
        if let file = currentFile, file.name == "Sample Song.mp3" {
            playerNode.pause()
        }
        playerState = .paused
        
        // Save current position when pausing
        saveCurrentPosition()
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
        currentTime = time
        if playerState == .playing {
            startTime = Date().addingTimeInterval(-time / Double(speed))
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
}

// MARK: - Main App Coordinator
class SambaPlayCoordinator {
    static let shared = SambaPlayCoordinator()
    
    let networkService = SimpleNetworkService()
    let audioPlayer = SimpleAudioPlayer()
    
    private init() {
        // Connect the audio player with the network service for position memory
        audioPlayer.setNetworkService(networkService)
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
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .systemBlue
        return label
    }()
    
    private lazy var pathLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        return label
    }()
    
    private lazy var backButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("← Back", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.addTarget(self, action: #selector(navigateBack), for: .touchUpInside)
        button.isHidden = true
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
    
    private lazy var nowPlayingButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Now Playing", for: .normal)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.addTarget(self, action: #selector(showNowPlaying), for: .touchUpInside)
        return button
    }()
    
    private var currentFiles: [MediaFile] = []
    
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
        connectToDemo()
    }
    
    private func setupUI() {
        title = "SambaPlay"
        view.backgroundColor = .systemBackground
        
        navigationController?.navigationBar.prefersLargeTitles = true
        
        // Navigation bar buttons
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "server.rack"),
            style: .plain,
            target: self,
            action: #selector(showServers)
        )
        
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
        view.addSubview(nowPlayingButton)
        
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
            tableView.bottomAnchor.constraint(equalTo: nowPlayingButton.topAnchor, constant: -8),
            
            nowPlayingButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            nowPlayingButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            nowPlayingButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            nowPlayingButton.heightAnchor.constraint(equalToConstant: 44)
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
                self?.currentFiles = files
                self?.tableView.reloadData()
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
}

// MARK: - Table View Data Source & Delegate
extension MainViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return currentFiles.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FileCell", for: indexPath)
        let file = currentFiles[indexPath.row]
        
        cell.textLabel?.text = file.name
        cell.detailTextLabel?.text = file.isDirectory ? "Folder" : ByteCountFormatter().string(fromByteCount: file.size)
        
        if file.isDirectory {
            cell.imageView?.image = UIImage(systemName: "folder.fill")
            cell.accessoryType = .disclosureIndicator
        } else if file.isAudioFile {
            cell.imageView?.image = UIImage(systemName: "music.note")
            cell.accessoryType = .none
        } else if file.isTextFile {
            cell.imageView?.image = UIImage(systemName: "doc.text.fill")
            cell.accessoryType = .disclosureIndicator
        } else {
            cell.imageView?.image = UIImage(systemName: "doc.fill")
            cell.accessoryType = .none
        }
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let file = currentFiles[indexPath.row]
        
        if file.isDirectory {
            coordinator.networkService.navigateToPath(file.path)
        } else if file.isAudioFile {
            playFile(file)
        } else if file.isTextFile {
            showTextViewer(for: file)
        }
    }
    
    private func playFile(_ file: MediaFile) {
        coordinator.audioPlayer.loadFile(file) { [weak self] result in
            switch result {
            case .success:
                self?.coordinator.audioPlayer.play()
                
                // Load subtitle if available
                if let textFile = file.associatedTextFile {
                    self?.coordinator.networkService.readTextFile(at: textFile) { textResult in
                        if case .success(let subtitle) = textResult {
                            DispatchQueue.main.async {
                                self?.coordinator.audioPlayer.subtitle = subtitle
                            }
                        }
                    }
                }
                
                self?.showNowPlaying()
                
            case .failure(let error):
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
        label.font = .systemFont(ofSize: 24, weight: .bold)
        label.textAlignment = .center
        label.numberOfLines = 2
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
        return slider
    }()
    
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
    private lazy var skipBackButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "gobackward.15", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)), for: .normal)
        button.addTarget(self, action: #selector(skipBackTapped), for: .touchUpInside)
        return button
    }()
    
    private lazy var playPauseButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)), for: .normal)
        button.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        return button
    }()
    
    private lazy var skipForwardButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "goforward.30", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)), for: .normal)
        button.addTarget(self, action: #selector(skipForwardTapped), for: .touchUpInside)
        return button
    }()
    
    private lazy var controlsStackView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [skipBackButton, playPauseButton, skipForwardButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .equalSpacing
        stack.alignment = .center
        stack.spacing = 40
        return stack
    }()
    
    private lazy var settingsButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "slider.horizontal.3", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), for: .normal)
        button.addTarget(self, action: #selector(showSettings), for: .touchUpInside)
        return button
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
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: settingsButton)
        
        view.addSubview(titleLabel)
        view.addSubview(positionRestoredLabel)
        view.addSubview(timeLabel)
        view.addSubview(speedPitchContainer)
        speedPitchContainer.addSubview(speedPitchStackView)
        view.addSubview(progressSlider)
        view.addSubview(controlsStackView)
        view.addSubview(subtitleHeaderLabel)
        view.addSubview(subtitleTextView)
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            positionRestoredLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
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
            
            controlsStackView.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: 32),
            controlsStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controlsStackView.widthAnchor.constraint(equalToConstant: 200),
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
    }
    
    private func updateUI() {
        titleLabel.text = coordinator.audioPlayer.currentFile?.name ?? "No Track"
        updateTime(coordinator.audioPlayer.currentTime)
        updatePlayButton(coordinator.audioPlayer.playerState)
        updateSpeedIndicator(coordinator.audioPlayer.speed)
        updatePitchIndicator(coordinator.audioPlayer.pitch)
        subtitleTextView.text = coordinator.audioPlayer.subtitle ?? "No subtitle available"
        showPositionRestoredIndicator(coordinator.audioPlayer.hasRestoredPosition)
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
        case .paused, .stopped:
            playPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)), for: .normal)
        default:
            playPauseButton.setImage(UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)), for: .normal)
        }
    }
    
    private func updateTime(_ time: TimeInterval) {
        let currentMinutes = Int(time) / 60
        let currentSeconds = Int(time) % 60
        let totalMinutes = Int(coordinator.audioPlayer.duration) / 60
        let totalSeconds = Int(coordinator.audioPlayer.duration) % 60
        
        timeLabel.text = String(format: "%d:%02d / %d:%02d", currentMinutes, currentSeconds, totalMinutes, totalSeconds)
        
        if coordinator.audioPlayer.duration > 0 {
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
        switch coordinator.audioPlayer.playerState {
        case .playing:
            coordinator.audioPlayer.pause()
        case .paused, .stopped:
            coordinator.audioPlayer.play()
        default:
            break
        }
    }
    
    @objc private func progressChanged() {
        let newTime = Double(progressSlider.value) * coordinator.audioPlayer.duration
        coordinator.audioPlayer.seek(to: newTime)
    }
    
    @objc private func skipBackTapped() {
        let currentTime = coordinator.audioPlayer.currentTime
        let newTime = max(0, currentTime - 15.0)
        coordinator.audioPlayer.seek(to: newTime)
    }
    
    @objc private func skipForwardTapped() {
        let currentTime = coordinator.audioPlayer.currentTime
        let duration = coordinator.audioPlayer.duration
        let newTime = min(duration, currentTime + 30.0)
        coordinator.audioPlayer.seek(to: newTime)
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
        container.layer.shadowColor = UIColor.black.cgColor
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
        container.layer.shadowColor = UIColor.black.cgColor
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
        container.layer.shadowColor = UIColor.black.cgColor
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