import XCTest

/// Walks the branded moments: onboarding, value reveal, swipe review,
/// ready-to-list and the listed celebration. Screenshots are attached to the
/// results and, when `RR_SCREENSHOT_DIR` is set, written to disk for the
/// App Store.
@MainActor
final class BrandJourneyUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testSwipeReviewAndCelebrateListing() {
        let app = XCUIApplication()
        app.launchArguments = ["-RRResetData"]
        app.launch()

        // Onboarding illustrations
        XCTAssertTrue(app.staticTexts["Find things to sell in your photos."].waitForExistence(timeout: 8))
        pause(0.6)
        snapshot("store-01-welcome")
        let pages = [
            ("store-02-privacy", "Your photos stay under your control."),
            ("store-03-categories", "Choose what to discover."),
            ("store-04-ready", "Ready when you are."),
        ]
        for (name, heading) in pages {
            // A tap during the page transition can be dropped; retry until the page shows.
            let title = app.staticTexts[heading]
            for _ in 0..<3 where !title.exists {
                app.buttons["Continue"].tap()
                _ = title.waitForExistence(timeout: 3)
            }
            XCTAssertTrue(title.exists, "\(heading) should appear")
            pause(0.8)
            snapshot(name)
        }
        app.buttons["onboarding.exploreSamples"].tap()

        // Value reveal
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '12 sample items'")).firstMatch.waitForExistence(timeout: 10))
        pause(1.8)
        snapshot("store-05-discover")
        app.swipeUp()
        pause(0.8)
        snapshot("store-06-discover-cards")
        app.swipeDown()

        // Swipe review
        app.buttons["tab.wardrobe"].tap()
        let prompt = app.buttons["Review (3)"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.tap()
        XCTAssertTrue(app.staticTexts["Do you still own this item?"].waitForExistence(timeout: 10))
        pause(0.6)
        snapshot("store-07-review")

        drag(in: app, from: 0.3, to: 0.95)
        XCTAssertTrue(app.staticTexts["2 to review"].waitForExistence(timeout: 10), "Swiping right should keep the item")
        pause(0.8) // let the next card settle before dragging it
        drag(in: app, from: 0.7, to: 0.05)
        XCTAssertTrue(app.staticTexts["1 to review"].waitForExistence(timeout: 10), "Swiping left should mark it not owned")
        XCTAssertTrue(app.buttons["Undo"].exists)
        app.buttons["I Own It"].tap()
        XCTAssertTrue(app.staticTexts["All Caught Up"].waitForExistence(timeout: 10))
        pause(0.35)
        snapshot("store-08-caught-up")

        // Ready to list
        app.buttons["Go to Sell"].tap()
        let trainers = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Trainers'")).firstMatch
        XCTAssertTrue(app.buttons["sell.ready"].waitForExistence(timeout: 10), "Swiped-right item should be ready to list")
        scrollTo(trainers, in: app)
        trainers.tap()
        let generate = app.buttons["Generate Listing"]
        XCTAssertTrue(app.switches["listing.ownershipDeclaration"].waitForExistence(timeout: 10))
        scrollTo(generate, in: app)
        generate.tap()
        let title = app.descendants(matching: .any)["listing.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value CONTAINS 'Trainers'"), evaluatedWith: title)
        waitForExpectations(timeout: 10)

        // Rakful doesn't estimate prices; the seller checks eBay's sold
        // listings and types their own.
        let price = app.textFields["Enter price"]
        scrollTo(price, in: app)
        XCTAssertTrue(app.links["See Sold Prices on eBay"].exists || app.buttons["See Sold Prices on eBay"].exists)
        price.tap()
        price.typeText("68")
        app.toolbars.buttons["Done"].tap()
        // The picker row ("Condition, …, Select") also contains a smaller
        // "Condition needs confirmation" button, so tap the row's value side.
        let condition = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Condition' AND label ENDSWITH 'Select'")).firstMatch
        scrollTo(condition, in: app, upward: true)
        let likeNew = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Like New'")).firstMatch
        // Tapping while the form is still decelerating can miss the menu.
        for _ in 0..<3 where !likeNew.exists {
            pause(0.6)
            condition.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            _ = likeNew.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(likeNew.exists, "Condition menu should open")
        likeNew.tap()

        // Defects answer and the seller's ownership confirmation.
        let defects = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Wear or Defects'")).firstMatch
        scrollTo(defects, in: app)
        let noneFound = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'None Found'")).firstMatch
        for _ in 0..<3 where !noneFound.exists {
            pause(0.6)
            defects.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            _ = noneFound.waitForExistence(timeout: 2)
        }
        noneFound.tap()
        let ownership = app.switches["listing.ownershipDeclaration"]
        scrollTo(ownership, in: app, upward: true)
        ownership.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()

        let reviewAndApprove = app.buttons["listing.reviewAndApprove"]
        scrollTo(reviewAndApprove, in: app)
        XCTAssertTrue(app.staticTexts["Ready to approve"].firstMatch.waitForExistence(timeout: 10), "Completing the draft should confirm it's ready")
        pause(0.5)
        snapshot("store-09-ready-to-list")
        app.swipeDown()
        app.swipeDown()
        pause(0.5)
        snapshot("store-09b-listing-top")

        // Approve, then the seller confirms it's listed.
        scrollTo(reviewAndApprove, in: app)
        reviewAndApprove.tap()
        let approve = app.buttons["approval.approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 15))
        approve.tap()
        let confirmListed = app.buttons["listing.confirmListed"]
        scrollTo(confirmListed, in: app)
        confirmListed.tap()
        let confirm = app.buttons["confirmListed.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        let listed = app.descendants(matching: .any).containing(NSPredicate(format: "label BEGINSWITH 'Marked as Listed'")).firstMatch
        XCTAssertTrue(listed.waitForExistence(timeout: 10), "Listing should be celebrated")
        pause(0.5)
        snapshot("store-10-listed")
    }

    // MARK: - Helpers

    private func drag(in app: XCUIApplication, from startX: CGFloat, to endX: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.45))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: 0.47))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// Scrolls with slow drags until the element sits clear of the bars;
    /// `isHittable` alone is true even under the navigation bar.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = false) {
        for attempt in 0..<12 {
            // Check the frame before hittability: asking an off-screen cell
            // whether it's hittable fails the test instead of returning false.
            if element.exists, element.frame.minY > 150, element.frame.maxY < app.frame.maxY - 150, element.isHittable { return }
            // Search in the given direction first, then the other way.
            let upward = element.exists ? element.frame.minY < 150 : (attempt < 6) == upward
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.35 : 0.65))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.65 : 0.35))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
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
