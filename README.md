# RedditAIBridge v2.0.0 — iOS "Ghost" tweak for Reddit × CapitalAI

Companion to the **capitalai-amateri** Chrome extension. Runs **inside the
official Reddit iOS app** (`com.reddit.Reddit`, iOS 15+, built for
**Dopamine rootless / iOS 17**) and auto-replies to incoming **private
messages** via the CapitalAI API — but unlike v1, it **never sends anything
over its own HTTP connection**.

## Why v2 exists (the ban problem)

v1 called `oauth.reddit.com` endpoints directly. Reddit's server-side
anomaly detection flags that pattern (own request cadence, non-app request
shape) and accounts get banned. v2 implements the **"Ghost user" method**:

| Layer | v1 (banned) | v2 (Ghost) |
| --- | --- | --- |
| Sending | own HTTP POST to `/api/comment` | types into the **real composer**, presses the **real Send button** |
| Auth | captured bearer token, own requests | app's own session, untouched |
| Headers | captured template | **the app's actual traffic** — nothing to replicate |
| TLS/JA3 | own stack (would need spoofing) | **the app's actual stack** — nothing to spoof |
| Typing indicator | absent (bot tell) | **native** — the app fires it while we "type" |
| Telemetry | absent (bot tell) | **native** — every tracking event the app normally emits fires |

