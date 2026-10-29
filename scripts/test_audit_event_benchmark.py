import unittest
from audit_event_benchmark import audit_report


class AuditTests(unittest.TestCase):
    def row(self):
        return dict(id='mixed_select_one_session', passed=False,
                    detail='Workshop: missing location details ["B2"] ⟵ got: Workshop',
                    actual=[dict(title='Workshop', location='O2 universum', notes='Bring a laptop. Room B2.')])

    def test_room_in_notes_is_accepted_without_mutating_original(self):
        source = {'outcomes': [self.row()]}
        result = audit_report(source)
        self.assertTrue(result['outcomes'][0]['passed'])
        self.assertFalse(source['outcomes'][0]['passed'])
        self.assertFalse(result['outcomes'][0]['originalPassed'])

    def test_other_failures_are_not_forgiven(self):
        for detail in ['missing start 2026-11-07T13:00', 'Workshop: wrong duration; Workshop: missing location details ["B2"]']:
            row=self.row();row['detail']=detail
            self.assertFalse(audit_report({'outcomes':[row]})['outcomes'][0]['passed'])
        row=self.row();row['actual'][0]['notes']='Bring a laptop.'
        self.assertFalse(audit_report({'outcomes':[row]})['outcomes'][0]['passed'])


if __name__ == '__main__':
    unittest.main()
