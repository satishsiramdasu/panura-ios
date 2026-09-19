# Shipping the iOS app

Ordered. Everything under "Done" is done; everything under "Blocked" needs the
App Store Connect access, which arrived on 2026-09-15.

## Done

- [x] App icon and launch screen in the asset catalog, and wired up
      (`ASSETCATALOG_COMPILER_APPICON_NAME`, `UILaunchScreen`).
- [x] `Resources/PrivacyInfo.xcprivacy` — required for upload. Declares no
      tracking, no collected data, and the one accessed API category the app
      does use (`UserDefaults`, reason `CA92.1`).
- [x] `ITSAppUsesNonExemptEncryption: false`, so uploads do not stop to ask.
- [x] `NSUserTrackingUsageDescription`, without which calling ATT is a
      rejection — even though this build never calls it.
- [x] Live AdMob app id and three unit ids, behind `FeatureFlags.adsEnabled`,
      which is `false`.
- [x] Privacy policy and terms cover iOS specifically: the four permissions, and
      what does and does not leave the device.
- [x] Support page at `panura.app/support`, and clean URLs for `/privacy`,
      `/terms` and `/support`.
- [x] `.github/workflows/ios-release.yml` — signed archive, export, validate,
      upload. Manual trigger only.
- [x] Listing copy, keywords, privacy-label answer, age-rating position and
      review notes: `store/app-store-listing.md`.
- [x] Firebase Crashlytics + Analytics, as Android ships them. Config comes from
      the `GOOGLE_SERVICE_INFO_PLIST` secret; the release workflow uploads dSYMs
      to Crashlytics. The privacy label and `PrivacyInfo.xcprivacy` declare the
      five data types it collects.

## Blocked on the account

1. ~~Enrolment completes.~~ Done 2026-09-15. App ID `panura.web.videoplayer` registered, no capabilities.
2. ~~Create the app record~~ Done: Apple ID `6812081774`, set in `VersionStore.appStoreID`.
3. ~~API key and secrets~~ Done 2026-09-15. Original key revoked after it was
   exposed; replacement set as `APPSTORE_KEY_ID` / `APPSTORE_PRIVATE_KEY`.
   For reference — Users and Access → Integrations → App Store
   Connect API, role **Admin** (App Manager cannot cloud-sign; export fails
   with "Cloud signing permission error"). Apple shows the `.p8` once. Set four
   repository secrets in `panura-ios`:
   - `APPSTORE_KEY_ID`, `APPSTORE_ISSUER_ID`, `APPSTORE_PRIVATE_KEY` (the whole
     `.p8`, BEGIN line to END line), `IOS_TEAM_ID`.
4. ~~`MANIFEST_SALT` secret~~ Done, with the **current** salt. Rotation deferred
   to a later update — see below.
   - **`GOOGLE_SERVICE_INFO_PLIST` secret** — the iOS app's Firebase config,
     pasted whole. The release workflow refuses to run without it, and checks
     the plist is for `panura.web.videoplayer` rather than some other app.
5. ~~VLCKit 4~~ Merged to `main` 2026-09-18 (`cf6a8ee`): VLCKit 4.0.0a24,
   Picture in Picture on the VLC path, and the streaming relay that fixed gated
   MKV. The `vlckit4` branch is merged and no longer builds on push.
6. **Screenshots**: taken by hand on the real devices once the build is in
   TestFlight — decided 2026-09-19, after the simulator harness cost nine CI
   rounds to produce what a person with the device does in ten minutes. The
   harness still works and is parked on the unmerged `screenshots` branch; see
   the Screenshots section of `app-store-listing.md` for when it is worth
   reaching for.
   - iPhone 14 Pro Max shoots **1290 × 2796** — accepted for the 6.9" slot as-is.
   - iPad 9th gen shoots **1620 × 2160**, which Apple rejects — but it is exactly
     3:4, as is the required **2064 × 2752**, so it upscales by 1.274× without
     cropping or distortion. A smaller device's shots are never scaled up by
     Apple; they are simply refused at upload.
   - The browser shot must not show `panura.app`'s home page — it carries a
     Google Play badge, and guideline 2.3.10 rejects metadata showing another
     mobile platform. Use `panura.app/support`.
7. ~~Run the release workflow~~ Done 2026-09-14: build **1.0 (3)** uploaded
   (build number = workflow run number) — **never reached App Store Connect**:
   altool printed "UPLOAD FAILED" (framework signatures, iPad orientations) and
   still exited 0. Build **1.0 (4)** is the first real upload: 2026-09-14, with
   Firebase, Delivery UUID `902eeaac-e0a8-4b0f-b4bf-be1b6bc3b64f`. The workflow
   now fails on altool errors and prints the Delivery UUID when one lands. It
   validates before it uploads, so a rejection costs a minute rather than a
   build number.
