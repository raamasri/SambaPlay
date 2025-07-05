import UIKit
import AVFoundation
import Combine
import MediaPlayer
import CoreData
import UniformTypeIdentifiers

// MARK: - Core Data Models
import CoreData

@objc(SambaServer)
public class SambaServer: NSManagedObject {
    @NSManaged public var name: String
    @NSManaged public var host: String
    @NSManaged public var port: Int32
    @NSManaged public var username: String
    @NSManaged public var password: String
    @NSManaged public var createdDate: Date
}

@objc(FavoriteDirectory)
public class FavoriteDirectory: NSManagedObject {
    @NSManaged public var path: String
    @NSManaged public var serverName: String
    @NSManaged public var displayName: String
    @NSManaged public var createdDate: Date
}

@objc(PlaybackPosition)
public class PlaybackPosition: NSManagedObject {
    @NSManaged public var fileIdentifier: String  // Unique identifier for the file
    @NSManaged public var fileName: String        // File name for display
    @NSManaged public var filePath: String        // Full path to file
    @NSManaged public var serverName: String      // Server name (or "Local" for local files)
    @NSManaged public var position: Double        // Playback position in seconds
    @NSManaged public var duration: Double        // Total file duration
    @NSManaged public var lastPlayed: Date        // When this position was last saved
    @NSManaged public var speed: Float           // Last used speed
    @NSManaged public var pitch: Float           // Last used pitch
}

@objc(FolderHistory)
public class FolderHistory: NSManagedObject {
    @NSManaged public var folderPath: String     // Local folder path
    @NSManaged public var displayName: String   // User-friendly name
    @NSManaged public var lastAccessed: Date    // When folder was last accessed
    @NSManaged public var accessCount: Int32    // How many times accessed
    @NSManaged public var bookmarkData: Data?   // Security-scoped bookmark data
}

