# Shipping the iOS app

Ordered. Everything above the line is done; everything below needs the Apple
Developer account, which is still in enrolment.

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

## Blocked on the account

1. **Enrolment completes.** Everything below follows from it.
2. **Create the app record** in App Store Connect for `com.panura.player`.
   - Copy the App Store ID it assigns into `VersionStore.appStoreID`. One line;
     until it is set the in-app "Update" link goes nowhere.
3. **App Store Connect API key**: Users and Access → Integrations → App Store
   Connect API, role **App Manager**. Apple shows the `.p8` once. Set four
   repository secrets in `panura-ios`:
   - `APPSTORE_KEY_ID`, `APPSTORE_ISSUER_ID`, `APPSTORE_PRIVATE_KEY` (the whole
     `.p8`, BEGIN line to END line), `IOS_TEAM_ID`.
4. **`MANIFEST_SALT` secret**, or the release workflow fails on purpose. See
   below — this is also the moment to rotate.
5. **Screenshots**: 6.9" iPhone and 13" iPad. See the end of
   `app-store-listing.md`.
6. **Run the release workflow** (Actions → iOS Release → Run workflow). It
   validates before it uploads, so a rejection costs a minute rather than a
   build number.
7. **Fill the listing** from `app-store-listing.md`, attach the build, submit.

## Rotate the salt at the same time

The manifest salt is committed in this public repo and is in its history
permanently, so today the hashing buys nothing: anyone can hash candidate
domains and read the deployed manifest. Rotation was deferred deliberately —
changing it mid-test breaks every rule match — and the first public release is
the natural moment.

The four steps are in the header of `Sources/Core/ManifestSalt.swift`: new salt
into `.manifest-src/salt.txt` in the `panura` repo, the same value into the
`MANIFEST_SALT` secret here, blank the committed literal, rebuild the manifest
and deploy. The salt in `.manifest-src/salt.txt` and the CI secret must match
exactly or every site rule stops matching.

## Decide before submitting

- **Ads.** `FeatureFlags.adsEnabled` is `false`. Shipping with it false is the
  simplest first submission: the privacy label is "Data Not Collected" and no
  ATT prompt exists to be questioned. Turning ads on later needs a new label and
  `NSPrivacyTracking: true`, which is an ordinary update.
- **iPad.** `TARGETED_DEVICE_FAMILY` is `1,2`, which obliges 13" iPad
  screenshots and an iPad that actually works. Narrowing to `1` is a product
  decision, not a technical one.

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
- Pinch zoom, sleep timer, background audio, resume.
- The offline error page, and private-mode theming.
