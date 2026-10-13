#!/usr/bin/env python3
"""Summarize AI-add benchmark runs (EC_AI_JSON files named <model>-<effort>.json) into one table:
accuracy per tier, latency, cost, and the speed/accuracy Pareto frontier.

    python3 scripts/summarize_event_benchmark.py <folder with .json results>
"""
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path


def percentile(values, fraction):
    values = sorted(values)
    return values[min(len(values) - 1, int(fraction * len(values)))] if values else 0


def main(folder):
    rows = []
    misses = defaultdict(list)
    for path in sorted(Path(folder).glob("*.json")):
        outcomes = json.loads(path.read_text())
        if not outcomes:
            continue
        name = path.stem
        tiers = defaultdict(lambda: [0, 0])
        for outcome in outcomes:
            tiers[outcome["tier"]][0] += outcome["passed"]
            tiers[outcome["tier"]][1] += 1
            if not outcome["passed"]:
                misses[outcome["id"]].append(name)
        answered = [o["seconds"] for o in outcomes if o["seconds"] > 0]
        rows.append({
            "name": name,
            "tiers": {tier: passed / total for tier, (passed, total) in tiers.items()},
            "accuracy": sum(o["passed"] for o in outcomes) / len(outcomes),
            "runs": len(outcomes),
            "errors": sum(o["detail"].startswith("error:") for o in outcomes),
            "median": statistics.median(answered) if answered else 0,
            "p90": percentile(answered, 0.9),
            "per_1000": 1000 * sum(o["cost"] for o in outcomes) / len(outcomes),
        })

    # Pareto on (median seconds ↓, accuracy ↑): nothing else is at least as fast and at least as accurate, and better in one.
    for row in rows:
        row["pareto"] = not any(
            other is not row and other["median"] <= row["median"] and other["accuracy"] >= row["accuracy"]
            and (other["median"] < row["median"] or other["accuracy"] > row["accuracy"]) for other in rows)

    tiers = sorted({tier for row in rows for tier in row["tiers"]})
    header = "| Config | " + " | ".join(f"Tier {t}" for t in tiers) + " | Overall | Median | p90 | $ / 1000 events | Pareto |"
    print(header)
    print("|" + " --- |" * (header.count("|") - 1))
    for row in sorted(rows, key=lambda r: (-r["accuracy"], r["median"])):
        cells = [f"{row['tiers'].get(t, 0) * 100:.0f}%" for t in tiers]
        errors = f" ({row['errors']} API errors)" if row["errors"] else ""
        print(f"| {row['name']} | " + " | ".join(cells) +
              f" | **{row['accuracy'] * 100:.1f}%** ({row['runs']}){errors} | {row['median']:.1f}s | {row['p90']:.1f}s"
              f" | ${row['per_1000']:.2f} | {'★' if row['pareto'] else ''} |")
    print("\nMisses by case:")
    for case, names in sorted(misses.items(), key=lambda item: -len(item[1])):
        counts = defaultdict(int)
        for name in names:
            counts[name] += 1
        print(f"- {case}: " + ", ".join(f"{name}×{n}" for name, n in sorted(counts.items())))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
