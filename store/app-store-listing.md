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
Play any video — found on a web page, or already in your library. Real subtitles, gestures, background audio, and your TV a tap away. No account, no downloads.
```

159 characters. Rewritten 2026-09-23: the old line said "find a video on any
site", which sold the browser and left the Videos tab out of the only 170
characters a passer-by reads. Both halves now appear in the first clause, and
"already in your library" is the honest phrasing — the photo library is what the
app reads, and it is not a Files-app player.

## Description (≤4000)

```
Panura is a web browser and a video player in one. What plays on a page and what
is already on your phone open in the same player — full screen, free of the
page's ads and pop-ups.

Browse to a page, press play, and Panura finds the stream the page is playing.
Or open the Videos tab, where the same player opens your library. Either way you
get real controls, a picture that fills the screen properly, and subtitles you
can size, colour and re-encode until they are readable.

BUILT-IN BROWSER
• Ad and pop-up blocking, so a page that opens six tabs opens none
• Private mode that keeps nothing once you leave it
• Desktop mode for sites that hide their player from phones
• Bookmarks, history and Watch Later, with the address bar where your thumb is

YOUR PHONE'S VIDEOS
• Every video in your photo library, in a grid or a list
• Albums, search, and sorting by name, date or size
• Length and file size on every row, and delete without leaving the app
• iCloud videos play too — Panura fetches them at full quality when you tap
• The same player, the same gestures, the same subtitle settings
• Add any of them to Watch Later, beside the pages you saved

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

WHAT PANURA DOES NOT DO
• No account, ever. Nothing to sign up for
• No downloading of anything you browse to
• No ad tracking. Your history, bookmarks and resume positions stay on the
  device and are deleted with the app
• YouTube and its domains are deliberately excluded

Panura is a player and a browser. It hosts no content of its own, indexes
nothing, and only ever opens the pages you ask it to.
```

**Do not write that the web "hides" video.** The opening line said so on
2026-09-23 and was replaced the same day. Two reasons, the second the real one:
sites are not concealing anything, they are playing video in their own poor
player — which is a truer and stronger complaint; and *hides* reads to a
reviewer as *circumvents*, which is Guideline 5.2, in the first sentence of a
browser that finds streams. The same applies to "the stream **behind** the
site's own player", now "the stream the page is playing". Claim a better
player, never secret access.

**Nor write anything against web pages.** The replacement opened "Web pages play
video in their own player. Panura gives you a better one" — accurate, and still
wrong for this field: the listing states what Panura does, and does not run down
what anyone else does. It also invited the comparison a reviewer is least keen
to referee. The lede states the benefit as a feature instead: *full screen, free of the
page's ads and pop-ups*. Distraction-free is the same promise the contrast was
reaching for, and it is ours to claim.

⚠️ **Scoped to "the page's" ads deliberately.** A flat "no ads" goes false the
day banner ads ship in 1.1, and a description that contradicts the running app
is a rejection and a refund thread. The blocker keeps working whatever Panura
itself shows, so the scoped phrasing survives the change.

The one surviving "hide" is • *Desktop mode for sites that hide their player
from phones*, which stays. That is literal — sites really do serve a different
player to mobile — and it describes the condition the feature exists to solve
rather than passing judgment on anyone.

**Why the Videos section is worded the way it is.** Rebalanced 2026-09-23: the
description used to be almost entirely about the browser, with four lines at the
bottom for the library. The section moved above THE PLAYER and grew, but every
bullet is held to what `LocalVideosModel` actually does, which is `PHAsset` and
nothing else:

- **No Files-app support.** No `CFBundleDocumentTypes`, no
  `LSSupportsOpeningDocumentsInPlace`, no `UIFileSharingEnabled`, no document
  picker, no share extension. Panura is not in Files' "Open in" sheet.
- **So MKV and AVI stay in the stream list, not the library list.** iOS Photos
  will not import either container, so on the local side the app sees
  MP4/MOV/HEVC. "Plays what other players refuse: HLS, MP4, MKV, AVI" is true of
  what it *plays*; it must not be re-used as a claim about your own files.
- **No resume claim for library videos.** `LocalVideosModel.lastPlayedID` exists
  because "the file URL behind it is a temporary copy that changes", and resume
  positions are keyed by URL. Resume is claimed for the player generally, never
  for the Videos tab specifically.
- **iCloud is claimed** because `isNetworkAccessAllowed` is true on both resolve
  paths and `copyOriginal` writes the full-size resource.

Adding Files import would make the local player real and is the single change
that would most improve both this section and the Guideline 5.2.3 position —
substantial functionality that is not "browse to a site and grab the stream".
Deferred past 1.0 by decision.

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
collect data from this app**, then tick exactly these seven:

**Answered 2026-09-23.** Seven types, none linked, none used for tracking.
`Resources/PrivacyInfo.xcprivacy` declares the same seven with the same
purposes — change one, change the other, or the binary and the listing disagree.

| Category → type | Purpose | Linked to the user | Used for tracking |
|---|---|---|---|
| Diagnostics → Crash Data | App Functionality | No | No |
| Diagnostics → Other Diagnostic Data | App Functionality, Analytics | No | No |
| Usage Data → Product Interaction | Analytics | No | No |
| Usage Data → Search History | App Functionality | No | No |
| Identifiers → Device ID | Analytics | No | No |
| Location → Coarse Location | Analytics | No | No |
| User Content → Customer Support | App Functionality | No | No |

**Crash Data is App Functionality, not Analytics.** Apple's Analytics purpose is
about evaluating *user behaviour*; a crash log measures software stability, and
"minimize app crashes" is named in the App Functionality description. Firebase's
own Crashlytics manifest says the same. Other Diagnostic Data carries both,
because stability figures across builds genuinely are looked at in aggregate.

**Two types the app collects itself, added 2026-09-23.** Neither comes from an
SDK, so neither appeared in any vendor's manifest and both were missing:

- **Customer Support** — "Report a problem" POSTs `{url, reason}` to Panura's own
  Worker. Apple's optional-disclosure exception nearly covers it, but one of its
  conditions is that collection be infrequent and outside primary functionality,
  and Report is offered in the site panel, on Home and in the drawer. Declared
  rather than argued. No name, email or device id is in the payload, which is
  also why it cannot be replied to.
- **Search History** — what is typed in the address bar goes to Google's suggest
  endpoint to be completed. No cookies, no identifier, and `SearchSuggestions`
  refuses to send anything containing `://` or beginning `www.`, so an address
  never leaves the device — only a search term. The judgment call: Google is not
  an SDK whose code was added, which is a reading under which this need not be
  declared. Declared anyway, because under-declaring is the failure Apple acts
  on.

