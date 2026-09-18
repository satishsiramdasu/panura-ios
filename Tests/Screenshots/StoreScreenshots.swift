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
        // navigation that clears detections — see ScreenshotMode.prime. Long,
        // because a cold web view on a runner is slow and a blank page is the
        // one failure this shot can have.
        Thread.sleep(forTimeInterval: 14)
        capture("02-browser")
        dumpTree("97-tree-browser")

        go("Videos")
        // The clip the workflow put in the library has to be scanned before the
        // grid can draw it.
        Thread.sleep(forTimeInterval: 4)
        capture("03-videos")
        dumpTree("98-tree-videos")

        // Best effort, and deliberately not an assertion: which query finds a
        // grid item depends on how SwiftUI exposed it, and a missing player shot
        // is worth less than losing the three above it to a failed run. The
        // element dump below says what was actually there.
        for candidate in [app.cells.firstMatch, app.images.firstMatch, app.otherElements.buttons.firstMatch] {
            guard candidate.waitForExistence(timeout: 5), candidate.isHittable else { continue }
            candidate.tap()
            Thread.sleep(forTimeInterval: 6)
            capture("04-player")
            // Controls fade on their own; a tap in the middle brings them back.
            app.tap()
            Thread.sleep(forTimeInterval: 1.5)
            capture("05-player-controls")
            break
        }

        dumpTree("99-tree-end")
    }

    /// The element hierarchy as XCUITest sees it. The only way to find out what
    /// a SwiftUI screen actually exposes without a Mac in front of you, so the
    /// next pass can address things by name instead of guessing.
    private func dumpTree(_ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name
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
