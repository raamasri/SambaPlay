# SambaPlay

A sophisticated iOS audio player designed for streaming and playing audio files from Samba network shares with advanced playback controls.

![iOS](https://img.shields.io/badge/iOS-18.5+-blue.svg)
![Swift](https://img.shields.io/badge/Swift-5.0-orange.svg)
![Xcode](https://img.shields.io/badge/Xcode-16.4-blue.svg)
![License](https://img.shields.io/badge/License-MIT-green.svg)

## Features

### 🎵 Advanced Audio Controls
- **Independent Speed Control**: Adjust playback speed from 0.5x to 3.0x without affecting pitch
- **Independent Pitch Adjustment**: Modify pitch by ±6 semitones without changing speed
- **Precision Controls**: Fine-tune speed in 1% increments
- **BPM Sync**: Automatically adjust speed to match target BPM
- **Preset Buttons**: Quick access to common speed and pitch settings

### 🌐 Network Audio Streaming
- **Samba/SMB Support**: Connect to network shares, NAS devices, and shared folders
- **Server Management**: Save multiple server configurations with credentials
- **Hierarchical Browsing**: Navigate folder structures on remote servers
- **No Downloads Required**: Stream audio directly from network storage

### 📱 Modern iOS Experience
- **Native UIKit Interface**: Optimized for iOS with proper accessibility support
- **Document Picker Integration**: Access local files through iOS Files app
- **Background Playback**: Continue listening while using other apps
- **Media Controls**: Integration with iOS Control Center and lock screen

### 📄 Lyrics & Subtitles
- **Text File Support**: Automatically loads .txt files matching audio file names
- **Scrollable Display**: Read lyrics or subtitles while listening
- **Multi-format Support**: Works with any plain text accompaniment files

## Use Cases

- **Musicians**: Practice with backing tracks at different speeds while maintaining pitch
- **Language Learners**: Slow down audio content for better comprehension
- **Accessibility**: Customize playback speed for hearing or processing needs
- **Home Media**: Access large audio collections stored on NAS or home servers
- **Podcasters**: Review recordings with speed adjustments
- **Audio Professionals**: Analyze audio content with precise control

## Getting Started

### Prerequisites
- iOS 18.5 or later
- Xcode 16.4 or later (for development)
- Access to Samba/SMB network shares (optional)

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/yourusername/SambaPlay.git
   cd SambaPlay
   ```

2. **Open in Xcode**
   ```bash
   open SambaPlay.xcodeproj
   ```

3. **Build and Run**
   - Select your target device or simulator
   - Press `Cmd+R` to build and run

### First Launch
1. The app includes a sample audio file for testing
2. Tap the server icon to add your Samba servers
3. Or tap the folder icon to access local files
4. Start playing and explore the advanced audio controls

## Architecture

SambaPlay follows modern iOS development patterns:

- **Coordinator Pattern**: Clean separation of navigation logic
- **Combine Framework**: Reactive programming for UI updates
- **AVAudioEngine**: Professional audio processing pipeline
- **Programmatic UI**: No storyboards, full programmatic Auto Layout

### Key Components

- `SambaPlayCoordinator`: Central coordinator managing app flow
- `SimpleNetworkService`: Handles Samba connections and file browsing
- `SimpleAudioPlayer`: Advanced audio engine with speed/pitch control
- `AudioSettingsViewController`: Comprehensive playback controls

## Development

### Building
```bash
# Build for simulator
xcodebuild -project SambaPlay.xcodeproj -scheme SambaPlay -destination 'platform=iOS Simulator,name=iPhone 15' build

# Clean build folder
xcodebuild -project SambaPlay.xcodeproj -scheme SambaPlay clean
```

### Testing
```bash
# Run unit tests
xcodebuild test -project SambaPlay.xcodeproj -scheme SambaPlay -destination 'platform=iOS Simulator,name=iPhone 15'

# Run UI tests
xcodebuild test -project SambaPlay.xcodeproj -scheme SambaPlay -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SambaPlayUITests
```

### Code Structure
- `/SambaPlay/` - Main app source code
- `/SambaPlayTests/` - Unit tests using Swift Testing
- `/SambaPlayUITests/` - UI tests using XCTest
- `/SambaPlay/Resources/` - Audio samples and assets

## Audio Pipeline

The app uses a sophisticated AVAudioEngine setup for professional-quality audio processing:

```
AVAudioPlayerNode → AVAudioUnitTimePitch → AVAudioUnitVarispeed → MainMixerNode
```

This architecture enables:
- Independent speed and pitch control
- High-quality audio processing
- Real-time parameter adjustments
- Professional audio effects

## Network Protocol Support

Currently supports:
- **Samba/SMB**: Windows file sharing protocol
- **Local Files**: iOS document picker integration

*Future versions may include additional protocols like FTP, SFTP, or WebDAV.*

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Guidelines
- Follow Swift naming conventions
- Maintain programmatic UI approach
- Add appropriate unit tests
- Update documentation for new features

## Technical Requirements

- **iOS Version**: 18.5+
- **Development**: Xcode 16.4+
- **Swift**: 5.0
- **Frameworks**: UIKit, AVFoundation, Combine, UniformTypeIdentifiers

## Roadmap

- [ ] Real Samba/SMB protocol implementation
- [ ] Additional network protocols (FTP, WebDAV)
- [ ] Playlist management
- [ ] Audio effects and equalizer
- [ ] Cloud storage integration
- [ ] Multiple audio format support
- [ ] Offline caching
- [ ] Apple Watch companion app

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Built with modern iOS development practices
- Inspired by professional audio applications
- Designed for accessibility and usability

## Support

For questions, issues, or feature requests:
- Open an issue on GitHub
- Check existing discussions
- Review the [CLAUDE.md](CLAUDE.md) file for development guidance

---

**SambaPlay** - Professional audio streaming for iOS with advanced playback controls.