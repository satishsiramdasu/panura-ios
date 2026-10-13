# Panura ad design

The agreed monetisation design, written once so both platforms implement the
same thing. **iOS is the reference implementation**; Android replicates it.
Android's older ad code — app-open ad, a browser timer, four interstitial
units, rewarded-to-convert — is *not* the model and is being replaced by this.

Settled 2026-10-11. iOS code lives in `Sources/Ads/`.

---

## 1. The whole design in one table

| Placement | Format | Trigger | Qualifier | Gap |
|---|---|---|---|---|
| Player exit | Interstitial | Leaving any player, any engine | country-tiered watch time **or** 25 % of duration | country-tiered |
| Cast entry | Interstitial | Receiver *confirmed* playing, before cast controls appear | — | country-tiered (shared) |
| Cast exit | Interstitial | Deliberate stop/disconnect | country-tiered watch time | country-tiered (shared) |
| Server refresh | **Rewarded** | Refresh pressed on a playlist server | — | 1 h free window, then due |
| Banner | Banner | Every screen except the player, cast controls included | — | 30 s refresh, set on the unit |

Plus two global rules that override all of the above:

- **The entire first session is ad-free**, banner included.
- **No global floor between placements.** Each keeps its own clock and nothing
  else's. Asked for and rejected: the rewarded ad is a button the user pressed,
  so suppressing it because an unrelated interstitial fired two minutes ago
  would withhold a feature they explicitly asked for. These are different
  actions.

Everything else in this document is the reasoning, the edge cases, and the
exact state each rule needs.

---

## 2. What is deliberately absent

| Not built | Why |
|---|---|
| App-open ad | The highest-complaint format there is; it taxes launching the app, which is not a thing we built. |
| Interstitial per video | In-player next/previous walks the playlist without closing the screen, so an exit-triggered ad gives one ad per *session* rather than one between every pair of episodes. The gap length could never have fixed this: episodes run 25–40 min, so any gap worth having is already satisfied when one ends. |
| Interstitial on opening a server | Where this started, and the highest-friction idea in the app: an unrequested ad in front of hardware the user owns. Replaced by refresh-as-reward. |
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

**Gap: country-tiered, 15 min by default.** Barely binds — the real gap for
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

## 4. Cast interstitials — one clock, two triggers

**Entry fires on confirmation, not on request.** The only moment a cast is
known to have worked is when the receiver reports it is playing frames. An ad
for a cast that was refused is an ad for a failure. So: arm a pending ad when
casting starts, fire it when the receiver confirms, and **disarm on a
15-second timeout**, so an armed ad can never fire against the next cast.

It is also the best-placed ad in the app — the TV is handshaking anyway, so it
costs no real time.

**Exit fires only on a deliberate stop** — the Stop button or Disconnect.
*Not* on the session-ended callback: that fires for a TV switched off, a
dropped network and an errored session as much as for Disconnect, and an ad
after an unplanned disconnection is an ad for a failure. That callback instead
**clears both cast clocks** and shows nothing.

**Exit qualifier:** 60 s of confirmed playback, matching the player's. Start
the clock on the same signal the entry ad waits for (first frames reported).
Something the receiver refuses, or that is abandoned after ten seconds, costs
nothing.

**The shared clock is the point.** Both triggers read one `cast` clock
(country-tiered, 15 min by default — see §12), so:

| Cast length | Ads |
|---|---|
| 2-minute test | 1 (entry only — exit falls inside the gap) |
| Full film | 2 (entry + exit) |

Separate clocks would put two full-screen ads either side of a three-minute
clip.

The gap also exists for channel zapping: casting IPTV and changing channel
sends a fresh load each time, and five channels in two minutes would otherwise
be five interstitials.

**Sequencing:** the exit ad has the same closing-screen problem as the player —
the Stop button stops the cast *and then* dismisses the cast controls. Queue,
and show from the controls screen's dismissal callback.

---

## 5. Server refresh — the rewarded placement

Playlist servers only (M3U / Xtream). **Not** SMB/SFTP/FTP: those list live
every time a folder is opened, so "refresh" there is just re-listing, and a
daily ad to re-read your own NAS is a toll with a nicer name.

One timestamp per server — *the last time the user refreshed*, meaning the last
time an ad was shown or waived — answers all three rules:

```
< 1 h       refresh is free, unlimited presses   — a retry is never punished
1 h – 24 h  refresh plays a rewarded ad          — voluntary
> 24 h      refresh is required                  — catalogue is not shown at all
```

### Why its own timestamp, and not the catalogue's fetch time

The obvious candidate is wrong. The store already re-fetches anything older
than its freshness window (3 h on iOS) by itself, and resets the fetch time as
it does — so a 24-hour wall built on that field would never appear. This is a
separate, user-driven clock, and **only a user-pressed refresh moves it.**

### Starting the clock

Stamped on the *first successful load* of a server, and only if not already
set. A server that has never been refreshed is **not** expired: meeting a wall
before ever seeing a channel reads as a broken app, not as a stale catalogue.

Stamp **before** the fetch, not after — otherwise a provider being down wastes
an ad the user has already watched.

Drop a server's timestamp when the server is deleted, so re-adding the same
address does not inherit a wall from the one before it.

### The expiry wall

