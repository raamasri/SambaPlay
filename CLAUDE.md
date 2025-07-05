# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SambaPlay is an iOS audio player application built with Swift and UIKit that specializes in playing audio files from Samba network shares. The app features advanced audio controls including independent speed and pitch adjustment, lyrics/subtitle display, and both network and local file support.

## Development Commands

### Building and Running
```bash
# Open project in Xcode
open SambaPlay.xcodeproj

# Build from command line (if xcodebuild is available)
xcodebuild -project SambaPlay.xcodeproj -scheme SambaPlay -destination 'platform=iOS Simulator,name=iPhone 15' build

# Clean build folder
xcodebuild -project SambaPlay.xcodeproj -scheme SambaPlay clean
```

### Testing
```bash
# Run unit tests
xcodebuild test -project SambaPlay.xcodeproj -scheme SambaPlay -destination 'platform=iOS Simulator,name=iPhone 15'

# Run specific test
xcodebuild test -project SambaPlay.xcodeproj -scheme SambaPlay -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SambaPlayTests/SambaPlayTests/example

# Run UI tests
xcodebuild test -project SambaPlay.xcodeproj -scheme SambaPlay -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SambaPlayUITests
```

## Architecture Overview

### Core Components

**SambaPlayCoordinator** - The main app coordinator following a coordinator pattern that manages dependencies and navigation flow. This is the central hub that connects all major components.

**SimpleNetworkService** - Handles all network operations including:
- Samba server connections (currently demo/mock implementation)
- File browsing and navigation
- Server management (add/remove/connect)
- Local file system integration via UIDocumentPicker

**SimpleAudioPlayer** - Advanced audio playback engine using AVAudioEngine with:
- Real audio playback for bundled sample files
- Independent speed control (0.5x - 3.0x) using AVAudioUnitVarispeed
- Independent pitch adjustment (±6 semitones) using AVAudioUnitTimePitch
- Precise timing control with CADisplayLink for smooth updates

### UI Architecture

**MainViewController** - Primary file browser interface with:
- Network connection status display
- Hierarchical file navigation with breadcrumb path
- Server management integration
- Local file picker integration

**SimpleNowPlayingViewController** - Full-featured audio player interface with:
- Standard media controls (play/pause/seek/skip)
- Time display and progress slider
- Lyrics/subtitle text view with scrolling
- Settings button for audio adjustments

**AudioSettingsViewController** - Comprehensive audio control panel featuring:
- Speed control with slider, text input, and preset buttons
- Pitch control with semitone display and musical notation
- Fine-tuned ±1% speed adjustments
- BPM sync functionality
- Reset to defaults option
- Visual feedback for all interactions

**ServerManagementViewController** - Server configuration interface for:
- Adding new Samba servers with connection details
- Editing existing server configurations
- Server deletion with swipe-to-delete
- Direct connection from server list

### Data Models

**MediaFile** - Central file representation with:
- Audio file type detection via extension checking
- Associated subtitle file discovery (.txt files)
- File metadata (size, modification date, directory status)

**SambaServer** - Server configuration model with connection parameters

**AudioPlayerState/NetworkConnectionState** - State management enums for UI updates

### Audio Pipeline

The audio system uses AVAudioEngine with a sophisticated node graph:
```
AVAudioPlayerNode → AVAudioUnitTimePitch → AVAudioUnitVarispeed → MainMixerNode
```

This allows independent control of speed and pitch while maintaining audio quality.

## Key Development Patterns

### Coordinator Pattern
The app uses a coordinator pattern with `SambaPlayCoordinator` managing the creation and relationships between view controllers, preventing tight coupling.

### Combine Integration
Extensive use of Combine for reactive UI updates:
- `@Published` properties for state management
- Automatic UI updates via `sink` subscriptions
- Clean separation of concerns between data and presentation

### Programmatic UI
All UI is built programmatically using Auto Layout with:
- Constraint-based layouts for responsive design
- Proper safe area handling
- Accessibility considerations built-in

### Demo/Mock Implementation
Network functionality includes demo data structures for development and testing without requiring actual Samba servers.

## Testing Framework

- **Unit Tests**: Uses Swift Testing framework in `SambaPlayTests`
- **UI Tests**: Uses XCTest framework in `SambaPlayUITests`
- Test targets are configured for both iOS device and simulator testing

## Project Configuration

- **Deployment Target**: iOS 18.5+
- **Swift Version**: 5.0
- **Development Team**: BJPH4NFNB7
- **Bundle Identifier**: raamblings.SambaPlay
- **Build System**: Xcode 16.4 project format

## Audio Resources

The project includes a sample audio file (`Sample Song.mp3`) in the Resources folder that serves as the primary test audio for demonstrating real playback functionality with speed and pitch controls.

## Common Development Tasks

When adding new audio features, follow the established pattern:
1. Update the audio player model with new properties
2. Add UI controls to `AudioSettingsViewController`
3. Implement the audio processing in `SimpleAudioPlayer`
4. Wire up Combine bindings for reactive updates

When adding network features:
1. Extend `SimpleNetworkService` with new methods
2. Update the demo data structures if needed
3. Add corresponding UI in `MainViewController`
4. Handle state updates through published properties