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
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["verificationStatus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["verificationStatus"].isHittable, "Vertical swipes over the photo must scroll to result details")
        XCTAssertTrue(app.buttons["editAgainButton"].isHittable)
        XCTAssertEqual(app.staticTexts["verificationStatus"].label, "Статус SynthID: не проверен")
        capture("05-result-details")
        app.swipeDown()
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
