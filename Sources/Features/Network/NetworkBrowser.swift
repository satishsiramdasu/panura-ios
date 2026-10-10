import Foundation
import VLCKit

/// Lists a directory on a network server.
///
/// **Every VLCKit symbol the browsing path uses is in this file.** VLCKit 4 is
/// an alpha and has renamed things since 3.x; keeping the contact surface in
/// one place means a rename costs one file rather than a hunt. The rest of the
/// feature deals in `NetworkEntry`, which is ours.
///
/// libVLC does the work. Its access modules — smb, sftp, ftp, nfs — are also
/// *browsers*: parse a media built on a directory URL and `subitems` comes back
/// as the listing. That is how VLC's own apps draw their network tabs, and it
/// means there is no FTP or SMB protocol code in this app at all.
///
/// **Parsing is not on `VLCMedia` in VLCKit 4.** It was in 3.x
/// (`parseWithOptions:`); 4.0 moved it to a separate `VLCMediaParser` that you
/// queue media on and which reports through its own delegate. `VLCMedia` kept
/// only `parsedStatus` and `subitems`. Worth stating because every tutorial and
/// every answer online is written against 3.x and none of it compiles.
///
/// Four things that are not obvious and cost an afternoon each:
///
/// 1. **The media must be retained for the whole parse.** It is asynchronous;
///    let it deallocate and `subitems` simply never arrives — no error, just an
///    empty list for ever.
/// 2. **Directory URLs end in a slash.** Without it libVLC may open the path as
///    a file and return nothing.
/// 3. **Never pass `VLCMediaDoInteract`.** It makes libVLC ask for credentials
///    through its dialog API, and with no `VLCDialogProvider` installed the
///    parse waits for an answer that never comes. Credentials go in the URL
///    instead — see `NetworkServer.url(password:path:)`.
/// 4. **The options are passed by raw value on purpose.** `VLCMediaParsingOptions`
///    is an alpha `NS_OPTIONS` whose Swift case names depend on how the importer
///    strips the shared prefix; the numbers are in the header and cannot be
///    renamed out from under us.
@MainActor
final class NetworkBrowser: NSObject, ObservableObject {
    /// Shared, because two screens need the same answer to "is a folder
    /// open?" — the listing itself, and `ServersView` above it, which shows
    /// the list of sources whenever nothing is.
    static let shared = NetworkBrowser()

    struct Entry: Identifiable, Hashable {
        var id: String { url.absoluteString }
        let name: String
        let url: URL
        let isDirectory: Bool
    }

    /// One level, for the breadcrumb and for going back up.
    struct Level: Identifiable, Hashable {
        var id: String { url.absoluteString }
        let name: String
        let url: URL
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var levels: [Level] = []
    @Published private(set) var isLoading = false
    /// Set when a listing fails or comes back empty for long enough to count.
    @Published private(set) var failure: String?

    /// The media being parsed. Held because letting it go loses the listing —
    /// see the note above, reason one.
    private var pending: VLCMedia?
    private var timeout: Task<Void, Never>?

    /// `VLCMediaParsingOptions.VLCMediaParse` — 0x01 in the header.
    ///
    /// Parse only. `VLCMediaFetchNetwork` (0x04) would also pull metadata and
    /// artwork for every entry over the wire, which on a folder of four hundred
    /// films is a great deal of network for two columns of text we do not draw.
    private static let parseOnly = VLCMediaParsingOptions(rawValue: 0x01)

    /// How long to wait before calling it a failure.
    ///
    /// Generous: a sleeping NAS spinning its disks up, or an FTP server that
    /// takes its time on PASV, is slow rather than broken. Shorter than this
    /// and the app gives up on servers that would have answered.
    private static let patience: Duration = .seconds(20)

    /// What is worth showing. Everything else on a server — documents,
    /// archives, a thousand photos — is noise on a screen that exists to find
    /// something to watch.
    private static let playable: Set<String> = [
        "mp4", "mkv", "avi", "mov", "m4v", "webm", "flv", "wmv", "mpg", "mpeg",
        "ts", "m2ts", "vob", "ogv", "divx", "rmvb", "3gp", "m3u8", "mp3", "flac",
        "m4a", "aac", "wav", "ogg", "opus",
    ]

    // MARK: opening

    /// Opens a server at its start path.
    func open(_ server: NetworkServer, password: String) {
        guard let url = server.url(password: password) else {
            failure = "That address is not valid."
            return
        }
        levels = [Level(name: server.displayName, url: url)]
        load(url)
    }

