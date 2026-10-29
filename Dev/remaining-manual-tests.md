# Remaining manual tests

Updated October 29, 2026. These are the unfinished parts of the app checklist. Related checks that already passed are noted below; these boxes stay open until the real-world scenarios have been tested.

## Bubble Up after laptop sleep

- [ ] Schedule an email to come back, put the Mac to sleep, and wake it after the scheduled time. Check that the email returns to the Imbox.

Already passed: quitting and reopening the app before the deadline, then letting the email return automatically when due. Actual Mac sleep has not been tested.

## Sending after laptop sleep

- [ ] Click Send, put the Mac to sleep during the undo countdown, and wake it after the countdown would have ended. Check that the app clearly shows whether the email was sent or needs attention, and that it does not send a duplicate.

Already passed: pausing the app process across the deadline held the email for review. Review, recovery after a failed send and relaunch, Retry, and Move to Drafts worked. Actual sleep still needs testing because it can also interrupt the network.

## Multiple screens and macOS desktops

- [ ] Check that the calendar overlay appears where expected while switching between macOS desktops (Spaces), full-screen apps, and available external monitors.

Already passed: the overlay appeared over a full-screen app. Every display and desktop combination has not been checked. Mouse, scrolling, and shortcut mechanics are excluded from this testing task.

## Changes from another device

- [ ] Read, move, or screen a disposable email on another device, then check that this app catches up. Make a change in this app and check that the other device catches up too, wherever that action is supported.

Already passed: independent Google API checks confirmed that the app's changes reached Google. A physical phone or other second device has not been used.

## Notifications and starting automatically

- [ ] Schedule a Bubble Up reminder and check that its macOS notification actually appears.
- [ ] Log out of the Mac and log back in. Check that the app starts automatically.

Already checked: both preferences are enabled. Actual notification delivery and an OS logout/login cycle have not been verified.

## Resolved setup issue: OpenAI connection

- [x] Replace the configured OpenAI key and verify a successful event extraction request.

Resolved October 29: the supplied working key is now saved in the app's Keychain and local build configuration. A live check using that credential returned successfully from GPT-6.1 Terra. The installed app now uses Terra low first and Haiku 5.5 medium as backup, as requested.
