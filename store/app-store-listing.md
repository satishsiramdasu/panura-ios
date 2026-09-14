# App Store Connect — listing and answers

Everything App Store Connect asks for, written out. Nothing here needs the
developer account, so it is all decided before enrolment clears; on the day, this
is a copy-paste exercise.

Character limits are Apple's and are noted where they bind.

---

## App record

| Field | Value |
|---|---|
| Bundle ID | `panura.web.videoplayer` |
| SKU | `panura-ios-1` |
| Primary language | English (U.S.) |
| Name (≤30) | `Panura Video Player & Web Cast` (30 — at the limit) |
| Subtitle (≤30) | `Browser, subtitles & TV` (23) |
| Primary category | Photo & Video |
| Secondary category | Utilities |

⚠️ **Creating this record is what produces the App Store ID.** Paste it into
`VersionStore.appStoreID` (`Sources/Core/VersionStore.swift`) — it is the one
place that needs it, and until it is set the in-app "Update" link goes nowhere.

## URLs

| Field | Value |
|---|---|
| Privacy Policy URL | `https://panura.app/privacy` |
| Support URL | `https://panura.app/support` |
| Marketing URL | `https://panura.app` |

All three are live. `/privacy`, `/terms` and `/support` are clean-URL redirects
served from the `panura` repo (`public/_redirects`).

## Keywords (≤100 characters, comma-separated, no spaces)

```
m3u8,hls,dash,stream,streaming,live,media,srt,mkv,mp4,webm,avi,hd,adblock,popup,casting
```

87 characters. Apple indexes name, subtitle and keywords together and counts a
word once, so nothing from the name (panura, video, player, web, cast) or the
subtitle (browser, subtitles, tv) is repeated here. No third-party trademarks — a brand name in the
keyword field is a rejection on its own. No `iptv` or `movies` either: both are
words reviewers read as a piracy app, whatever the app actually does.

## Promotional text (≤170, editable without a new build)

```
Find a video on any site and play it properly: real subtitles, gestures, background audio, and your TV a tap away. No account, no downloads, no tracking.
```

## Description (≤4000)

```
Panura turns the web's video into video you can actually watch.

Browse to a page, press play, and Panura spots the stream behind the site's own
player. From there it is yours: a real player with real controls, a picture that
fills the screen properly, and subtitles you can size, colour and re-encode until
they are readable.

BUILT-IN BROWSER
• Ad and pop-up blocking, so a page that opens six tabs opens none
• Private mode that keeps nothing once you leave it
• Desktop mode for sites that hide their player from phones
• Shortcuts and history, with the address bar where your thumb is

THE PLAYER
• Plays what other players refuse: HLS, MP4, MKV, AVI, and more
• Gestures for seek, brightness, volume and hold-to-speed
• Pinch to zoom and move the picture inside the frame
• Subtitle control that goes past on and off: size, font, colour, outline,
  background, and the character encoding that fixes garbled non-English files
• Audio and subtitle track switching, with sidecar subtitles found on the page
• Background audio, resume where you left off, and a sleep timer

PLAY ON TV
• Cast to a Chromecast, or to Panura on an Android TV
• Discovery runs on your own network and stops when you leave the screen

YOUR OWN VIDEOS
• The Videos tab plays everything in your photo library, in a grid or a list
• The same player, the same subtitle and gesture settings

WHAT PANURA DOES NOT DO
• No account, ever. Nothing to sign up for
• No downloading of anything you browse to
• No tracking. Your history, shortcuts and resume positions stay on the device
  and are deleted with the app
• YouTube and its domains are deliberately excluded

Panura is a player and a browser. It hosts no content of its own, indexes
nothing, and only ever opens the pages you ask it to.
```

## What's New (first release)

```
First iOS release.

• In-app browser with automatic stream detection
• VLC-powered player: HLS, MP4, MKV and more
• Subtitle control down to font, colour, outline and encoding
• Gestures, pinch zoom, background audio, sleep timer, resume
• Cast to Chromecast or to Panura on Android TV
• Ad and pop-up blocking
• Your library, in a grid or a list
```

Keep this in step with `version.json` in the `panura` repo — the in-app What's
New screen reads the changelog from there, and two different stories about the
same release is the kind of thing reviewers notice.

---

