import Foundation

extension CastRemux {

    /// MPEG-2 transport stream work: enough to take two single-stream segments
    /// apart and put one two-stream segment back together.
    ///
    /// Deliberately not a general TS library. It assumes what HLS guarantees —
    /// 188-byte packets, one program, one elementary stream per input segment —
    /// and returns nil the moment an input is not that, because the caller's
    /// fallback (send the stream untouched and let the television try) is
    /// better than a muxer guessing.
    ///
    /// **Nothing is re-encoded.** A PES packet is moved across byte for byte;
    /// only the four-byte transport header in front of it is rewritten. So the
    /// picture and sound the television decodes are exactly the CDN's, and the
    /// work per segment is a couple of passes over a megabyte.
    enum TS {
        static let size = 188

        private static let patPID = 0x0000
        private static let nullPID = 0x1FFF

        /// Where the output puts things.
        ///
        /// Both inputs number their one elementary stream `0x100`, so at least
        /// one has to move. Both are renumbered rather than only the audio: it
        /// costs nothing, and it means the output's numbering never depends on
        /// what the provider happened to choose.
        private static let outPMT = 0x1000
        private static let outVideo = 0x0100
        private static let outAudio = 0x0101

        /// MPEG-1/2 video, H.264, H.265.
        private static let videoTypes: Set<UInt8> = [0x01, 0x02, 0x1B, 0x24]
        /// MP3, AAC in ADTS, AAC in LATM, AC-3, E-AC-3.
        private static let audioTypes: Set<UInt8> = [0x03, 0x04, 0x0F, 0x11, 0x81, 0x87]

        /// One PES packet and the offsets of the transport packets carrying it.
        ///
        /// Offsets, not copies: a video segment is a megabyte and gets walked
        /// twice, so the packets stay where they were read and only the output
        /// buffer is built.
        struct Unit {
            let pid: Int
            let pts: Int64?
            var packets: [Int]
        }

        struct Parsed {
            /// Elementary stream number to stream type, from the PMT.
            let streams: [Int: UInt8]
            let units: [Unit]
        }

        // MARK: - the mux

        /// Video whole, audio limited to `span`, as one transport stream.
        ///
        /// `span` is a half-open PTS range and the caller is responsible for
        /// making consecutive segments' ranges meet exactly — see
        /// `Session.window`. Everything audible depends on it: a range that
        /// overlaps its neighbour repeats a block of sound at every segment
        /// join, and one that falls short drops a block.
        static func mux(video: Data, audio: [Data], keeping span: Range<Int64>) -> Data? {
            let videoBytes = [UInt8](video)
            guard let parsedVideo = parse(videoBytes),
                  let videoPID = parsedVideo.streams.first(where: { videoTypes.contains($0.value) })?.key,
                  let videoType = parsedVideo.streams[videoPID]
            else { return nil }

            let pictures = parsedVideo.units
                .filter { $0.pid == videoPID }
                .sorted { ($0.packets.first ?? 0) < ($1.packets.first ?? 0) }
            guard !pictures.isEmpty else { return nil }

            var buffers: [[UInt8]] = []
            var blocks: [(buffer: Int, unit: Unit)] = []
            var audioType: UInt8 = 0x0F
            for segment in audio {
                let bytes = [UInt8](segment)
                guard let parsed = parse(bytes),
                      let pid = parsed.streams.first(where: { audioTypes.contains($0.value) })?.key,
                      let type = parsed.streams[pid]
                else { continue }
                audioType = type
                let index = buffers.count
                buffers.append(bytes)
                for unit in parsed.units where unit.pid == pid {
                    guard let pts = unit.pts, span.contains(pts) else { continue }
                    blocks.append((index, unit))
                }
            }
            blocks.sort { ($0.unit.pts ?? 0) < ($1.unit.pts ?? 0) }
            // Neighbouring segments are fetched with a margin, so the same
            // block can arrive twice if a provider ever repeats one. Keeping
            // both would send audio whose timestamps go backwards.
            var deduped: [(buffer: Int, unit: Unit)] = []
            for block in blocks where deduped.last?.unit.pts != block.unit.pts {
                deduped.append(block)
            }
            guard !deduped.isEmpty else { return nil }

            var out = [UInt8]()
            out.reserveCapacity(videoBytes.count + buffers.reduce(0) { $0 + $1.count / 2 } + size * 2)
            out += section(pid: patPID, table: patTable())
            out += section(pid: outPMT, table: pmtTable(video: videoType, audio: audioType))

            var videoCounter: UInt8 = 0
            var audioCounter: UInt8 = 0
            var next = 0
            // Audio that is due goes out before the picture it belongs with, so
            // a receiver's demuxer never has to hold a picture waiting for
            // sound it has not been given yet. The two stay within a few
            // hundred milliseconds of each other, which is what every player's
            // buffer is built for.
            var threshold = pictures.first?.pts ?? span.lowerBound
            for picture in pictures {
                if let pts = picture.pts { threshold = pts }
                while next < deduped.count, (deduped[next].unit.pts ?? 0) <= threshold {
                    copy(deduped[next].unit.packets, from: buffers[deduped[next].buffer],
                         to: &out, pid: outAudio, counter: &audioCounter)
                    next += 1
                }
                copy(picture.packets, from: videoBytes, to: &out, pid: outVideo, counter: &videoCounter)
            }
            while next < deduped.count {
                copy(deduped[next].unit.packets, from: buffers[deduped[next].buffer],
                     to: &out, pid: outAudio, counter: &audioCounter)
                next += 1
            }
            return Data(out)
        }

