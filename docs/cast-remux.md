# Casting HLS with separate audio to an old Chromecast

Written for whoever ports this to Android. The algorithm is short; two parts of
it are subtle enough that getting them wrong produces something that *mostly*
works, which is worse than something that fails.

## The problem

An HLS master that declares

```
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",LANGUAGE="tel",NAME="Telugu",DEFAULT=YES,URI=".../te/index.txt"
#EXT-X-STREAM-INF:BANDWIDTH=5437609,CODECS="avc1.640028,mp4a.40.2",AUDIO="aac",RESOLUTION=1920x816
.../vfhd/index.txt
```

has **no audio in its video segments**. `vfhd` carries one elementary stream —
H.264 on PID `0x100`, nothing else — and the sound arrives from `te` as its own
playlist. Playing that needs two media pipelines running in step.

The Chromecast built into an Android 6 or 7 television has one. On those sets
the stream loads, shows a frame, and stops after five to ten seconds. They are
the whole point of the Cast path: too old to install Panura's own receiver,
reachable no other way.

### What is not the cause

Ruled out by measurement, so nobody has to re-theorise:

| Suspect | Finding |
|---|---|
| Disguised segment extensions (`.jpg` video, `.svg` audio) | Not it. Both are clean MPEG-TS — `47 40 11 10 …` at byte 0, no decoy header. The receiver also force-sets `hlsSegmentFormat = TS` / `hlsVideoSegmentFormat = MPEG2_TS` for every `.m3u8`, so nothing has to be inferred from the extension. |
| Fragmented MP4 needing different hints | No `#EXT-X-MAP` anywhere. It is transport stream. |
| Segment gating / headers | Sequential GETs all 200, ranged GET 206 with `Content-Range`, Chromecast and Android TV user agents accepted. |
| CORS at the CDN | Fully present. **CORS on the phone's own server was absent and is a real bug** — a Cast receiver fetches adaptive streams with XHR, so a manifest served without `Access-Control-Allow-Origin` is refused (error `3116403`). Fixed; keep it fixed. |
| Too many audio renditions | Not the variable. The stream above has **one**, and fails. |

That last row is the one that cost the most time. `CastAudioMaster` reduces the
*number* of renditions, which is the right answer to "five languages, one
pipeline" and no answer at all to "the audio is not in the video" — one
rendition is still a second pipeline.

## The fix

Serve the television a master whose variants point at the phone, and build each
segment by folding the audio into the video as it is asked for. Nothing is
re-encoded: PES packets are copied byte for byte and only the four-byte
transport header in front of each is rewritten.

### Output shape

Per segment, in this order:

1. **PAT** on PID `0x0000` — one program, pointing at PMT PID `0x1000`.
2. **PMT** on `0x1000` — `PCR_PID` = `0x100`, two streams: video `0x100`
   (type from the source: `0x1b` H.264, `0x24` HEVC), audio `0x101` (`0x0f`
   AAC-ADTS).
3. The video's PES packets, in order, renumbered to `0x100`.
4. The audio's PES packets for this segment's window, renumbered to `0x101`,
   each emitted just before the picture it belongs with.

Both inputs number their one elementary stream `0x100`, so at least one must
move. Renumber both — it costs nothing and makes the output independent of what
the provider chose.

PCR needs nothing synthesised: it lives in the adaptation fields of video
packets that cross over untouched, so declaring `PCR_PID` = the video stream
gives the television the encoder's own timing.

### Trap 1 — the audio window must tile exactly

This is the one that matters.

Segment *n*'s audio window must **end exactly where segment *n+1*'s begins**,
with both derived from the same accumulated playlist clock:

```
lo(n) = audioOffset + start(n)     * 90000
hi(n) = audioOffset + start(n + 1) * 90000      // not start(n) + duration(n)
```

where `start(n)` is the running sum of `#EXTINF` values and `audioOffset` is the
first PTS in the first audio segment, measured once.

Deriving `hi(n)` from segment *n*'s own duration looks equivalent. It is not:
the two boundaries then disagree by a fraction of a block, and each of a film's
hundreds of joins either repeats a piece of audio or drops one.

