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
/// **One launch per screen, and not one tap in the whole run.** That is the
/// design, and it is not fussiness: XCUITest waits for the app under test to be
/// idle before every interaction, and the screens worth photographing are never
/// idle — a page with CSS animation, a video playing, a timer refreshing
/// fixtures. Tapping through them made two consecutive runs sit in a 25-minute
/// timeout. A screenshot needs no idle app, so the app is launched straight into
/// each screen instead (`-panura-screen`, read by `ScreenshotMode`) and
/// photographed.
///
/// Every shot is an `XCTAttachment`; the workflow pulls them out of the
/// `.xcresult` with `xcresulttool export attachments`. Names are numbered
/// because App Store Connect orders screenshots by upload order, and the first
/// two are the ones shown in search results.
final class StoreScreenshots: XCTestCase {
    /// Seconds to let a screen settle before photographing it. Generous, because
    /// the whole run is four launches and nothing else — and a screenshot of a
    /// half-drawn screen costs another 16-minute run.
    private enum Settle {
        static let plain: TimeInterval = 4
        /// A cold web view fetching a real page on a CI runner.
        static let web: TimeInterval = 16
        /// The library has to be scanned, then the player opened and the first
        /// frames decoded.
        static let player: TimeInterval = 14
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testCaptureStoreScreenshots() throws {
        shoot("01-home", screen: "home", settle: Settle.plain)
        shoot("02-browser", screen: "web", settle: Settle.web)
        shoot("03-videos", screen: "videos", settle: Settle.plain)
        // No tree for the player: `debugDescription` takes an accessibility
        // snapshot, and asking a screen that is decoding video for one is the
        // same bet that cost two runs.
        shoot("04-player", screen: "player", settle: Settle.player, tree: false)
    }

    /// Launches the app straight into one screen, waits, photographs it, and
    /// leaves it terminated so the next launch starts clean.
    private func shoot(_ name: String, screen: String, settle: TimeInterval, tree wantsTree: Bool = true) {
        let app = XCUIApplication()
        app.launchArguments = ["-panura-screenshots", "-panura-screen", screen]
        app.launch()
        Thread.sleep(forTimeInterval: settle)

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        // Without this the attachment is discarded for a passing test, which is
        // every run the files are actually wanted from.
        shot.lifetime = .keepAlways
        add(shot)

        // The element hierarchy as XCUITest sees it — the only way to find out
        // what a SwiftUI screen exposes without a Mac in front of you, and the
        // one diagnostic that says whether a blank-looking shot is an empty
        // screen or a screen that never drew.
        if wantsTree {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "tree-\(name)"
            tree.lifetime = .keepAlways
            add(tree)
        }

        app.terminate()
    }
}
