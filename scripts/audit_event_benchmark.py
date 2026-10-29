#!/usr/bin/env python3
"""Apply documented, model-independent rubric corrections to saved v2 outputs.

Never overwrites raw reports. This changes no prompts, inputs, or model responses.
"""
import copy
import json
import sys
from pathlib import Path

AUDIT_VERSION = '2026-10-29-room-detail-v1'


def audit_report(report):
    result = copy.deepcopy(report)
    result['auditVersion'] = AUDIT_VERSION
    for row in result['outcomes']:
        row['originalPassed'] = row['passed']
        row['originalDetail'] = row['detail']
        actual = row.get('actual', [])
        # B2 in notes is still a usable room detail; do not forgive any other failure.
        if row['id'] == 'mixed_select_one_session' and len(actual) == 1 and not row.get('errorKind'):
            event = actual[0]
            only_error = f'{event["title"]}: missing location details ["B2"]'
            if row['detail'].split(' ⟵ got: ')[0] == only_error and 'b2' in event.get('notes', '').lower():
                row['passed'] = True
                row['adjudication'] = 'Room B2 is preserved in notes; venue remains in location.'
                row['detail'] = row['adjudication']
    return result


def main(folder):
    source = Path(folder)
    destination = source/'audited'
    destination.mkdir(exist_ok=True)
    for path in sorted(source.glob('*.json')):
        data = json.loads(path.read_text())
        if not isinstance(data, dict) or data.get('schemaVersion') != 2:
            continue
        result = audit_report(data)
        (destination/path.name).write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
        changed = sum(r['passed'] != r['originalPassed'] for r in result['outcomes'])
        print(f'{path.name}: {changed} rubric correction(s)')


if __name__ == '__main__':
    main(sys.argv[1])
