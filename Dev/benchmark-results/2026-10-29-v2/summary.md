## 2026-10-29-v2 · fingerprint 32fc7a91beac

| Model · effort | Passed requests | Cases passing every repeat | Call/output errors | Median | p90 | Est. $ / 1,000 requests |
| --- | --- | --- | --- | --- | --- | --- |
| gpt-6.1-terra · low | 219/219 (100.0%) | 73/73 | 0 | 2.83s | 3.57s | $2.84 |
| gpt-6.1-sol · low | 219/219 (100.0%) | 73/73 | 0 | 2.91s | 4.84s | $5.65 |
| claude-haiku-5-5 · medium | 212/219 (96.8%) | 70/73 | 0 | 3.19s | 4.59s | $0.60 |
| claude-haiku-5-5 · high | 212/219 (96.8%) | 68/73 | 0 | 3.81s | 5.41s | $0.67 |
| claude-haiku-5-5 · low | 205/219 (93.6%) | 67/73 | 0 | 2.41s | 4.20s | $0.54 |

Latency covers returned, parsed answers (including wrong answers); errors are reported separately. Costs are token estimates, not invoice totals; failed calls may incur unrecorded charges.

### claude-haiku-5-5 · high

Tiers: 1: 38/39; 2: 55/57; 3: 53/57; 4: 66/66

Served models: claude-haiku-5-5: 219

Cases with misses: czech_last_correction ×3; email_ambiguous_date ×1; email_flight ×1; text_relative ×1; ticket_chosen_show ×1

### claude-haiku-5-5 · low

Tiers: 1: 39/39; 2: 54/57; 3: 49/57; 4: 63/66

Served models: claude-haiku-5-5: 219

Cases with misses: czech_last_correction ×3; email_ambiguous_date ×1; email_thread_changed ×3; no_event_missing_date ×1; text_repeat_weekdays ×3; ticket_chosen_show ×3

### claude-haiku-5-5 · medium

Tiers: 1: 39/39; 2: 54/57; 3: 54/57; 4: 65/66

Served models: claude-haiku-5-5: 219

Cases with misses: czech_last_correction ×3; text_repeat_weekdays ×1; ticket_chosen_show ×3

### gpt-6.1-sol · low

Tiers: 1: 39/39; 2: 57/57; 3: 57/57; 4: 66/66

Served models: gpt-6.1-sol: 219

### gpt-6.1-terra · low

Tiers: 1: 39/39; 2: 57/57; 3: 57/57; 4: 66/66

Served models: gpt-6.1-terra: 219