**Browsing History is deliberately NOT declared.** The only URL that ever leaves
the device is the one page a user knowingly attaches to a report, which is
customer-support data. Bookmarks, history, Watch Later and resume points stay in
`UserDefaults`.

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

`Resources/PrivacyInfo.xcprivacy` declares the same seven types. Change one,
change the other.

### The ATT key blocked submission — fixed 2026-09-24, needs a new build

"Add for Review" refused the first attempt with: *your app contains
`NSUserTrackingUsageDescription`, indicating that it may request permission to
track users. To submit for review, update your App Privacy response to indicate
that data collected from this app will be used for tracking purposes, or update
your app binary and upload a new build.*

Apple offers two ways out and only one of them is honest. **Declaring tracking
would be a false statement to App Review** — 2.3 Accurate Metadata — and would
hang a "Data Used to Track You" panel on the listing of an app that does not
track: `AdManager.startIfEnabled` returns on `FeatureFlags.adsEnabled` *before*
it reaches ATT, so with ads off the prompt cannot be raised at all, and
`NSPrivacyTracking` is false for the same reason.

So the key is gone from `project.yml` and the build has to be re-uploaded. The
string itself is preserved in the comment that replaced it, because restoring it
is part of turning ads on and the wording was already settled. **The table above
does not change** — the answers were never the problem, the plist was.

⚠️ **Turning ads on changes this again.** Personalised AdMob ads add Usage Data →
Advertising Data, mark Device ID as used for tracking, flip `NSPrivacyTracking`
to `true`, and make the ATT prompt mandatory. Do not ship ads without all four.

`GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS` is `false` in
`project.yml` as of 2026-09-23. Firebase's default is to ALLOW those signals,
which lets Google use Analytics data to personalise advertising — the one route
by which "Device ID is not used for tracking" could stop being true without
anyone changing a line. Turning it back on is a decision with an ATT prompt
attached, not a default to inherit.

## Accessibility (the nutrition label)

