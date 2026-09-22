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
| Name (≤30) | `Panura: Video Browser, TV Cast` (30) |
| Subtitle (≤30) | `Web player with subtitles` (25) |
| Primary category | Photo & Video |
| Secondary category | Utilities |

**Why the name is shaped that way.** The app has three strengths — detection,
a player that opens almost anything, and casting — and thirty characters. They
do not fit, so each is placed where it works rather than crammed into the title:

- **Browsing leads, because it is the main feature.** An earlier draft was
  `Panura Cast: Web Video Player`, built on the argument that casting is the
  winnable search — true, and beside the point. Casting is a side feature. A
  name that opens with `Cast:` tells the store, and the user reading the
  listing, that the app is a casting tool with a browser attached, which is
  backwards. The title now says what the app is first.
- **Detection is not a search term.** Nobody types "video detection" into the
  App Store. It is why people keep the app, not how they find it, so it is sold
  in the promotional text and the first screenshot, where conversion happens.
- **The player is identity, not the phrase to compete on.** "Video player" is
  VLC, Infuse and nPlayer territory — free, entrenched, unrankable for a new
  app. It moves to the subtitle, which still carries `web player`.
- **`TV Cast`, not `Caster` or `Cast TV`.** All three were tried. `Caster` is
  the wrong token — people search `cast`, and the two do not reliably match, so
  it rented a keyword slot to cover itself. `Cast TV` is not idiomatic: you
  cast *to* a TV, and `Browse & Cast TV` parses as "browse TV and cast TV".
  `TV Cast` is how the store itself phrases it, and it puts `tv` and `cast`
  next to each other.

Accepted cost: `web` is no longer in the title, so `web video` is not adjacent —
`web` is in the subtitle and `video` in the name. Both stay indexed and the
search still matches; only the phrase-adjacency bonus is lost. `video browser`
and `tv cast` are both adjacent, which is where the adjacency is worth more.

**Trademarks.** `TV Cast` is also an existing app's name, and `Caster` is a word
in several — Chromecast TV Caster, Castify: WebCaster. Neither is a borrowed
brand: both are generic and used descriptively right across the category, and a
name led by `Panura:` is not confusable with an app called `TV Cast`. The line
is copying a competitor's whole distinctive name, which is why the phrase "Web
Video Caster" — InstantBits' app — stays out of every field. The individual
words web, video, browser, player, cast, caster and tv are all fine.

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
m3u8,hls,dash,stream,streaming,live,media,srt,mkv,mp4,webm,avi,hd,adblock,popup,captions,flv,mov
```

96 characters. Apple indexes name, subtitle and keywords together and counts a
word once, so nothing from the name (panura, video, browser, tv, cast) or the
subtitle (web, player, subtitles) is repeated here.

`cast` used to live here, bought by a name that said `Caster`. The name says
`Cast` now, so the slot went to `flv` and `mov` — two containers the app really
does play, and formats are something people search by name.

No third-party trademarks — a brand name in the keyword field is a rejection on
its own. No `iptv` or `movies` either: both are words reviewers read as a piracy
app, whatever the app actually does.

The whole indexed set, which should contain no word twice:

```
panura video browser tv cast web player subtitles
m3u8 hls dash stream streaming live media srt mkv mp4 webm avi hd
adblock popup captions flv mov
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

## Availability — the EU is out for 1.0

**Decided 2026-09-22: ship everywhere except the 27 EU member states, and add
them once a business is registered.**

The Digital Services Act requires Apple to verify *and publicly display* a
trader's contact details on the product page in EU storefronts: legal entity
name, address, phone and email, visible to anyone with no sign-in, on both the
App Store app and the indexable `apps.apple.com` pages. The developer account is
an individual registered at a home address, so declaring trader today would put
that address on a public, searchable page for as long as the app is listed in
the EU.

The identification documents and payment details Apple collects are *not*
displayed — only the four fields above. That distinction is the whole of the
decision: the problem is not that Apple holds the address, it is that the store
shows it.

Not shipping to the EU removes the requirement rather than answering it. Nothing
else is affected: availability is per-region and editable at any time, no new
build or version is needed to change it, and the rest of the listing is
unaffected.

**To do it:** App Store Connect → the app → Pricing and Availability →
Availability → deselect the 27 EU member states. The UK is not in the EU and
stays selected. Check Norway, Iceland and Liechtenstein against Apple's own list
rather than assuming — EEA membership is not EU membership and the two are
treated differently.

**To undo it later:** register the business, complete the DSA trader declaration
with the business address, then re-select the regions. The trader verification
has to be finished first, or the regions cannot be added back.