**Do not try to snap to an audio frame grid.** There is no global grid — each
audio segment repacks its own PES boundaries, and 6.016 s is not a multiple of
the 170.67 ms per PES. The first version here snapped, and put 21 ms of
duplicated audio at every one of 1334 joins.

Segment lists do **not** correspond: in the stream above the video has 1334
segments of 2.5–10 s and the audio has 1335 of ~6 s, totalling 8005.88 s and
8006.06 s. Index *n* of one is unrelated to index *n* of the other. Map by time,
fetch the audio segments overlapping the window **plus one either side** — a
block belonging in a window can sit in a segment whose declared range does not
quite reach it — and select by PTS.

### Trap 2 — continuity counters

The audio has had packets removed, so its counters no longer run consecutively
and a receiver reads the skip as packet loss. Renumber per output stream, and
remember that **a packet with no payload does not advance the counter**
(`adaptation_field_control == 2`). Easy to get wrong, invisible when wrong.

### Trap 3 — PSI details

- Sections are checked with **CRC-32/MPEG-2** — no reflection, no final
  inversion, not zlib's. A section whose CRC does not verify is dropped
  silently.
- PMT `section_length` counts from after the length field through the CRC:
  `9 + 5·streams + 4` = 23 for two streams.
- Strip `AUDIO="group"` from every `EXT-X-STREAM-INF` in the master you serve.
  Leaving it names a group that master no longer declares, which a receiver may
  reject outright.

### Keep every variant

Mux each video variant to its own playlist rather than picking the best one. The
phone is in the path now, and a link that cannot keep up needs a lower gear
instead of a stall; with all variants offered the receiver runs its own bitrate
ladder exactly as it would against the CDN.

### Refuse rather than half-work

- **Live playlists** (no `#EXT-X-ENDLIST`): a snapshot served with fixed segment
  numbers is a film a few minutes long that then ends, while the channel carries
  on. Muxing live needs re-reading both playlists on a timer and renumbering as
  segments fall off the front — different work.
- **Encrypted segments** (`#EXT-X-KEY` other than `METHOD=NONE`): nothing to
  open.
- **Fragmented MP4** (`#EXT-X-MAP`): different container, different muxer.

In all three cases fall back to sending the stream untouched, and *say so on
screen*. A switch that is on and doing nothing is the worst of the three states.

### Subtitles pass through

`EXT-X-MEDIA:TYPE=SUBTITLES` is a text track, not a media pipeline, so it is no
part of this problem. Carry those lines into the served master with their URIs
made absolute.

## The decision: four answers, in order

The question is not "should this be proxied" but **"is there anything wrong with
handing the television the address"**. Only a yes puts the phone in the path.

1. **Mux**, when the master declares its audio separately — *on by default*.
   That shape is unplayable on this hardware, so waiting to be asked only means
   the first attempt fails.
2. **Proxy**, when the stream is gated by a header no television can send.
   Everything goes through the phone but nothing is rebuilt; it is forwarded,
   with the playlist rewritten so segment requests come back through us.
3. **Filter the master** to one rendition, when muxing was declined or is
   impossible but the master still declares several renditions, several groups,
   or an undecodable codec. A kilobyte, once.
4. **Send it untouched** — most streams, and much the cheapest: the television
   streams from the CDN and the phone may leave the network.

### Why muxing is on by default but still a switch

There is nothing to detect. A set lacking the second pipeline does not say so —
it shows a frame and stops, which is also what a slow network, a refused
manifest and an undecodable codec look like from the sofa. But the *stream* can
be read, and a master with separately-declared audio is one this hardware cannot
play, so the default follows the stream rather than waiting on the person.

The switch is then there to be turned **off**: for the television that turns out
to manage the original perfectly well and should not pay for the bytes. Stored
per set, as three states — unanswered, yes, no — because "nobody has said" has
to be distinguishable from "no".

### Gated streams: the phone, not the television

