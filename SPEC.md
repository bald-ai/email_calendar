# Email + Calendar — v1 Spec

A native macOS mail + calendar app for one person (the owner), connected to one Google account. The mail side is modeled on HEY: boring email done right, plus **Set Aside**, **Bubble Up** and the **Screener**. The calendar side is a plain, essential calendar, plus one signature feature: a **drop-down week overlay** that a global hotkey summons on top of anything.

The app is designed to be ADHD-friendly: low clutter, fast to glance at, nothing that nags.

This spec is intentionally loose. Where it says "should", use judgement. Where it says "must", don't.

---

## Constraints

- **Platform:** macOS only. Native Swift 6, SwiftUI for the UI, AppKit wherever SwiftUI can't do the job (the overlay panel, the global hotkey). Target macOS 15+.
- **Single user, local-first:** no backend server. All state lives in Gmail, Google Calendar, or a local SQLite database (GRDB recommended).
- **Google:** the owner's own Google Cloud project, with an OAuth "Desktop app" client in testing mode (no Google verification needed).
  - Sign in with OAuth + PKCE through `ASWebAuthenticationSession` and a loopback redirect.
  - Tokens go in the Keychain.
  - Client ID/secret go in `Secrets.xcconfig`, which is gitignored. Commit a `Secrets.example.xcconfig` alongside it.
- **Scopes:** `gmail.modify`, `gmail.settings.basic` (for filters), `calendar`.
- **Accounts:** one Google account in v1. Don't hard-code that assumption into the data model.
- **Dependencies:** keep them minimal. Use [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) for the global hotkey. Use plain `URLSession` against the Gmail and Calendar REST APIs rather than a heavy Google SDK.

## App shell

- Regular windowed app with a sidebar: **Imbox · Set Aside · Bubble Up · Screener · Sent · Drafts · All Mail · Calendar**.
- Menu bar icon (calendar glyph): opens the overlay or the main window, and holds Preferences and Quit.
- Launch at login via `SMAppService`. Default on, toggle in Preferences.
- Preferences: overlay hotkey, launch at login, account sign-in/out, overlay height.

---

## Email

### Sync

- Gmail is the source of truth. The local DB is a cache plus app-only metadata, such as Bubble Up times.
- Do an initial sync of recent mail (e.g. last 90 days), then sync incrementally with the Gmail `history` API.
  - Poll every ~60s while the app is open, and refresh immediately on window focus.
- HEY-style states are **Gmail labels**, so they're visible in Gmail on the phone. Use these labels: `HEY/Set Aside`, `HEY/Bubble Up`, `HEY/Screener`, `HEY/Screened Out`. Create them on first run if they're missing.

### Boring email features (must work well)

- Thread list and thread view (HTML rendering in a sandboxed `WKWebView`, remote images blocked by default with a per-sender "load images" option).
- Compose, reply, reply-all and forward, with attachments both ways and drafts saved to Gmail.
- Archive, delete (move to Trash only, never hard-delete), mark read/unread.
- Search, passed through to Gmail's search syntax.
- Keyboard-first:
  - `j/k` to move between threads, `enter` to open, `e` to archive, `r` to reply, `a` to reply all, `f` to forward, `c` to compose, `/` to search.
  - `s` for Set Aside, `b` for Bubble Up.
  - `cmd+K` opens a command palette.
- Undo for destructive or moving actions (toast with undo, ~5s).

### Imbox

- The Imbox shows Gmail `INBOX` threads from **approved senders only**.
- Threads are shown newest first. Unread threads are visually distinct but not loud.

### Screener (filter senders)

- When a sender emails for the first time (no prior decision), their mail lands in **Screener**: the app adds `HEY/Screener` and removes `INBOX`.
- Screener view: one row per sender with a preview of their latest message, and two big buttons:
  - **Yes:** the sender is approved, and all their mail moves to the Imbox.
  - **No:** the sender is screened out. Their mail gets `HEY/Screened Out` and stays out of the Inbox.
- On **No**, also create a **Gmail filter** for that sender (skip inbox + apply the `HEY/Screened Out` label), so rejection keeps working when the app is closed and on the phone.
- Decisions are stored locally and can be changed later from a "Screened senders" list. Undoing a "No" deletes the Gmail filter.
- Allow screening by domain as well as by single address.
- On first run, seed the approved list with everyone the owner has ever sent mail to, so the Screener isn't flooded.

### Set Aside

- Set Aside is for "I need this handy but it's not an action item."
- `s` (or a button) adds `HEY/Set Aside` and removes the thread from the Imbox.
- The Set Aside view is a simple stack. Remove from it with one key (`s` again), which returns the thread to the Imbox.

### Bubble Up

- Bubble Up means "show me this again later."
- `b` opens a small picker: **Later today · Tomorrow morning · This weekend · Next week · Pick a date…**
- The thread gets `HEY/Bubble Up`, leaves the Imbox, and the time is stored in the local DB.
- When the time arrives, remove the label and return the thread to the **top** of the Imbox with a subtle "bubbled up" marker. Send a quiet notification, which is a preference and default on.
- Due bubble-ups are processed on launch, so nothing is lost if the Mac was asleep.

### Out of scope for v1

- HEY's Feed and Paper Trail, multiple accounts, rules beyond the Screener, snooze-if-no-reply, offline compose queue.

---

## Calendar

### Core

