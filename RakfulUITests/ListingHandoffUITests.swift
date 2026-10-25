import XCTest

/// An owned clothing item taken from photo review through approval, manual
/// handoff and the seller's own confirmation that it's listed. In
/// Simulator the automatic person check can't run, so the journey also
/// covers reviewing photos by hand; on a device they may already be checked.
@MainActor
final class ListingHandoffUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testOwnedClothingItemFromApprovalToSellerConfirmedListing() {
        let app = XCUIApplication()
        app.launchArguments = ["-RRResetData", "-rr.onboardingComplete", "YES", "-RRSeedListingItem", "-RRShowFirstItem"]
        app.launch()

        // Owned item → listing draft
        XCTAssertTrue(app.navigationBars["Denim Jacket"].waitForExistence(timeout: 15), "The owned item's detail should open")
        let prepare = app.buttons["Prepare Listing"]
        scrollTo(prepare, in: app)
        XCTAssertTrue(prepare.exists)
        prepare.tap()
        let ownership = app.switches["listing.ownershipDeclaration"]
        XCTAssertTrue(ownership.waitForExistence(timeout: 10), "The listing editor should open")
        snapshot("listing-01-editor")

        // Review each photo: check it shows only the item.
        app.buttons["listing.choosePhotos"].tap()
        XCTAssertTrue(app.navigationBars["Listing Photos"].waitForExistence(timeout: 10))
        for position in 1...2 {
            app.buttons["Review photo \(position)"].tap()
            let done = app.navigationBars["Check Photo"].buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 10))
            let confirm = app.buttons["photoReview.confirm"]
            if confirm.waitForExistence(timeout: 3) {
                if position == 1 { snapshot("listing-02-photo-review") }
                confirm.tap()
            } else {
                done.tap() // Already checked automatically (on a device)
            }
            XCTAssertTrue(app.navigationBars["Listing Photos"].waitForExistence(timeout: 10))
        }
        XCTAssertTrue(app.staticTexts["Checked by you"].exists || app.staticTexts["Checked · no people found"].exists)
        snapshot("listing-03-photos")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Ownership, text, condition, defects and price
        XCTAssertTrue(ownership.waitForExistence(timeout: 10))
        ownership.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(ownership.value as? String, "1", "Seller confirms they own it and want to sell it")

        app.buttons["Generate Listing"].tap()
        let title = app.descendants(matching: .any)["listing.title"]
        expectation(for: NSPredicate(format: "value CONTAINS 'Denim Jacket'"), evaluatedWith: title)
        waitForExpectations(timeout: 10)

        choose("Good", inPickerLabelled: "Condition", in: app)
        choose("None Found", inPickerLabelled: "Wear or Defects", in: app)

        let price = app.textFields["Enter price"]
        scrollTo(price, in: app)
        price.tap()
        price.typeText("25")
        app.toolbars.buttons["Done"].tap()

        let reviewAndApprove = app.buttons["listing.reviewAndApprove"]
        scrollTo(reviewAndApprove, in: app)
        snapshot("listing-04-ready")
        XCTAssertTrue(app.staticTexts["Ready to approve"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(reviewAndApprove.isEnabled)

        // One approval screen with the exact package
        reviewAndApprove.tap()
        let approve = app.buttons["approval.approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 15), "The approval screen should prepare the photos")
        XCTAssertTrue(app.staticTexts["Photo 1 · Main"].exists)
        snapshot("listing-05-approval")
        let approvedTitle = app.staticTexts["approval.title"]
        scrollTo(approvedTitle, in: app)
        XCTAssertTrue(approvedTitle.label.contains("Denim Jacket"))
        XCTAssertTrue(app.staticTexts["None found"].exists || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'None found'")).firstMatch.exists)
        snapshot("listing-05b-approval-details")
        approve.tap()

        let status = app.descendants(matching: .any).matching(identifier: "listing.status").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.hasPrefix("Approved"), status.label)

        // Manual handoff: copying doesn't mark it as listed.
        app.buttons["listing.export"].tap()
        let copy = app.buttons["handoff.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        copy.tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.hasPrefix("Handed Off · Not confirmed as listed"))
        snapshot("listing-06-handoff")
        app.navigationBars["Export Listing"].buttons["Done"].tap()

        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.hasPrefix("Handed Off"), status.label)
        XCTAssertFalse(status.label.contains("Confirmed by you"))

        // The Sell tab agrees: handed off, not listed.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Handed Off · Not confirmed'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The draft should be under Handed Off")
        XCTAssertFalse(app.staticTexts["Listed"].exists)
        row.tap()

        // The seller confirms it's live, with a link.
        XCTAssertTrue(app.switches["listing.ownershipDeclaration"].waitForExistence(timeout: 10) || app.staticTexts["You confirmed you own this and want to sell it"].waitForExistence(timeout: 10))
        let confirmListed = app.buttons["listing.confirmListed"]
        scrollTo(confirmListed, in: app)
        XCTAssertTrue(confirmListed.exists)
        confirmListed.tap()
        let link = app.textFields["confirmListed.link"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        link.typeText("ebay.co.uk/itm/1234")
        snapshot("listing-07-confirm")
        app.buttons["confirmListed.confirm"].tap()

        let celebration = app.descendants(matching: .any).containing(NSPredicate(format: "label BEGINSWITH 'Marked as Listed'")).firstMatch
        XCTAssertTrue(celebration.waitForExistence(timeout: 10))
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.hasPrefix("Listed · Confirmed by you"), status.label)
        XCTAssertTrue(app.links["Open Your Listing"].exists || app.buttons["Open Your Listing"].exists)
        snapshot("listing-08-listed")
    }

    // MARK: - Helpers

    /// Opens a menu-style picker in a form and chooses an option.
    private func choose(_ option: String, inPickerLabelled label: String, in app: XCUIApplication) {
        let picker = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        scrollTo(picker, in: app)
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", option)).firstMatch
        // Tapping while the form is still decelerating can miss the menu.
        for _ in 0..<3 where !item.exists {
            pause(0.6)
            picker.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            _ = item.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(item.exists, "\(label) menu should open")
        item.tap()
        pause(0.4)
    }

    /// Scrolls with slow drags until the element sits clear of the bars.
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for attempt in 0..<12 {
            // Check the frame before hittability: asking an off-screen cell
            // whether it's hittable fails the test instead of returning false.
            if element.exists, element.frame.minY > 150, element.frame.maxY < app.frame.maxY - 150, element.isHittable { return }
            // Not loaded yet: look below first, then above.
            let upward = element.exists ? element.frame.minY < 150 : attempt >= 6
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