**Answered 2026-09-23: Yes, supporting two — Dark Interface and Sufficient
Contrast.** Everything else No.

**Dark Interface.** The criterion is a mostly dark interface with few or no
large light views, *excluding third-party or user-generated content* — which is
what lets a browser qualify despite rendering white pages. One dark palette
throughout, `UIUserInterfaceStyle: Dark`, `.preferredColorScheme(.dark)`, and a
launch screen painted `#0F0F0E`, the same value as the app background, so launch
never flashes white. The Smart Invert fallback in that criterion is for apps
*without* a native dark appearance and does not apply.

**Sufficient Contrast**, measured with the WCAG formula rather than estimated:

| pair | ratio |
|---|---:|
| primary text (white) on any surface | 17.07 – 19.18 |
| secondary text (white 60%) on any surface | 6.77 – 7.25 |
| amber accent on background / surfaces | 9.51 – 10.69 |
| dark-on-amber, filled buttons | 8.33 |
| private-mode violet on background | 9.63 |
| duration badge, worst case over a white video frame | 8.45 |
| `outline`, borders only, never text | 3.18 |

Lowest text ratio is 6.77 against a 4.5 bar; `outline` clears the 3:1 that
applies to non-text components. The only things below 4.5 are disabled controls
— the greyed chevrons at 1.78 and disabled panel cells at 2.71 — which are
inactive components, exempt, and have to look inactive: at full brightness the
chevron is 6.84 and reads as enabled.

**Why the rest are No**, so 1.1 does not have to re-derive it:

- **Larger Text** — the criterion is 200%. 65 fixed `.system(size:)` calls, no
  `dynamicTypeSize` handling anywhere, and hard frames throughout (52pt header,
  92pt cards, 142×80 posters) that would clip. This is the one worth fixing:
  mechanical work, no device needed to start.
- **VoiceOver, Voice Control** — 26 accessibility labels is not the same as
  completing every common task, and none of it has been run under either. Needs
  a device pass, not more labels.
- **Reduced Motion** — no `accessibilityReduceMotion` anywhere, and the drawer,
  panel and found bar all animate unconditionally.
- **Captions, Audio Descriptions** — the app ships no content of its own. It
  displays subtitles from whatever is played but cannot guarantee any video has
  them.
- **Differentiate Without Color Alone** — probably true and not audited. The
  states checked do change shape as well as colour (`bookmark`↔`bookmark.fill`,
  `clock`↔`clock.fill`) and private mode changes the placeholder text too.

**Accessibility URL: blank.** A thin page describing work not yet done is worse
than none.

## Price: Free, no in-app purchases

**Pricing and Availability → Price Schedule → Free.** App Store Connect will not
let the app be submitted until a tier is chosen, and no tier is chosen by default
— which is what "You must choose a price tier in Pricing" means.

Free is not a placeholder. The Android app is free with interstitials, the
business model is the same one, and `FeatureFlags.adsEnabled` being false in 1.0
makes this release free in the plainest sense: no price, no ads, nothing to buy.
Charging for a first version of a browser-plus-player, in a category where VLC
and Infuse set the free floor, sells nothing.

There are no in-app purchases and no subscriptions, so the IAP section stays
empty and the "Paid Apps" agreement is not needed — only the Free Apps agreement,
which the account already has. A price can be changed later without a new build;
adding IAP cannot.

## Availability — the EU and mainland China are out for 1.0

**Decided 2026-09-22: ship everywhere except the 27 EU member states and
mainland China. The EU comes back once a business is registered; China stays
out.**

Two different reasons, and only one of them is temporary.

### Mainland China: no ICP filing

Apple requires an Internet Content Provider filing number from China's MIIT for
an app to be listed in the mainland China App Store. There is no way to defer
this one the way the EU can be deferred — without the number the app cannot be
distributed there at all.

Obtaining one needs a mainland Chinese business entity or a local publishing
partner, which is a larger undertaking than the EU registration and buys a
market this app has no particular claim on. Not worth it for 1.0, and probably
not for 1.x.

Hong Kong, Macau and Taiwan are separate storefronts, are unaffected, and stay
selected.

### The EU: trader details would be published

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
Availability → deselect the 27 EU member states and mainland China. That leaves
roughly 147 of the account's 175 regions. The UK is not in the EU and stays
selected. Check Norway, Iceland and Liechtenstein against Apple's own list
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
Panura is a web browser and a video player in one. The user browses to a page
themselves; when that page plays a video, Panura detects the stream the page is
already loading and offers to play the same video in its own player, which
handles more formats and gives the subtitle, audio-track, speed and aspect
control the page's own player does not. That same player opens videos already in
the user's photo library. For adults who watch video on the web.

