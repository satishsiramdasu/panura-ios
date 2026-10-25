# Panura ad design

The agreed monetisation design, written once so both platforms implement the
same thing. **iOS is the reference implementation**; Android replicates it.
Android's older ad code — app-open ad, a browser timer, four interstitial
units, rewarded-to-convert — is *not* the model and is being replaced by this.

Settled 2026-10-11. iOS code lives in `Sources/Ads/`.

---

## 1. The whole design in one table

*Revised 2026-10-25 (Android 3.5 first; iOS to follow). The earlier design gave
each placement its own clock and made server refresh a rewarded wall; both are
superseded below.*

| Placement | Format | Trigger | Qualifier |
|---|---|---|---|
| App open | App open | Returning to the app after >= 30 s away. Never a cold start, never over a video or a cast | an hour since the last app open |
| Player exit | Interstitial | Leaving any player, any engine | tier watch time **or** 25 % of duration |
| Cast success | Interstitial | Receiver *confirmed* playing, within 15 s of the request | - |
| Cast stop | Interstitial | Deliberate Stop / Disconnect | tier watch time of confirmed playback |
| Download start | Interstitial | A download was successfully enqueued | - |
| Server open | Interstitial | A server's listing **has loaded** after the person opened it | - |
| Server refresh | Interstitial | A listing **has loaded** after a manual refresh | - |
| Convert to share | **Rewarded** | Person asks to share a downloaded HLS video as MP4 | - |
| Banner | Banner | Every screen except the player, cast controls included | 30 s refresh, set on the unit |

Three global rules override everything above:

- **One interstitial clock.** Every interstitial placement *and app open* read
  and reset one shared clock. The gap is the manifest's country-tiered
  `gapSeconds` (§12) - 15 min by default, 5 min in the low-CPM tier. The
  placements are only *triggers*: watching the player-exit ad and then tapping
  Save shows nothing, because the gap has not passed. Rewarded has its own
  clock and never waits on, or delays, the interstitials - the person asked for
  it.
- **The first two launches are ad-free**, banner included (§7).
- **No timers.** Every ad follows something the person did. The old
  mid-playback interstitial (5 min into a video) and the browser interstitial
  (every 30 min of browsing) are removed: AdMob treats an interstitial that
  interrupts content as an unexpected interruption, the fastest route to a
  limited account.

Everything else in this document is the reasoning, the edge cases, and the
exact state each rule needs.

---

## 2. What is deliberately absent

| Not built | Why |
|---|---|
| App-open ad **on launch** | The highest-complaint format there is; it taxes launching the app, which is not a thing we built. An app-open ad on *returning* was added later on request, hedged — see §13. |
| Interstitial per video | In-player next/previous walks the playlist without closing the screen, so an exit-triggered ad gives one ad per *session* rather than one between every pair of episodes. The gap length could never have fixed this: episodes run 25–40 min, so any gap worth having is already satisfied when one ends. |
| Interstitial *before* a server listing | An ad between the tap and the thing asked for is an ad for waiting. The server ad (§5) shows only after the listing has loaded. |
| Mid-playback / mid-task interstitials | Accidental clicks, invalid-traffic flags, uninstalls. |
| Ads on AirPlay | No AirPlay code was written — the system route picker does it. *"We only monetise what we worked and built."* |
| Rewarded on showing cast controls | Considered, dropped. Replaced by the cast exit interstitial. |
| Personalised ads | `npa=1` on every request. See §8. |

---

## 3. Player exit interstitial

**Trigger:** the player screen is closing, whatever opened it — browser,
playlist server, file share, camera roll. It was browser-only for a while;
extending it to every engine sweeps in camera-roll videos too, which is
somebody's own file but still our player, and the player is the thing that was
built.

**Qualifier:** `watchedEnough(seconds, duration)` → `true` if
`seconds >= AdCountryPolicy.minWatchSeconds` (60 s by default, 30 s in the
low-CPM tier — never zero, or a stream that dies in seconds earns an ad), else `true` if `duration`
is known and `seconds >= duration * 0.25`.

Without the qualifier, a stream that dies after eight seconds still counts as
playback ending, and the user gets an ad immediately after the app failed
them. They waited on a video and got an advert for the privilege. That is the
worst ad moment it is possible to build, and it would ship to everyone whose
link expired.

The 25 % branch exists so a 90-second clip can qualify while a 40-minute
episode does not need ten minutes of credit.