⚠️ Check before the first external TestFlight round whether any tester is in the
EU. Trader requirements have been extended in ways that reach beyond the public
store, and an EU tester may be blocked by the same declaration this decision
defers.

## Age rating

**Answered 2026-09-22. Apple calculated 16+, accepted without override.**

One Yes in the whole questionnaire: **Unrestricted Web Access**, because the app
contains a general-purpose web browser. That answer alone sets the rating.

Everything else is None or No, and the reason is the same for all of them: these
questions ask what the app *contains, shows or provides*, and Panura provides no
content of its own — no catalogue, no directory, no bundled media.

| Section | Answer |
|---|---|
| Parental Controls, Age Assurance | No — site toggles and private browsing are not guardian tools |
| User-Generated Content, Social Media, Messaging | No — nothing a user makes is distributed to anyone |
| Social Media Disabled for Under 13 | No — Yes would assert the Declared Age Range API is called, and it is not |
| Advertising | **No, while `FeatureFlags.adsEnabled` is false.** The SDK is linked but never starts. See the ads section above: this becomes Yes before any build that ships them |
| Mature themes, medical, sexuality, violence, gambling, contests | None throughout |

It is tempting to hedge on the content screens, because a browser can reach
anything. Don't. The open web is declared by Unrestricted Web Access — that is
the mechanism Apple provides for exactly this — and marking a content category
would claim the app supplies it. Hedging also buys nothing: web access has
already taken the rating as high as these answers can.

**Do not override to 18+.** The override exists for an app whose EULA sets an
age floor, and neither document does: `terms-of-use.html` states no minimum age,
and the privacy policy's Children section says only that the app is not directed
at children and points parents to Screen Time and Family Link. A rating above
the calculated one would also make Panura look like it carries adult content of
its own, which is the opposite of what every other answer establishes. Age
Suitability URL stays blank.

This is the same position Safari and every third-party browser is in. Do not try
to argue the browser is incidental; it is the main feature, and understating it
is a rejection. (An earlier draft of this section said to expect "the highest
tier" — true under the old system, where unrestricted web access forced 17+.
Apple's revised tiers land it at 16+. The instruction was right; only the number
moved.)

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

A public-domain page that demonstrates it end to end, if you would like one:
archive.org/details/BigBuckBunny_124 — press play on the page's own player, then
tap the bar that appears at the bottom of the screen.
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

### How they are captured — by hand, decided 2026-09-19

On the real devices, from the TestFlight build:

- **iPhone 14 Pro Max** shoots **1290 × 2796**, which is one of the two sizes
  Apple accepts for the 6.9" slot. Upload as-is.
- **iPad 9th gen** shoots **1620 × 2160**, which Apple does *not* accept — but it
  is exactly 3:4, and so is the required 2064 × 2752. So it upscales by 1.274×
  with no cropping and no distortion:

  ```python
  from PIL import Image
  for p in Path("ipad").glob("*.png"):
      Image.open(p).resize((2064, 2752), Image.LANCZOS).save(f"out/{p.name}")
  ```

### The simulator harness, on demand

**Actions → "App Store Screenshots" → Run workflow**, with a device choice of
both / iphone / ipad. It is manual-trigger only and never runs on a push to
`main`, so it costs nothing until asked for. Run it right before publishing, when
the screens are final.

It produces all four shots at both exact sizes, checks the pixel dimensions
before uploading, and posts a thumbnail of each as a notice annotation — readable
without a token, unlike the artifact itself. The pieces:
`.github/workflows/ios-screenshots.yml`, `Tests/Screenshots/StoreScreenshots.swift`,
`Sources/Core/ScreenshotMode.swift` (seeds the app, `#if DEBUG`), and
`Tools/make-demo-clip.swift` (draws the footage behind the player shot, so no
third party's CDN or content is involved).

Two things about it worth knowing before relying on it. **It takes no taps** —
it launches straight into each screen via `-panura-screen`, because XCUITest
waits for the app to go idle before every interaction and these screens never do
(animating page, playing video, fixture timer). And **it touches no photo
library** — the clip is bundled into the build instead, because
`simctl privacy grant photos` hangs until the job times out.

It took nine rounds to get right, at ~16 minutes of macOS runner time each,
billed at 10×. A person with the device in hand does it in ten minutes. So hand
capture is the default; this is for a size nobody owns, or a re-shoot when the UI
changes and nobody wants to redo five screens twice.

One trap it did catch, which applies however the shots are taken: **the browser
screenshot must not show panura.app's home page**, which carries a Google Play
badge. App Review guideline 2.3.10 rejects metadata naming or showing another
mobile platform, and screenshots are metadata. `panura.app/support` is clean.
