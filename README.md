# Email + Calendar

> **Status: in progress.** A personal project I use daily. Demo mode runs without a Google account.

A native macOS 15+ app written in Swift 6, SwiftUI and AppKit. Mail is backed by Gmail, calendars by Google Calendar, and the local cache by SQLite. The week overlay opens from cached data with **⌘F3**: tap to toggle, hold to peek. It scrolls smoothly through days, and switches between a week timeline and a month view.

**Highlights**

- **AI event extraction:** paste a screenshot or a sentence, and the app proposes calendar events with warnings for anything doubtful. Time-zone and weekday checks are done in code, not by the model. [Details and benchmark ↓](#ai-event-extraction-and-benchmark)
- **46-case tiered benchmark** for that feature: simple → context → traps → app controls, run against several models for accuracy, latency and cost.
- **Demo mode:** the real mail and calendar code runs against a fake Gmail and Google Calendar, so you can try everything without signing in.

## Run on your Mac (demo data, no Google account)

1. Install **Xcode 16 or later** and open `EmailCalendar.xcodeproj`.
2. Select the **EmailCalendar** scheme and run. With no Google client ID configured, the app starts in **demo mode**.

Demo mode runs the real mail and calendar code against a fake Gmail and Google Calendar inside the app (`EmailCalendar/Google/MockGoogle`). It comes with a seeded mailbox, four calendars with recurring events, invitations, and an event about 35 minutes after first launch, so the overlay's "Next" line has something to show. Everything works: Screener and its filters, Set Aside, Bubble Up, drafts, sending, search, and creating, editing and RSVPing events. Changes are saved to `~/Library/Containers/ai.bald.EmailCalendar/Data/Library/Application Support/EmailCalendar/Mock/`.

- A few unknown senders arrive after the first sync, so the Screener has something in it.
- **File → Simulate Incoming Email** (⇧⌘M), the menu bar icon, or Preferences delivers another email. Screened-out senders' new mail is caught by their filter.
- **Preferences → Reset demo data** starts over with fresh data, dated relative to today.
- Force a mode with the `EC_MOCK=1` or `EC_MOCK=0` environment variable in the scheme.

## Connect your Google account (later)

1. Create a Google Cloud project, enable the **Gmail API** and **Google Calendar API**, and configure an external OAuth consent screen in **Testing**. Add your own Google address as a test user.
2. Create an OAuth client with application type **Desktop app**. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig`, and fill in its client ID and client secret. The app uses an ephemeral localhost redirect with PKCE; do not create a Web application client.
3. Choose your signing team in **Signing & Capabilities**, and run. Xcode resolves the sole package dependency, [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts).
4. Sign in from the welcome screen. The first mail sync scans all sent-message recipients to seed your approved senders, so a large account can take a while. Calendar sync runs independently. Subsequent syncs use Gmail history and Calendar sync tokens.

The requested scopes are `gmail.modify`, `gmail.settings.basic`, and `calendar`. Tokens are saved in Keychain. OAuth credentials are build settings from the ignored `Secrets.xcconfig`; they are never stored in the mail database.

**Google’s testing-mode limit:** refresh tokens for these scopes normally expire after seven days. The app restores a valid session across restarts and refreshes access tokens, but Google can require another sign-in after that limit or after access is revoked. A Desktop client and a testing consent screen do not remove that Google policy.

For normal use, build a signed app, move it to `/Applications`, and launch it there before enabling launch at login. macOS may require approval in System Settings → General → Login Items. Preferences include the shortcut, overlay height, login item and quiet Bubble Up notifications. Resizing the overlay stores a height for that display.

## Included

- Mail in one centered column with no sidebar: Imbox (new for you / previously seen), Screener, Set Aside (also as a pile at the bottom of the Imbox), Bubble Up, Drafts, Sent, Screened Out, Everything and Calendar, reached from the menu under the logo.
- Threads open as full pages with a floating action bar: Reply Now, Set Aside, Bubble Up, To-do, Archive, More.
- **Days and To-do drawers** beside mail, Ulysses-style: the next seven days on the left, to-dos on the right, one at a time. Slide them with a two-finger swipe, `←` / `→`, the toggles in the top bar, or by clicking a folded drawer's spine. Days is an agenda with a now-line; click an event to see its linked email, open it, or join its call. To-dos are local to this Mac (per account): add, rename (double-click), notes, done, and a folded Completed list.
- **Link email to events and to-dos**: drag a mail row (or an open thread's subject) onto an event, a to-do, or the add field (which makes a new to-do from it). Hovering a dragged email over a folded drawer's spine opens it. Or press `l` and click an event or to-do. Linked threads show a link mark in the list and chips under the subject; events show a mail count; to-dos show the sender. **To-do** (`t`) makes a linked to-do and takes the email out of the Imbox; undo reverses both. Links and to-dos are stored locally with the mail cache.
- Gmail history sync with expired-cursor recovery, full Gmail search, thread reading, compose/reply/reply-all/forward, attachments, Gmail drafts, read state, archive and Trash.
- Sender and domain decisions, all-mail moves, Google rejection filters, and five-second undo that restores each message’s previous labels. Remote-image permission is separate from sender approval.
- Durable Bubble Up times processed on launch and refresh; Gmail labels expose mail states on other devices. Due mail returns at the top when it surfaces, then sorts alongside newer mail.
- Calendar visibility, Day/Week/Month views, expanded recurring events, event creation/editing/deletion, this-event/all-events scope, invitation responses and detected video links.
- A nonactivating, full-width `NSPanel` over Spaces/full-screen apps, selected by mouse display, with tap/hold hotkey, Escape/outside-click/Space dismissal, Reduce Motion, resizing, now-line, live next-event anchor, week navigation and quick event creation.
- **Quick alarms** in the overlay (`A`): one-click 5m–1h presets, or type `10m`, `1h30`, `14:30`, `7pm`, with an optional label. Clicking an empty slot also offers **Alarm** at that time. A due alarm takes over every screen with a flashing red window and a looping beep until you **Snooze** (5 minutes; `S` or Space) or **Stop** (Return or Escape). Alarms survive relaunches; a missed one rings as soon as the app runs again. Pending alarms show in the overlay header and the menu bar, where they can be cancelled.
- **AI add** in the overlay (`I`, or `⌘V` with a screenshot or text on the clipboard): describe an event, paste or drop a screenshot, or upload an image, and Claude Haiku 5.5 (high effort) proposes events, with GPT-6.1 Sol (normal speed, medium reasoning) as the automatic backup if a call fails. `EventAssistant.preferred` swaps the order. Each one shows the weekday, date, time, length and how far away it is, with editable date pickers and warnings for anything doubtful. Time-zone conversion and weekday checks are done in code, not by the model. The AI can also set what the editor offers: a real repeat rule ("every Tuesday for 8 weeks", "weekdays"), the calendar you name, and an alarm when you ask to be reminded; each card shows these as menus you can change. Events already in your calendar at that time are flagged: red for a likely duplicate, orange for an overlap. **Add** saves it to your primary calendar; **Add + alarm** also rings 10 minutes before (09:00 for all-day events). Keys come from Preferences (Keychain), `ANTHROPIC_API_KEY` / `ANTHROPIC_WORKSPACE_ID` / `OPENAI_API_KEY` in `Config/Secrets.xcconfig`, or the environment.
- Sandboxed, ephemeral HTML rendering with JavaScript, forms, frames and remote resources blocked; remote images can be allowed per sender.

The app polls while open and refreshes on focus and wake. Cached mail and events remain available offline; network writes report a failure and keep editable compose/event content open. Quit flushes pending draft edits and waits for a send already in progress. If Gmail cannot save the draft, a local recovery copy (including recipients and attachments) opens in the composer on the next launch or sign-in to that account. There is no offline send queue. Gmail mail deletion only moves mail to Trash; the integration exposes no permanent message deletion endpoint.

## Keyboard

| Key | Action |
| --- | --- |
| `h` | Open the go-to menu; then `1`–`6` for Imbox, Calendar, Screener, Set Aside, Bubble Up, Drafts |
| `j` / `k`, Return | Move through emails, open one (in a thread, `j`/`k` go to the next or previous) |
| `p` | Power Through New: all new mail as one scrolling stack of cards; `j`/`k` jump between cards, `s` marks the one in view seen, Return opens its whole thread |
| `r`, `f`, `c` | Reply, forward, write a new email (reply all is under More) |
| `a` (or `s`) | Set Aside, or take it back |
| `z` (or `b`) | Bubble Up |
| `e`, `m` | Archive, More |
| `←` / `→` | Slide the drawers: Days on the left, To-do on the right (same as a two-finger swipe) |
| `t`, `l`, `+` | Move the email to To-do, link it to an event or to-do, add a to-do |
| `/`, `⌘K` | Search, command palette |
| Escape, `⌘Z` | Back, undo |
| `⌘Return` | Send from the composer |
| `⌘F3` | Toggle the calendar overlay; hold to peek (on most Macs, press fn too unless F-keys are standard function keys) |
| `W` / `M` | Overlay week or month view |
| `←` / `→`, `T`, Escape | Overlay previous/next week (or month), today, dismiss |
| `A`, `I`, `⌘V` | Overlay alarm, AI add, paste a screenshot into AI add |

## Validate

On a Mac, run:

```sh
./scripts/check.sh
```

This runs the platform-neutral tests, then compiles the native app with Xcode without code signing. The core has a separate Swift Package so SQLite, REST, MIME and sync behavior can also be tested on Linux with Swift 6 and SQLite development headers:

```sh
swift test --parallel
```

Tests use temporary databases and mock URLSession transports; they do not touch your Google account.

## AI event extraction and benchmark

**What it does:** in the overlay, press `I` or paste a screenshot. The model proposes events (date, time, length, repeat rule, calendar, reminder), and the app shows them as editable cards. Anything doubtful gets a warning instead of a silent guess: a changed plan, an ambiguous date, an unconfirmed time zone, a likely duplicate. Time-zone conversion, weekday checks and clock-change nights are handled in code; the model only reports what the source says.

**Results** (12 October 2026, 38 cases in tiers 1–3, each run 3 times = 114 answers per setup; selected rows):

| Model · reasoning | Simple | Context | Traps | Overall | Median | $ / 1000 events |
| --- | --- | --- | --- | --- | --- | --- |
| Haiku 5.5 · high | 100% | 100% | 100% | 114/114 | 3.4 s | $0.53 |
| Sol 6.1 · medium | 100% | 100% | 100% | 114/114 | 4.3 s | $4.78 |
| Luna 6 · low | 100% | 100% | 100% | 114/114 | 2.7 s | $0.26 |
| Haiku 5.5 · medium | 100% | 100% | 94% | 112/114 | 3.1 s | $0.48 |
| Luna 6 · none | 100% | 100% | 88% | 110/114 | 2.1 s | $0.23 |

- Every setup passed the simple and context tiers; the traps tier is what separates them.
- The dangerous misses were wrong dates or times with no warning: a meeting moved "to 4:30 the same day" put on today instead of Thursday, and a UTC invite read as Prague time.
- Haiku 5.5 high and Sol 6.1 made no mistakes across all rounds. Haiku is about 9× cheaper and faster, so it is the default, with Sol as the automatic backup.
- After adding tier 4 (app controls, 8 cases), both scored 100% on it.

Small samples: a perfect score over 114 answers does not prove a model never errs. Costs are estimates from published prices.

**Running it:** the live benchmark is skipped by default. It sends the 46 cases in `Tests/Fixtures/EventImages` (fictional screenshots of emails, event pages, chats, tickets and posters, plus typed text, regenerated with `python3 scripts/make_event_fixtures.py`) and compares the results with `cases.json`. Tier 1 is simple, tier 2 needs context (relative dates, durations, time zones, several events), tier 3 is traps (changed plans, cancellations, wrong weekdays, ambiguity that must be flagged), tier 4 is app controls (repeat rules, a named calendar, reminders). Models named `claude-…` use the Anthropic API (`ANTHROPIC_API_KEY`, plus `ANTHROPIC_WORKSPACE_ID` for keys not scoped to a workspace):

```sh
EC_LIVE_AI=1 OPENAI_API_KEY=sk-… EC_AI_MODEL=gpt-6.1-sol EC_AI_REASONING=medium EC_AI_REPEATS=3 \
  EC_AI_JSON=results/gpt-6.1-sol-medium.json swift test --filter LiveEventExtraction
python3 scripts/summarize_event_benchmark.py results
```

The Xcode project is checked in. After adding Swift source files, regenerate it with `python3 scripts/generate_project.py`.

Validated on macOS with Xcode: the app compiles and **all tests pass**, covering SQLite isolation/rollback, OAuth-token retry, MIME/attachments, history and sync-token recovery, sender/filter undo, account-switch cancellation, Bubble Up, drafts/sending, recurrence, invitations and confirmed-write recovery. All 29 app source files passed parsing for the macOS 15 target, and the project references, scheme and resource plists parsed successfully. Native SDK compilation is covered by the added macOS CI workflow but has not run here.

Before treating this as a finished release, verify on your Mac:

- Real OAuth sign-in, token restore after relaunch, and Keychain behavior in a signed build.
- Overlay first-frame latency under 150 ms, over a full-screen app, on multiple displays and Spaces; focus restoration for both taps and peeks.
- Screen an address/domain out and confirm the filter in Gmail on your phone; undo removes it and restores prior labels.
- Compose, Gmail draft continuation, attachment upload/download and reply threading with real mail.
- Calendar recurrence and invitation writes in your own calendars, time-zone/DST transitions, sleep/wake Bubble Up, and notification/login permissions.

The development environment for this implementation is Linux. Core Swift compilation, mock integration tests and macOS source syntax can be checked here; native SDK typechecking, UI execution, real account access and overlay timing require Xcode/macOS.

## Source map

`EmailCalendar/App` owns the shell and main-actor store; `Auth` owns OAuth/Keychain; `Google` owns the REST transport and MIME encoder; `Data` owns SQLite and mail normalization; `Services` owns sync and workflows; `UI` owns mail/calendar views and `UI/Planner` the Days and To-do drawers; `Overlay` owns the AppKit panel. Account IDs namespace persisted data even though v1 connects one account at a time.

The product requirements are in [SPEC.md](SPEC.md).
