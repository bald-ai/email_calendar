# Email + Calendar

A native macOS 15+ app written in Swift 6, SwiftUI and AppKit. Mail is backed by Gmail, calendars by Google Calendar, and the local cache by SQLite. The week overlay opens from cached data with **⌥Space**: tap to toggle, hold to peek.

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

- Imbox, Set Aside, Bubble Up, Screener, Sent, Drafts, All Mail and Calendar.
- Gmail history sync with expired-cursor recovery, full Gmail search, thread reading, compose/reply/reply-all/forward, attachments, Gmail drafts, read state, archive and Trash.
- Sender and domain decisions, all-mail moves, Google rejection filters, and five-second undo that restores each message’s previous labels. Remote-image permission is separate from sender approval.
- Durable Bubble Up times processed on launch and refresh; Gmail labels expose mail states on other devices. Due mail returns at the top when it surfaces, then sorts alongside newer mail.
- Calendar visibility, Day/Week/Month views, expanded recurring events, event creation/editing/deletion, this-event/all-events scope, invitation responses and detected video links.
- A nonactivating, full-width `NSPanel` over Spaces/full-screen apps, selected by mouse display, with tap/hold hotkey, Escape/outside-click/Space dismissal, Reduce Motion, resizing, now-line, live next-event anchor, week navigation and quick event creation.
- Sandboxed, ephemeral HTML rendering with JavaScript, forms, frames and remote resources blocked; remote images can be allowed per sender.

The app polls while open and refreshes on focus and wake. Cached mail and events remain available offline; network writes report a failure and keep editable compose/event content open. There is no offline send queue. Gmail mail deletion only moves mail to Trash; the integration exposes no permanent message deletion endpoint.

## Keyboard

| Key | Action |
| --- | --- |
| `j` / `k`, Return | Navigate/open threads; Return edits a selected draft |
| `e`, `r`, `a`, `f`, `c` | Archive, reply, reply all, forward, compose |
| `/`, `⌘K` | Gmail search, command palette |
| `s`, `b`, `⌘Z` | Toggle Set Aside, Bubble Up, undo |
| `⌘Return` | Send from the composer |
| `⌥Space` | Toggle week overlay; hold to peek |
| `←` / `→`, `T`, Escape | Overlay previous/next week, now, dismiss |

## Validate

On a Mac, run:

```sh
./scripts/check.sh
```

This runs the platform-neutral tests, then compiles the native app with Xcode without code signing. The core has a separate Swift Package so SQLite, REST, MIME and sync behavior can also be tested on Linux with Swift 6 and SQLite development headers:

```sh
swift test --parallel
```

Tests use temporary databases and mock URLSession transports; they do not touch your Google account. The Xcode project is checked in. After adding Swift source files, regenerate it with `python3 scripts/generate_project.py`.

Validated on macOS with Xcode: the app compiles and **all tests pass**, covering SQLite isolation/rollback, OAuth-token retry, MIME/attachments, history and sync-token recovery, sender/filter undo, account-switch cancellation, Bubble Up, drafts/sending, recurrence, invitations and confirmed-write recovery. All 29 app source files passed parsing for the macOS 15 target, and the project references, scheme and resource plists parsed successfully. Native SDK compilation is covered by the added macOS CI workflow but has not run here.

Before treating this as a finished release, verify on your Mac:

- Real OAuth sign-in, token restore after relaunch, and Keychain behavior in a signed build.
- Overlay first-frame latency under 150 ms, over a full-screen app, on multiple displays and Spaces; focus restoration for both taps and peeks.
- Screen an address/domain out and confirm the filter in Gmail on your phone; undo removes it and restores prior labels.
- Compose, Gmail draft continuation, attachment upload/download and reply threading with real mail.
- Calendar recurrence and invitation writes in your own calendars, time-zone/DST transitions, sleep/wake Bubble Up, and notification/login permissions.

The development environment for this implementation is Linux. Core Swift compilation, mock integration tests and macOS source syntax can be checked here; native SDK typechecking, UI execution, real account access and overlay timing require Xcode/macOS.

## Source map

`EmailCalendar/App` owns the shell and main-actor store; `Auth` owns OAuth/Keychain; `Google` owns the REST transport and MIME encoder; `Data` owns SQLite and mail normalization; `Services` owns sync and workflows; `UI` owns mail/calendar views; `Overlay` owns the AppKit panel. Account IDs namespace persisted data even though v1 connects one account at a time.

The product requirements are in [SPEC.md](SPEC.md).