No content is hosted, bundled, indexed or recommended by us. There is no
catalogue, no directory, no recommendations and no search across other people's
sites, and the app never suggests a site to visit. The first screen is a browser
address bar. The only media we host anywhere is on our own demo page,
panura.app/demo: a ten-second excerpt of "Big Buck Bunny", (c) 2008 Blender
Foundation, under Creative Commons Attribution 3.0 and attributed there.

There is NO download feature on iOS. Nothing browsed to can be saved to the
device. The Videos tab plays videos already in the user's photo library, via
PHPhotoLibrary, and nothing else.

YouTube and its associated domains are explicitly blocked from detection, in line
with their terms.

NO ACCOUNTS of any kind - no registration, login or account deletion. No
user-generated content, so nothing to report or block. No paid content, no
in-app purchase, no subscription. Nothing is gated and no credentials are needed.

TO TRY IT: type any site with video into the address bar and press play on that
site's own player. A bar appears at the bottom naming what was found, with a Play
button; if the page offers several streams it shows a count, and tapping it lists
them. panura.app/demo demonstrates it end to end - that page carries its clip in
two qualities, so the bar shows 2. archive.org/details/BigBuckBunny_124 works the
same way if you would rather use a page that is not ours.

PERMISSIONS: Photos, to list and play the user's own videos in the Videos tab.
Local Network, to find a Chromecast or a Panura receiver on an Android TV, and
only while "Play on TV" is open. Background audio, only when the user turns
background play on. App Transport Security allows arbitrary loads because a
browser must reach sites that are still HTTP; no connection of our own is
weakened.

This build shows no ads: the Google Mobile Ads SDK is linked but gated off at
compile time, never initialised, and the App Tracking Transparency prompt is
never shown.

EXTERNAL SERVICES: Google - Analytics for Firebase and Crashlytics (aggregate
usage statistics and crash reports, linked to no identity and not used for
tracking), the Cast SDK, and address-bar completion via
suggestqueries.google.com (search terms only; anything containing "://" or
beginning "www." is refused). Filter lists fetched and compiled on the device:
EasyList, EasyPrivacy, uBlock Origin, AdGuard mobile, oisd. Ours:
panura.app/version.json (version and changelog), panura.app/manifest.json (tunes
stream detection and cannot enable a feature), and a Cloudflare Worker receiving
Report a Problem. VLCKit is a bundled playback engine, not a service. No
authentication, payment, AI or content-provider service.

Browsing history and the pages a user visits are never sent anywhere. The only
playback events logged record the format ("hls", "mkv") and which of the two
engines played it, never an address.

