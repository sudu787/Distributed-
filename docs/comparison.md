# SyncSphere compared with similar apps

Market survey from web research in October 2026. Feature and pricing facts come from app-store listings and reviews
and may change. **No sync accuracy numbers appear here yet.** None of these apps, SyncSphere included, has been
measured on real phones in this project. The table below is about features, not about how well the apps sync.

## What exists

| App / technology | Platforms | How it works | Strengths | Limits compared with SyncSphere |
|---|---|---|---|---|
| **AmpMe** | Android, iOS | Host starts a party, others join with a code; streaming services and local music | Best known; cross-platform; store listings updated in 2026 | Hosting needs a paid trial or subscription and shows ads; reviews mention price and Bluetooth issues; sync accuracy not published |
| **SoundSeeder** | Android, plus Windows, Linux and Raspberry Pi receivers | Local files over Wi-Fi, offline | Closest to SyncSphere; most often recommended for your own files; up to 16 devices | Free tier limited to 2 speakers for 15 minutes; one-time purchase (about $4); needs very good Wi-Fi; no host takeover |
| **LekSync** | Android | Offline local sync | New, offline | Free tier limited to 2 receivers; accuracy claims are the vendor's own |
| **Rave** | Android, iOS | Internet-based "listen and watch together" | Social features | Needs the internet; reports of freezes; not designed for one room's speakers |
| **Spotify Jam** | Spotify apps | Shared queue for several accounts | Huge user base | Not multi-speaker sync: one account plays on one device at a time |
| **Snapcast** | Linux server, Android client | Open-source time-synced multi-room audio | Very accurate sync | Needs a server (a Pi or PC running MPD or Mopidy); not a phones-only party app |
| **Auracast** (Samsung "Audio Broadcast", Android 16) | Galaxy S23 and newer with One UI 8.5; Android 16 for discovery and control | Bluetooth LE Audio broadcast to any number of listeners | Built in, no app | Listeners need LE Audio earbuds or speakers, not other phones' loudspeakers; Bluetooth range |
| Speaker ecosystems (Sonos, AirPlay 2, Google and Alexa groups, JBL PartyBoost) | Specific hardware | Vendor multi-room | Polished | Need those speakers; phones cannot act as the speakers |

## Where SyncSphere differs

**Rare or unique among phone-only apps:**

- measured clock sync with an uncertainty bound, and drift correction (numbers so far come from simulation)
- automatic host takeover, and handback to the original host
- acoustic "calibrate to this spot"
- exact-seek PCM copies of MP3 files, so phones do not drift apart after a seek
- works fully offline with no account
- open protocol and documentation

**Missing or unproven:**

- no measurements on real phones yet
- Android only
- local files only, no streaming services

## Fair head-to-head test (to do)

Use the same phones, the same Wi-Fi access point and the same audio file for every app.

1. Generate the test file: `python3 tools/make_click_track.py click.wav --minutes 10`. Put the identical file on
   each phone (or on the host only, for apps that stream from the host).
2. Tape one microphone over each phone's speaker. Record on one audio interface with one input per phone, all on a
   shared sample clock. A 2-input interface with 2 lavalier microphones is enough for pairwise runs.
3. For each app, run three times:
   - play from the start and record 5 minutes
   - pause, wait 10 s, resume
   - seek to the middle, where the app supports seeking
4. Analyze each recording: `python3 tools/onset_skew.py run.wav --names a,b --out run.samples.jsonl`, then
   `python3 tools/analyze_samples.py run.samples.jsonl`.
5. Commit the raw recordings or JSONL files under `benchmarks/results/real/<date>-<app>-<setup>/` and fill in the
   table below from those files only.

## Measured results

| App | Phones | Network | Spread after start, median / p95 (ms) | After pause and resume | After seek | Raw data |
|---|---|---|---|---|---|---|
| SyncSphere | – | – | not measured yet | – | – | – |
| SoundSeeder | – | – | not measured yet | – | – | – |
| AmpMe | – | – | not measured yet | – | – | – |

## Sources (October 2026)

- [Best apps to play music on multiple phones (LekSync blog)](https://leksync.in/blogs/best-apps-to-play-music-on-multiple-phones)
- [SoundSeeder on Google Play](https://play.google.com/store/apps/details?id=com.kattwinkel.android.soundseeder.player&hl=en_US), [SoundSeeder on AlternativeTo](https://alternativeto.net/software/soundseeder/about), [APKMirror listing](https://www.apkmirror.com/apk/jekapps/soundseeder-music-player-2-0-share-your-music/)
- [AmpMe on Google Play](https://play.google.com/store/apps/details?id=com.amp.android&hl=en_US), [AmpMe App Store data (AppFollow)](https://apps.appfollow.io/ios/ampme-speaker-music-sync/986905979?country=tw)
- [TechWiser: music sync apps](https://techwiser.com/music-sync-app/)
- [Spotify Community: one account plays on one device](https://community.spotify.com/t5/Your-Library/Play-Spotify-on-more-than-1-local-speaker/m-p/6696273/highlight/true)
- [Snapcast on F-Droid](https://f-droid.org/packages/de.badaix.snapcast/)
- [Samsung: broadcast audio from your Galaxy phone](https://www.samsung.com/us/support/answer/ANS10001042/), [SamMobile: One UI 8.5 Audio Broadcast](https://www.sammobile.com/news/one-ui-8-5-makes-silent-disco-parties-easier-on-galaxy-phones/), [BGR: Android 16 Auracast](https://bgr.com/tech/android-16-will-add-auracast-bluetooths-latest-breakthrough-tech/)
