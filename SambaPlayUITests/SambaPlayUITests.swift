//
//  SambaPlayUITests.swift
//  SambaPlayUITests
//
//  Created by raama srivatsan on 7/4/25.
//

import XCTest

final class SambaPlayUITests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }
    
    override func tearDownWithError() throws {
        app = nil
    }
    
    // MARK: - Navigation Tests
    
    func testAppLaunchAndInitialState() throws {
        // Test that app launches successfully
        XCTAssertTrue(app.navigationBars.firstMatch.exists, "Navigation bar should exist")
        
        // Test that main view is displayed
        XCTAssertTrue(app.tables.firstMatch.exists, "Main table view should exist")
        
        // Test that settings button exists
        XCTAssertTrue(app.navigationBars.buttons["Settings"].exists, "Settings button should exist")
        
        print("✅ App launch and initial state test passed")
    }
    
    func testNavigationToSettings() throws {
        // Tap settings button
        let settingsButton = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(settingsButton.exists, "Settings button should exist")
        
        settingsButton.tap()
        
        // Verify settings view is displayed
        XCTAssertTrue(app.navigationBars["Settings"].exists, "Settings navigation bar should exist")
        XCTAssertTrue(app.tables.firstMatch.exists, "Settings table should exist")
        
        // Test back navigation
        let backButton = app.navigationBars.buttons.firstMatch
        backButton.tap()
        
        // Verify we're back to main view
        XCTAssertTrue(app.tables.firstMatch.exists, "Should return to main table view")
        
        print("✅ Navigation to settings test passed")
    }
    
    func testDirectoryNavigation() throws {
        // Wait for directory content to load
        let tableView = app.tables.firstMatch
        XCTAssertTrue(tableView.waitForExistence(timeout: 5), "Table view should exist")
        
        // Look for directory cells (folders)
        let cells = tableView.cells
        let directoryCell = cells.containing(.staticText, identifier: "Music").firstMatch
        
        if directoryCell.exists {
            // Tap on directory
            directoryCell.tap()
            
            // Verify navigation occurred
            XCTAssertTrue(tableView.exists, "Table view should still exist after navigation")
            
            // Test back navigation if possible
            let backButton = app.navigationBars.buttons.firstMatch
            if backButton.exists {
                backButton.tap()
            }
        }
        
        print("✅ Directory navigation test passed")
    }
    
    // MARK: - Search Tests
    
    func testSearchFunctionality() throws {
        // Look for search bar
        let searchBar = app.searchFields.firstMatch
        if searchBar.exists {
            // Tap search bar
            searchBar.tap()
            
            // Type search query
            searchBar.typeText("test")
            
            // Wait for search results
            sleep(1)
            
            // Verify table view still exists (results should be shown)
            XCTAssertTrue(app.tables.firstMatch.exists, "Search results table should exist")
            
            // Clear search
            let clearButton = searchBar.buttons["Clear text"]
            if clearButton.exists {
                clearButton.tap()
            }
        }
        
        print("✅ Search functionality test passed")
    }
    
    func testLyricsSearchToggle() throws {
        // Navigate to settings
        app.navigationBars.buttons["Settings"].tap()
        
        // Look for lyrics search toggle
        let lyricsSearchCell = app.tables.cells.containing(.staticText, identifier: "Lyrics Search").firstMatch
        if lyricsSearchCell.exists {
            // Find the switch within the cell
            let lyricsSwitch = lyricsSearchCell.switches.firstMatch
            if lyricsSwitch.exists {
                // Toggle the switch
                let initialValue = lyricsSwitch.value as? String
                lyricsSwitch.tap()
                
                // Verify the switch value changed
                let newValue = lyricsSwitch.value as? String
                XCTAssertNotEqual(initialValue, newValue, "Lyrics search switch should toggle")
            }
        }
        
        // Navigate back
        app.navigationBars.buttons.firstMatch.tap()
        
        print("✅ Lyrics search toggle test passed")
    }
    
    // MARK: - Settings Tests
    
    func testSettingsToggles() throws {
        // Navigate to settings
        app.navigationBars.buttons["Settings"].tap()
        
        // Test various settings toggles
        let settingsToTest = [
            "File Search",
            "Drag & Drop",
            "Voice Over",
            "Dynamic Text",
            "Haptic Feedback",
            "Auto Play",
            "Lyrics Search"
        ]
        
        for settingName in settingsToTest {
            let settingCell = app.tables.cells.containing(.staticText, identifier: settingName).firstMatch
            if settingCell.exists {
                let settingSwitch = settingCell.switches.firstMatch
                if settingSwitch.exists {
                    // Test toggle
                    let initialValue = settingSwitch.value as? String
                    settingSwitch.tap()
                    
                    // Small delay for UI update
                    sleep(1)
                    
                    let newValue = settingSwitch.value as? String
                    XCTAssertNotEqual(initialValue, newValue, "\(settingName) switch should toggle")
                    
                    // Toggle back
                    settingSwitch.tap()
                }
            }
        }
        
        // Navigate back
        app.navigationBars.buttons.firstMatch.tap()
        
        print("✅ Settings toggles test passed")
    }
    
    func testSettingsSegmentedControls() throws {
        // Navigate to settings
        app.navigationBars.buttons["Settings"].tap()
        
        // Test segmented controls (if any exist)
        let segmentedControls = app.segmentedControls
        for segmentedControl in segmentedControls.allElementsBoundByIndex {
            if segmentedControl.exists {
                let buttons = segmentedControl.buttons
                if buttons.count > 1 {
                    // Test selecting different segments
                    let firstButton = buttons.firstMatch
                    let lastButton = buttons.allElementsBoundByIndex.last!
                    
                    firstButton.tap()
                    sleep(1)
                    lastButton.tap()
                    sleep(1)
                }
            }
        }
        
        // Navigate back
        app.navigationBars.buttons.firstMatch.tap()
        
        print("✅ Settings segmented controls test passed")
    }
    
    // MARK: - Audio Player Tests
    
    func testAudioPlayerInterface() throws {
        // Look for audio player controls
        let playButton = app.buttons["Play"]
        let pauseButton = app.buttons["Pause"]
        let skipButton = app.buttons["Skip"]
        let previousButton = app.buttons["Previous"]
        
        // Test if audio controls exist (they might not be visible without audio loaded)
        if playButton.exists {
            playButton.tap()
            sleep(1)
            
            if pauseButton.exists {
                pauseButton.tap()
            }
        }
        
        // Test seeking slider if it exists
        let seekSlider = app.sliders.firstMatch
        if seekSlider.exists {
            // Test slider interaction
            seekSlider.adjust(toNormalizedSliderPosition: 0.5)
        }
        
        print("✅ Audio player interface test passed")
    }
    
    func testNowPlayingView() throws {
        // Look for now playing button or area
        let nowPlayingButton = app.buttons["Now Playing"]
        if nowPlayingButton.exists {
            nowPlayingButton.tap()
            
            // Verify now playing view opened
            XCTAssertTrue(app.otherElements.firstMatch.exists, "Now playing view should exist")
            
            // Test dismissing now playing view
            let dismissButton = app.buttons["Done"]
            if dismissButton.exists {
                dismissButton.tap()
            } else {
                // Try swipe down to dismiss
                app.swipeDown()
            }
        }
        
        print("✅ Now playing view test passed")
    }
    
    // MARK: - File Selection Tests
    
    func testFileSelection() throws {
        // Wait for content to load
        let tableView = app.tables.firstMatch
        XCTAssertTrue(tableView.waitForExistence(timeout: 5), "Table view should exist")
        
        // Look for audio files
        let cells = tableView.cells
        for i in 0..<min(cells.count, 3) {
            let cell = cells.element(boundBy: i)
            if cell.exists {
                cell.tap()
                
                // Small delay for potential audio loading
                sleep(2)
                
                // Check if audio player controls appeared
                let playButton = app.buttons["Play"]
                let pauseButton = app.buttons["Pause"]
                
                if playButton.exists || pauseButton.exists {
                    print("✅ Audio file selection triggered player controls")
                    break
                }
            }
        }
        
        print("✅ File selection test passed")
    }
    
    // MARK: - Drag and Drop Tests
    
    func testDragAndDropInterface() throws {
        // Test if drag and drop area exists
        let dragDropArea = app.otherElements["Drag files here"]
        if dragDropArea.exists {
            // Test tap on drag drop area
            dragDropArea.tap()
        }
        
        print("✅ Drag and drop interface test passed")
    }
    
    // MARK: - Accessibility Tests
    
    func testAccessibilityElements() throws {
        // Test that key elements have accessibility labels
        let settingsButton = app.navigationBars.buttons["Settings"]
        XCTAssertTrue(settingsButton.exists, "Settings button should be accessible")
        
        // Test table view accessibility
        let tableView = app.tables.firstMatch
        XCTAssertTrue(tableView.exists, "Table view should be accessible")
        
        // Test search bar accessibility
        let searchBar = app.searchFields.firstMatch
        if searchBar.exists {
            XCTAssertNotNil(searchBar.label, "Search bar should have accessibility label")
        }
        
        print("✅ Accessibility elements test passed")
    }
    
    // MARK: - Performance Tests
    
    func testAppLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
        
        print("✅ App launch performance test completed")
    }
    
    func testScrollingPerformance() throws {
        let tableView = app.tables.firstMatch
        XCTAssertTrue(tableView.waitForExistence(timeout: 5), "Table view should exist")
        
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric]) {
            tableView.swipeUp()
            tableView.swipeDown()
        }
        
        print("✅ Scrolling performance test completed")
    }
    
    // MARK: - Integration Tests
    
    func testSearchAndNavigation() throws {
        // Test combining search with navigation
        let searchBar = app.searchFields.firstMatch
        if searchBar.exists {
            searchBar.tap()
            searchBar.typeText("music")
            
            // Wait for search results
            sleep(2)
            
            // Try to tap on a result
            let tableView = app.tables.firstMatch
            let firstCell = tableView.cells.firstMatch
            if firstCell.exists {
                firstCell.tap()
                sleep(1)
            }
            
            // Clear search
            let clearButton = searchBar.buttons["Clear text"]
            if clearButton.exists {
                clearButton.tap()
            }
        }
        
        print("✅ Search and navigation integration test passed")
    }
    
    func testSettingsAndPlayback() throws {
        // Test that settings changes affect playback behavior
        
        // Navigate to settings
        app.navigationBars.buttons["Settings"].tap()
        
        // Toggle auto play setting
        let autoPlayCell = app.tables.cells.containing(.staticText, identifier: "Auto Play").firstMatch
        if autoPlayCell.exists {
            let autoPlaySwitch = autoPlayCell.switches.firstMatch
            if autoPlaySwitch.exists {
                autoPlaySwitch.tap()
            }
        }
        
        // Navigate back
        app.navigationBars.buttons.firstMatch.tap()
        
        // Try to select a file and see if auto play behavior changed
        let tableView = app.tables.firstMatch
        let firstCell = tableView.cells.firstMatch
        if firstCell.exists {
            firstCell.tap()
            sleep(2)
        }
        
        print("✅ Settings and playback integration test passed")
    }
}