## App Privacy (the nutrition label)

**Answer: Data Not Collected.**

That is literally true for this build and worth stating precisely, because the
binary does link an ads SDK:

- `FeatureFlags.adsEnabled` is `false`, and it gates everything:
  `MobileAds.shared.start(...)` is never called, no ad is ever requested, and
  the ATT prompt is never raised.
- Browsing history, shortcuts, resume positions and detected streams are written
  to `UserDefaults` on the device. They are never uploaded, so they are not
  "collected" in Apple's sense.
- The only two things that leave the device are a report the user chooses to
  send (page address plus what they typed) and an ordinary download of
  `manifest.json` / `version.json` from panura.app, which sends nothing about
  the user.

⚠️ **Turning ads on changes this answer.** `adsEnabled = true` means declaring,
at minimum, Identifiers → Device ID and Usage Data → Advertising Data, both
linked to the user and used for tracking, and `NSPrivacyTracking` in
`Resources/PrivacyInfo.xcprivacy` flips to `true`. Do not ship ads without
updating both.

## Age rating

Answer the questionnaire honestly and expect **the highest tier**: the app
contains a general-purpose web browser, so "Unrestricted Web Access" is a yes.
Everything else — violence, sexual content, gambling, contests — is no, since the
app has no content of its own.

This is the same position Safari and every third-party browser is in. Do not try
to argue the browser is incidental; it is the main feature, and understating it
is a rejection.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `false` in `project.yml`, so the upload does
not stop to ask. The app uses HTTPS and the system's own crypto and implements
none of its own, which is the exemption.

## Content rights

"Does your app contain, display, or access third-party content?" → **Yes.**
It is a browser: the user navigates to sites we neither own nor index. Panura
hosts no content, ships no catalogue, and has no directory of sites.

## Sign-in

No account exists, so: **Sign-in not required**. No demo account to provide.

---

## Notes for App Review

Paste this into the review notes field. Every paragraph answers a question this
app will otherwise be asked.

```
Panura is a web browser with a video player attached. The user browses to a page
themselves; when that page plays a video, Panura detects the stream the page is
already loading and offers to play it in its own player, which handles formats
and subtitle options the web player does not.

No content is hosted, indexed, bundled or recommended by us. There is no
catalogue, no search of other people's sites, and no list of sources anywhere in
the app. The first screen is a browser address bar.

There is NO download feature on iOS. Nothing the user browses to can be saved to
the device. (The Videos tab plays videos that are already in the user's own
photo library, via PHPhotoLibrary, and nothing else.)

YouTube and its associated domains are explicitly blocked from detection, in
line with their terms.

The app requests:
- Photos, to list and play the user's own videos in the Videos tab.
- Local Network, to discover a Chromecast or a Panura receiver on an Android TV.
  Discovery only runs while the "Play on TV" screen is open.
- Background audio, only when the user turns background play on in Settings.

App Transport Security allows arbitrary loads because the app is a browser and
must reach sites that are still HTTP. It is not used to weaken any connection of
our own.

This build does not show ads. The Google Mobile Ads SDK is linked but gated off
at compile time (FeatureFlags.adsEnabled = false), so it is never initialised,
no ad is requested, and the App Tracking Transparency prompt is never shown.
The privacy label is filed as "Data Not Collected" accordingly.

To try the app: open it, type any site with video into the address bar, and press
play on that site's player. A bar appears at the bottom of the browser naming the
stream that was found; tapping it plays. No account or sign-in is needed.
```

---

## Screenshots

Required, and the one item on this page that needs a Mac or a device. Apple asks
for:

- **6.9" iPhone** (1320 × 2868 or 1290 × 2796) — required.
- **13" iPad** (2064 × 2752) — required, because `TARGETED_DEVICE_FAMILY` is
  `1,2`. Dropping iPad to `1` would remove this requirement and shrink the test
  surface; that is a product decision, not a technical one.

Up to 10 each; 3–5 is plenty. Worth showing, in order: the browser with the
found-stream bar visible, the player with its controls up, the subtitle options,
"Play on TV" with a device listed, and the Videos tab.

They can be captured in the iOS Simulator on the macOS CI runner without a
device. Ask if you want that automated — it needs a small XCUITest target, and
it is only worth writing if you cannot borrow a Mac for twenty minutes.
