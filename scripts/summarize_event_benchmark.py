#!/usr/bin/env python3
"""Summarize versioned live extraction reports without comparing incompatible suites.

Usage: python3 scripts/summarize_event_benchmark.py Dev/benchmark-results/<run>
Costs are recorded estimates per 1,000 requests, not per extracted event.
"""
import json
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path


def percentile(values, fraction):
    values = sorted(values)
    return values[min(len(values) - 1, int((len(values) - 1) * fraction))] if values else None


def summarize(path):
    data = json.loads(path.read_text())
    if isinstance(data, list):
        # Historical files do not identify exact fixtures, prompt or scorer. Never mix with v2.
        rows = data
        metadata = {"model": path.stem, "reasoning": "legacy", "suiteVersion": "legacy-unverified"}
        group = ("legacy-unverified",)
    elif data.get("schemaVersion") == 2:
        metadata = data
        rows = data["outcomes"]
        expected = Counter({case: data["repeats"] for case in data["caseIDs"]})
        if Counter(row["id"] for row in rows) != expected:
            raise ValueError(f"{path.name}: incomplete or unexpected cases")
        if len({(row["id"], row["attempt"]) for row in rows}) != len(rows):
            raise ValueError(f"{path.name}: duplicate attempts")
        if any(not 1 <= row["attempt"] <= data["repeats"] for row in rows):
            raise ValueError(f"{path.name}: invalid attempt number")
        group = (data["suiteVersion"], data["fingerprint"], tuple(data["caseIDs"]), data["repeats"], data["parallelism"], data["serviceTier"], data.get("auditVersion", "raw"))
    else:
        return None
    if not rows:
        raise ValueError(f"{path.name}: no outcomes")
    errors = Counter(row.get("errorKind", "legacy_error") for row in rows if row.get("errorKind") or row["detail"].startswith("error:"))
    answered = [row["seconds"] for row in rows if not row.get("errorKind") and not row["detail"].startswith("error:")]
    by_case = defaultdict(list)
    tiers = defaultdict(lambda: [0, 0])
    served = Counter()
    for row in rows:
        by_case[row["id"]].append(row["passed"])
        tiers[row["tier"]][0] += row["passed"]
        tiers[row["tier"]][1] += 1
        served[row.get("servedModel") or "unrecorded"] += 1
    return dict(name=f"{metadata['model']} · {metadata['reasoning']}", group=group, rows=rows,
                passed=sum(r["passed"] for r in rows), total=len(rows), errors=errors,
                stable=sum(all(v) for v in by_case.values()), cases=len(by_case), tiers=tiers, served=served,
                median=statistics.median(answered) if answered else None, p90=percentile(answered, .9),
                cost=1000 * sum(r.get("cost", 0) for r in rows) / len(rows))


def main(folder):
    groups = defaultdict(list)
    for path in sorted(Path(folder).glob("*.json")):
        row = summarize(path)
        if row:
            groups[row["group"]].append(row)
    if not groups:
        print("No completed benchmark reports found.")
        return
    for group, rows in groups.items():
        print(f"## {group[0]}" + (f" · fingerprint {group[1][:12]}" if len(group) > 1 else ""))
        print("\n| Model · effort | Passed requests | Cases passing every repeat | Call/output errors | Median | p90 | Est. $ / 1,000 requests |")
        print("| --- | --- | --- | --- | --- | --- | --- |")
        for row in sorted(rows, key=lambda r: (-r['passed']/r['total'], r['median'] or float('inf'))):
            median = f"{row['median']:.2f}s" if row['median'] is not None else "—"
            p90 = f"{row['p90']:.2f}s" if row['p90'] is not None else "—"
            print(f"| {row['name']} | {row['passed']}/{row['total']} ({100*row['passed']/row['total']:.1f}%) | {row['stable']}/{row['cases']} | {sum(row['errors'].values())} | {median} | {p90} | ${row['cost']:.2f} |")
        print("\nLatency covers returned, parsed answers (including wrong answers); errors are reported separately. Costs are token estimates, not invoice totals; failed calls may incur unrecorded charges.")
        for row in rows:
            print(f"\n### {row['name']}")
            print("\nTiers: " + "; ".join(f"{tier}: {p}/{n}" for tier, (p,n) in sorted(row['tiers'].items())))
            print("\nServed models: " + "; ".join(f"{model}: {count}" for model, count in sorted(row['served'].items())))
            if row['errors']:
                print("\nErrors: " + "; ".join(f"{kind}: {count}" for kind, count in sorted(row['errors'].items())))
            misses = Counter(r['id'] for r in row['rows'] if not r['passed'])
            if misses:
                print("\nCases with misses: " + "; ".join(f"{case} ×{count}" for case, count in sorted(misses.items())))


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else '.')
