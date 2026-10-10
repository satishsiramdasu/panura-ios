import Foundation

/// A server on somebody's own network, as they described it.
///
/// One record for SMB, FTP and SFTP, because the only thing that differs
/// between them is the scheme in the URL — libVLC browses and plays all three
/// through the same call. Splitting them into three screens would be three
/// copies of one form.
///
/// **SMB is listed first on purpose.** A home NAS in 2026 speaks SMB; FTP is
/// what a router or an old media box offers. People arrive here wanting the
/// first one and would have to be told the second exists.
struct NetworkServer: Codable, Identifiable, Hashable {
    enum Scheme: String, Codable, CaseIterable, Identifiable {
        case smb, sftp, ftp

        var id: String { rawValue }

        var label: String {
            switch self {
            case .smb: return "SMB"
            case .sftp: return "SFTP"
            case .ftp: return "FTP"
            }
        }

        var detail: String {
            switch self {
            case .smb: return "Windows share or NAS"
            case .sftp: return "SSH file transfer"
            case .ftp: return "Plain FTP"
            }
        }

        /// Only where it is not the scheme's own default — the URL carries no
        /// port at all then, which is what libVLC wants.
        var defaultPort: Int {
            switch self {
            case .smb: return 445
            case .sftp: return 22
            case .ftp: return 21
            }
        }
    }

    var id: UUID = UUID()
    /// What the user calls it. Falls back to the host when left empty.
    var name: String = ""
    var scheme: Scheme = .smb
    var host: String = ""
    /// nil means the scheme's own default.
    var port: Int?
    /// Where to start. For SMB this is usually the share name.
    var path: String = "/"
    /// Empty means anonymous (FTP) or guest (SMB).
    var user: String = ""

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? host : trimmed
    }

    /// What the row under the name shows: who it signs in as, and where.
    /// Never the password. Mirrors `IPTVSource.subtitle`, because the two sit
    /// in the same list and a row that explains itself differently from the
    /// one above it reads as a different kind of thing.
    var subtitle: String {
        var place = host
        if let port, port != scheme.defaultPort { place += ":\(port)" }
        place += path.hasPrefix("/") ? path : "/" + path
        let who = user.trimmingCharacters(in: .whitespaces)
        return who.isEmpty ? place : "\(who) · \(place)"
    }

    /// Where the password is kept. The record itself never holds one.
    var credentialKey: String { id.uuidString }

    /// The URL libVLC is given, credentials included.
    ///
    /// libVLC takes the password in the URL. The alternative is its dialog
    /// callback, which means installing a `VLCDialogProvider` and answering a
    /// prompt we would have to draw ourselves — and if nothing answers it, the
    /// parse never returns. Credentials in the URL is the quieter path, and the
    /// URL is built here rather than being kept anywhere.
    ///
    /// Percent-encoded against `urlUserAllowed`, so a password with an `@` or a
    /// `/` in it does not rewrite the host.
    func url(password: String, path overridePath: String? = nil) -> URL? {
        var text = scheme.rawValue + "://"
        if !user.isEmpty {
            text += Self.escape(user)
            if !password.isEmpty { text += ":" + Self.escape(password) }
            text += "@"
        }
        text += host
        if let port, port != scheme.defaultPort { text += ":\(port)" }

        var directory = overridePath ?? path
        if !directory.hasPrefix("/") { directory = "/" + directory }
        // A directory URL has to end in a slash or libVLC may try to open it as
        // a file and come back with nothing rather than a listing.
        if !directory.hasSuffix("/") { directory += "/" }
        text += directory.split(separator: "/").map(Self.escape).joined(separator: "/")
        if !text.hasSuffix("/") { text += "/" }
        return URL(string: text)
    }

    private static func escape(_ value: some StringProtocol) -> String {
        String(value).addingPercentEncoding(withAllowedCharacters: .urlUserAllowed)
            ?? String(value)
    }
}

/// The servers somebody has set up, and their passwords.
@MainActor
final class NetworkServerStore: ObservableObject {
    static let shared = NetworkServerStore()

    @Published private(set) var servers: [NetworkServer] = []

    private static let key = "network_servers"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode([NetworkServer].self, from: data)
        else { return }
        servers = saved
    }

    func password(for server: NetworkServer) -> String {
        Keychain.get(server.credentialKey)
    }

    func save(_ server: NetworkServer, password: String) {
        if let i = servers.firstIndex(where: { $0.id == server.id }) {
            servers[i] = server
        } else {
            servers.append(server)
        }
        Keychain.set(password, for: server.credentialKey)
        persist()
    }

    func remove(_ server: NetworkServer) {
        servers.removeAll { $0.id == server.id }
        // The password goes with it. A credential left behind for a server
        // nobody can see any more is a credential nobody can delete.
        Keychain.remove(server.credentialKey)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
