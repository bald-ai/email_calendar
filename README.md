# Email + Calendar

> **Status: in progress.** A personal project I use daily. A Google account is required for mail and calendars.

A native macOS 15+ app written in Swift 6, SwiftUI and AppKit. Mail is backed by Gmail, calendars by Google Calendar, and the local cache by SQLite. The week overlay opens from cached data with **⌘F3**: tap to toggle, hold to peek. It scrolls smoothly through days, and switches between a week timeline and a month view.

**Highlights**

- **AI event extraction:** paste a screenshot or a sentence, and the app proposes calendar events with warnings for anything doubtful. Time-zone and weekday checks are done in code, not by the model. [Details and benchmark ↓](#ai-event-extraction-and-benchmark)
- **73-case tiered benchmark** for that feature: simple → context → traps → app controls, including multiple screenshots and text corrections, with repeated runs for accuracy, latency and cost.

## Run on your Mac

Install **Xcode 16 or later** and open `EmailCalendar.xcodeproj`. Configure Google access before running:

1. Create a Google Cloud project, enable the **Gmail API** and **Google Calendar API**, and configure an external OAuth consent screen in **Testing**. Add your own Google address as a test user.
2. Create an OAuth client with application type **Desktop app**. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig`, and fill in its client ID and client secret. The app uses an ephemeral localhost redirect with PKCE; do not create a Web application client.
3. Choose your signing team in **Signing & Capabilities**, or, without a team, set `CODE_SIGN_STYLE = Manual` and a local code-signing certificate as `CODE_SIGN_IDENTITY` in `Secrets.xcconfig` (an ad-hoc signed build changes with every rebuild, so the Keychain asks for access again each time). Select the **EmailCalendar** scheme and run. Xcode resolves the sole package dependency, [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts).
4. Sign in from the welcome screen. The first mail sync scans all sent-message recipients to seed your approved senders, so a large account can take a while. Calendar sync runs independently. Subsequent syncs use Gmail history and Calendar sync tokens.

Without a configured Google client ID, the app stays at the welcome screen and shows configuration guidance. Existing Google sessions are restored on subsequent launches.

The requested scopes are `gmail.modify`, `gmail.settings.basic`, and `calendar`. Tokens are saved in Keychain. OAuth credentials are build settings from the ignored `Secrets.xcconfig`; they are never stored in the mail database.

**Google’s testing-mode limit:** refresh tokens for these scopes normally expire after seven days. The app restores a valid session across restarts and refreshes access tokens, but Google can require another sign-in after that limit or after access is revoked. A Desktop client and a testing consent screen do not remove that Google policy.

For normal use, build a signed app, move it to `/Applications`, and launch it there before enabling launch at login. macOS may require approval in System Settings → General → Login Items. Preferences include the shortcut, overlay height, login item and quiet Bubble Up notifications. Resizing the overlay stores a height for that display.

## Included

- Mail in one centered column with no sidebar: Imbox (new for you / previously seen), Screener, Set Aside (also as a pile at the bottom of the Imbox), Bubble Up, Drafts, Sent, Screened Out, Spam, Everything and Calendar, reached from the menu under the logo.
- Previously Seen puts bubbled-up conversations first, newest return first, then sorts the rest by when each conversation most recently became read. Opening unread mail, Seen, and marking it read record that time; reopening read mail leaves it in place. Reads in other apps use the time this app detects them during sync. Mail already read before tracking began stays below tracked mail, ordered by message date, unless it bubbles up. Seen times are stored per account on this Mac.
- Threads open as full pages with a floating action bar: Reply Now, Set Aside, Bubble Up, To-do, Archive, More.
- **Days and To-do drawers** beside mail, Ulysses-style: the next seven days on the left, to-dos on the right, one at a time. Slide them with a two-finger swipe, `←` / `→`, the toggles in the top bar, or by clicking a folded drawer's spine. Days is an agenda with a now-line; click an event to see its linked email, open it, or join its call. To-dos are local to this Mac (per account): add, rename (double-click), notes, done, and a folded Completed list.
- **Link email to events and to-dos**: drag a mail row (or an open thread's subject) onto an event, a to-do, or the add field (which makes a new to-do from it). Hovering a dragged email over a folded drawer's spine opens it. Or press `l` and click an event or to-do. Linked threads show a link mark in the list and chips under the subject; events show a mail count; to-dos show the sender. **To-do** (`t`) makes a linked to-do and takes the email out of the Imbox; undo reverses both. Links and to-dos are stored locally with the mail cache.
- Gmail history sync with expired-cursor recovery, full Gmail search, thread reading, compose/reply/reply-all/forward, attachments, Gmail drafts, read state, archive and Trash.
- **HTML email with pasted screenshots**: email goes out as HTML with a plain-text copy, Gmail-style. Paste (⌘V), drop or choose images and they sit between paragraphs at full resolution, scaled to fit while writing; ⌘Z removes an accidental paste; dropped files that aren't images become attachments. Pasted web content arrives as plain text. Replies and forwards add the quoted original (with its inline images) when saved or sent; while writing it is shown as plain text only, so its remote images never load. Reopened drafts, including ones started in Gmail elsewhere, come back with their text, images and quote; formatting the editor can't show is simplified, and the composer says so. The composer shows the running size against Gmail's 25 MB limit.
- **Send mail as**: verified Gmail "Send mail as" addresses appear as a From menu in the composer. Replies and forwards go out from the address the original was sent to (so mail forwarded in from another account is answered from that account), and none of your addresses get a copy of a reply-all.
- **Spam**: Gmail's Spam folder with an unread count in the menu. Move to Spam, Not spam (back to the Imbox, approving the sender if it had no decision yet) and Trash, all undoable and mirrored in Gmail. Searching from Spam searches only Spam. A conversation is hidden from other mailboxes only when every message in it is spam.
- **Select several emails**: ⌘-click, ⇧-click for a range, hover a row and click the circle beside the avatar, or press `x` / `⇧J` / `⇧K` / `⌘A`. While anything is selected a bar at the bottom offers Archive, Set Aside, Bubble Up, Mark read or unread, Spam and Trash for all of them (also in the right-click menu, the command palette and the usual keys `e`, `a`, `z`), and a plain click picks rows instead of opening them. One Undo reverses the whole batch; if a few fail, the rest still go through and the app says how many didn't. In the Screener the same selection gives Yes or No for several senders at once.
- Sender and domain decisions, all-mail moves, Google rejection filters, and five-second undo that restores each message’s previous labels. Remote-image permission is separate from sender approval.
- Durable Bubble Up times processed on launch and refresh; Gmail labels expose mail states on other devices. Bubbled-up mail takes priority within its Imbox section, newest return first, including already-read mail in Previously Seen.
- Calendar visibility, Day/Week/Month views, expanded recurring events, event creation/editing/deletion, this-event/all-events scope, invitation responses and detected video links.
- A nonactivating, full-width `NSPanel` over Spaces/full-screen apps, selected by mouse display, with tap/hold hotkey, Escape/outside-click/Space dismissal, Reduce Motion, resizing, now-line, live next-event anchor, week navigation and quick event creation.
- **Quick alarms** in the overlay (`A`): one-click 5m–1h presets, or type `10m`, `1h30`, `14:30`, `7pm`, with an optional label. Clicking an empty slot also offers **Alarm** at that time. A due alarm takes over every screen with a flashing red window and a looping beep until you **Snooze** (5 minutes; `S` or Space) or **Stop** (Return or Escape). Alarms survive relaunches; a missed one rings as soon as the app runs again. While an alarm is less than four hours away the Mac doesn't idle-sleep (closing the lid still sleeps it, and the sound follows the system volume). Pending alarms show in the overlay header and the menu bar, where they can be cancelled.
- **AI add** in the overlay (`I`, or `⌘V` with a screenshot or text on the clipboard): describe an event, paste or drop a screenshot, or upload an image, and GPT-6.1 Terra (normal speed, low reasoning) proposes events, with Claude Haiku 5.5 (medium effort) as the automatic backup if a call fails. `EventAssistant.preferred` swaps the order. Each one shows the weekday, date, time, length and how far away it is, with editable date pickers and warnings for anything doubtful. Time-zone conversion and weekday checks are done in code, not by the model. The AI can also set what the editor offers: a real repeat rule ("every Tuesday for 8 weeks", "weekdays"), the calendar you name, and an alarm when you ask to be reminded; each card shows these as menus you can change. Events already in your calendar at that time are flagged: red for a likely duplicate, orange for an overlap. **Add** saves it to your primary calendar; **Add + alarm** also rings 10 minutes before (09:00 for all-day events). Keys come from Preferences (Keychain), `ANTHROPIC_API_KEY` / `ANTHROPIC_WORKSPACE_ID` / `OPENAI_API_KEY` in `Config/Secrets.xcconfig`, or the environment.
- Sandboxed, ephemeral HTML rendering with JavaScript, forms, frames and remote resources blocked; remote images can be allowed per sender.

**Undo Send**: Send saves the complete email as a Gmail draft and starts a 30-second countdown ("Sending in 24s · Subject · Undo") shown over mail and calendar; several emails count down independently, and clicking one opens a read-only preview. Undo reopens the draft for editing. At zero Gmail sends that exact draft, with the same duplicate protection as before, and "Sent" links to the sent copy. Quit waits for pending emails (with Send now and Undo still available). Mail that was due while the Mac slept or the app was closed is never sent late without review: it stays at the top of the Imbox with Review, Retry (a fresh countdown) and Move to Drafts. A send interrupted after reaching Gmail is looked up in Sent instead of being retried.

The app polls while open and refreshes on focus and wake. Cached mail and events remain available offline; network writes report a failure and keep editable compose/event content open. Quit flushes pending draft edits and waits for pending sends. If Gmail cannot save the draft, a local recovery copy (including recipients and attachments) opens in the composer on the next launch or sign-in to that account. Save & close while Gmail can't be reached keeps the email on this Mac and closes the composer; each refresh (and the next launch) tries again until it reaches Drafts. There is no offline send queue. Gmail mail deletion only moves mail to Trash. The only permanent removal is the composer's **Discard** (after a confirmation), which deletes that unsent draft, as Gmail's own Discard does.

## Keyboard

| Key | Action |
| --- | --- |
| `h` | Open the go-to menu; then `1`–`6` for Imbox, Calendar, Screener, Set Aside, Bubble Up, Drafts |
| `j` / `k`, Return | Move through emails, open one (in a thread, `j`/`k` go to the next or previous) |
| `p` | Power Through New: all new mail as one scrolling stack of cards, each ending in Reply, Set Aside, Bubble Up, Archive and Seen; long emails stop at Show full email; `j`/`k` jump between cards, `s` marks the one in view seen, Return opens its whole thread |
| `r`, `f`, `c` | Reply, forward, write a new email (reply all is under More) |
| `a` (or `s`) | Set Aside, or take it back |
| `z` (or `b`) | Bubble Up |
| `e`, `m` | Archive, More |
| `x`, `⇧J` / `⇧K`, `⌘A` | Select the email in focus, grow the selection down or up, select all; `e`, `a`, `z` then act on every selected email, Escape clears |
| `←` / `→` | Slide the drawers: Days on the left, To-do on the right (same as a two-finger swipe) |
| `t`, `l`, `+` | Move the email to To-do, link it to an event or to-do, add a to-do |
| `/`, `⌘K` | Search, command palette |
| `⌘R` | Refresh mail and calendar |
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

**Historical results, not scores on the current suite** (12 October 2026, 38 cases in tiers 1–3, each run 3 times = 114 answers per setup; selected rows):

| Model · reasoning | Simple | Context | Traps | Overall | Median | $ / 1000 requests |
| --- | --- | --- | --- | --- | --- | --- |
| Haiku 5.5 · high | 100% | 100% | 100% | 114/114 | 3.4 s | $0.53 |
| Sol 6.1 · medium | 100% | 100% | 100% | 114/114 | 4.3 s | $4.78 |
| Luna 6 · low | 100% | 100% | 100% | 114/114 | 2.7 s | $0.26 |
| Haiku 5.5 · medium | 100% | 100% | 94% | 112/114 | 3.1 s | $0.48 |
| Luna 6 · none | 100% | 100% | 88% | 110/114 | 2.1 s | $0.23 |

- Every setup passed the simple and context tiers; the traps tier is what separates them.
- The dangerous misses were wrong dates or times with no warning: a meeting moved "to 4:30 the same day" put on today instead of Thursday, and a UTC invite read as Prague time.
- Haiku 5.5 high and Sol 6.1 made no mistakes across those historical rounds. That originally led to Haiku high as the default. After the expanded October 29 comparison, the app uses Terra 6.1 low first and Haiku 5.5 medium as backup; see the [current results](Dev/benchmark-results/2026-10-29-v2/README.md).
- After adding tier 4 (app controls, 8 cases), both scored 100% on it.

Small samples: a perfect score over 114 answers does not prove a model never errs. Costs are estimates from published prices.

**Current suite:** version `2026-10-29-v2` has 73 cases. The previous fixture file actually contained 49 cases despite the old 46-case label. The revision adds 24 cases and tightens the existing expectations. See [the benchmark protocol](Dev/event-extraction-benchmark.md) for coverage, scoring, limitations and the low → medium → high stopping rule.

**Running it:** the live benchmark is skipped by default. It sends fictional screenshots and typed text from `Tests/Fixtures/EventImages`, using the production prompt and parser, and compares the resulting event proposals with `cases.json`. Screenshot fixtures can be regenerated with `python3 scripts/make_event_fixtures.py`. Tier 1 is simple, tier 2 needs context, tier 3 contains traps, and tier 4 covers app controls and combined input. Models named `claude-…` use the Anthropic API (`ANTHROPIC_API_KEY`, plus `ANTHROPIC_WORKSPACE_ID` for keys not scoped to a workspace). Set the selected provider's key in the environment, then choose a model explicitly:

```sh
EC_LIVE_AI=1 EC_AI_MODEL=MODEL_ID EC_AI_REASONING=low EC_AI_REPEATS=3 EC_AI_PARALLEL=1 \
  EC_AI_JSON=results/MODEL_ID-low.json swift test --filter LiveEventExtraction
python3 scripts/summarize_event_benchmark.py results
```

The Xcode project is checked in. After adding Swift source files, regenerate it with `python3 scripts/generate_project.py`.

Validated on macOS with Xcode on 28 October 2026: the automated suite passes, and both Debug and signed universal Release builds compile. Regression coverage includes SQLite isolation/rollback, OAuth-token retry, MIME/attachments, history and sync-token recovery, sender/filter undo, account-switch cancellation, Bubble Up, drafts/sending, recurrence, invitations and confirmed-write recovery. The latest run also covers preserving another composer's recovery checkpoint when saving a parked draft, closing a discarded draft after a failed follow-up refresh, and zero-minute reminders at midnight.

Native app checks covered long/short HTML rendering, expansion and collapse, Power Through navigation and selection, sender details, manual refresh, draft autosave, Undo Send, and pending-send previews. Live Gmail-to-HEY delivery preserved Czech text and a Unicode attachment filename; the received 4 MiB attachment matched the original SHA-256. Google Calendar timed/all-day edits and the midnight reminder were checked against the connected account. Temporary calendar data and sender-screening changes were cleaned up. Mouse-wheel automation was unavailable; HTML scrolling was exercised through accessibility scroll actions and native layout measurements.

Before treating this as a finished release, verify on your Mac:

- Real OAuth sign-in, token restore after relaunch, and Keychain behavior in a signed build.
- Overlay first-frame latency under 150 ms, over a full-screen app, on multiple displays and Spaces; focus restoration for both taps and peeks.
- Screen an address/domain out and confirm the filter in Gmail on your phone; undo removes it and restores prior labels.
- Calendar recurrence and invitation writes in your own calendars, time-zone/DST transitions, sleep/wake Bubble Up, and notification/login permissions.

## Source map

`EmailCalendar/App` owns the shell and main-actor store; `Auth` owns OAuth/Keychain; `Google` owns the REST transport and MIME encoder; `Data` owns SQLite and mail normalization; `Services` owns sync and workflows; `UI` owns mail/calendar views and `UI/Planner` the Days and To-do drawers; `Overlay` owns the AppKit panel. Account IDs namespace persisted data even though v1 connects one account at a time.

The product requirements are in [SPEC.md](SPEC.md).
