import XCTest

/// The floating dock drives every tab, and each screen's last row scrolls
/// clear of it.
@MainActor
final class RedesignUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = true
    }

    func testDockNavigatesAndNeverCoversTheLastRow() {
        let app = XCUIApplication()
        app.launchArguments = ["-RRResetData", "-rr.onboardingComplete", "YES", "-RRSeedSamples"]
        app.launch()

        let home = app.buttons["tab.home"]
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Your discoveries'")).firstMatch.waitForExistence(timeout: 10))
        snapshot("redesign-01-home")

        let screens: [(tab: String, last: String, name: String)] = [
            ("tab.home", "Mode", "home"),
            ("tab.wardrobe", "Beanie", "wardrobe"),
            ("tab.sell", "Beanie", "sell"),
            ("tab.activity", "Sample items added", "activity"),
        ]
        for screen in screens {
            let tab = app.buttons[screen.tab]
            tab.tap()
            XCTAssertTrue(tab.isSelected, "\(screen.tab) should be selected")
            pause(0.8)
            for _ in 0..<8 { app.swipeUp(velocity: .fast) }
            pause(1)
            snapshot("redesign-02-\(screen.name)-bottom")
            let last = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", screen.last)).firstMatch
            XCTAssertTrue(last.exists, "\(screen.last) should be on \(screen.name)")
            let dockTop = tab.frame.minY - 6
            XCTAssertLessThanOrEqual(last.frame.maxY, dockTop, "\(screen.last) must sit above the dock on \(screen.name)")
        }

        // A pushed form ends above the dock too.
        app.buttons["tab.wardrobe"].tap()
        for _ in 0..<8 { app.swipeDown(velocity: .fast) }
        let card = app.buttons["Denim Jacket"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.navigationBars["Denim Jacket"].waitForExistence(timeout: 10))
        for _ in 0..<8 { app.swipeUp(velocity: .fast) }
        pause(1)
        snapshot("redesign-03-item-detail-bottom")
        let remove = app.buttons["Remove Item"]
        XCTAssertTrue(remove.exists)
        XCTAssertLessThanOrEqual(remove.frame.maxY, app.buttons["tab.wardrobe"].frame.minY - 6, "The last row of a pushed screen must sit above the dock")
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func snapshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["RR_SCREENSHOT_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}
