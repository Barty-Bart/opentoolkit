import sys, unittest, types
from pathlib import Path
from unittest.mock import Mock, patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Voice'))
from command_session import CommandSession
from wake_engine import detector_phrases, migrate_voice_branding
import voice_control as v

class CommandSessionTests(unittest.TestCase):
    def test_actions_require_wake_and_are_consumed_once(self):
        gate=CommandSession()
        self.assertFalse(gate.consume(10,1))
        gate.arm(10,1)
        self.assertTrue(gate.consume(15,1))
        self.assertFalse(gate.consume(15.1,1))
    def test_timeout_and_new_recording_invalidate_window(self):
        for now,epoch in [(18,1),(11,2)]:
            gate=CommandSession();gate.arm(10,1)
            self.assertFalse(gate.consume(now,epoch))
        gate.arm(20,2);self.assertTrue(gate.expire(28,2));self.assertFalse(gate.expire(29,2))
    def test_new_default_and_old_custom_phrase_survive(self):
        config={'brandingVersion':1,'wakePhrase':'hey open toolkit','phrases':{'start':'hey open toolkit start dictating'}}
        upgraded=migrate_voice_branding(config)
        self.assertEqual(upgraded['wakePhrase'],'hey toolkit')
        self.assertEqual(upgraded['phrases']['start'],'start dictating')
        custom={**config,'wakePhrase':'hello pocket','phrases':{'start':'begin writing'}}
        self.assertEqual(migrate_voice_branding(custom)['wakePhrase'],'hello pocket')
    def test_keyword_detector_has_separate_wake_and_action_labels(self):
        commands=detector_phrases(v.DEFAULTS)
        self.assertEqual(commands['wake'],'hey toolkit')
        self.assertEqual(commands['screenshot'],'take a screenshot')
        self.assertEqual(commands['summarize'],'summarize into bullet points')
    def test_real_voice_router_only_dispatches_inside_window(self):
        c=v.VoiceControl.__new__(v.VoiceControl)
        c.command_session=CommandSession();c.epoch=3;c.enabled=True
        c.d=types.SimpleNamespace(busy=False,wake_feedback=Mock(),end_wake_feedback=Mock())
        c.accept=Mock();c.label=Mock()
        with patch.object(v.time,'monotonic',return_value=100):
            c.heard('screenshot',3);c.accept.assert_not_called()
            c.heard('wake',3);c.d.wake_feedback.assert_called_once()
            c.heard('screenshot_short',3);c.accept.assert_called_once_with('screenshot',3)
            c.heard('email',3);self.assertEqual(c.accept.call_count,1)
        with patch.object(v.time,'monotonic',return_value=200):c.heard('wake',3)
        with patch.object(v.time,'monotonic',return_value=209):c.heard('start',3)
        self.assertEqual(c.accept.call_count,1)
        c.heard('wake',2);self.assertEqual(c.d.wake_feedback.call_count,2)

if __name__=='__main__':unittest.main()