        /// The earliest PTS in a segment — how the audio clock's start is read.
        static func firstPTS(in bytes: [UInt8]) -> Int64? {
            parse(bytes)?.units.compactMap(\.pts).min()
        }

        // MARK: - taking a segment apart

        static func parse(_ bytes: [UInt8]) -> Parsed? {
            guard bytes.count >= size, bytes[0] == 0x47 else { return nil }

            var pmtPID: Int?
            var streams: [Int: UInt8] = [:]
            var units: [Unit] = []
            var open: [Int: Unit] = [:]
            var offset = 0

            while offset + size <= bytes.count {
                let packet = offset
                offset += size
                guard bytes[packet] == 0x47 else { return nil }

                let pid = (Int(bytes[packet + 1] & 0x1F) << 8) | Int(bytes[packet + 2])
                guard pid != nullPID else { continue }
                let unitStart = bytes[packet + 1] & 0x40 != 0
                let control = (bytes[packet + 3] >> 4) & 0x03

                var payload = packet + 4
                if control == 2 || control == 3 { payload += 1 + Int(bytes[packet + 4]) }
                let end = packet + size
                let hasPayload = (control == 1 || control == 3) && payload < end

                if pid == patPID {
                    if unitStart, hasPayload {
                        pmtPID = firstProgram(bytes, at: payload, end: end) ?? pmtPID
                    }
                    continue
                }
                if pid == pmtPID {
                    if unitStart, hasPayload {
                        for (stream, type) in elementaryStreams(bytes, at: payload, end: end) {
                            streams[stream] = type
                        }
                    }
                    continue
                }

                if unitStart {
                    if let finished = open[pid] { units.append(finished) }
                    open[pid] = Unit(
                        pid: pid,
                        pts: hasPayload ? presentationStamp(bytes, at: payload, end: end) : nil,
                        packets: [packet]
                    )
                } else if open[pid] != nil {
                    open[pid]?.packets.append(packet)
                }
            }
            units.append(contentsOf: open.values)
            guard !streams.isEmpty else { return nil }
            return Parsed(streams: streams, units: units)
        }

        /// The PMT's own stream number, out of a PAT.
        private static func firstProgram(_ bytes: [UInt8], at payload: Int, end: Int) -> Int? {
            let table = payload + 1 + Int(bytes[payload])
            guard table + 12 <= end else { return nil }
            let length = (Int(bytes[table + 1] & 0x0F) << 8) | Int(bytes[table + 2])
            let last = min(table + 3 + length - 4, end)
            var cursor = table + 8
            var found: Int?
            while cursor + 4 <= last {
                found = (Int(bytes[cursor + 2] & 0x1F) << 8) | Int(bytes[cursor + 3])
                cursor += 4
            }
            return found
        }

        /// (stream number, stream type) for each entry in a PMT.
        private static func elementaryStreams(
            _ bytes: [UInt8], at payload: Int, end: Int
        ) -> [(Int, UInt8)] {
            let table = payload + 1 + Int(bytes[payload])
            guard table + 12 <= end else { return [] }
            let length = (Int(bytes[table + 1] & 0x0F) << 8) | Int(bytes[table + 2])
            let programInfo = (Int(bytes[table + 10] & 0x0F) << 8) | Int(bytes[table + 11])
            let last = min(table + 3 + length - 4, end)
            var cursor = table + 12 + programInfo
            var found: [(Int, UInt8)] = []
            while cursor + 5 <= last {
                let type = bytes[cursor]
                let pid = (Int(bytes[cursor + 1] & 0x1F) << 8) | Int(bytes[cursor + 2])
                let info = (Int(bytes[cursor + 3] & 0x0F) << 8) | Int(bytes[cursor + 4])
                found.append((pid, type))
                cursor += 5 + info
            }
            return found
        }

