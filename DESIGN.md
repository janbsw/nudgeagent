# Nudge Agent: Design

A macOS menu bar app for people with ADHD. The user sets a goal ("Find 20 qualified fintech leads and add them to Attio", "Finish the pitch deck by 5pm"). The app watches what is on screen, judges whether the current activity serves that goal, and gently nudges the user back when they drift.

Status: design agreed, not yet implemented.

## Decisions

| # | Decision | Notes |
|---|---|---|
| 1 | **Tiered sensing** instead of fixed-interval screenshots or recording | Cheap signals run continuously; expensive checks only when unsure |
| 2 | **Trips, not windows** | A trip away from the work is judged as a whole (where it started, the chain of hops, return, copy and paste) |
| 3 | **Task-agnostic** | Every task has an output, sources and tools. Every judgment depends on the current goal. No global block lists |
| 4 | **Screenshots for any app**, active window only | On-device text recognition first; image goes to a vision model only when there is too little text |
| 5 | **No browser extension in the MVP** | URLs via AppleScript (Chrome, Safari, Arc, Edge, Brave) and Accessibility (Firefox), screenshot as fallback |
| 6 | **Native Swift menu bar app**, macOS 14+ | Almost every sensor is a macOS system feature |
| 7 | **No backend** | Runs entirely on the Mac; only LLM calls leave the device |
| 8 | **Cloud models** for text and vision | Claude Haiku 5.5 (`claude-haiku-5-5`) behind a swappable gateway |
| 9 | **Team-internal** for now | Each user enters an API key, stored in the Keychain |

## Architecture

```
SENSORS ──► CONTEXT BUILDER ──► TRIP TRACKER ──► CLASSIFIER CASCADE ──► DRIFT ENGINE ──► NUDGE UI
                                                       ▲
GOAL SETUP ──► TASK PROFILE ───────────────────────────┘

Local SQLite: profiles, corrections, cache, session log (never images)
LLM gateway: one interface, provider behind it
```

### 1. Sensors

| Sensor | Source |
|---|---|
| App switches | `NSWorkspace.didActivateApplicationNotification` |
| Window titles | Accessibility API (focused window title), checked every ~5 s |
| Browser URL | AppleScript (Chromium browsers, Safari); Accessibility address bar for Firefox |
| Idle, lock, sleep | `CGEventSource` seconds since last input; lock and sleep notifications |
| Copy and paste | `NSPasteboard.changeCount` (detects a copy, never reads content) |
| Output file changes | FSEvents on files named in the task profile |
| Meetings | Zoom, Teams or Meet frontmost, or microphone in use |
| Screenshot | ScreenCaptureKit, active window only, in memory |
| Text recognition | Vision framework (`VNRecognizeTextRequest`), on device |

A context only counts after a short dwell (a few seconds), so a fast Cmd+Tab past a distraction is ignored.

### 2. Context builder

Turns sensor events into one record per moment: bundle id, app name, cleaned title (unread counts like "(3)" removed), URL, domain, URL path, search query (parsed from `q=` and similar), timestamps.

### 3. Trip tracker

Three states:

| State | Meaning | Behavior |
|---|---|---|
| Anchored | In the output or a confirmed source/tool | Quiet |
| Excursion | Away, still plausibly working | Quiet, keeps scoring |
| Drifting | The trip has lost its connection to the goal | Drift engine counts time |

Builds a **trip summary** for the classifier: goal, where the trip started, chain of hops (titles, domains, queries), time away, copy events, whether the output changed on return.

Evidence that a trip is work, strongest first:
1. Copy in a source, then the output changes
2. Return to the output with an edit within a few minutes
3. Search query or page topic matches the goal or the output's content
4. Hop inherits relevance from the previous hop, weakening with each step
5. Behavior pattern (short scans and typing vs. endless scrolling or autoplay)

### 4. Classifier cascade

Each step runs only if the previous one is unsure. Result: `on_task | supporting | neutral | off_task | unsure` with a confidence.

1. **User corrections** ("this IS relevant") for this goal
2. **Profile rules**: bundle id, domain, URL path, title keywords
3. **Cache** keyed by bundle id + domain/path + cleaned title
   - Stable contexts (a named file): whole session
   - Changing contexts (Slack, Mail, search pages, feeds): ~10 min
4. **Text LLM** with goal + profile + trip summary
5. **Screenshot**, when step 4 is unsure and dwell is 60 s or more, or as a spot check every 5 to 10 min during long stays in changing apps
   - Skip if the image is nearly identical to the last check
   - Text recognition on device, then back to the text LLM
6. **Vision LLM** only if the recognized text is too thin (design tools, video, images, charts)