`castHeaders` is deliberately narrower than `headers`: a session cookie is bound
to the address and user agent that obtained it, so replaying it from a second
device is worse than sending none — proven by a TV getting HTTP 200 with a body
reading `security error`. So a stream that *needs* one is a stream no television
can open, and forwarding from the phone is the only route. The phone is the
device that holds the cookie.

For the same reason **the muxer fetches with `headers`, not `castHeaders`** —
the phone is doing the fetching now, and the television only ever talks to us.
Using the TV's narrowed set there failed gated streams for no reason.

### Surround is never offered

Choosing a 5.1 track closes the player on these televisions: it is either a
codec they cannot decode at all (`ac-3`, `ec-3`) or more channels than the audio
pipeline accepts. Downmixing would mean decoding and re-encoding the sound,
which is the one thing this deliberately never does — so surround renditions are
left out of the picker and never chosen by default.

Detected from `CHANNELS` > 2, then from the name (`5.1`, `7.1`, `atmos`,
`dd+`, `dts`…), because providers label it inconsistently. **Ids are not
renumbered** when the list is narrowed — a rendition's id is its position in the
unfiltered master, which is what both the playlist filter and the muxer count
to. If filtering would leave nothing, the whole list comes back: a playlist whose
every track is a 5.1 mix is one where a track that may fail beats silence.

### A sub-playlist is a sub-playlist whatever it is called

In the proxy path, what a URI *is* comes from where it sits, not from its name. A
URI on its own line after `#EXT-X-STREAM-INF` is a variant playlist and a
`TYPE=AUDIO` rendition's URI is a media playlist — the spec allows nothing else
in either position — and both are routinely served as `.txt`, or with no
extension. Deciding by `.m3u8` sent those to the segment route, where they went
to the television unrewritten and every segment inside them then resolved
against the phone and 404'd. Believe the extension only where position cannot
say: a subtitle rendition, which may be a playlist or may be a WebVTT file.

## Cost, stated plainly

CDN → phone → television instead of CDN → television, for the length of the
film. ~2.5 Mbps average on the stream above. The phone must stay awake and on
the network. That is the price of the television being too old.

## Not fixable in the receiver

A CAF receiver can pick an `activeTrackId` and nothing more; no JavaScript adds
an audio pipeline to hardware that lacks one. It would also mean a
deploy-and-test loop on the oldest hardware in the fleet, against an app ID
(`BE269497`) shared with live Android users.

## iOS file map

| File | What it holds |
|---|---|
| `Sources/Cast/CastRemux.swift` | Reads the master, both playlists and the audio offset; `Session` answers the television and caches six segments. |
| `Sources/Cast/TransportStream.swift` | `TS.mux`, the parser, PAT/PMT construction, CRC-32/MPEG-2. |
| `Sources/Cast/PanuraCastServer.swift` | `/mux/v<k>.m3u8` and `/mux/<k>-<n>.ts`, plus the CORS set every response needs. |
| `Sources/Cast/CastFlow.swift` | `chromecastPayload` picks between muxing, filtering and sending as-is; owns the audio-track change. |
| `Sources/Cast/CastPreferences.swift` | `needsMuxing(on:)` — the per-television answer. |
| `Sources/Cast/CastSessionView.swift` | The switch and the audio picker on the cast control screen. |
| `Sources/Cast/CastAudioMaster.swift` | The cheap path: fewer renditions, for hardware that only chokes on the count. |

## Android notes

The sender already serves a local HTTP proxy (`CastServer`), so the routes have
a home. Things to carry across:

- NanoHTTPD sets `Content-Length` for free, which iOS's Swifter does not — the
  iOS code sets it by hand and must.
- The CORS set is required on **every** response the receiver fetches, playlists
  and segments both, including `Access-Control-Expose-Headers: Content-Length,
  Content-Range`.
- Clear the muxing session anywhere the proxy is repointed, or the next cast is
  handed the previous film's pictures under this film's playlist.
- A muxed segment has no meaningful byte ranges — do not advertise
  `Accept-Ranges`.
- `ExoPlayer`'s own TS extractor is stricter than FFmpeg's about decoy headers;
  strip them before muxing, as iOS does via `StreamProxy.stripDecoyHeader`.