The tweak only makes **two read-only GETs** (`/message/unread`,
`/message/messages/<root>`), and those replay the app's **exact captured
header template** (User-Agent, X-Reddit-*, device IDs — captured live from
the app's own requests, only the Bearer token is refreshed).

## What it does

1. **Token + header capture** — hooks `NSURLSession` task creation/resume;
   reads `Authorization: Bearer …` and the full header set of the app's own
   requests (read-only; nothing is modified, nothing leaves the device).
2. **Poll** — every `pollIntervalSec` (default 180 s, jittered ±20%):
   fetch unread PMs → per-target thread history (last 20 messages).
3. **Think** — randomized 3–12 s pause before typing starts.
4. **Type** — the reply text is typed into the composer in 1–3 char bursts,
   180 ms/char average (±30% jitter), extra pauses at punctuation, occasional
   mid-sentence hesitation; light **haptic taps** while typing; Reddit's own
   `is_typing` indicator runs the whole time.
5. **Send** — presses the real Send button (accessibility activation →
   UIControl actions → synthetic touch, multi-strategy with logging).
6. **Chat swap** — with `autoNavigate` on, it opens the Chat tab, taps the
   right conversation in the inbox itself, replies, and taps Back.
7. **Warm-up** — while idle (~every 5 min): simulates feed scrolling and
   "views" posts for a few seconds; occasional 1–2 min **idle breaks**
   between chatting sessions.
8. **Caps (the anti-ban core)** — daily cap 40, hourly cap 8, per-thread
   cooldown 10 min, ≥ 20 s between replies — **all adjustable in the
   floating 🤖 options bubble**.
9. **Kill-switch** — any **429** halts automation for 12 h, any **403** for
   24 h (both configurable). Manual big-red-stop = master switch in the panel.
10. **Anti-hallucination guard** (extension v1.9.4 parity) — duplicate API
    pieces dropped; nothing after a `?`-ending piece is sent; max 2 pieces
    joined into ONE message.
11. **Transparent AI** — a disclosure line is appended to the first reply of
    every thread (`disclosureFirstReplyOnly` / `disclosureText`).

## The 🤖 options bubble

Floats over the app (drag it anywhere). Contains:

- **MODE**: master switch · dry-run (default **ON** — safe first run) ·
  ghost mode · auto chat-swap · haptics · warm-up · idle breaks ·
  discovery mode
- **SAFETY LIMITS — "how many requests I accept"**: replies/day ·
  replies/hour · per-thread cooldown · poll interval · typing speed ·
  kill-switch length
- **CAPITALAI ACCOUNT**: `licensekey` (masked) + `accountId`
- Buttons: **Force cycle** · **Dump UI tree** · **Typing test** · Close
- Live engine status + last 12 log lines

Changes apply instantly (written to the config plist — no respring).

## Build & install (iOS 17.0.3 + Dopamine)

```bash
cd reddit-capital-ai-tweak
export THEOS=~/theos
make package FINALPACKAGE=1          # THEOS_PACKAGE_SCHEME=rootless is the default
# → packages/com.capitalai.redditbridge_2.0.0_iphoneos-arm64.deb
```

Install via Filza (tap the .deb → Install), then **open Reddit**. The 🤖
bubble appears after ~12 s. Set `licensekey` + `accountId` in the bubble,
keep **Dry-run ON** until you've watched it work, then flip dry-run off.

## First-run tuning (Discovery mode)

Reddit ships different UI per version/locale. The finders are **adaptive
heuristics** (a11y labels: `labelChatTab` "Chat", `labelSend "Send"`,
`labelBack "Back"`), and every step logs what it did:

1. Enable **Discovery mode** in the bubble (or `"discoveryMode" = YES`).
2. Open the Chat tab + one conversation + press Send manually once.
3. Watch syslog (Console.app / `idevicesyslog`), filter `RAB` — the
   `[DUMP]` lines show real view classes, frames and a11y labels.
4. If a finder missed, adjust `labelChatTab` / `labelSend` / `labelBack` in
   the plist for your app language — or send the dump back to me and I tune
   the heuristics for your exact build.

## Config

`/var/mobile/Library/Preferences/com.capitalai.redditbridge.plist` — every
key optional except `licensekey` + `accountId`. Full key list with defaults
is in `RABConfig.m` (single source of truth).

## Honest limitations

- **No test device here** — the code compiles against the real iOS 16.5 SDK
  (arm64) but UI heuristics (composer/send/back/inbox-cell finders, the
  synthetic-touch strategy) are written defensively and MUST be tuned once on
  your device via Discovery mode. The engine never throws; worst case a step
  logs "not found" and aborts that reply.
- **App must be foreground** — the Ghost method drives the real UI, so replies
  happen while the Reddit app is open (that's also what makes the traffic
  pattern human). iOS suspends backgrounded apps anyway.
- **Old-style PMs only** — the new-style Reddit chat API is undocumented;
  unread items with `was_chat` are skipped (logged).
- **Token lifecycle** — tokens expire (~1 h). The engine idles with a log
  message until you open the app again (it grabs the fresh token instantly).
- **Reddit ToS** — automating an account violates Reddit's rules; personal
  use at your own risk. Keep the caps low, disclosure ON, and don't run it on
  an account you can't afford to lose.

## Files

| File | Purpose |
| --- | --- |
| `Tweak.x` | Logos hooks: token/header capture, 429/403 watch, ctor |
| `RABEngine.m` | orchestrator: poll → history → CapitalAI → ghost send, caps, kill-switch, warm-up |
| `RABGhost.m` | UI automation: composer/send/back/tab/cell finders, humanized typing + haptics, scroll warm-up, discovery dump |
| `RABNet.m` | read-only Reddit GETs with replicated headers, CapitalAI call, piece guard |
| `RABConfig.m` | plist config + defaults (single source of truth) |
| `RABPanel.m` | floating 🤖 options bubble + settings panel |
| `RABLog.m` | ring-buffer logger (surfaced in the panel) |

## Ideas / roadmap (what to add next)

- scheduled **quiet hours** (no replies 00:00–08:00)
- **whitelist / blacklist** usernames
- per-persona **tone presets** (CapitalAI model/preset per partner)
- reply **queue viewer** + send-delay slider in the panel
- **stats screen** (replies/day, avg think time, kills)
- **account warm-up scheduler** for fresh accounts (days of light manual-like activity)
- media PMs → pass image URLs into CapitalAI `file[]` (extension v1.9 parity)
- per-subreddit/language persona switching
