# Forwarded account's spam never reaches the app

Noted 2026-10-21. To address later.

Placeholders: `main@example.com` is the inbox the app connects to; `work@example.com` is the second Gmail account that forwards into it.

## Problem

- work@example.com forwards to main@example.com (copy kept in work@example.com).
- Gmail does **not** forward messages it marks as spam.
- So anything in work@example.com's Spam never reaches main@example.com or this app.
- Matters during the job hunt: recruiter mail from unknown senders can land in Spam.

## Workaround for now

Check work@example.com's Spam in Gmail every few days.

## Possible fixes

- A spam view in the app only shows main@example.com's Spam, so it doesn't cover this.
- Gmail filter in work@example.com that marks job-related senders/keywords as "Never send to Spam", so they get forwarded.
- Connect work@example.com read-only to the app just to surface its Spam folder.
