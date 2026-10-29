import json
import tempfile
import unittest
from pathlib import Path
from summarize_event_benchmark import summarize


class ReportTests(unittest.TestCase):
    def report(self):
        return dict(schemaVersion=2, suiteVersion='test', fingerprint='abc', model='model', reasoning='low',
                    caseIDs=['one'], repeats=2, parallelism=1, serviceTier='default', outcomes=[
                        dict(id='one', attempt=1, tier=1, passed=True, detail='ok', seconds=2, cost=.001, servedModel='model'),
                        dict(id='one', attempt=2, tier=1, passed=False, detail='error: timeout', seconds=60, cost=0, errorKind='transport_or_configuration')])

    def read(self, data):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'report.json'
            path.write_text(json.dumps(data))
            return summarize(path)

    def test_failure_not_hidden_by_average_or_latency(self):
        result = self.read(self.report())
        self.assertEqual((result['passed'], result['total'], result['stable']), (1, 2, 0))
        self.assertEqual(result['median'], 2)
        self.assertEqual(result['errors']['transport_or_configuration'], 1)

    def test_incomplete_and_duplicate_attempts_rejected(self):
        data = self.report(); data['outcomes'].pop()
        with self.assertRaises(ValueError): self.read(data)
        data = self.report(); data['outcomes'][1]['attempt'] = 1
        with self.assertRaises(ValueError): self.read(data)

    def test_changed_fixtures_cannot_share_comparison_group(self):
        original = self.read(self.report())
        data = self.report(); data['fingerprint'] = 'different'
        self.assertNotEqual(original['group'], self.read(data)['group'])


if __name__ == '__main__':
    unittest.main()