        /// A PES packet's PTS: 33 bits, in five bytes, with markers between.
        private static func presentationStamp(_ bytes: [UInt8], at payload: Int, end: Int) -> Int64? {
            guard payload + 14 <= end,
                  bytes[payload] == 0x00, bytes[payload + 1] == 0x00, bytes[payload + 2] == 0x01,
                  bytes[payload + 7] & 0x80 != 0
            else { return nil }
            let stamp = payload + 9
            return (Int64((bytes[stamp] >> 1) & 0x07) << 30)
                | (Int64(bytes[stamp + 1]) << 22)
                | (Int64(bytes[stamp + 2] >> 1) << 15)
                | (Int64(bytes[stamp + 3]) << 7)
                | Int64(bytes[stamp + 4] >> 1)
        }

        // MARK: - putting one back together

        /// Copies packets across, renumbering the stream and the continuity
        /// counter.
        ///
        /// The counter has to be rewritten rather than carried over, because
        /// the audio arriving here has had packets removed — the blocks outside
        /// this segment's window. A receiver that sees the counter skip treats
        /// it as packet loss. A packet with no payload does not advance it,
        /// which is the one rule easy to get wrong and invisible when wrong.
        private static func copy(
            _ offsets: [Int], from source: [UInt8], to out: inout [UInt8],
            pid: Int, counter: inout UInt8
        ) {
            for offset in offsets {
                guard offset + size <= source.count else { continue }
                let base = out.count
                out.append(contentsOf: source[offset..<(offset + size)])
                out[base + 1] = (out[base + 1] & 0xE0) | UInt8((pid >> 8) & 0x1F)
                out[base + 2] = UInt8(pid & 0xFF)
                let control = (out[base + 3] >> 4) & 0x03
                out[base + 3] = (out[base + 3] & 0xF0) | (counter & 0x0F)
                if control != 2 { counter = (counter &+ 1) & 0x0F }
            }
        }

        /// One program, pointing at our PMT.
        private static func patTable() -> [UInt8] {
            [
                0x00, 0xB0, 0x0D,           // table id, section length 13
                0x00, 0x01,                 // transport stream id
                0xC1, 0x00, 0x00,           // version 0, current, section 0 of 0
                0x00, 0x01,                 // program 1
                UInt8(0xE0 | ((outPMT >> 8) & 0x1F)), UInt8(outPMT & 0xFF),
            ]
        }

        /// Both streams, with the clock taken from the video.
        ///
        /// `PCR_PID` is the video stream because that is where the provider put
        /// the clock, in the adaptation fields of packets this carries across
        /// untouched. Nothing has to be synthesised, and the timing the
        /// television sees is the timing the encoder wrote.
        private static func pmtTable(video: UInt8, audio: UInt8) -> [UInt8] {
            let streams: [UInt8] = [
                video, UInt8(0xE0 | ((outVideo >> 8) & 0x1F)), UInt8(outVideo & 0xFF), 0xF0, 0x00,
                audio, UInt8(0xE0 | ((outAudio >> 8) & 0x1F)), UInt8(outAudio & 0xFF), 0xF0, 0x00,
            ]
            // From after the length field through the CRC: 5 bytes of section
            // header, 4 of PCR and program info, the streams, 4 of CRC.
            let length = 9 + streams.count + 4
            return [
                0x02, UInt8(0xB0 | ((length >> 8) & 0x0F)), UInt8(length & 0xFF),
                0x00, 0x01,                 // program 1
                0xC1, 0x00, 0x00,           // version 0, current, section 0 of 0
                UInt8(0xE0 | ((outVideo >> 8) & 0x1F)), UInt8(outVideo & 0xFF),
                0xF0, 0x00,                 // no program descriptors
            ] + streams
        }

        /// A whole table in one packet, padded. Every section here is far
        /// shorter than a packet, so there is never a continuation to handle.
        private static func section(pid: Int, table: [UInt8]) -> [UInt8] {
            var packet: [UInt8] = [
                0x47,
                UInt8(0x40 | ((pid >> 8) & 0x1F)), UInt8(pid & 0xFF),
                0x10,                       // payload only, counter 0
                0x00,                       // pointer field
            ]
            packet += table
            let crc = crc32(table)
            packet += [
                UInt8(truncatingIfNeeded: crc >> 24),
                UInt8(truncatingIfNeeded: crc >> 16),
                UInt8(truncatingIfNeeded: crc >> 8),
                UInt8(truncatingIfNeeded: crc),
            ]
            packet += [UInt8](repeating: 0xFF, count: size - packet.count)
            return packet
        }

        /// CRC-32/MPEG-2: the one PSI sections are checked with, and not the
        /// same as zlib's — no reflection, no final inversion. A receiver drops
        /// a section whose CRC it cannot confirm, silently.
        static func crc32(_ data: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in data {
                crc ^= UInt32(byte) << 24
                for _ in 0..<8 {
                    crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
                }
            }
            return crc
        }
    }
}