REGIONS: the app behaves identically in every region where it is available.
Nothing is geo-gated.
```

**The detection manifest is deliberately not mentioned in the notes — option B,
decided 2026-09-23.** Three options were weighed: disclose it, stay silent, or
stay silent while keeping the old sentence "no list of sources anywhere in the
app". The third was the only dangerous one, because a hashed host list *is* a
list of sites and that sentence was therefore false in writing to App Review —
2.3 Accurate Metadata, and account-level rather than app-level if it ever landed
badly. So the sentence is gone regardless; the notes now claim no catalogue, no
directory, no cross-site search and no suggested sites, all of which are true.

Silence is not a claim. There is no obligation to document the architecture, and
remote configuration is ordinary. **If App Review asks, answer immediately and
fully**: it is data, not code; nothing fetched is executed; it cannot enable any
feature absent from the reviewed build; hostnames are one-way hashes because the
file is publicly reachable. Nothing in the notes contradicts any of that, which
is the entire point of having removed the sentence.

⚠️ **The rule that keeps this true: the manifest may only tune behaviour the
reviewed build already has.** The moment it can *enable* something — ads, a
feature toggle, a new capability — it is Guideline 2.5.2, downloading code that
changes functionality after review. This is why `FeatureFlags.adsEnabled` is
compile-time and must stay compile-time.

---

## Guideline 2.1 Information Needed — asked 2026-09-25

Not a rejection of anything in the app. It is the questionnaire Apple sends every
developer account with little review history: a screen recording plus six written
answers. Nothing was found wrong; nothing in the build or the metadata has to
change.

The six answers are condensed into the Notes block above, because Apple asks for
them there as well as in the reply ("for reference on future submissions"). The
Notes field caps at **4000 characters**, which is why several paragraphs were
tightened when these were added — it now sits at ~3900 including newlines. Anything
added later has to come out of something else.

### The recording — what it must and must not show

Apple watches this for 5.2.3 as much as for completeness, so the choice of page
matters more than the production does.

**Browse panura.app/demo, and archive.org if a second is wanted. Nothing else.**
Not a site that streams films it has no right to, not one wrapped in pop-ups for
them — a reviewer seeing that, in a recording *we* chose, learns what the app is
for from the one piece of evidence we controlled entirely. Everything the notes
say about no catalogue and no directory is true and stays true; the recording has
to look like it too.

One take, physical device, latest iOS, starting with the app launching:

1. Launch → Home.
2. Address bar → `panura.app/demo` → press play on the page's own player → the
   found bar appears showing **2** → tap it → the quality list → Play.
3. The player: controls up, subtitle options, aspect, speed, rotate.
4. Back → **Videos** tab → allow Photos when asked → open one → the same player.
5. **Play on TV** → the scan. Show a device being found if there is one on the
   network; if not, let the scan run so it is plain the feature is real.
6. **Settings** → blocking, playback engine, background audio.

No account flow, no IAP, no UGC reporting to film — there are none, and the reply
says so rather than leaving Apple to wonder. Keep it two to three minutes; attach
it in Resolution Center rather than linking to it, so nothing depends on a
third-party host resolving.

### The reply, in full

```
Thank you for the review. All six items are answered below, and the same
information has been added to the Notes field in App Review Information.

1. SCREEN RECORDING
Attached, recorded on a physical iPhone running the current iOS, beginning with
the app launching. It shows the typical flow: Home, browsing to a video page,
the stream being detected, playback in Panura's player with its subtitle and
aspect controls, a video from the device's own photo library opening in the same
player, the Play on TV screen, and Settings.
The app has no account registration, no login and no account deletion, because it
has no accounts of any kind. It hosts no user-generated content, so there is
nothing to report or block. There is no paid content, no in-app purchase and no
subscription: the app is free, and this build shows no ads.

2. PURPOSE AND TARGET AUDIENCE
Panura is a web browser and a video player in one.
The problem: video on the open web plays in whatever player the page happens to
provide. Those players usually offer no subtitle control, no choice of audio
track, no playback speed, no resume, no background audio, no Picture in Picture
and no way to send the video to a television — and many formats will not play at
all. The user's own videos, already on the phone, need a separate app again.
What Panura does: when a page plays a video, Panura detects the stream that page
is already loading and offers to play the same video in its own player, which
handles HLS, DASH, MP4, MKV, AVI, WebM and more, embedded and external subtitles,
audio-track selection, speed and aspect control, background audio, Picture in
Picture, and casting to a Chromecast or to an Android TV. That same player opens
the videos already in the user's photo library.
Audience: adults who watch video on the web on a phone or iPad. The app is rated
16+ for unrestricted web access, in the same position as any third-party browser.

3. SETTING UP AND ACCESSING THE MAIN FEATURES
Nothing is gated. There is no login, no credential and no sample file to install.
- Detection: open the app, type a site with video into the address bar, and press
  play on that site's own player. A bar appears at the bottom of the browser
  naming what was found, with a Play button on it. If the page offers several
  qualities the bar shows a count instead, and tapping it lists them.
  A page that demonstrates this end to end: https://panura.app/demo — our own
  sample page, carrying a Creative Commons clip in two qualities, so the bar
  shows 2. https://archive.org/details/BigBuckBunny_124 is a public-domain page
  that works the same way if you would prefer one that is not ours.
- The user's own videos: the Videos tab, allowing Photos access when asked. Only
  video assets are read, and only while that tab is open.
- Play on TV: open Play on TV and the app looks for a Chromecast, or for the
  Panura receiver on an Android TV, on the same Wi-Fi network. A television on
  the network is needed to see this one finish.
- Settings: subtitle appearance, playback engine, background audio, and the ad
  and tracker blocking used in the browser.

