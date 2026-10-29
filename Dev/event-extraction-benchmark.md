# Event extraction benchmark

Suite: `2026-10-29-v2`, prepared October 29, 2026.

## What this measures

This benchmarks the app's **Find events** operation: text and/or screenshots go through the production `EventExtractor`, including its prompt, structured output schema, date/time conversion and warning logic. The resulting proposals are scored before the user edits or saves them.

It does not benchmark Gmail, Google Calendar writes, the interactive editor, Add all, conflict detection, notifications, or sleep/wake. Those are app tests. Existing calendar events are not sent to the model, so duplicate/overlap detection against the user's calendar must not be credited to a model.

The fixture file previously contained 49 cases, although the README still said 46. The revised suite keeps those cases with corrected/tighter expectations and adds 24, for 73 total. Historical model scores belong to the old suite and are not comparable to this one.

## Coverage

- Fictional emails, chats, tickets, posters, event pages, a handwritten-style note and typed English/Czech requests.
- A screenshot plus text selecting one session, correcting its time, or choosing a calendar and reminder.
- Multiple images: two bookings, duplicate copies of one booking, and an event mixed with irrelevant account mail.
- Titles, useful venue/address/link details and selected important notes, as well as dates and times.
- Explicit durations, the app's one-hour default, timed midnight, short events, all-day spans and exclusive end dates.
- Source time zones, travel with different departure/arrival zones, daylight-saving transitions, a user in Tokyo, New Year and leap day.
- Latest confirmed plans, cancellations without replacements, receipts, incomplete plans, ambiguity and conflicting weekdays.
- Weekly, weekday, monthly and biweekly repeats; finite counts; separate dates that must not become a recurrence.
- Named and unavailable calendars, localized calendar names, reminders at the start, explicit no-reminder requests and combined controls.
- Two distinct events with the same start time, scored independently of output order.

Most legacy cases deliberately keep October 12, 2026 as their fixed clock so their relative dates remain reproducible. Individual new cases override the clock, time zone or available calendars. Advancing the clock to today's real date would invalidate the screenshot expectations.

All current PNGs fit within the app's 2048-pixel long-side limit. The benchmark reads these prepared PNGs directly; it does not measure screenshot capture, compression or attachment UI. The screenshots remain synthetic, so this is a controlled regression corpus rather than an estimate of the user's real-world input distribution.

## Scoring

A request passes only when every expected event is present and correct, with no extra events. Checks include:

- Exact accepted start/end instants, or an explicit duration; all-day versus timed behavior.
- Expected calendar and reminder, and no unrequested calendar, reminder or repeat.
- Exact RRULE key/value tokens, with day-list order ignored. `COUNT=80` cannot pass `COUNT=8`; an arbitrary December date cannot pass the last occurrence cutoff.
- Short case-insensitive/diacritic-insensitive title, location and notes fragments where specified. These are deliberately selected facts, not full prose string matches.
- A relevant warning for specified ambiguity cases. An unrelated past-date warning no longer satisfies a time-zone ambiguity check.
- No-event inputs must return no events and a nonempty explanation.

The old recurrence expectation that accepted a past first occurrence was removed. Wrong-weekday cases now preserve the explicit calendar date, as the production prompt specifies. A no-zone foreign-organizer case uses the local time with a warning, rather than silently inventing a foreign zone.

Warnings are scored after the app's deterministic checks. A pass therefore measures the complete extraction flow, not the model's unaided date arithmetic. Warning keyword checks and permitted wording alternatives are imperfect; review failed outputs and a sample of passes before making a model choice. If a genuine rubric error is found after running, document it and rescore all models consistently from saved outputs; do not quietly tune expectations for one model.

### Documented scoring correction

During review of low-effort responses, `mixed_select_one_session` exposed an overly strict field requirement: room B2 in the notes, with the venue in the location field, was marked wrong. That preserves the useful information and is accepted. The correction applies to every model and every effort, only when this is the sole reported error. Wrong dates, durations, missing rooms and other errors remain failures.

`scripts/audit_event_benchmark.py` writes separate `audited/` reports, retaining `originalPassed`, `originalDetail` and the reason for each change. Raw reports are never overwritten. Use audited scores for the stopping rule and final comparison. The correction version is `2026-10-29-room-detail-v1`; it changes no input, prompt or model response.

## Comparison protocol

1. Validate fixtures and the scorer locally without model calls.
2. Run one simple connection/format check for each requested model. Keep these smoke reports separate from scored runs.
3. Start each model at low effort, with three complete passes: 73 × 3 = 219 requests per setting.
4. Move that model to medium, then high, only if the preceding setting fails to reach 219/219. Stop at the first perfect setting. API failures do not establish that more reasoning is needed: investigate them separately before escalating.
5. Use one request at a time per model, the same fixture order, and standard/default service tier. Different models may run concurrently. Latency is observed end-to-end API latency, including production retries, and can vary with network/provider load and caching.
6. Preserve all attempts. Do not rerun only mistakes and replace them with successes. Any diagnostic reruns are separate from the original score.

Three repeats reveal some inconsistency, but repeated cases are correlated. A perfect 219/219 means a perfect score on this corpus, not proof of 100% real-world accuracy. Report both passed requests and the number of cases that passed every repeat. Do not manufacture a population-confidence claim from this synthetic sample.

The chosen settings use the app's existing output budgets: low 2,400 tokens, medium 8,192, high 16,384. A truncated response is a failure of that app/model configuration, not necessarily evidence that the underlying model cannot solve the case. Record truncation separately.

## Reports and reproducibility

`EC_AI_JSON` writes a versioned report containing the requested model, effort, service tier, repeat count, concurrency, suite version, selected case IDs, creation time and a SHA-256 fingerprint of the fixtures, images, extractor and scoring source. Every outcome retains the served model, attempt number, token usage, elapsed time, errors and structured event proposals. `EC_AI_PROGRESS` optionally writes completed outcomes as JSONL while the run is in progress.

The summarizer separates different fingerprints/settings instead of ranking incompatible runs together. It rejects incomplete reports and duplicate attempts, reports API/transport/refusal/truncation/invalid-output errors separately, and lists the actual served models so provider fallback is visible. No app-level provider fallback is used in these direct extractor runs.

Cost is an estimate per 1,000 **requests**, not per event; some requests create several events or none. It uses returned token usage and the app's rate table. Failed responses may incur charges without exposing usable token counts, so the report is not an invoice. Standard short-context prices checked October 29: [Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol), [Terra](https://developers.openai.com/api/docs/models/gpt-6.1-terra), [Haiku](https://platform.claude.com/docs/en/models/haiku-5-5/overview). Terra's rate was added rather than inheriting Sol's default rate.

Run the offline checks:

```sh
swift test --filter 'EventBenchmarkValidationTests|EventExtractorTests'
python3 -m unittest discover -s scripts -p 'test_summarize_event_benchmark.py'
```

With the chosen provider credentials in the environment:

```sh
EC_LIVE_AI=1 EC_AI_MODEL=MODEL_ID EC_AI_REASONING=low \
  EC_AI_REPEATS=3 EC_AI_PARALLEL=1 \
  EC_AI_JSON=results/MODEL_ID-low.json \
  swift test --filter LiveEventExtraction
python3 scripts/summarize_event_benchmark.py results
```

Apply the documented scoring correction and summarize the corrected reports:

```sh
python3 scripts/audit_event_benchmark.py results
python3 scripts/summarize_event_benchmark.py results/audited
```

The live runner rejects missing credentials, invalid repeat/concurrency values, unknown case filters and missing fixture images. Live calls remain opt-in for ordinary test runs.