After 24 h the content is **deleted, not hidden** — channels, movies, series,
and every section's cache file. So the screen is not withholding a list it is
quietly holding; there is no list. A hard wall was chosen over a prompt:
*"we don't show content, instead we show a message… What user left is to press
refresh."*

The wall is: an icon, "Catalogue expired", an age-aware line explaining that
provider catalogues go stale, one filled **Refresh** button, and — only when
an ad is actually due — the line **"A short ad plays first."**

Naming the ad before it plays is not politeness, it is the rewarded format's
rule: the reward has to be described before the ad. A screen whose only control
is Refresh would otherwise be an interstitial with a reward unit's paperwork.
Backing out of the server is the decline path.

### The free hour is anchored to the last ad, not the last refresh

This is the one thing in the design that is easy to get backwards, and getting
it backwards makes the rewarded ad **unreachable**.

The per-server timestamp moves on *every* refresh — it has to, because it also
drives the 24-hour wall and the catalogue really was just refreshed. So "has an
hour passed since the last refresh" is a question that can never answer yes to
anybody who refreshes more than once an hour: pressing the button resets the
clock the button is waiting on.

Gate the ad on the **ad** clock — one hour since the last rewarded ad was
*shown* — which pressing Refresh does not touch. That gives exactly the agreed
behaviour: an ad, then an hour of unlimited free refreshes, then the next ad.

The per-server timestamp still has two jobs, neither of them the hour: the
24-hour expiry, and "has this server ever loaded" (nothing is owed by somebody
who has not finished opening it once).

iOS shipped the wrong version of this for one build. The symptom is the
tell — every other placement fires, the rewarded gap reads *ready*, and the ad
never comes.

### One door

Any other reload affordance — a toolbar refresh glyph, pull-to-refresh — must
route through the *same* gated function. Two doors means the clock can be
walked round by using the other one.

### Grant on failure — the rule that keeps a wall from becoming a lock

The reward is granted when **no ad could be shown at all**: no fill, no
network, no unit configured, ads switched off, or no ad due. Fill is our
problem, not the user's — a server they added, on hardware they own, must never
stay shut because an ad network had a bad minute.

The reward is withheld **only** when somebody opened the ad and closed it
early. Nothing is taken away; the button is still there.

And **only a watched ad spends the hour.** Closing one early leaves the clock
alone, so the next press still has something to offer.

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

### The cast screen is the one page that claims it

The cast controls are presented *over* the shell, so the shell's banner is
behind them and the screen would otherwise be the one ad-free surface in the
app that people leave open longest — a film runs two hours on the television
and they come back to these controls repeatedly. So that page carries the
banner along its own bottom edge.

It is the **same** view, not a second one. A second banner would mean a second
request per appearance on the same unit, which is the 30-second-floor problem
above. So ownership is explicit: the shell draws the banner while nothing has
claimed it, and a page over the shell claims it on appear and releases it on
disappear (`BannerSlot` on iOS). One state change hands it over, which avoids
two strips racing to adopt the same view and one of them showing an empty gap.

Claims do not stack, deliberately — one page over the shell is the whole of the
need, and the cast page is never presented from another page that has a banner.

---

## 7. First session

**The entire first session shows nothing, banner included.** Somebody who
installs the app, watches one thing and leaves sees no ads — and was never
going to earn anything either way.

Counted in **launches**, not with a timer. Simpler, and strictly more generous:
a timer is burned by backgrounding the app for ten seconds to read a message,
and *"ads start the second time you open it"* is a sentence anybody can check.
Increment a launch counter once at startup, before anything asks; ads are off
while it is `<= 1`.

Two consequences, both accepted:

- **App Review almost certainly sees no ads at all**, since a reviewer works in
  one session. Good for approval — and the reason the ad paths have to be right
  *before* shipping rather than after.
- Day-one impressions from install-once-and-leave users are lost, which is
  close to nothing in revenue.

---

## 8. Consent, tracking, and the launch crash

**Non-personalised only.** `npa=1` registered on every request. No tracking
prompt, tracking declared false in the privacy manifest, and the store
description's "No ad tracking" line stays true. The cost is eCPM.

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

Five keys and nothing else. All plain preferences.

| Key | Type | Written when |
|---|---|---|
| `ads.launch_count` | Int | Once per launch, at startup |
| `ads.last.player` | Epoch seconds | A player-exit interstitial is **presented** |
| `ads.last.cast` | Epoch seconds | A cast interstitial is **presented** (either trigger) |
| `ads.last.servers` | Epoch seconds | A rewarded ad is **earned** |
| `server.refreshed.<server id>` | Epoch seconds | First successful load, and every user refresh |

**Record on presentation, never on request.** A failed load that spent the gap
would also spend the next genuine chance with it.

All of these are cleared by Clear Data — which is also the fastest way to test
without waiting an hour.

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
| Units served | **Google test units everywhere** (`adsUseTestUnits = true`) |
| Interstitial units | Three live units exist in AdMob |
| Banner unit | ⚠️ not created yet — real id is empty, so the banner draws nothing |
| Rewarded unit | ⚠️ not created yet — real id is empty, so refresh is granted free |
| Before submitting | `adsUseTestUnits = false`; both missing units created; banner refresh set to 30 s in the console; `GADApplicationIdentifier` verified against the AdMob app |

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
