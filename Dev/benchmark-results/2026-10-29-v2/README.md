# October 29 model comparison — complete

Recommendation among the requested models: **GPT-6.1 Terra at low effort**. It matched Sol low's perfect score on this corpus at roughly half the estimated token cost. The small median latency difference is not evidence of a general speed advantage.

The revised benchmark contains 73 cases, repeated three times per configuration. All five completed configurations have 219 outcomes: 1,095 scored requests, plus three separate connection checks. Sol and Terra stopped at low after perfect scores. Haiku progressed through low, medium and high; none reached 100%.

| Model | Effort | Correct | Median | Estimated cost / 1,000 requests |
| --- | --- | --- | --- | --- |
| Terra 6.1 | Low | 219/219 (100%) | 2.83 s | $2.84 |
| Sol 6.1 | Low | 219/219 (100%) | 2.91 s | $5.65 |
| Haiku 5.5 | Low | 205/219 (93.6%) | 2.41 s | $0.54 |
| Haiku 5.5 | Medium | 212/219 (96.8%) | 3.19 s | $0.60 |
| Haiku 5.5 | High | 212/219 (96.8%) | 3.81 s | $0.67 |

Haiku's mistakes included wrong dates, ignored durations, recurring events starting in the past, an all-day event instead of a timed call/flight, a venue spelling and a missing no-event explanation. Medium and high had equal aggregate scores but failed different cases. Higher effort was not uniformly more reliable.

All scored requests returned without a call/output-format error, and every reported served model matched the requested model. Production retry behavior remained enabled. Costs are estimates from returned token usage, not invoice totals.

One rubric correction was applied consistently: a room number preserved in notes counts as present, even if the venue occupies the location field. Raw reports remain untouched. Corrected reports preserve the original score and reason for each adjustment. Every failed case and selected passing outputs were reviewed; the theatre-duration and changed-thread screenshots were visually checked.

These are controlled synthetic cases, not a measured sample of everyday traffic. Three repetitions catch some inconsistency; 100% here does not guarantee perfect performance on unseen inputs. No app model defaults were changed by this comparison.

- [Full breakdown](summary.md)
- [Protocol, coverage and scoring correction](../../event-extraction-benchmark.md)
- `*.json`: original reports, including settings, input fingerprint, tokens and extracted proposals.
- `audited/*.json`: consistently corrected reports with original scores retained.
- `*.jsonl`: incremental outcomes saved during execution.
- `smoke/`: separate one-case connection checks, excluded from scores.
- `input-checksums.json` and `analysis-checksums.json`: input and analysis provenance.
