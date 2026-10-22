import sys,unittest,tempfile
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Voice'))
from corrections import candidate,RuleStore,EditWatch
class CorrectionsTests(unittest.TestCase):
    def test_word(self):self.assertEqual(candidate('Hello bear, how are you?','Hello Taylor, how are you?'),('bear','Taylor'))
    def test_phrase(self):self.assertEqual(candidate('Open para key today','Open parakeet today'),('para key','parakeet'))
    def test_no_deletion_or_added_words(self):
        self.assertIsNone(candidate('Hello dear friend','Hello friend'));self.assertIsNone(candidate('Hello','Hello friend'))
    def test_no_punctuation_or_case(self):
        self.assertIsNone(candidate('Hello!','Hello.'));self.assertIsNone(candidate('hello','Hello'))
    def test_unrelated_edits(self):self.assertIsNone(candidate('Hello bear this works','Hi bear this fails'))
    def test_confirm_disable_undo(self):
        with tempfile.TemporaryDirectory() as d:
            store=RuleStore(Path(d)/'rules.json');self.assertEqual(store.apply('bear'),'bear')
            rule=store.save('bear','Taylor');self.assertEqual(store.apply('bear bears'),'Taylor bears')
            self.assertIsNone(store.save('bear','Other'))
            store.change(rule['id'],'disable');self.assertEqual(store.apply('bear'),'bear')
            store.change(rule['id'],'enable');self.assertEqual(store.apply('bear'),'Taylor')
            store.change(rule['id'],'undo');self.assertEqual(store.read(),[])
    def test_monitor_verifies_delivery_and_debounce(self):
        w=EditWatch('Prefix ','Hello bear',' suffix',0)
        self.assertIsNone(w.poll('Prefix Hello bear suffix',.3))
        self.assertIsNone(w.poll('Prefix Hello Taylor suffix',1))
        self.assertEqual(w.poll('Prefix Hello Taylor suffix',3),('bear','Taylor'))
    def test_outside_range_stops(self):
        w=EditWatch('Prefix ','bear',' suffix',0);w.poll(w.expected,.2)
        self.assertIsNone(w.poll('Different bear suffix',1));self.assertTrue(w.done)
    def test_timeout(self):
        w=EditWatch('','bear','',0);w.poll('bear',.2);self.assertIsNone(w.poll('Taylor',31));self.assertTrue(w.done)
    def test_missing_delivery(self):
        w=EditWatch('','bear','',0);w.poll('Taylor',3);self.assertTrue(w.done)
class FocusTests(unittest.TestCase):
    def test_transient_focus_loss_resumes_same_field(self):
        w=EditWatch('','pair cake','',0);w.poll('pair cake',.1)
        self.assertTrue(w.focus_available(False,1))
        self.assertTrue(w.focus_available(True,1.3))
        w.poll('parakeet',1.4)
        self.assertEqual(w.poll('parakeet',3),('pair cake','parakeet'))
    def test_sustained_focus_loss_cancels(self):
        w=EditWatch('','bear','',0)
        w.focus_available(False,1)
        self.assertFalse(w.focus_available(False,2.1))
        self.assertFalse(w.focus_available(True,2.2))
    def test_return_after_timeout_does_not_resume(self):
        w=EditWatch('','bear','',0);w.focus_available(False,1)
        self.assertFalse(w.focus_available(True,3))
if __name__=='__main__':unittest.main()