- Google Calendar, read and write, one account. Show all of the owner's calendars, with a per-calendar visibility toggle.
- Sync incrementally with `syncToken`.
- Views in the main window: **Day · Week · Month**. Week is the default.
- Create, edit and delete events: title, time, all-day, location, description, calendar. Recurring events are displayed correctly. Editing a recurring event asks "this event / all events".
- Accept or decline invitations.
- Respect the system time zone. Event times are shown in local time.

### Out of scope for v1

- Scheduling links, multiple time zones side-by-side, tasks, natural-language event entry (nice-to-have if trivial).

---

## The Drop-Down Week Overlay (signature feature)

The goal is a glanceable "where am I in my week?" view, one keystroke away, on top of whatever is on screen. Like a Quake console, but for your week.

### Summoning

- The default global hotkey is **⌘F2**, configurable in Preferences.
- **Tap** the hotkey to toggle the overlay open and closed.
- **Hold** it to peek: the overlay shows while held and hides on release. This allows a 1-second glance without breaking focus.
- The overlay appears on the **screen containing the mouse cursor**.

### Window behavior (must)

- The overlay is an `NSPanel` with `.nonactivatingPanel`, borderless, at a high window level (≥ `.statusBar`).
- Set `collectionBehavior` to `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, so it works over full-screen apps and on every Space.
- It must not steal app activation. It can become key so it receives Esc and arrow keys, and it hands focus back to the previous app on close.
- The overlay spans the full width of the screen and slides down from the top edge.
  - Use a short spring animation, about 200–250 ms in and faster on the way out.
  - Respect "Reduce Motion": fade instead of slide.
- Default height is **~37.5% of the screen**. Drag the bottom edge to resize, and remember the height per display.
- It dismisses on: the hotkey, `Esc`, clicking outside, or switching Spaces.

### Layout

```
┌──────────────────────────────────────────────────────────────────────────┐
│  ● Next: Design review in 23 min                      Week 40 · Oct 2026 │  ← header
├─────────┬─────────┬─────────┬─────────┬─────────┬─────────┬─────────┬────┤
│ Mon 28  │ Tue 29  │ Wed 30  │ Thu 1   │▌FRI 2  ▐│ Sat 3   │ Sun 4   │    │  ← all-day row
│         │         │         │ ░ Trip  │▌        ▐│         │         │    │
├─────────┼─────────┼─────────┼─────────┼─────────┼─────────┼─────────┤    │
│ 14:00   │ ▓ 1:1   │         │         │▌▓ Design▐│         │         │    │  ← hour band,
│ 15:00 ──│─────────│─────────│─────────│▌━━━━━━━━▐│─────────│─────────│    │    scrolls vertically
│ 16:00   │         │ ▓ Gym   │         │▌        ▐│         │         │    │    (now-line in red)
└─────────┴─────────┴─────────┴─────────┴─────────┴─────────┴─────────┴────┘
```

- **Header:** a "Next up" line with a live countdown ("Design review in 23 min", or "Now: Standup, ends in 8 min"). This is the ADHD anchor: it answers "what's next?" without reading the grid.
- **Columns:** 7 day columns. Today's column is highlighted, and past days are dimmed.
- **Rows:** an all-day row, then an hour band. On open, the band is **centered on the current time**, with ~4–6 hours visible depending on height.
- A red **now-line** runs across today.

### Navigation

- Vertical scroll (trackpad or wheel) moves through the hours of the day.
- A horizontal two-finger swipe, or `←/→`, moves one week back or forward with a snappy slide.
- `T` jumps back to now.

### Interaction (light by design)

- Click an event to show a small popover with time, location, video link and notes. Video calls get a big **Join** button (Meet/Zoom links detected).
- Double-click an empty slot to create an event inline: type a title, press enter. It defaults to 30 min in the primary calendar.
- Anything more complex has an "Open in app" button, which opens the main window on that event.

### Look and feel

- Calm and dense, but not cramped. Use system materials (`.hudWindow`/`.popover` vibrancy) behind solid event chips in the calendar's color.
- Follow light and dark mode.
- No badges, no red dots, no motion except the slide and the now-line.
- It must feel instant: render from the local cache, and never wait on the network to open.

---

## Milestones (suggested order)

1. **Skeleton + auth:** Xcode project, sign in with Google, tokens in Keychain, menu bar icon, empty sidebar.
2. **Calendar sync + overlay:** sync Google Calendar into the local DB, then build the overlay against the real data. Ship this early: it's the feature the owner wants most.
3. **Calendar main views:** day, week and month views, plus create, edit and delete.
4. **Email core:** sync, thread list and thread view, compose/reply/forward, archive/delete, search, keyboard shortcuts.
5. **HEY features:** Screener (with Gmail filters), Set Aside, Bubble Up.
6. **Polish:** undo toasts, notifications, Preferences, launch at login, Reduce Motion, edge cases (sleep/wake, token refresh, offline).

## Definition of done (v1)

- [ ] I can sign in once and stay signed in across restarts.
- [ ] ⌘F2 opens the week overlay in under 150 ms on any Space, including over a full-screen app, on the display under my cursor.
- [ ] The overlay shows my real events, the now-line and the "Next up" countdown. I can scroll hours, page weeks and quick-add an event.
- [ ] I can triage the Imbox entirely from the keyboard.
- [ ] A new sender lands in the Screener. Saying No keeps them out, also on my phone's Gmail.
- [ ] Set Aside and Bubble Up work, and their states show as labels in Gmail.
- [ ] Nothing is ever hard-deleted. Secrets are never committed.