8. **Fill the listing** from `app-store-listing.md`, attach the build, submit.

## Submission day, in order

Each step depends on the one before it, and two of them are easy to do in the
wrong order.

1. **Device pass** on the TestFlight build — the list at the bottom of this file.
2. **Run `iOS Release (TestFlight)`** from `main`. Leave the version input blank
   to ship `1.0`. Note the build number it prints: it is the workflow's run
   number, and it is what `CFBundleVersion` becomes.
3. **`version.json` in the `panura` repo**: set `ios.versionCode` to that build
   number before the release goes live. The in-app update banner compares
   `ios.versionCode` against `CFBundleVersion`, so a version.json still saying
   `1` while the shipped build is `24` means the app can never see an update —
   and the first number that *is* larger would have to be a build number, not a
   version. Bump it with every release, from now on, to the uploaded build
   number. Edit `.manifest-src/manifest.source.json`, run `node
   .manifest-src/build.mjs`, commit both generated files.
4. **Screenshots** from that same build (sizes below), uploaded to App Store
   Connect.
5. **Fill the listing** from `app-store-listing.md` — the copy, the five privacy
   answers, age rating, content rights, review notes.
6. **Submit for review.**
**No salt rotation in this release** — decided 2026-09-18, for the Android
reason in the section below. 1.0 ships on the current salt.

## Rotate the salt (not in 1.0 — decided 2026-09-18)

The manifest salt is committed in this public repo and is in its history
permanently, so today the hashing buys nothing: anyone can hash candidate
domains and read the deployed manifest.

**It is still not worth rotating for this release, because Android reads the
manifest too.** That was the deciding fact and the repo docs had it wrong: the
Android app fetches `manifest.json` and hashes hosts with its own baked-in
`BuildConfig.MANIFEST_SALT` (`core/extractor/build.gradle.kts`) — the old
`CDN_EXTRACTORS_ENABLED = false` gate only ever disabled the retired per-host
scripts. Deploying a re-hashed manifest would therefore stop every site rule
matching on **every installed Android build** as well, until a Play release
carrying the new salt reached users. Rotation is a coordinated two-platform
release, not a CDN change, and it buys nothing that shipping 1.0 does not.

Do it when Android and iOS next ship together — or when the panura-ios repo goes
private, which removes the exposure without touching anyone's install. Order,
once: new salt into `.manifest-src/salt.txt` (`panura`), the same value into the
`MANIFEST_SALT` secret here **and** into the Android build's `local.properties` /
CI secret, blank the literal in `Sources/Core/ManifestSalt.swift`, ship both
apps, then rebuild and deploy the manifest. Four copies, all byte-identical, or
no rule matches anywhere.

## Decide before submitting

- **Ads.** `FeatureFlags.adsEnabled` is `false`. Shipping with it false is the
  simplest first submission: no advertising data in the privacy label and no
  ATT prompt to be questioned. Turning ads on later needs a new label and
  `NSPrivacyTracking: true`, which is an ordinary update.
- ~~**iPad.**~~ Decided: kept. `TARGETED_DEVICE_FAMILY` stays `1,2`, so the
  iPad layout needs a real test pass on the iPad before submitting, and 13" iPad
  screenshots are required.

## Test on a device before submitting

Reviewers use real hardware, and the simulator does not exercise most of this:

- Icon and launch screen, and that the launch image dissolves into the first
  screen rather than flashing.
- Detection end to end: browse, press play, tap the found bar, watch it play.
- Cast: local-network prompt, Chromecast discovery starting only when picked.
- Videos tab: photo permission, an iCloud-only video, a slow-motion or edited
  clip (both take the `PHAssetResourceManager` path).
- Subtitles: size, colour, outline, and `:freetype-font`, which may need a
  PostScript name rather than a family name on device.
- Pinch zoom (it now goes below 100%), sleep timer, background audio, resume.
- The offline error page, and private-mode theming.
- **Engine hand-over**: a stream the Apple player cannot decode — HEVC in
  MPEG-TS, an MKV — starts in VLC on its own, with no error shown and no VLC
  branding. Settings → Playback is on **Auto**; forcing Apple there should make
  the same stream show the unsupported message instead of loading forever.
- **A gated stream from the browser** (one whose site rule asks for `origin` or
  a cookie): it goes through the relay, and must start in seconds and seek.
- **Picture in Picture** on both engines: swipe up mid-video, the picture
  follows, and tapping it returns to the player rather than the browser.
- Controls at phone width with quality options showing — nothing clipped, close
  button reachable.