// MARK: - Media File Model
struct MediaFile: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let modificationDate: Date
    let isDirectory: Bool
    let fileExtension: String
    
    var identifier: String {
        return "\(path)_\(size)_\(modificationDate.timeIntervalSince1970)"
    }
    
    var isAudioFile: Bool {
        let audioExtensions = ["mp3", "m4a", "wav", "aiff", "flac", "aac", "ogg", "wma"]
        return audioExtensions.contains(fileExtension.lowercased())
    }
    
    var isTextFile: Bool {
        let textExtensions = ["txt", "srt", "vtt", "ass", "ssa"]
        return textExtensions.contains(fileExtension.lowercased())
    }
    
    var hasAssociatedTextFile: Bool {
        // Check if there's a corresponding .txt file
        return isAudioFile && !name.hasSuffix(".txt")
    }
    
    var associatedTextFileName: String {
        // Return the corresponding .txt file name
        let nameWithoutExtension = (name as NSString).deletingPathExtension
        let pathWithoutFile = (path as NSString).deletingLastPathComponent
        return "\(pathWithoutFile)/\(nameWithoutExtension).txt"
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

// MARK: - Enhanced Network Service
class SimpleNetworkService: ObservableObject {
    @Published var connectionState: NetworkConnectionState = .disconnected
    @Published var currentFiles: [MediaFile] = []
    @Published var currentPath: String = ""
    @Published var savedServers: [SambaServer] = []
    @Published var currentServer: SambaServer?
    @Published var pathHistory: [String] = []
    @Published var isLocalMode: Bool = false
    
    private var demoDirectories: [String: [MediaFile]] = [:]
    
    // Core Data context for server management
    var context: NSManagedObjectContext {
        return CoreDataStack().context
    }
    
    init() {
        setupDemoData()
        loadSavedServers()
    }
    
    private func setupDemoData() {
        // Root directory
        demoDirectories["/"] = [
            MediaFile(name: "Music", path: "/Music", size: 0, modificationDate: Date(), isDirectory: true, fileExtension: ""),
            MediaFile(name: "Podcasts", path: "/Podcasts", size: 0, modificationDate: Date(), isDirectory: true, fileExtension: ""),
            MediaFile(name: "Documents", path: "/Documents", size: 0, modificationDate: Date(), isDirectory: true, fileExtension: ""),
            MediaFile(name: "Sample Song.mp3", path: "/Sample Song.mp3", size: 3932160, modificationDate: Date(), isDirectory: false, fileExtension: "mp3"),
            MediaFile(name: "Sample Song.txt", path: "/Sample Song.txt", size: 1024, modificationDate: Date(), isDirectory: false, fileExtension: "txt")
        ]
        
        // Music directory
        demoDirectories["/Music"] = [
            MediaFile(name: "Rock", path: "/Music/Rock", size: 0, modificationDate: Date(), isDirectory: true, fileExtension: ""),
            MediaFile(name: "Jazz", path: "/Music/Jazz", size: 0, modificationDate: Date(), isDirectory: true, fileExtension: ""),
            MediaFile(name: "Favorite Song.mp3", path: "/Music/Favorite Song.mp3", size: 4567890, modificationDate: Date(), isDirectory: false, fileExtension: "mp3"),
            MediaFile(name: "Favorite Song.txt", path: "/Music/Favorite Song.txt", size: 892, modificationDate: Date(), isDirectory: false, fileExtension: "txt")
        ]
        
        // Podcasts directory
        demoDirectories["/Podcasts"] = [
            MediaFile(name: "Tech Talk Episode 1.mp3", path: "/Podcasts/Tech Talk Episode 1.mp3", size: 25000000, modificationDate: Date(), isDirectory: false, fileExtension: "mp3"),
            MediaFile(name: "Music Podcast.m4a", path: "/Podcasts/Music Podcast.m4a", size: 30000000, modificationDate: Date(), isDirectory: false, fileExtension: "m4a")
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
    }
    
    private func loadSavedServers() {
        // For demo purposes, create a simple server list
        // In real implementation, this would load from Core Data
        savedServers = []
    }
    
    func addServer(name: String, host: String, port: Int32 = 445, username: String = "", password: String = "") {
        // This would normally save to Core Data
        print("Added server: \(name) at \(host):\(port)")
    }
    
    func removeServer(_ server: SambaServer) {
        // This would normally remove from Core Data
        print("Removed server: \(server.name)")
    }
    
    func connect(to server: SambaServer) {
        isLocalMode = false
        currentServer = server
        connectionState = .connecting
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.connectionState = .connected
            self.navigateToPath("/")
        }
    }
    
    func connectToLocalFiles() {
        isLocalMode = true
        currentServer = nil
        connectionState = .connected
        currentPath = "Local Files"
        pathHistory = []
        currentFiles = []
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
    
    func navigateToDirectory(_ path: String) {
        navigateToPath(path)
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
            
            "default": """
            📝 Subtitle Content
            
            This is a sample subtitle file
            Accompanying the audio track
            You can scroll through the lyrics
            While the music plays back
            
            Features:
            - Independent speed control
            - Pitch adjustment
            - Network file browsing
            - Local file support
            """
        ]
        
        let text = sampleTexts[fileName] ?? sampleTexts["default"]!
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            completion(.success(text))
        }
    }
    
    func loadTextFile(_ file: MediaFile, completion: @escaping (Result<String, Error>) -> Void) {
        // Simulate network delay for demo
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            // For demo purposes, generate sample text content
            let sampleContent = """
            📄 Text File: \(file.name)
            
            This is a sample text file content for demonstration purposes.
            
            In a real implementation, this would load the actual text content from:
            • Samba network shares
            • Local file system
            • Cloud storage services
            
            File Details:
            • Name: \(file.name)
            • Path: \(file.path)
            • Size: \(file.size) bytes
            • Modified: \(DateFormatter.localizedString(from: file.modificationDate, dateStyle: .medium, timeStyle: .short))
            
            This text viewer supports:
            ✓ Font size adjustment
            ✓ Text sharing
            ✓ Non-intrusive viewing (doesn't interrupt audio playback)
            ✓ Full-screen reading experience
            
            Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.
            
            Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.
            
            Sed ut perspiciatis unde omnis iste natus error sit voluptatem accusantium doloremque laudantium, totam rem aperiam, eaque ipsa quae ab illo inventore veritatis et quasi architecto beatae vitae dicta sunt explicabo.
            """
            
            completion(.success(sampleContent))
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
    
    private var audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var timePitchNode = AVAudioUnitTimePitch()
    private var variableSpeedNode = AVAudioUnitVarispeed()
    private var displayLink: CADisplayLink?
    private var startTime: Date?
    
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
        
        if currentTime >= duration {
            stop()
        }
    }
    
    func loadFile(_ file: MediaFile, completion: @escaping (Result<Void, Error>) -> Void) {
        currentFile = file
        currentTime = 0
        playerState = .stopped
        
        // If this is the Sample Song, load the actual bundled audio file
        if file.name == "Sample Song.mp3" {
            guard let audioURL = Bundle.main.url(forResource: "Sample Song", withExtension: "mp3") else {
                completion(.failure(NSError(domain: "AudioPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sample audio file not found in bundle"])))
                return
            }
            
            do {
                let audioFile = try AVAudioFile(forReading: audioURL)
                duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
                
                // Load the file into the audio engine
                playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                    DispatchQueue.main.async {
                        self?.playerState = .stopped
                        self?.currentTime = 0
                    }
                }
                
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        } else {
            // For other demo files, use simulated duration
            duration = 180 // 3 minutes demo
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
    }
    
    func stop() {
        if let file = currentFile, file.name == "Sample Song.mp3" {
            playerNode.stop()
        }
        playerState = .stopped
        currentTime = 0
        startTime = nil
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
class SambaPlayCoordinator: ObservableObject {
    let networkService: SimpleNetworkService
    let audioPlayer: AudioPlayerService
    private let coreDataStack: CoreDataStack
    private let playbackPositionManager: PlaybackPositionManager
    private let folderHistoryManager: FolderHistoryManager
    
    init() {
        self.coreDataStack = CoreDataStack()
        self.networkService = SimpleNetworkService()
        self.audioPlayer = AudioPlayerService()
        self.playbackPositionManager = PlaybackPositionManager(context: coreDataStack.context)
        self.folderHistoryManager = FolderHistoryManager(context: coreDataStack.context)
        
        // Set up audio player with position manager
        audioPlayer.setPositionManager(playbackPositionManager)
    }
    
    func handleFileSelection(_ file: MediaFile, from viewController: UIViewController) {
        if file.isDirectory {
            // Navigate into directory
            networkService.navigateToDirectory(file.path)
        } else if file.isAudioFile {
            // Play audio file
            playAudioFile(file, from: viewController)
        } else if file.isTextFile {
            // Show text viewer
            showTextViewer(for: file, from: viewController)
        }
    }
    
    private func playAudioFile(_ file: MediaFile, from viewController: UIViewController) {
        audioPlayer.loadFile(file) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.showNowPlayingScreen(from: viewController)
                case .failure(let error):
                    self?.showAlert(title: "Playback Error", message: error.localizedDescription, from: viewController)
                }
            }
        }
    }
    
    private func showTextViewer(for file: MediaFile, from viewController: UIViewController) {
        let textViewer = TextViewerViewController(file: file, coordinator: self)
        let navController = UINavigationController(rootViewController: textViewer)
        viewController.present(navController, animated: true)
    }
    
    private func showNowPlayingScreen(from viewController: UIViewController) {
        let nowPlayingVC = NowPlayingViewController(coordinator: self)
        let navController = UINavigationController(rootViewController: nowPlayingVC)
        viewController.present(navController, animated: true)
    }
    
    func showAudioSettings(from viewController: UIViewController) {
        let audioSettingsVC = AudioSettingsViewController(coordinator: self)
        let navController = UINavigationController(rootViewController: audioSettingsVC)
        viewController.present(navController, animated: true)
    }
    
    func addFolderToHistory(path: String, displayName: String, bookmarkData: Data? = nil) {
        folderHistoryManager.addFolder(path: path, displayName: displayName, bookmarkData: bookmarkData)
    }
    
    func getFolderHistory() -> [FolderHistory] {
        return folderHistoryManager.getFolderHistory()
    }
    
    func getRecentFiles() -> [PlaybackPosition] {
        return playbackPositionManager.getRecentFiles()
    }
    
    private func showAlert(title: String, message: String, from viewController: UIViewController) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        viewController.present(alert, animated: true)
    }
    
    func removeFolderFromHistory(path: String) {
        folderHistoryManager.removeFolder(path: path)
    }
    
    func showFolderHistory(from viewController: UIViewController) {
        let folderHistoryVC = FolderHistoryViewController(coordinator: self)
        let navController = UINavigationController(rootViewController: folderHistoryVC)
        viewController.present(navController, animated: true)
    }
    
    func showRecentFiles(from viewController: UIViewController) {
        let alert = UIAlertController(title: "Recent Files", message: "Choose a recent file to resume playback", preferredStyle: .actionSheet)
        
        let recentFiles = getRecentFiles()
        
        if recentFiles.isEmpty {
            alert.message = "No recent files found"
            alert.addAction(UIAlertAction(title: "OK", style: .default))
        } else {
            for position in recentFiles.prefix(10) {
                let timeString = formatTime(position.position)
                let totalTimeString = formatTime(position.duration)
                let actionTitle = "\(position.fileName)\n\(timeString) / \(totalTimeString)"
                
                let action = UIAlertAction(title: actionTitle, style: .default) { [weak self] _ in
                    self?.resumeRecentFile(position, from: viewController)
                }
                alert.addAction(action)
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        }
        
        if let popover = alert.popoverPresentationController {
            popover.sourceView = viewController.view
            popover.sourceRect = CGRect(x: viewController.view.bounds.midX, y: viewController.view.bounds.midY, width: 0, height: 0)
        }
        
        viewController.present(alert, animated: true)
    }
    
    private func resumeRecentFile(_ position: PlaybackPosition, from viewController: UIViewController) {
        // Create a MediaFile from the saved position
        let mediaFile = MediaFile(
            name: position.fileName,
            path: position.filePath,
            size: 0, // Not critical for playback
            modificationDate: position.lastPlayed,
            isDirectory: false,
            fileExtension: URL(fileURLWithPath: position.fileName).pathExtension
        )
        
        audioPlayer.loadFile(mediaFile) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.showNowPlayingScreen(from: viewController)
                case .failure(let error):
                    self?.showAlert(title: "Resume Error", message: error.localizedDescription, from: viewController)
                }
            }
        }
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
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
        view.addSubview(backButton)
        view.addSubview(tableView)
        view.addSubview(nowPlayingButton)
        
        NSLayoutConstraint.activate([
            connectionStatusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            connectionStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            connectionStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            
            pathLabel.topAnchor.constraint(equalTo: connectionStatusLabel.bottomAnchor, constant: 4),
            pathLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            pathLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            
            backButton.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 8),
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
            let port = Int32(portText) ?? 445
            let username = alert.textFields?[3].text ?? ""
            let password = alert.textFields?[4].text ?? ""
            
            self.coordinator.networkService.addServer(name: name, host: host, port: port, username: username, password: password)
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
            coordinator.networkService.navigateToDirectory(file.path)
        } else if file.isAudioFile {
            playFile(file)
        }
    }
    
    private func playFile(_ file: MediaFile) {
        coordinator.audioPlayer.loadFile(file) { [weak self] result in
            switch result {
            case .success:
                self?.coordinator.audioPlayer.play()
                
                // Load subtitle if available
                if file.hasAssociatedTextFile {
                    let textFile = file.associatedTextFileName
                    self?.coordinator.networkService.readTextFile(at: textFile) { textResult in
                        if case .success(let subtitle) = textResult {
                            DispatchQueue.main.async {
                                // Subtitle handling would go here
                                print("📄 Loaded subtitle: \(subtitle.prefix(100))...")
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
        view.addSubview(timeLabel)
        view.addSubview(progressSlider)
        view.addSubview(controlsStackView)
        view.addSubview(subtitleHeaderLabel)
        view.addSubview(subtitleTextView)
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            timeLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            timeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            timeLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            progressSlider.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 16),
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
        
        // Subtitle updates would be handled here if implemented
        // coordinator.audioPlayer.$subtitle...
    }
    
    private func updateUI() {
        titleLabel.text = coordinator.audioPlayer.currentFile?.name ?? "No Track"
        updateTime(coordinator.audioPlayer.currentTime)
        updatePlayButton(coordinator.audioPlayer.playerState)
        subtitleTextView.text = "No subtitle available"
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
        var localFiles: [MediaFile] = []
        
        for url in urls {
            // Start accessing security-scoped resource
            guard url.startAccessingSecurityScopedResource() else { continue }
            
            defer { url.stopAccessingSecurityScopedResource() }
            
            // Add folder to history (without security-scoped bookmarks for iOS)
            coordinator.addFolderToHistory(
                path: url.path,
                displayName: url.lastPathComponent,
                bookmarkData: nil
            )
            
            print("📁 Added folder to history: \(url.lastPathComponent)")
            
            // If this is a directory, load its contents
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                // Load directory contents
                do {
                    let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
                    
                    for fileURL in contents {
                        let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
                        
                        let isDirectory = resourceValues.isDirectory ?? false
                        let fileSize = resourceValues.fileSize ?? 0
                        let modificationDate = resourceValues.contentModificationDate ?? Date()
                        let fileExtension = fileURL.pathExtension.lowercased()
                        
                        let mediaFile = MediaFile(
                            name: fileURL.lastPathComponent,
                            path: fileURL.path,
                            size: Int64(fileSize),
                            modificationDate: modificationDate,
                            isDirectory: isDirectory,
                            fileExtension: fileExtension
                        )
                        
                        localFiles.append(mediaFile)
                    }
                } catch {
                    print("❌ Failed to read directory contents: \(error)")
                }
            } else {
                // Single file
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
        }
        
        coordinator.networkService.currentFiles = localFiles
        
        // Show success message if folders were added to history
        if !urls.isEmpty {
            let folderCount = urls.filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }.count
            
            if folderCount > 0 {
                let message = folderCount == 1 ? "Folder added to history" : "\(folderCount) folders added to history"
                showTemporaryMessage(message)
            }
        }
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // User cancelled, stay in local mode but show empty list
        coordinator.networkService.currentFiles = []
    }
    
    private func showTemporaryMessage(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        present(alert, animated: true)
        
        // Auto-dismiss after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            alert.dismiss(animated: true)
        }
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
            let port = Int32(portText) ?? 445
            let username = alert.textFields?[3].text ?? ""
            let password = alert.textFields?[4].text ?? ""
            
            self.networkService.addServer(name: name, host: host, port: port, username: username, password: password)
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

// MARK: - Playback Position Manager
class PlaybackPositionManager {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext) {
        self.context = context
    }
    
    func savePosition(for file: MediaFile, position: Double, duration: Double, speed: Float, pitch: Float, serverName: String = "Local") {
        // Find existing position or create new one
        let request = NSFetchRequest<PlaybackPosition>(entityName: "PlaybackPosition")
        request.predicate = NSPredicate(format: "fileIdentifier == %@", file.identifier)
        
        do {
            let existingPositions = try context.fetch(request)
            let playbackPosition = existingPositions.first ?? PlaybackPosition(context: context)
            
            playbackPosition.fileIdentifier = file.identifier
            playbackPosition.fileName = file.name
            playbackPosition.filePath = file.path
            playbackPosition.serverName = serverName
            playbackPosition.position = position
            playbackPosition.duration = duration
            playbackPosition.lastPlayed = Date()
            playbackPosition.speed = speed
            playbackPosition.pitch = pitch
            
            try context.save()
            print("💾 Saved playback position: \(file.name) at \(position)s")
        } catch {
            print("❌ Failed to save playback position: \(error)")
        }
    }
    
    func getPosition(for file: MediaFile) -> PlaybackPosition? {
        let request = NSFetchRequest<PlaybackPosition>(entityName: "PlaybackPosition")
        request.predicate = NSPredicate(format: "fileIdentifier == %@", file.identifier)
        
        do {
            let positions = try context.fetch(request)
            return positions.first
        } catch {
            print("❌ Failed to fetch playback position: \(error)")
            return nil
        }
    }
    
    func getRecentFiles(limit: Int = 10) -> [PlaybackPosition] {
        let request = NSFetchRequest<PlaybackPosition>(entityName: "PlaybackPosition")
        request.sortDescriptors = [NSSortDescriptor(key: "lastPlayed", ascending: false)]
        request.fetchLimit = limit
        
        do {
            return try context.fetch(request)
        } catch {
            print("❌ Failed to fetch recent files: \(error)")
            return []
        }
    }
    
    func clearOldPositions(olderThan days: Int = 30) {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let request = NSFetchRequest<PlaybackPosition>(entityName: "PlaybackPosition")
        request.predicate = NSPredicate(format: "lastPlayed < %@", cutoffDate as NSDate)
        
        do {
            let oldPositions = try context.fetch(request)
            for position in oldPositions {
                context.delete(position)
            }
            try context.save()
            print("🗑️ Cleared \(oldPositions.count) old playback positions")
        } catch {
            print("❌ Failed to clear old positions: \(error)")
        }
    }
}

// MARK: - Folder History Manager
class FolderHistoryManager {
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext) {
        self.context = context
    }
    
    func addFolder(path: String, displayName: String, bookmarkData: Data? = nil) {
        // Check if folder already exists
        let request = NSFetchRequest<FolderHistory>(entityName: "FolderHistory")
        request.predicate = NSPredicate(format: "folderPath == %@", path)
        
        do {
            let existingFolders = try context.fetch(request)
            let folder = existingFolders.first ?? FolderHistory(context: context)
            
            folder.folderPath = path
            folder.displayName = displayName
            folder.lastAccessed = Date()
            folder.accessCount = (existingFolders.first?.accessCount ?? 0) + 1
            folder.bookmarkData = bookmarkData
            
            try context.save()
            print("📁 Added/Updated folder history: \(displayName)")
        } catch {
            print("❌ Failed to save folder history: \(error)")
        }
    }
    
    func getFolderHistory() -> [FolderHistory] {
        let request = NSFetchRequest<FolderHistory>(entityName: "FolderHistory")
        request.sortDescriptors = [NSSortDescriptor(key: "lastAccessed", ascending: false)]
        
        do {
            return try context.fetch(request)
        } catch {
            print("❌ Failed to fetch folder history: \(error)")
            return []
        }
    }
    
    func removeFolder(path: String) {
        let request = NSFetchRequest<FolderHistory>(entityName: "FolderHistory")
        request.predicate = NSPredicate(format: "folderPath == %@", path)
        
        do {
            let folders = try context.fetch(request)
            for folder in folders {
                context.delete(folder)
            }
            try context.save()
            print("🗑️ Removed folder from history: \(path)")
        } catch {
            print("❌ Failed to remove folder from history: \(error)")
        }
    }
}

// MARK: - Core Data Stack
class CoreDataStack {
    lazy var persistentContainer: NSPersistentContainer = {
        // Create a simple in-memory Core Data stack for demo purposes
        let model = NSManagedObjectModel()
        
        // Create entities programmatically
        let serverEntity = NSEntityDescription()
        serverEntity.name = "SambaServer"
        serverEntity.managedObjectClassName = NSStringFromClass(SambaServer.self)
        
        let serverAttributes = [
            createAttribute(name: "name", type: .stringAttributeType),
            createAttribute(name: "host", type: .stringAttributeType),
            createAttribute(name: "port", type: .integer32AttributeType),
            createAttribute(name: "username", type: .stringAttributeType),
            createAttribute(name: "password", type: .stringAttributeType),
            createAttribute(name: "createdDate", type: .dateAttributeType)
        ]
        serverEntity.properties = serverAttributes
        
        let positionEntity = NSEntityDescription()
        positionEntity.name = "PlaybackPosition"
        positionEntity.managedObjectClassName = NSStringFromClass(PlaybackPosition.self)
        
        let positionAttributes = [
            createAttribute(name: "fileIdentifier", type: .stringAttributeType),
            createAttribute(name: "fileName", type: .stringAttributeType),
            createAttribute(name: "filePath", type: .stringAttributeType),
            createAttribute(name: "serverName", type: .stringAttributeType),
            createAttribute(name: "position", type: .doubleAttributeType),
            createAttribute(name: "duration", type: .doubleAttributeType),
            createAttribute(name: "lastPlayed", type: .dateAttributeType),
            createAttribute(name: "speed", type: .floatAttributeType),
            createAttribute(name: "pitch", type: .floatAttributeType)
        ]
        positionEntity.properties = positionAttributes
        
        let historyEntity = NSEntityDescription()
        historyEntity.name = "FolderHistory"
        historyEntity.managedObjectClassName = NSStringFromClass(FolderHistory.self)
        
        let historyAttributes = [
            createAttribute(name: "folderPath", type: .stringAttributeType),
            createAttribute(name: "displayName", type: .stringAttributeType),
            createAttribute(name: "lastAccessed", type: .dateAttributeType),
            createAttribute(name: "accessCount", type: .integer32AttributeType),
            createOptionalAttribute(name: "bookmarkData", type: .binaryDataAttributeType)
        ]
        historyEntity.properties = historyAttributes
        
        model.entities = [serverEntity, positionEntity, historyEntity]
        
        let container = NSPersistentContainer(name: "SambaPlay", managedObjectModel: model)
        
        // Use in-memory store for demo
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        
        container.loadPersistentStores { _, error in
            if let error = error {
                print("Core Data error: \(error)")
            }
        }
        
        return container
    }()
    
    private func createAttribute(name: String, type: NSAttributeType) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = false
        return attribute
    }
    
    private func createOptionalAttribute(name: String, type: NSAttributeType) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = true
        return attribute
    }
    
    var context: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
    
    func save() {
        if context.hasChanges {
            try? context.save()
        }
    }
}

