import XCTest

@MainActor
final class StudioFlowTests: XCTestCase {
    func testHomeAndInformation() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["photoPickerButton"].waitForExistence(timeout: 10))
        capture("01-home")
        app.buttons["infoButton"].tap()
        XCTAssertTrue(app.staticTexts["Что с SynthID"].waitForExistence(timeout: 5))
        capture("02-about")
    }

    func testProcessingComparisonAndReset() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture"]
        app.launch()
        let process = app.buttons["processButton"]
        XCTAssertTrue(process.waitForExistence(timeout: 15))
        capture("03-photo-ready")
        process.tap()
        XCTAssertTrue(app.buttons["saveButton"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.sliders["comparisonSlider"].exists)
        app.sliders["comparisonSlider"].adjust(toNormalizedSliderPosition: 0.75)
        capture("04-result")
        let scroll = app.scrollViews["studioScroll"]
        // Start inside the photograph, above the fixed export toolbar. A swipe
        // on the entire application can start on that toolbar instead.
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.65))
            .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)))
        if !app.buttons["editAgainButton"].isHittable {
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.65))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)))
        }
        XCTAssertTrue(app.staticTexts["verificationStatus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["verificationStatus"].isHittable, "Vertical swipes over the photo must scroll to result details")
        XCTAssertTrue(app.buttons["editAgainButton"].isHittable)
        XCTAssertEqual(app.staticTexts["verificationStatus"].label, "Статус SynthID: не проверен")
        capture("05-result-details")
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.25))
            .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.8)))
        app.buttons["resetButton"].tap()
        XCTAssertTrue(app.buttons["photoPickerButton"].exists)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