Expected volume per user per day: ~50 to 100 text calls, a small number of image calls.

### 5. Goal setup and task profile

The user writes one sentence. The LLM proposes a profile, the user confirms or edits it on one screen. Follow-up questions only when the LLM is unsure.

```json
{
  "goal": "Find 20 qualified fintech leads in DACH and add them to Attio",
  "type": "research",
  "output": [{ "app": "Attio", "match": ["app.attio.com"] }],
  "sources": ["linkedin.com/in/*", "linkedin.com/sales/*", "apollo.io", "company websites", "google.com/search"],
  "tools": ["Excel", "Google Sheets"],
  "drift": ["linkedin.com/feed", "news sites", "email not about leads"],
  "target": { "count": 20, "unit": "leads" },
  "deadline": "2026-11-16T17:00"
}
```

Task types and defaults:

| Type | Examples | Working looks like | Typical drift |
|---|---|---|---|
| Create | Deck, memo, code, design | Output changes | Anything outside sources |
| Research | Leads, market research, due diligence | Source to output moves, records grow | Feeds, rabbit holes |
| Process | Inbox zero, admin, expenses | Items done | Reading without acting |
| Communicate | Follow-ups, outreach | Messages sent | Other threads |
| Learn | Course, long report | Steady reading in one place | Jumping around |

A session can have several outputs (for example a deck and the Excel model that feeds it).

### 6. Drift engine

- Nudge on **sustained** drift: 1.5 min off task within a 10 min rolling window (default, adjustable)
- Every excursion gets 1.5 min grace unless clearly off task for this goal
- Ladder: notification, then a card 1 min later, then the next step 1.5 min after that, repeats every 3 min; at least 1 min between nudges
- Unclear context: one-tap question after 1.5 min; screenshot check after 30 s
- Pauses: break button, meetings, "working offline" button, idle, lock
- Unsure for a few minutes: ask with one tap instead of nudging

### 7. Nudge UI

Escalation ladder:
1. Menu bar icon changes color
2. Notification: "Still on the lead search? 2h left."
3. Floating card with **"Back to X"**, which brings the output app, file or URL to the front
4. (Opt-in) sound or stronger card

Tone: curious, never shaming. Every nudge offers "This is relevant", "Snooze" and "Take a break". Answers feed the corrections store.

Extras:
- **Parking lot** hotkey to dump a thought and return to work
- **Progress**: counter for count goals (hotkey or detected), output activity
- **Session recap**: focused time, drift count, where drift went; factual, no guilt
- **Task queue**: finishing one goal suggests the next

### 8. Privacy

- Screenshots in memory only, never written to disk; only recognized text or a shrunk image is sent
- Never captured: password managers, banking, Messages, WhatsApp, private and incognito windows (by bundle id or title), plus a user list
- Windows that hide themselves from capture (for example 1Password) stay hidden
- Clipboard: only the change counter is read, never content
- Session log stores classifications and metadata, no page content

### 9. Permissions

Screen Recording, Accessibility, Automation (per browser), Notifications. Onboarding explains each one in plain language.

### 10. Team distribution

- Signed with a Developer ID and notarized, shared as a download
- API key entered on first launch, stored in the Keychain

## Not in the MVP

- Browser extension (Firefox and Chromium share one codebase when added)
- Backend (needed only if this becomes a product: key handling, usage)
- Local models (the gateway allows adding them)
- Windows support
- Integrations: Office progress via AppleScript, Attio and HubSpot APIs, GitHub

## Build steps

| Step | Scope | Done when |
|---|---|---|
| 0 | Skeleton: menu bar app, settings, Keychain key, SQLite, permission onboarding | App launches, permissions granted, key saved |
| 1 | Sensors + context builder + live debug window | Team sees a correct live stream of app, title, URL, query, idle for a day of real work |
| 2 | Goal setup + task profile + confirmation screen | Five real goals produce sensible profiles |
| 3 | Classifier steps 1 to 4 + trip tracker (no screenshots) | Labeled day of real work classified with acceptable accuracy; "unsure" rate measured |
| 4 | Drift engine + nudge UI + feedback buttons | Team uses it for real; nudges feel fair |
| 5 | Screenshots + on-device text recognition + vision LLM | "Unsure" rate drops; cost per day measured |
| 6 | Parking lot, breaks, meetings, progress, recap | Full MVP |
| 7 | Team dogfooding, two weeks | Metrics below reviewed |

Metrics to watch during dogfooding:
- False nudges (user pressed "This is relevant")
- Nudge acceptance (user pressed "Back to X" or returned within a minute)
- Unsure rate per classifier step
- LLM cost per user per day
- Whether people keep it running after the first week
