import XCTest

/// The App Store screenshots, captured in the simulator so they do not depend on
/// owning one of every device Apple asks for.
///
/// Apple rejects a screenshot that is not the exact pixel size of the device it
/// claims to be from, and will not scale one up. `XCUIScreen.main.screenshot()`
/// captures at the simulator's real resolution, so the destination picked in
/// `.github/workflows/ios-screenshots.yml` is what decides the size:
///
///   iPhone 16 Pro Max     1320 × 2868   ("6.9-inch display", required)
///   iPad Pro 13-inch (M4) 2064 × 2752   ("13-inch display", required while
///                                        TARGETED_DEVICE_FAMILY is 1,2)
///
/// The app is launched with `-panura-screenshots`, which `ScreenshotMode` reads
/// to seed a browser state that does not need a live site — see that file for
/// why capturing real detection off the network is not worth its flakiness.
///
/// Every shot is an `XCTAttachment`; the workflow pulls them out of the
/// `.xcresult` with `xcresulttool export attachments`. Names are numbered
/// because App Store Connect orders screenshots by upload order, and the first
/// two are the ones shown in search results.
final class StoreScreenshots: XCTestCase {
    private var app: XCUIApplication!

    /// Long enough for a first launch on a cold simulator, short enough that a
    /// screen that never arrives fails the run rather than hanging it.
    private let appear: TimeInterval = 30

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-panura-screenshots"]
        app.launch()
    }

    func testCaptureStoreScreenshots() throws {
        // Home is the first screen, and the bar it sits on is what every other
        // step navigates with — so its absence is the one failure worth
        // reporting precisely.
        XCTAssertTrue(
            tab("Home").waitForExistence(timeout: appear),
            "The app bar never appeared; nothing below this point can be captured."
        )
        capture("01-home")

        go("Web")
        // The page has to commit and the found-bar fixture has to survive the
        // navigation that clears detections — see ScreenshotMode.prime.
        Thread.sleep(forTimeInterval: 8)
        capture("02-browser")

        go("Videos")
        capture("03-videos")

        // A dump of the tree, so the next pass can address elements by name
        // instead of guessing at them. Cheap, and it is the only way to see
        // inside a SwiftUI hierarchy from here.
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "99-element-tree"
        tree.lifetime = .keepAlways
        add(tree)
    }

    // MARK: driving the app

    private func tab(_ label: String) -> XCUIElement {
        app.buttons[label]
    }

    /// Taps a seat in the app bar and waits for the animation to settle. The
    /// destinations are all composed and swapped by opacity, so there is nothing
    /// to wait for the *existence* of — only for the fade to finish.
    private func go(_ label: String) {
        let seat = tab(label)
        XCTAssertTrue(seat.waitForExistence(timeout: appear), "No \(label) seat in the app bar")
        seat.tap()
        Thread.sleep(forTimeInterval: 1.2)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        // Without this the attachment is discarded for a passing test, which is
        // every run we actually want the files from.
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