    /// Enters a directory from the listing.
    func enter(_ entry: Entry) {
        guard entry.isDirectory else { return }
        levels.append(Level(name: entry.name, url: entry.url))
        load(entry.url)
    }

    /// Back to a level in the breadcrumb, dropping everything under it.
    func go(to level: Level) {
        guard let index = levels.firstIndex(of: level) else { return }
        levels = Array(levels.prefix(through: index))
        load(level.url)
    }

    func up() {
        guard levels.count > 1 else { return }
        levels.removeLast()
        if let last = levels.last { load(last.url) }
    }

    func close() {
        cancel()
        levels = []
        entries = []
        failure = nil
    }

    // MARK: the one place VLCKit is touched

    private func load(_ url: URL) {
        cancel()
        entries = []
        failure = nil
        isLoading = true

        guard let media = VLCMedia(url: url) else {
            isLoading = false
            failure = "That address is not valid."
            return
        }
        pending = media
        // One shared parser for the app. Nothing else in Panura parses media,
        // so taking its delegate is safe — and it is a delegate rather than a
        // completion handler, which is why the browser is an NSObject.
        let parser = VLCMediaParser.shared()
        parser.delegate = self
        // Returns a libvlc status that is only ever interesting when the
        // parser is torn down, which is not something this does.
        _ = parser.queue(media, options: Self.parseOnly)

        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.patience)
            guard let self, !Task.isCancelled, self.isLoading else { return }
            self.isLoading = false
            self.pending = nil
            self.failure = "The server did not answer. Check the address, "
                + "the share name and whether it needs a username."
        }
    }

    private func cancel() {
        timeout?.cancel()
        timeout = nil
        if let pending { VLCMediaParser.shared().cancelParsing(for: pending) }
        pending = nil
        isLoading = false
    }

    /// Turns libVLC's subitems into our own rows.
    private func collect(_ media: VLCMedia) {
        guard let list = media.subitems else {
            finish(with: [])
            return
        }
        var found: [Entry] = []
        for index in 0..<list.count {
            // `mediaAtIndex:` takes an NSUInteger while `count` is an NSInteger,
            // so the two do not meet without this.
            guard let item = list.media(at: UInt(index)), let url = item.url else { continue }
            let directory = item.mediaType == .directory
            let name = item.metaData.title ?? url.lastPathComponent
            guard directory || Self.playable.contains(url.pathExtension.lowercased()) else {
                continue
            }
            found.append(Entry(name: name, url: url, isDirectory: directory))
        }
        finish(with: found)
    }

    private func finish(with found: [Entry]) {
        timeout?.cancel()
        timeout = nil
        pending = nil
        isLoading = false
        // Folders first, then by name — the order every file browser uses, and
        // the one that puts the thing people are looking for near the top.
        entries = found.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if entries.isEmpty {
            failure = "Nothing here that can be played."
        }
    }

    /// What the player is handed.
    ///
    /// The URL already carries the credentials, so nothing further is needed —
    /// and nothing further is stored. It is pinned to VLC by scheme, because
    /// AVPlayer cannot open any of these — see `PlayerEngineKind.needsVLC`.
    static func item(for entry: Entry) -> MediaItem {
        MediaItem(
            title: entry.name,
            url: entry.url,
            isLocal: false
        )
    }
}

extension NetworkBrowser: VLCMediaParserDelegate {
    nonisolated func mediaFinishedParsing(_ media: VLCMedia, with status: VLCMediaParsedStatus) {
        Task { @MainActor in
            // The shared parser may still be finishing something this browser
            // has already moved on from.
            guard media === self.pending else { return }
            guard status == .done else {
                self.timeout?.cancel()
                self.timeout = nil
                self.pending = nil
                self.isLoading = false
                self.failure = Self.message(for: status)
                return
            }
            self.collect(media)
        }
    }

    /// Why libVLC gave up, in words somebody can act on.
    private static func message(for status: VLCMediaParsedStatus) -> String {
        switch status {
        case .timeout:
            return "The server took too long to answer."
        case .cancelled:
            return "Stopped."
        default:
            // Covers failed and skipped, which are the same thing to a user:
            // the address, the share name or the sign-in is wrong.
            return "Could not open that. Check the address, the share name, "
                + "and whether it needs a username and password."
        }
    }
}
