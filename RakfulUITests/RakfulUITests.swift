import XCTest

/// End-to-end journeys through the real app. Screenshots are attached to the
/// test results and, when `RR_SCREENSHOT_DIR` is set, also written to disk.
@MainActor
final class RakfulUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    // MARK: - Journeys

    func testOnboardingLeadsToLabelledSampleItems() {
        let app = launch(["-RRResetData"])
        XCTAssertTrue(app.staticTexts["Find things to sell in your photos."].waitForExistence(timeout: 8))
        snapshot("01-onboarding-welcome")

        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Your photos stay under your control."].waitForExistence(timeout: 10))
        snapshot("02-onboarding-privacy")

        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Choose what to discover."].waitForExistence(timeout: 10))
        snapshot("03-onboarding-categories")

        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Ready when you are."].waitForExistence(timeout: 10))
        snapshot("04-onboarding-ready")

        app.buttons["onboarding.exploreSamples"].tap()
        XCTAssertTrue(app.staticTexts["12 items"].waitForExistence(timeout: 10), "Demo summary should appear")
        XCTAssertTrue(app.staticTexts["Sample item, not from your photos"].exists, "Sample items must be labelled")
        snapshot("05-discover-samples")
    }

    func testReviewOwnershipThenGenerateListing() {
        let app = launch(["-RRResetData", "-rr.onboardingComplete", "YES", "-RRSeedSamples"])
        let review = app.buttons["Review (3)"]
        // A tap right after launch can be dropped; tap the tab again if needed.
        for _ in 0..<3 where !review.waitForExistence(timeout: 4) {
            app.tabBars.buttons["Wardrobe"].tap()
        }
        XCTAssertTrue(review.exists)
        snapshot("06-items-grid")

        review.tap()
        XCTAssertTrue(app.staticTexts["Do you still own this item?"].waitForExistence(timeout: 10))
        snapshot("07-review")
        app.buttons["I Own It"].tap()
        XCTAssertTrue(app.staticTexts["2 to review"].waitForExistence(timeout: 10), "Queue should advance after confirming")
        app.buttons["Done"].firstMatch.tap()

        app.tabBars.buttons["Sell"].tap()
        let trainers = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Trainers'")).firstMatch
        XCTAssertTrue(trainers.waitForExistence(timeout: 10), "Confirmed item should be ready to list")
        snapshot("08-sell")
        trainers.tap()

        let generate = app.buttons["Generate Listing"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        generate.tap()
        let title = app.descendants(matching: .any)["listing.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value CONTAINS 'Trainers'"), evaluatedWith: title)
        waitForExpectations(timeout: 10)
        snapshot("09-listing-generated")
    }

    func testDiscoveryAnalysesRealPhotoLibrary() {
        let app = launch(["-RRResetData", "-rr.onboardingComplete", "YES"])
        let start = app.buttons["Start Discovery"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow Full Access"]
        if allow.waitForExistence(timeout: 10) {
            snapshot("10-permission-prompt")
            allow.tap()
        } else {
            snapshot("10-no-prompt-found")
            if let directory = ProcessInfo.processInfo.environment["RR_SCREENSHOT_DIR"] {
                try? springboard.debugDescription.write(toFile: directory + "/springboard.txt", atomically: true, encoding: .utf8)
            }
        }

        // On a device, discovery finishes with items listed. In Simulator,
        // Vision's classifier is degenerate, and the app must say so instead
        // of silently marking photos as analysed.
        let discovered = app.staticTexts.containing(NSPredicate(format: "label MATCHES '^[1-9][0-9,]* items?$'")).firstMatch
        let unavailable = app.alerts.containing(NSPredicate(format: "label CONTAINS[c] 'Discovery Couldn' OR identifier CONTAINS[c] 'Discovery Couldn'")).firstMatch
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !discovered.exists, !unavailable.exists { _ = discovered.waitForExistence(timeout: 1) }

        if unavailable.exists {
            snapshot("11-analysis-unavailable")
            #if targetEnvironment(simulator)
            unavailable.buttons["OK"].tap()
            // Nothing may be marked as analysed when the model is unusable.
            XCTAssertTrue(app.buttons["Start Discovery"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.staticTexts["No Items Found Yet"].exists)
            #else
            XCTFail("On-device analysis should be available on a real iPhone")
            #endif
        } else {
            XCTAssertTrue(discovered.exists, "Discovery should complete and show discovered items")
            XCTAssertTrue(app.buttons["Start Discovery"].waitForExistence(timeout: 60))
            snapshot("11-discover-real")
        }

        app.tabBars.buttons["Wardrobe"].tap()
        snapshot("12-items-real")
        app.tabBars.buttons["Activity"].tap()
        snapshot("13-activity-real")
    }

    // MARK: - Helpers

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
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