4. EXTERNAL SERVICES, TOOLS AND PLATFORMS
Google: Google Analytics for Firebase and Firebase Crashlytics (aggregate usage
statistics and crash reports), the Google Cast SDK (finding and playing to a
Chromecast), and address-bar completion via suggestqueries.google.com — search
terms only, never a URL; the code refuses to send anything containing "://" or
beginning "www.". The Google Mobile Ads SDK and UserMessagingPlatform are linked
into the binary but disabled at compile time (FeatureFlags.adsEnabled = false) and
never initialised, so this build requests no ads and shows none.
Ad and tracker filter lists, downloaded and compiled on the device into a
WKContentRuleList: EasyList and EasyPrivacy (easylist.to), uBlock Origin's filter
lists (ublockorigin.github.io), AdGuard's mobile filter (filters.adtidy.org) and
oisd (small.oisd.nl).
Our own: panura.app/version.json, the current version and changelog for the
in-app update notice; panura.app/manifest.json, settings that tune how streams
are recognised and which cannot enable any feature the reviewed build does not
already have; and a Cloudflare Worker that receives a Report a Problem message
(the page address and the text the user typed, nothing identifying).
Bundled libraries rather than services: VLCKit (VideoLAN) as the second playback
engine, and a local HTTP server used only to relay a stream to a television on
the same network. Neither contacts anything of ours.
There is no authentication service, no payment processor, no AI service, and no
content provider or data provider — the app has no catalogue for one to supply.

5. REGIONAL DIFFERENCES
There are none. The app behaves identically in every region where it is
available: no feature, content or restriction varies by country, and nothing is
geo-gated or geo-detected. For business reasons the app is not distributed in the
27 EU member states or in mainland China, which is a choice about where it is
sold, not a difference in what it does.

6. REGULATED INDUSTRY AND PROTECTED THIRD-PARTY MATERIAL
Neither applies. The app is not in a regulated industry, and it ships no
third-party content. It hosts no media, bundles none and indexes none. There is
no catalogue, no directory, no recommendations and no search across other
people's sites, and the app never suggests a site to visit — the first screen is
a browser address bar. What plays is whatever page the user typed in themselves,
exactly as it would in Safari, plus files already in their own photo library.
There is no download feature on iOS: nothing browsed to can be saved to the
device.
The only media we host anywhere is on our own demo page, https://panura.app/demo:
a ten-second excerpt of "Big Buck Bunny", © 2008 Blender Foundation, published
under the Creative Commons Attribution 3.0 licence
(https://creativecommons.org/licenses/by/3.0/) and attributed on the page itself.
That licence permits redistribution, including commercially.
YouTube and its associated domains are explicitly blocked from detection, in line
with their terms.
```

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

**The page it is shot on is `https://panura.app/demo`** — a video page built for
this, laid out the way an ordinary one is: player, title, meta row, channel,
description, up-next list. It carries a ten-second excerpt of *Big Buck Bunny*
(© 2008 Blender Foundation, CC BY 3.0, attributed on the page) in two renditions,
so the found-stream bar has a real quality list to show rather than one row.

Three things were rejected on the way to it:

- **`/support`**, which the run used before. Clean, and useless: a found-stream
  bar floating over a FAQ shows the feature working on nothing.
- **`demo.mediacms.io`**, an open-source project's public demo. Their branding
  would be in our store metadata, which Apple reads for third-party marks, and
  the page could change or go down between the screenshot and the review.
- **Hot-linking the clip** from a public test bucket. `Tools/make-demo-clip.swift`
  already exists because of this rule: nobody else's CDN gets to decide whether a
  screenshot run produces an image. The two MP4s are served from `public/demo/` in
  the panura repo, cached immutably in `_headers`.

It is also the page named in Notes for App Review, so it has to keep working.

**On iPad, only the Home shot has the menu open.** Every other screen is shot with
the navigation rail — icon-only — because that is the resting state the design
settled on, and a screenshot showing the full labelled menu on all five screens
says the app eats 260pt of an iPad for a menu nobody asked for. Home is the one
place the open menu is the subject.

That was not just a capture note: `didOpenSidebar` was `@State`, so the one-time
introduction fired **once per launch** rather than once ever, and every cold start
on an iPad popped the menu open. It is `@AppStorage("ipad_drawer_intro_shown")`
now, and the screenshot run suppresses it on every screen but Home.

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
mobile platform, and screenshots are metadata. `panura.app/demo` names no
platform — that is a requirement of the page, not an accident of it.
