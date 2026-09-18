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
| Name (≤30) | `Panura Cast: Web Video Player` (29) |
| Subtitle (≤30) | `Browser, subtitles & TV` (23) |
| Primary category | Photo & Video |
| Secondary category | Utilities |

**Why the name is shaped that way.** The app has three strengths — detection,
casting, and a player that opens almost anything — and thirty characters. They do
not fit, so each is placed where it works rather than crammed into the title:

- **Detection is not a search term.** Nobody types "video detection" into the App
  Store. It is why people keep the app, not how they find it, so it is sold in
  the promotional text and the first screenshot, where conversion happens.
- **The player is identity, not the phrase to compete on.** "Video player" is
  VLC, Infuse and nPlayer territory — free, entrenched, unrankable for a new app.
  The title carries `web video player` because that is what the app *is*.
- **Casting is the winnable search**, so it takes the brand slot, where it is
  read first. `Panura Web Video Player & Cast` had "Cast" trailing at the end,
  reading as an afterthought, and never mentioned a TV at all.

Accepted cost: `cast to tv` is no longer adjacent — "cast" is in the name, "TV"
in the subtitle. Both stay indexed, so the search still matches; only the
phrase-adjacency bonus is lost. `Panura: Web Video Cast to TV` (28) is the
alternative that buys that phrase back by giving up `web video player`.

Do not borrow a competitor's name. "Web Video Caster" is InstantBits' app;
echoing it — "Caster" in that arrangement included — risks rejection for
impersonation. The generic words web, video, player and cast are fine.

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
m3u8,hls,dash,stream,streaming,live,media,srt,mkv,mp4,webm,avi,hd,adblock,popup,captions
```

88 characters. Apple indexes name, subtitle and keywords together and counts a
word once, so nothing from the name (panura, cast, web, video, player) or the
subtitle (browser, subtitles, tv) is repeated here.

`casting` was replaced by `captions` when "Cast" moved into the name: Apple does
not reliably match `casting` to a search for *cast*, so the keyword was buying
almost nothing, while `captions` is a term the app genuinely competes on and had
nowhere else to live.

No third-party trademarks — a brand name in the keyword field is a rejection on
its own. No `iptv` or `movies` either: both are words reviewers read as a piracy
app, whatever the app actually does.

The whole indexed set, which should contain no word twice:

```
panura cast web video player browser subtitles tv
m3u8 hls dash stream streaming live media srt mkv mp4 webm avi hd
adblock popup captions
```

## Promotional text (≤170, editable without a new build)

```
Find a video on any site and play it properly: real subtitles, gestures, background audio, and your TV a tap away. No account, no downloads.
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
• Picture in Picture, so the video follows you out of the app
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
• No ad tracking. Your history, shortcuts and resume positions stay on the
  device and are deleted with the app
• YouTube and its domains are deliberately excluded

Panura is a player and a browser. It hosts no content of its own, indexes
nothing, and only ever opens the pages you ask it to.
```

## What's New (first release)

```
First iOS release.

• In-app browser with automatic stream detection
• Two playback engines, chosen for you: HLS, MP4, MKV, AVI and more
• Subtitle control down to font, colour, outline and encoding
• Gestures, pinch zoom, background audio, sleep timer, resume
• Picture in Picture, and Cast to Chromecast or Panura on Android TV
• Ad and pop-up blocking
• Your library, in a grid or a list
```

Keep this in step with `version.json` in the `panura` repo — the in-app What's
New screen reads the changelog from there, and two different stories about the
same release is the kind of thing reviewers notice.

---

## App Privacy (the nutrition label)

Firebase Crashlytics and Analytics are in the app, so the answer is **not**
"Data Not Collected". App Store Connect → App Privacy → Get Started → **Yes, we
collect data from this app**, then tick exactly these five:

| Category → type | Purpose | Linked to the user | Used for tracking |
|---|---|---|---|
| Diagnostics → Crash Data | App Functionality | No | No |
| Diagnostics → Other Diagnostic Data | App Functionality, Analytics | No | No |
| Usage Data → Product Interaction | Analytics | No | No |
| Identifiers → Device ID | Analytics | No | No |
| Location → Coarse Location | Analytics | No | No |

What each one is:

- **Crash Data, Other Diagnostic Data** — Crashlytics: stack traces, device
  model, OS version, memory and disk state at the moment of a crash.
- **Product Interaction** — Analytics' automatic events (first open, sessions,
  screens viewed) plus three playback events from
  `Sources/Core/PlayerAnalytics.swift`, which record only the format played
  (`hls`, `mkv`, …), which engine played it, whether the source was the web or
  the device, and whether the app had to switch engines. No URL, host, page
  title or file name is ever a parameter.
- **Device ID** — Firebase's app instance id. Not the advertising identifier:
  `FirebaseAnalytics` without the identity-support module never reads IDFA, and
  the ATT prompt is never shown.
- **Coarse Location** — the country or region Analytics derives from the IP
  address. Nothing reads GPS.
- **Not linked** — the app has no accounts, so nothing ties any of this to a
  person. This is the one judgment call on the page: Device ID identifies an
  install, not a person, and with no account or user id set, Google's own
  guidance treats Analytics data as unlinked.
- **Not tracking** — nothing is combined with other companies' data or used for
  advertising.

Still **not** collected, and worth being exact about: browsing history,
shortcuts, resume positions and detected streams stay in `UserDefaults` on the
device. Analytics' automatic screen events name the app's screens, never the
pages visited. A report the user chooses to send carries the page address and
their text, to Panura's own worker, not to Firebase.

`Resources/PrivacyInfo.xcprivacy` declares the same five types. Change one,
change the other.

⚠️ **Turning ads on changes this again.** Personalised AdMob ads add Usage Data →
Advertising Data, mark Device ID as used for tracking, flip `NSPrivacyTracking`
to `true`, and make the ATT prompt mandatory. Do not ship ads without all four.

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

Firebase Crashlytics and Analytics are used for crash reports and aggregate
usage statistics. Neither is linked to an identity (there are no accounts) or
used for tracking, as declared in the privacy label. Browsing history and the
pages a user visits are never sent anywhere; the only playback events we log
record the format (for example "hls" or "mkv") and which of the app's two
playback engines handled it, never an address.

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

Up to 10 each; 3–5 is plenty.

**The first one must be the browser with the found-stream bar visible**, and that
is not a preference. Detection is the app's strongest feature and the one no
search term reaches — nobody types "video detection" — so the name cannot sell
it and the keywords cannot either. The first screenshot is the only place it gets
sold, and it is what the App Store shows in search results.

After that, in order: the player with its controls up, the subtitle options,
"Play on TV" with a device listed, and the Videos tab.

They can be captured in the iOS Simulator on the macOS CI runner without a
device — `.github/workflows/ios-screenshots.yml` does exactly that, driven by
`Tests/Screenshots/StoreScreenshots.swift`, and checks the pixel sizes before
uploading them. An iPhone 14 Pro Max shoots 1290 × 2796 by hand and is accepted
as-is; a 10.2" iPad shoots 1620 × 2160, which is the same 3:4 as the required
2064 × 2752 and so upscales without distortion.