**Gap: the shared interstitial clock (§1), country-tiered, 15 min by default.** Barely binds — the real gap for
anyone watching something of normal length is however long that thing was. It
bites on short clips opened and abandoned one after another, which is exactly
when it should. Fifteen rather than ten not because ten fires too often, but
because the cost of being wrong is asymmetric: an ad too many is remembered,
an ad too few is not noticed. See §12 for how the gap varies by country.

**Presentation order matters.** On iOS the player is a full-screen cover owned
by the root view, and presenting a second modal from a controller that is
already presenting silently does nothing at all. So the player *queues* the ad
on its way out and the shell shows it from the cover's dismissal callback.
Android equivalent: do not call `show()` from inside a closing
Activity/Fragment — finish the player, then show from the host.

---

## 4. Cast interstitials - two triggers, the shared clock

**Success fires on confirmation, not on request.** The only moment a cast is
known to have worked is when the receiver reports it is playing frames. An ad
for a cast that was refused is an ad for a failure. So: arm a pending ad when
casting starts, fire it when the receiver confirms, and **disarm on a
15-second timeout**, so an armed ad can never fire against the next cast.

It is also the best-placed ad in the app - the TV is handshaking anyway, so it
costs no real time.

**Stop fires only on a deliberate stop** - the Stop button or Disconnect.
*Not* on the session-ended callback: that fires for a TV switched off, a
dropped network and an errored session as much as for Disconnect, and an ad
after an unplanned disconnection is an ad for a failure. That callback instead
clears the cast state and shows nothing.

**Stop qualifier:** the tier's `minWatchSeconds` of confirmed playback (60 s by
default, 30 s low-CPM), counted from the same signal the success ad waits for.
Something the receiver refuses, or that is abandoned after ten seconds, costs
nothing.

**Both triggers read the one shared clock (§1)**, so:

| Cast length | Ads |
|---|---|
| 2-minute test | 1 (success only - stop falls inside the gap) |
| Full film | 2 (success + stop) |

The gap also covers channel zapping: casting IPTV and changing channel sends a
fresh load each time, and five channels in two minutes would otherwise be five
interstitials.

**Sequencing:** the stop ad has the same closing-screen problem as the player -
the Stop button stops the cast *and then* dismisses the cast controls. Queue,
and show from the controls screen's dismissal callback.

---

## 5. Servers - open and refresh

*Replaces the rewarded refresh wall (1 h free / ad / 24 h expiry). There is no
per-server clock and no wall any more.*

