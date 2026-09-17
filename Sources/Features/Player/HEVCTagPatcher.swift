import Foundation

/// Renames HEVC sample entries from `hev1` to `hvc1` (and Dolby Vision's
/// `dvhe` to `dvh1`), in an MP4's sample descriptions and in an HLS playlist's
/// CODECS attributes.
///
/// The two tags describe the same video. `hev1` allows parameter sets to live
/// in the stream as well as in the sample entry; `hvc1` keeps them in the entry.
/// Apple's players accept only `hvc1`, so an HEVC file tagged `hev1` — common
/// from web encoders and FFmpeg's default — fails to open in AVPlayer while
/// every FFmpeg-based player plays it. Renaming four bytes is the whole fix
/// when the entry's `hvcC` already carries the parameter sets, which FFmpeg
/// writes for both tags.
///
/// Pure Foundation, so the check in `Tools/hevc-check` runs it against
/// AVFoundation on a Mac.
enum HEVCTagPatcher {
    struct Patch: Equatable {
        /// Absolute file offset of the four-character code.
        var offset: Int64
        var bytes: [UInt8]
    }

    private static let renames: [String: String] = ["hev1": "hvc1", "dvhe": "dvh1"]
    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]

    // MARK: files

    /// Walks a file's top-level boxes with ranged reads to reach `moov`, then
    /// returns the patches its sample descriptions need. Empty when there is
    /// nothing to rename, or the file does not parse.
    static func locate(length: Int64, read: (Int64, Int) async throws -> Data) async throws -> [Patch] {
        var offset: Int64 = 0
        for _ in 0..<64 {
            guard offset + 8 <= length else { return [] }
            let header = [UInt8](try await read(offset, 16))
            guard header.count >= 8 else { return [] }
            var size = Int64(u32(header, 0))
            if size == 1 {
                guard header.count >= 16 else { return [] }
                size = Int64(clamping: u64(header, 8))
            } else if size == 0 {
                size = length - offset
            }
            guard size >= 8 else { return [] }
            if fourCC(header, 4) == "moov" {
                guard size <= 64_000_000 else { return [] }
                let box = [UInt8](try await read(offset, Int(size)))
                guard box.count == Int(size) else { return [] }
                var found: [Patch] = []
                walk(box, 0..<box.count, base: offset, into: &found)
                return found
            }
            offset += size
        }
        return []
    }

    /// Patches a whole buffer already in memory — an HLS init segment. nil
    /// when it holds nothing to rename.
    static func patch(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var found: [Patch] = []
        walk(bytes, 0..<bytes.count, base: 0, into: &found)
        guard !found.isEmpty else { return nil }
        var out = data
        apply(found, to: &out, at: 0)
        return out
    }

    /// Rewrites whichever bytes of `data` — read from `offset` in the file —
    /// fall under a patch. Chunks arrive at arbitrary boundaries, so a code
    /// split across two chunks is patched half in each.
    static func apply(_ patches: [Patch], to data: inout Data, at offset: Int64) {
        guard !patches.isEmpty, !data.isEmpty else { return }
        let end = offset + Int64(data.count)
        data.withUnsafeMutableBytes { raw in
            for patch in patches where patch.offset < end && patch.offset + 4 > offset {
                for k in 0..<4 {
                    let position = patch.offset + Int64(k) - offset
                    if position >= 0, position < Int64(raw.count) {
                        raw[Int(position)] = patch.bytes[k]
                    }
                }
            }
        }
    }

    // MARK: playlists

    /// True when a playlist advertises a `hev1` / `dvhe` rendition, which is
    /// enough for AVPlayer to skip it before fetching anything.
    static func namesHEV1(_ playlist: String) -> Bool {
        playlist.components(separatedBy: .newlines).contains { line in
            line.contains("CODECS=") && (line.contains("hev1.") || line.contains("dvhe."))
        }
    }

    static func renameCodecs(_ playlist: String) -> String {
        playlist.components(separatedBy: "\n").map { line in
            guard line.contains("CODECS=") else { return line }
            return line
                .replacingOccurrences(of: "hev1.", with: "hvc1.")
                .replacingOccurrences(of: "dvhe.", with: "dvh1.")
        }.joined(separator: "\n")
    }

    // MARK: box walk

    private static func walk(_ b: [UInt8], _ range: Range<Int>, base: Int64, into found: inout [Patch]) {
        var i = range.lowerBound
        while i + 8 <= range.upperBound {
            var size = Int(u32(b, i))
            var header = 8
            if size == 1 {
                guard i + 16 <= range.upperBound else { return }
                size = Int(clamping: u64(b, i + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - i
            }
            guard size >= header, i + size <= range.upperBound else { return }
            let type = fourCC(b, i + 4)
            if containers.contains(type) {
                walk(b, (i + header)..<(i + size), base: base, into: &found)
            } else if type == "stsd" {
                // Full box header and entry count, then the sample entries.
                var j = i + header + 8
                while j + 8 <= i + size {
                    let entrySize = Int(u32(b, j))
                    if let renamed = renames[fourCC(b, j + 4)] {
                        found.append(Patch(offset: base + Int64(j + 4), bytes: Array(renamed.utf8)))
                    }
                    guard entrySize >= 8 else { break }
                    j += entrySize
                }
            }
            i += size
        }
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        let high = (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16)
        return high | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }

    private static func u64(_ b: [UInt8], _ i: Int) -> UInt64 {
        (UInt64(u32(b, i)) << 32) | UInt64(u32(b, i + 4))
    }

    private static func fourCC(_ b: [UInt8], _ i: Int) -> String {
        String(decoding: b[i..<(i + 4)], as: UTF8.self)
    }
}