// MARK: - Audio Player Service
class AudioPlayerService: ObservableObject {
    @Published var playerState: AudioPlayerState = .stopped
    @Published var currentFile: MediaFile?
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var speed: Float = 1.0
    @Published var pitch: Float = 1.0
    
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitchNode = AVAudioUnitTimePitch()
    private let variableSpeedNode = AVAudioUnitVarispeed()
    
    private var audioFile: AVAudioFile?
    private var startTime: Date?
    private var currentFrame: AVAudioFramePosition = 0
    private var positionSaveTimer: Timer?
    private var playbackPositionManager: PlaybackPositionManager?
    private var currentServerName: String = "Local"
    
    init() {
        setupAudioEngine()
        setupMediaPlayerInfo()
    }
    
    deinit {
        positionSaveTimer?.invalidate()
    }
    
    func setPositionManager(_ manager: PlaybackPositionManager) {
        self.playbackPositionManager = manager
    }
    
    func setCurrentServer(_ serverName: String) {
        self.currentServerName = serverName
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
    
    private func setupMediaPlayerInfo() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        
        commandCenter.stopCommand.addTarget { [weak self] _ in
            self?.stop()
            return .success
        }
        
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.skipForward()
            return .success
        }
        
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skipBackward()
            return .success
        }
    }
    
    func loadFile(_ file: MediaFile, completion: @escaping (Result<Void, Error>) -> Void) {
        // Save current position before loading new file
        saveCurrentPosition()
        
        currentFile = file
        currentTime = 0
        currentFrame = 0
        playerState = .stopped
        
        // Check for saved position
        if let savedPosition = playbackPositionManager?.getPosition(for: file) {
            // Restore saved position and settings
            currentTime = savedPosition.position
            currentFrame = AVAudioFramePosition(savedPosition.position * 44100) // Assuming 44.1kHz
            duration = savedPosition.duration
            speed = savedPosition.speed
            pitch = savedPosition.pitch
            
            // Apply saved speed and pitch
            setSpeed(speed)
            setPitch(pitch)
            
            print("📍 Restored position: \(file.name) at \(savedPosition.position)s (speed: \(speed)×, pitch: \(pitch)×)")
        }
        
        // If this is the Sample Song, load the actual bundled audio file
        if file.name == "Sample Song.mp3" {
            guard let audioURL = Bundle.main.url(forResource: "Sample Song", withExtension: "mp3") else {
                completion(.failure(NSError(domain: "AudioPlayer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sample audio file not found in bundle"])))
                return
            }
            
            do {
                let audioFile = try AVAudioFile(forReading: audioURL)
                self.audioFile = audioFile
                
                // Calculate duration
                let sampleRate = audioFile.processingFormat.sampleRate
                let lengthInSamples = audioFile.length
                duration = Double(lengthInSamples) / sampleRate
                
                // Start position save timer
                startPositionSaveTimer()
                
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        } else {
            // For other files, just set up demo mode
            duration = 180.0 // 3 minutes demo
            startPositionSaveTimer()
            completion(.success(()))
        }
    }
    
    private func startPositionSaveTimer() {
        positionSaveTimer?.invalidate()
        positionSaveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.saveCurrentPosition()
        }
    }
    
    private func saveCurrentPosition() {
        guard let file = currentFile,
              let positionManager = playbackPositionManager,
              currentTime > 0,
              duration > 0 else { return }
        
        // Only save if we're more than 5 seconds in and not near the end
        if currentTime > 5.0 && currentTime < (duration - 10.0) {
            positionManager.savePosition(
                for: file,
                position: currentTime,
                duration: duration,
                speed: speed,
                pitch: pitch,
                serverName: currentServerName
            )
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
                    if let audioURL = Bundle.main.url(forResource: "Sample Song", withExtension: "mp3"),
                       let audioFile = try? AVAudioFile(forReading: audioURL) {
                        self.audioFile = audioFile
                        
                        // Schedule from current frame position
                        playerNode.scheduleSegment(audioFile, startingFrame: currentFrame, frameCount: AVAudioFrameCount(audioFile.length - currentFrame), at: nil)
                    }
                }
                
                playerNode.play()
                startTime = Date().addingTimeInterval(-currentTime)
            } else {
                // Demo mode
                if playerState == .paused {
                    startTime = Date().addingTimeInterval(-currentTime)
                } else {
                    startTime = Date().addingTimeInterval(-currentTime)
                }
            }
            
            playerState = .playing
            startPositionSaveTimer()
            
            // Start time update timer
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                guard let self = self, self.playerState == .playing else {
                    timer.invalidate()
                    return
                }
                
                if let startTime = self.startTime {
                    let elapsed = Date().timeIntervalSince(startTime) * Double(self.speed)
                    self.currentTime = min(elapsed, self.duration)
                    
                    if file.name == "Sample Song.mp3" {
                        // Update frame position for real audio
                        self.currentFrame = AVAudioFramePosition(self.currentTime * 44100)
                    }
                    
                    if self.currentTime >= self.duration {
                        self.stop()
                        timer.invalidate()
                    }
                }
            }
            
        } catch {
            print("Failed to play audio: \(error)")
        }
    }
    
    func pause() {
        if let file = currentFile, file.name == "Sample Song.mp3" {
            playerNode.pause()
        }
        playerState = .paused
        positionSaveTimer?.invalidate()
        saveCurrentPosition() // Save position when pausing
    }
    
    func stop() {
        if let file = currentFile, file.name == "Sample Song.mp3" {
            playerNode.stop()
        }
        playerState = .stopped
        positionSaveTimer?.invalidate()
        saveCurrentPosition() // Save position when stopping
        currentTime = 0
        currentFrame = 0
        startTime = nil
    }
    
    func seek(to time: Double) {
        let clampedTime = max(0, min(time, duration))
        currentTime = clampedTime
        currentFrame = AVAudioFramePosition(clampedTime * 44100)
        
        if playerState == .playing {
            // Restart playback from new position
            if let file = currentFile, file.name == "Sample Song.mp3" {
                playerNode.stop()
                if let audioFile = audioFile {
                    playerNode.scheduleSegment(audioFile, startingFrame: currentFrame, frameCount: AVAudioFrameCount(audioFile.length - currentFrame), at: nil)
                    playerNode.play()
                }
            }
            startTime = Date().addingTimeInterval(-currentTime)
        }
        
        saveCurrentPosition() // Save position when seeking
    }
    
    func skipForward() {
        seek(to: currentTime + 30)
    }
    
    func skipBackward() {
        seek(to: currentTime - 15)
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

// MARK: - Text Viewer Controller
class TextViewerViewController: UIViewController {
    private let file: MediaFile
    private let coordinator: SambaPlayCoordinator
    private var textView: UITextView!
    
    init(file: MediaFile, coordinator: SambaPlayCoordinator) {
        self.file = file
        self.coordinator = coordinator
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
        
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissViewer))
        
        // Create text view
        textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.font = .systemFont(ofSize: 16)
        textView.backgroundColor = .systemBackground
        textView.textColor = .label
        textView.contentInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        
        view.addSubview(textView)
        
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        // Add toolbar for text options
        let toolbar = UIToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        
        let fontSizeButton = UIBarButtonItem(title: "Aa", style: .plain, target: self, action: #selector(adjustFontSize))
        let flexSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let shareButton = UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(shareText))
        
        toolbar.items = [fontSizeButton, flexSpace, shareButton]
        
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            
            textView.bottomAnchor.constraint(equalTo: toolbar.topAnchor)
        ])
    }
    
    private func loadTextContent() {
        // Show loading indicator
        let loadingView = UIActivityIndicatorView(style: .large)
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        loadingView.startAnimating()
        view.addSubview(loadingView)
        
        NSLayoutConstraint.activate([
            loadingView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        
        // Load text content
        coordinator.networkService.loadTextFile(file) { [weak self] result in
            DispatchQueue.main.async {
                loadingView.removeFromSuperview()
                
                switch result {
                case .success(let content):
                    self?.textView.text = content
                case .failure(let error):
                    self?.textView.text = "Failed to load text file: \(error.localizedDescription)"
                    self?.textView.textColor = .systemRed
                }
            }
        }
    }
    
    @objc private func dismissViewer() {
        dismiss(animated: true)
    }
    
    @objc private func adjustFontSize() {
        let alert = UIAlertController(title: "Font Size", message: "Choose font size", preferredStyle: .actionSheet)
        
        let sizes: [CGFloat] = [12, 14, 16, 18, 20, 24]
        for size in sizes {
            let action = UIAlertAction(title: "\(Int(size))pt", style: .default) { [weak self] _ in
                self?.textView.font = .systemFont(ofSize: size)
            }
            if size == textView.font?.pointSize {
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
    
    @objc private func shareText() {
        let activityVC = UIActivityViewController(activityItems: [textView.text ?? ""], applicationActivities: nil)
        
        if let popover = activityVC.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItem
        }
        
        present(activityVC, animated: true)
    }
}

// MARK: - Folder History View Controller
class FolderHistoryViewController: UIViewController {
    private let coordinator: SambaPlayCoordinator
    private var folderHistory: [FolderHistory] = []
    private var cancellables = Set<AnyCancellable>()
    
    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.delegate = self
        table.dataSource = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "FolderCell")
        return table
    }()
    
    private lazy var emptyStateView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        let imageView = UIImageView(image: UIImage(systemName: "folder.badge.questionmark"))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = .systemGray3
        imageView.contentMode = .scaleAspectFit
        
        let titleLabel = UILabel()
        titleLabel.text = "No Folder History"
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .systemGray2
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        let messageLabel = UILabel()
        messageLabel.text = "Import folders from the Files app to see them here"
        messageLabel.font = .systemFont(ofSize: 16)
        messageLabel.textColor = .systemGray3
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        
        view.addSubview(imageView)
        view.addSubview(titleLabel)
        view.addSubview(messageLabel)
        
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            imageView.widthAnchor.constraint(equalToConstant: 80),
            imageView.heightAnchor.constraint(equalToConstant: 80),
            
            titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
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
        loadFolderHistory()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadFolderHistory() // Refresh when view appears
    }
    
    private func setupUI() {
        title = "Folder History"
        view.backgroundColor = .systemBackground
        
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissController)
        )
        
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Clear All",
            style: .plain,
            target: self,
            action: #selector(clearAllHistory)
        )
        
        view.addSubview(tableView)
        view.addSubview(emptyStateView)
        
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            
            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
    
    private func loadFolderHistory() {
        folderHistory = coordinator.getFolderHistory()
        updateUI()
    }
    
    private func updateUI() {
        tableView.reloadData()
        
        if folderHistory.isEmpty {
            tableView.isHidden = true
            emptyStateView.isHidden = false
            navigationItem.rightBarButtonItem?.isEnabled = false
        } else {
            tableView.isHidden = false
            emptyStateView.isHidden = true
            navigationItem.rightBarButtonItem?.isEnabled = true
        }
    }
    
    @objc private func dismissController() {
        dismiss(animated: true)
    }
    
    @objc private func clearAllHistory() {
        let alert = UIAlertController(
            title: "Clear All History",
            message: "This will remove all folder history. This action cannot be undone.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear All", style: .destructive) { [weak self] _ in
            self?.performClearAll()
        })
        
        present(alert, animated: true)
    }
    
    private func performClearAll() {
        for folder in folderHistory {
            coordinator.removeFolderFromHistory(path: folder.folderPath)
        }
        loadFolderHistory()
    }
    
    private func accessFolder(_ folder: FolderHistory) {
        // Try to access the folder using security-scoped bookmark
        if let bookmarkData = folder.bookmarkData {
            do {
                var isStale = false
                let url = try URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
                
                if isStale {
                    // Bookmark is stale, user needs to re-select
                    showStaleBookmarkAlert(for: folder)
                    return
                }
                
                guard url.startAccessingSecurityScopedResource() else {
                    showAccessErrorAlert(for: folder)
                    return
                }
                
                defer { url.stopAccessingSecurityScopedResource() }
                
                // Load files from the folder
                loadFilesFromFolder(url: url, folder: folder)
                
            } catch {
                showAccessErrorAlert(for: folder)
            }
        } else {
            // No bookmark data, show error
            showAccessErrorAlert(for: folder)
        }
    }
    
    private func loadFilesFromFolder(url: URL, folder: FolderHistory) {
        do {
            let fileManager = FileManager.default
            let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            
            var mediaFiles: [MediaFile] = []
            
            for fileURL in contents {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
                
                let isDirectory = resourceValues.isDirectory ?? false
                let fileSize = resourceValues.fileSize ?? 0
                let modificationDate = resourceValues.contentModificationDate ?? Date()
                let fileExtension = fileURL.pathExtension.lowercased()
                
                let mediaFile = MediaFile(
                    name: fileURL.lastPathComponent,
                    path: fileURL.path,
                    size: Int64(fileSize),
                    modificationDate: modificationDate,
                    isDirectory: isDirectory,
                    fileExtension: fileExtension
                )
                
                mediaFiles.append(mediaFile)
            }
            
            // Update network service with loaded files
            coordinator.networkService.currentFiles = mediaFiles
            
            // Update folder access count
            coordinator.addFolderToHistory(
                path: folder.folderPath,
                displayName: folder.displayName,
                bookmarkData: folder.bookmarkData
            )
            
            // Dismiss and return to main view
            dismiss(animated: true)
            
        } catch {
            showAccessErrorAlert(for: folder)
        }
    }
    
    private func showStaleBookmarkAlert(for folder: FolderHistory) {
        let alert = UIAlertController(
            title: "Access Expired",
            message: "Access to \"\(folder.displayName)\" has expired. Please re-import this folder from the Files app.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Remove from History", style: .destructive) { [weak self] _ in
            self?.coordinator.removeFolderFromHistory(path: folder.folderPath)
            self?.loadFolderHistory()
        })
        
        alert.addAction(UIAlertAction(title: "Keep", style: .cancel))
        
        present(alert, animated: true)
    }
    
    private func showAccessErrorAlert(for folder: FolderHistory) {
        let alert = UIAlertController(
            title: "Access Error",
            message: "Unable to access \"\(folder.displayName)\". The folder may have been moved or deleted.",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Remove from History", style: .destructive) { [weak self] _ in
            self?.coordinator.removeFolderFromHistory(path: folder.folderPath)
            self?.loadFolderHistory()
        })
        
        alert.addAction(UIAlertAction(title: "Keep", style: .cancel))
        
        present(alert, animated: true)
    }
}