**Triggers:** a media server opened from the Servers list (playlist, Xtream,
SMB share or DLNA device), and a refresh the person pressed (the refresh button
inside a server, or Refresh on a server's card).

**After, never before.** The ad shows once the listing has *loaded*, never in
front of it - an ad between the tap and the thing asked for is an ad for
waiting. A load that fails shows nothing.

**What is not an open:** walking into folders inside a server, and returning
to a playlist that is already open (switching tabs and back). Saving a newly
added server also opens it, but shows nothing - nobody adds a server to be
shown an ad.

**Open and refresh share one unit and the shared clock**, so open-then-refresh
is one ad, not two.

Android: `IptvViewModel.loadedByUser` / `NetworkBrowserViewModel.loadedByUser`
emit on the loaded listing; `ServersScreen` calls `AdManager.showForServer`.
The unit created as "browser" serves this placement (unit ids cannot be
renamed).

---

## 6. Banner

Bottom edge, every screen, **never on the player**. On iOS it is one bottom
safe-area inset applied outermost, so the found-video bar and the cast bar
stack above it for free.

**One long-lived view for the life of the process, never rebuilt per screen.**
Tearing it down and remaking it on each tab switch fires a fresh request every
time, and a tab switch is a two-second action — well inside the 30-second floor
for repeat requests on one unit, which is invalid-traffic territory. A
short-lived view also never survives long enough to reach the server-side
refresh cycle where banner revenue actually accumulates.

**Refresh is 30 s, configured on the unit in the AdMob console — there is no
refresh code**, which is exactly why the decision has to be written down.
30 rather than the usual 60 because banner revenue tracks *visible seconds* and
this app has unusually few of them: the player hides the banner and the player
is where the time goes, so a session leaves only two to four banner-visible
minutes. A shorter cycle converts more of what little there is — eCPM dips as
it shortens, but not proportionally. In an app where somebody sits on one
screen for twenty minutes the session is not the constraint and 60 is fine;
here it is the constraint.

30 is also the floor. Below it, repeat requests on one unit are invalid-traffic
territory — the same number, for the same reason.

Size: anchored adaptive for the current orientation. **Not** the large variant:
it runs to about 100 pt on a phone, and this banner pushes every screen's
content up.

### The cast screen sits above the app, and above the banner's inset

The cast controls are the screen people leave open longest — a film runs two
hours on the television and they come back to these controls repeatedly — so
the banner has to be there too.

It is a **layer inside the shell**, not a presentation over it. The shell's
banner inset is outermost, so the cast page covers every screen and stops at
the banner, which never moves, is never re-parented and never re-requested.

It was a full-screen cover for a while. That hid the shell's banner, so the
page borrowed the one banner view and handed it back on the way out
(`BannerSlot`). Still one banner and one request — never two stacked — but a
hand-over is state to get wrong, and a layer needs none. Android: draw the cast
controls inside the host that owns the banner, not as a second Activity with a
banner of its own.

---

## 7. First sessions

**The first two launches show nothing, banner included.** Somebody who
installs the app, tries it, and comes back once more sees no ads.

Counted in **launches**, not with a timer. Simpler, and strictly more generous:
a timer is burned by backgrounding the app for ten seconds to read a message,
and *"ads start the third time you open it"* is a sentence anybody can check.
Increment a launch counter once at startup, before anything asks; ads are off
while it is `<= 2`.

Two consequences, both accepted:

- **Store review almost certainly sees no ads at all**, since a reviewer works
  in one or two sessions. Good for approval - and the reason the ad paths have
  to be right *before* shipping rather than after.
- Early impressions from install-and-leave users are lost, which is close to
  nothing in revenue.

---

## 8. Consent, tracking, and the launch crash

**iOS: non-personalised only.** `npa=1` registered on every request. No tracking
prompt, tracking declared false in the privacy manifest, and the store
description's "No ad tracking" line stays true. The cost is eCPM.

**Android: personalised.** Android has no tracking prompt to avoid, so it does
not send `npa=1`; the Play Data safety form must then declare the advertising
ID. Consent comes from UMP below (`AdConsent.gather` before `MobileAds`
starts, and a Privacy choices button in About when UMP says it is required).

**A certified CMP is mandatory** regardless of personalisation: without one,
AdMob stops serving EEA and UK traffic altogether. iOS uses Google's UMP —
gather consent *first*, then start the SDK, then preload. Android needs the
same (`com.google.android.ump`).

⚠️ **iOS-only trap, recorded because it already shipped once.** Calling
`ATTrackingManager.requestTrackingAuthorization()` with no
`NSUserTrackingUsageDescription` in `Info.plist` terminates the process
instantly and with no alert — exactly like a missing camera usage string. That
key is deliberately absent, because App Store Connect refuses a build carrying
it unless the privacy answers declare tracking. So the ATT request sits behind
its own flag, which stays false. *"App just opens then closes"* was this.

Android has no equivalent crash, but it does need the advertising-id permission
declared — only if personalisation is ever turned on.

---

## 9. State to persist

| Key | Type | Written when |
|---|---|---|
| `ads.launch_count` | Int | Once per launch, at startup |
| `ads.last.interstitial` | Epoch ms | **Any** interstitial *or app open* is **presented** |
| `ads.last.appOpen` | Epoch ms | An app-open ad is **presented** |
| `ads.last.rewarded` | Epoch ms | A rewarded ad is presented (bookkeeping only; nothing waits on it) |
| `ads.tiers` | JSON | The manifest's `ads` block, cached so an offline launch keeps the last tier |

**Record on presentation, never on request.** A request that found nothing
loaded spent nothing, and the next trigger may try.

All of these are cleared by Clear Data - which is also the fastest way to test.
(Android: `panura_ads` shared preferences - `launches`, `last_interstitial`,
`last_app_open`, `last_rewarded`, `tiers`.)

---

## 10. Invariants an implementation must not break

1. **The user's action always completes.** Every ad callback runs the
   continuation whether an ad appeared or not — no fill, no network, no unit,
   present-failed, or the clock said no. A present-failure is a dismissal as
   far as the app is concerned.
2. **One full-screen ad at a time.** Two presentations racing is a black
   screen, and these *can* collide — a cast confirming while a player closes.
   Guard with a single `presenting` flag.
3. **No ad before or during an action; only after a successful one.**
4. **Never show from a screen that is going away.** Queue, and show from the
   host's dismissal callback.
5. **Separate ad units per placement.** AdMob reports per unit, and one merged
   unit makes "which screen earns" unanswerable. Unit ids cannot be renamed, so
   a unit keeps its original name even when its placement is later redefined.
6. **Test units in every non-release build.** A debug-only guard is not enough:
   TestFlight — and an Android internal-test track — builds Release, so there
   is an explicit flag as well. Shipping a test unit earns zero; tapping your
   own live unit gets the unit limited and the account flagged.

---

## 11. Current status (iOS)

| | |
|---|---|
| Build | All placements implemented, behind `FeatureFlags.adsEnabled` |
| Units served | **Google test units** (`adsUseTestUnits = true`) while 1.1 is tested. ⚠️ Set it false in the build that is submitted; the live ids are all in place |
| Interstitial units | `player` `…/4427286974` (player exit), `cast` `…/6201839976` (cast entry and exit). A third, `browser` `…/6832395366`, exists in AdMob and is deliberately unused |
| Banner unit | `…/5744975130` |
| Rewarded unit | "Server Ads" `…/3135868525` |
| Console | Banner refresh is set to 30 s (done 2026-10-13). App ID `ca-app-pub-6998555111280991~2675221601` matches `GADApplicationIdentifier` |
| ⚠️ Testing a Release build | TestFlight now loads live ads. Do not tap them: register the phone as a test device in AdMob, or set `adsUseTestUnits` back to true for a test build |

### iOS file map

| File | Holds |
|---|---|
| `Sources/Ads/AdPolicy.swift` | *May we* — gaps, first session, the watch qualifier. No ad SDK at all. |
| `Sources/Ads/AdCountryPolicy.swift` | Country tier lookup — reads the manifest's `ads` block and the Store's storefront country, caches gap/qualifier for `AdPolicy` to read synchronously. |
| `Sources/Ads/AdManager.swift` | Loading and presenting. Slots, queue/flush, the banner view. |
| `Sources/Ads/AdConsent.swift` | UMP consent gathering and the privacy-options form. |
| `Sources/Ads/BannerStrip.swift` | The bottom inset and the long-lived banner host. |
| `Sources/Ads/ServerRefresh.swift` | Per-server refresh clocks: free hour, ad due, 24-hour expiry. |

Splitting policy from the SDK is deliberate: every rule about *whether* to show
something reads in one screen, without Google's framework in the picture.
Android should split the same way — the policy half ports almost literally, and
only the manager half is platform code.

### Android translation notes

- `InterstitialAd` / `RewardedAd` / `AdView`, `AdRequest.Builder`,
  `FullScreenContentCallback`,
  `AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize`.
- `npa=1` goes on via
  `AdRequest.Builder().addNetworkExtrasBundle(AdMobAdapter::class.java, bundleOf("npa" to "1"))`.
- Android's existing `AppBannerAd.kt` already has the right shape for a single
  long-lived banner — keep that, drop the rest of the old ad code.
- The "never present from a dismissing screen" rule maps to not calling
  `show()` from a finishing Activity; show from the host once navigation has
  settled.
- Separate AdMob app and separate units throughout: an iOS unit id cannot serve
  Android.
- Same manifest `ads` block, same tier logic (§12) — read the viewer's Play
  Store country (`BillingClient`'s `getBillingConfigAsync` → `countryCode`,
  not a `Locale`), resolve the tier, cache it, and feed it into the same
  gap/qualifier fields Android's `AdPolicy` port already needs.

---

## 12. Country-tiered pacing

**What varies:** the player/cast interstitial gap, and the player/cast watch
qualifier (§3, §4). **What never varies:** the rewarded-refresh gap (§5) — that
lever answers "how much do we trust this feature", not "what is this
impression worth", so it stays fixed everywhere.

### Where the tiers live

The table is server-side, in the `panura` CDN repo's manifest source
(`.manifest-src/manifest.source.json`, `ads` key), built into the deployed
`manifest.json` **unhashed** — country codes aren't hosts, there is nothing to
hide, and a human should be able to read the tiers straight off the served
file. Shape:

```json
"ads": {
  "defaultGapSeconds": 900,
  "defaultMinWatchSeconds": 60,
  "tiers": [
    { "id": "high-cpm", "gapSeconds": 900, "minWatchSeconds": 60, "countries": ["US", "GB", "..."] },
    { "id": "low-cpm",  "gapSeconds": 300, "minWatchSeconds": 30, "countries": ["IN", "PK", "..."] }
  ]
}
```

First matching tier wins; a country in none of them gets the default — which
today equals the high-CPM tier, i.e. unchanged behaviour for most of the
world. Editing the table is a CDN commit, not an app release, same as a site
rule.

### Why a static table, not a live per-user response

Cloudflare Pages serves `public/` as static files; a response that varies per
visitor needs a Worker or Pages Function instead, and that function would only
know the request's **IP country** — a VPN changes that in one tap, which is
exactly the thing being asked to resist. A static table plus a client-side
country lookup is simpler, cacheable, and no weaker against VPNs than the
dynamic version would have been.

### Country source: the Store, not the IP, not the device locale

`Storefront.current.countryCode` (StoreKit 2) — the country the Apple ID's
App Store account is registered to. Changing it means changing the Apple
account, not flipping a toggle. `Locale.current.region` is the fallback for
the rare nil, and is a device setting anyone can edit freely — treated as
strictly weaker.

### VPN users: detect and log, never block

A VPN user's IP country and Store country can disagree. That mismatch is a
*weak* signal — plenty of people genuinely travel, or bought their phone
elsewhere — and the thing it would protect against barely matters:

- Looking poorer than you are (real country low-CPM, Store/VPN says
  high-CPM) costs the user nothing but a slightly longer wait between ads.
- Looking richer than you are gets *more* ads, not fewer, which is not a
  thing anyone exploits for their own benefit.
- AdMob is paid on measured impressions regardless; frequency doesn't create
  revenue that wasn't going to be served anyway, it just paces it.

So there's no case for blocking on mismatch, and a real one: false positives
(travellers, corporate VPNs, misconfigured carriers) would be punished for
nothing. If a signal is ever wanted, Cloudflare's `request.cf.country` vs. the
client-declared country, with `request.cf.asOrganization` flagging obvious
datacenter ASNs, is the available pair — but that requires a Worker in the
request path and a decision about what "log" means for privacy-policy
purposes. Not built, because the stakes don't justify it yet.

### Privacy

No country value — Store, locale, or IP — is sent to any Panura server or
logged anywhere. The lookup is entirely client-side (manifest fetch + local
`Storefront` read); the only persistence is the in-memory cached tier. If that
ever changes — a Worker reading `request.cf.country` for VPN-mismatch
logging, say — the privacy policy needs updating first, not after.

---

## 13. App open

Unit "App Open". **Shown only on a return to the app**, and only when all of
these hold:

- the app was away for **at least 30 seconds** - a glance at a message is not
  opening the app, and the return from a tapped ad leaves the same way;
- **nothing is playing**: no player, no Picture in Picture, no cast. Coming
  back to something playing is coming back for a control;
- no other full-screen ad is up;
- not one of the first two launches;
- **an hour** since the last app open - fixed, not country-tiered: this is the
  one ad nobody did anything to bring on;
- **the shared interstitial gap has passed** - it is full-screen too, so
  closing the player on an ad, leaving for 30 s and coming back is one ad, not
  two. Showing it then resets the shared clock.

**Never on a cold start.** Nothing is loaded that early, and holding the first
screen back for an ad is the version of this format people uninstall over.

An app-open ad expires four hours after it loads; a stale one is dropped and
reloaded rather than shown.

---

## 14. Conversion for the TV — rewarded, added 2026-10-14

A file on the phone that a Chromecast cannot play as it is (several audio
languages, surround or Dolby sound, a QuickTime wrapper, HEVC, HDR, Dolby
Vision) is no longer converted on arrival. The cast screen offers
**Convert and play on TV**, with "A short ad plays while it converts" when one
is due.

- Pressing it starts the conversion **and** the rewarded ad together, so the
  wait and the ad are the same minute.
- Watched to the end: the video goes to the TV. An H.264 file is streamed as it
  converts and starts at once; anything whose picture must be re-encoded waits
  for the whole-file conversion, already under way during the ad.
- Closed early: the conversion is cancelled and the offer comes back.
- No ad available (fill, network, first session): the conversion goes ahead,
  as every rewarded placement grants on failure.
- **No gap.** Each conversion is real work done on request. A copy converted
  before plays without asking again; a streamed file is converted afresh each
  time, so it asks each time.
- Panura on Android TV is never asked: it plays the file as it is, except for a
  Dolby Vision or HDR picture, which it is offered the same way.

Clock: `ads.last.conversion`, recorded only when the ad is earned. Same unit
as the server refresh ("Server Ads").
