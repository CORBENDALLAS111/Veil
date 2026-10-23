import XCTest

@MainActor
final class StudioFlowTests: XCTestCase {
    func testHomeAndInformation() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-light"]
        app.launch()
        XCTAssertTrue(app.buttons["photoPickerButton"].waitForExistence(timeout: 10))
        capture("01-home")
        app.buttons["infoButton"].tap()
        XCTAssertTrue(app.staticTexts["synthidExplanation"].waitForExistence(timeout: 5))
        capture("02-about")
    }

    func testProcessingComparisonAndReset() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "-ui-light"]
        app.launch()
        let process = app.buttons["processButton"]
        XCTAssertTrue(process.waitForExistence(timeout: 15))
        XCTAssertEqual(process.label, "Обработать")
        XCTAssertTrue(app.staticTexts["Без перерисовки · исходный размер"].exists)
        capture("03-photo-ready")
        process.tap()
        XCTAssertTrue(app.buttons["saveButton"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.sliders["comparisonSlider"].exists)
        app.sliders["comparisonSlider"].adjust(toNormalizedSliderPosition: 0.75)
        capture("04-result")
        let scroll = app.scrollViews["studioScroll"]
        if !app.staticTexts["verificationStatus"].isHittable {
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.65))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)))
        }
        XCTAssertTrue(app.staticTexts["verificationStatus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["verificationStatus"].isHittable)
        XCTAssertTrue(app.buttons["editAgainButton"].isHittable)
        XCTAssertEqual(app.staticTexts["verificationStatus"].label, "SynthID не проверен")
        capture("05-result-details")
        app.buttons["editAgainButton"].tap()
        XCTAssertTrue(app.buttons["processButton"].waitForExistence(timeout: 5))
        app.buttons["resetButton"].tap()
        XCTAssertTrue(app.buttons["photoPickerButton"].exists)
    }

    func testDarkGlassEditor() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-fixture", "-ui-dark", "-ui-metadata"]
        app.launch()
        XCTAssertTrue(app.buttons["processButton"].waitForExistence(timeout: 15))
        capture("06-dark-editor")
        app.buttons["processButton"].tap()
        XCTAssertTrue(app.buttons["saveButton"].waitForExistence(timeout: 45))
        XCTAssertTrue(app.buttons["shareButton"].isHittable)
        capture("07-dark-result")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