// MARK: - Folder History Table View
extension FolderHistoryViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return folderHistory.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FolderCell", for: indexPath)
        let folder = folderHistory[indexPath.row]
        
        cell.textLabel?.text = folder.displayName
        cell.detailTextLabel?.text = "Last accessed: \(DateFormatter.localizedString(from: folder.lastAccessed, dateStyle: .medium, timeStyle: .short)) • \(folder.accessCount) times"
        cell.imageView?.image = UIImage(systemName: "folder.fill")
        cell.imageView?.tintColor = .systemBlue
        cell.accessoryType = .disclosureIndicator
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let folder = folderHistory[indexPath.row]
        accessFolder(folder)
    }
    
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let folder = folderHistory[indexPath.row]
            coordinator.removeFolderFromHistory(path: folder.folderPath)
            folderHistory.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .fade)
            updateUI()
        }
    }
    
    func tableView(_ tableView: UITableView, titleForDeleteConfirmationButtonForRowAt indexPath: IndexPath) -> String? {
        return "Remove"
    }
}

// MARK: - Now Playing View Controller (Placeholder)
class NowPlayingViewController: UIViewController {
    private let coordinator: SambaPlayCoordinator
    
    init(coordinator: SambaPlayCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Now Playing"
        view.backgroundColor = .systemBackground
        
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissController))
        
        let label = UILabel()
        label.text = "Now Playing Screen\n(Placeholder)"
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
    
    @objc private func dismissController() {
        dismiss(animated: true)
    }
}

// ... existing code ... 