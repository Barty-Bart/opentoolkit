"""Synthetic AX/paste completion tests; no real UI, clipboard or microphone."""
import types
import unittest
from unittest.mock import Mock, patch

from test_voice import dictation_class
import numpy as np
import voice_control as v


class PasteVerificationTests(unittest.TestCase):
    def setUp(self):
        self.tree = {
            'old': {'AXRole': 'AXTextArea', 'AXWindow': 'window', 'AXParent': 'parent',
                    'AXIdentifier': 'message', 'AXValue': 'Hi 😀 old end'},
            'new': {'AXRole': 'AXTextArea', 'AXWindow': 'window', 'AXParent': 'parent',
                    'AXIdentifier': 'message', 'AXValue': 'Hi 😀 corrected end'},
            'parent': {'AXChildren': ['old']},
        }
        self.spans = {'old': (6, 3), 'new': (15, 0)}
        patch.object(v, 'ax', side_effect=lambda el, key: self.tree.get(el, {}).get(key)).start()
        patch.object(v, 'CFEqual', side_effect=lambda a, b: a == b).start()
        patch.object(v, 'selection_range', side_effect=lambda el: self.spans.get(el)).start()
        self.addCleanup(patch.stopall)
        self.target = v.FocusTarget(10, 'old', 'Synthetic editor', 'test.editor')
        self.tree['parent']['AXChildren'] = ['new']
        self.current = v.FocusTarget(10, 'new', 'Synthetic editor', 'test.editor')
        self.focus = patch.object(v, 'focus', return_value=self.current).start()

    def verify(self):
        return v.refresh_pasted_target(self.target, 'Hi 😀 ', 'corrected', ' end')

    def test_recreated_field_refreshes_only_after_exact_paste_result(self):
        # The old comparison rejects the newly pasted value. Confirming the
        # expected change repairs its anchor for Send and correction watching.
        self.assertFalse(v.same_focus(self.target))
        self.assertTrue(self.verify())
        self.assertEqual(self.target[1], 'new')
        self.assertEqual(self.target.value, 'Hi 😀 corrected end')
        self.assertEqual(self.target.span, (15, 0))
        self.assertTrue(v.same_focus(self.target))

    def test_wrong_value_or_caret_does_not_refresh(self):
        for value, span in [('Hi 😀 old end', (6, 3)), ('Hi 😀 corrected end', (0, 0)),
                            ('Hi 😀 corrected more end', (20, 0))]:
            with self.subTest(value=value, span=span):
                self.tree['new']['AXValue'] = value; self.spans['new'] = span
                self.assertFalse(self.verify())
                self.assertEqual(self.target[1], 'old')
                self.assertEqual(self.target.value, 'Hi 😀 old end')

    def test_same_result_in_another_field_or_app_is_rejected(self):
        for attr, value in [('window', 'another'), ('parent', 'another'), ('index', 3),
                            ('role', 'AXTextField'), ('identifier', 'other')]:
            with self.subTest(attribute=attr):
                original = getattr(self.current, attr); setattr(self.current, attr, value)
                self.assertFalse(self.verify()); setattr(self.current, attr, original)
        self.current[0] = 11
        self.assertFalse(self.verify())

    def test_missing_anchor_data_does_not_rebind(self):
        for attr in ('parent', 'window', 'index'):
            original = getattr(self.current, attr); setattr(self.current, attr, None)
            self.assertFalse(self.verify()); setattr(self.current, attr, original)

    def test_original_ax_object_also_requires_exact_text_and_caret(self):
        self.focus.return_value = self.target
        self.assertFalse(self.verify())
        self.tree['old']['AXValue'] = 'Hi 😀 corrected end'; self.spans['old'] = (15, 0)
        self.assertTrue(self.verify())
        self.assertEqual(self.target.value, 'Hi 😀 corrected end')

    def test_empty_web_editor_placeholder_line_break_is_accepted(self):
        # An empty web editor reports one line break, then drops it once text arrives.
        self.focus.return_value = self.target
        self.tree['old']['AXValue'] = 'Dictated words.'; self.spans['old'] = (15, 0)
        self.assertEqual(v.refresh_pasted_target(self.target, '', 'Dictated words.', '\n'), ('', ''))
        self.tree['old']['AXValue'] = 'First\nDictated words.'; self.spans['old'] = (21, 0)
        self.assertEqual(v.refresh_pasted_target(self.target, 'First\n', 'Dictated words.', '\n'), ('First\n', ''))
        self.tree['old']['AXValue'] = 'Dictated words.\n'; self.spans['old'] = (15, 0)
        self.assertEqual(v.refresh_pasted_target(self.target, '', 'Dictated words.', '\n'), ('', '\n'))

    def test_placeholder_tolerance_does_not_accept_other_changes(self):
        self.focus.return_value = self.target
        for value, span, prefix, suffix in [
                ('Dictated words.', (15, 0), '', ' end\n'),        # real trailing text vanished
                ('Dictated words.', (15, 0), '', '\n\n'),          # more than one placeholder
                ('Hi Dictated words.', (18, 0), 'Hi ', '\n'),       # caret mid-line, not an empty paragraph
                ('Dictated words', (14, 0), '', '\n'),              # pasted text differs
                ('Dictated words.', (0, 0), '', '\n')]:             # caret moved
            with self.subTest(value=value, prefix=prefix, suffix=suffix):
                self.tree['old']['AXValue'] = value; self.spans['old'] = span
                self.assertIsNone(v.refresh_pasted_target(self.target, prefix, 'Dictated words.', suffix))

    def test_watcher_uses_observed_suffix(self):
        c = v.VoiceControl.__new__(v.VoiceControl)
        c.d = types.SimpleNamespace(recording=False, input_revision=1, delivery_generation=1)
        c.delivery_status = Mock(); c.watch_correction = Mock(); c.send_when_pasted = Mock()
        pending = []
        timer = types.SimpleNamespace(scheduledTimerWithTimeInterval_repeats_block_=lambda d, r, fn: pending.append(fn))
        with patch.object(v, 'NSTimer', timer), patch.object(v, 'refresh_pasted_target', return_value=('', '')):
            c.confirm_paste(self.target, '', 'words', '\n', 1, 1)
            pending.pop(0)(None)
        c.watch_correction.assert_called_once_with(self.target, '', 'words', '')


class PasteCompletionTests(unittest.TestCase):
    def setUp(self):
        self.c = v.VoiceControl.__new__(v.VoiceControl)
        self.c.d = types.SimpleNamespace(recording=False, input_revision=7, delivery_generation=2)
        self.c.delivery_status = Mock(); self.c.watch_correction = Mock(); self.c.send_when_pasted = Mock()
        self.pending = []
        timer = types.SimpleNamespace(scheduledTimerWithTimeInterval_repeats_block_=lambda delay, repeat, fn: self.pending.append(fn))
        patch.object(v, 'NSTimer', timer).start()
        self.verify = patch.object(v, 'refresh_pasted_target', return_value=None).start()
        self.addCleanup(patch.stopall)
        self.target = [10, 'field', 'Synthetic editor', 'test.editor']

    def begin(self, send=False):
        self.c.confirm_paste(self.target, 'before ', 'words', ' after', 7, 2, send=send)

    def tick(self):
        self.pending.pop(0)(None)

    def test_waits_for_verified_result_then_watches_once(self):
        self.begin(); self.tick()
        self.c.watch_correction.assert_not_called()
        self.verify.return_value = ('before ', ' after'); self.tick()
        self.c.watch_correction.assert_called_once_with(self.target, 'before ', 'words', ' after')
        self.c.send_when_pasted.assert_not_called()
        self.assertFalse(self.pending)

    def test_send_waits_for_verified_result(self):
        self.begin(send=True); self.tick()
        self.c.send_when_pasted.assert_not_called()
        self.verify.return_value = ('before ', ' after'); self.tick()
        self.c.send_when_pasted.assert_called_once_with(self.target, 'words')
        self.c.watch_correction.assert_not_called()

    def test_missing_confirmation_times_out_without_send_or_watch(self):
        self.begin(send=True)
        while self.pending: self.tick()
        self.assertEqual(self.verify.call_count, 8)
        self.c.send_when_pasted.assert_not_called(); self.c.watch_correction.assert_not_called()
        self.assertIn('Could not verify', self.c.delivery_status.call_args.args[0])

    def test_new_input_or_new_dictation_cancels_pending_completion(self):
        for attr, value in [('input_revision', 8), ('delivery_generation', 3), ('recording', True)]:
            with self.subTest(attribute=attr):
                previous = getattr(self.c.d, attr); self.begin(send=True)
                setattr(self.c.d, attr, value); self.verify.return_value = ('before ', ' after'); self.tick()
                self.c.send_when_pasted.assert_not_called(); self.c.watch_correction.assert_not_called()
                setattr(self.c.d, attr, previous)

    def test_pipeline_requests_confirmation_instead_of_immediate_send(self):
        cls, env = dictation_class(); d = cls.__new__(cls)
        d.voice_control = Mock(config={}); d.transcriber = Mock(name='Synthetic')
        d.transcriber.name = 'Synthetic'; d.transcriber.transcribe.return_value = 'words'
        d.voice_control.strip_command.side_effect = lambda text: text
        d.db = Mock(); d.input_revision = 7; d.delivery_generation = 2
        context = dict(app='Synthetic', voice=False, mode='dictation', target=self.target,
                       send=True, input_revision=7, delivery_generation=2)
        with patch.object(v, 'same_focus', return_value=True), patch.object(v, 'focus', return_value=self.target), \
                patch.object(v, 'ax', return_value='before old after'), patch.object(v, 'selection_range', return_value=(7, 3)):
            d._transcribe_and_paste(np.zeros(16000), context)
        env['paste'].assert_called_once_with('words')
        d.voice_control.confirm_paste.assert_called_once_with(self.target, 'before ', 'words', ' after', 7, 2, send=True)
        d.voice_control.send_when_pasted.assert_not_called(); d.voice_control.watch_correction.assert_not_called()

    def test_queued_delivery_from_old_session_does_not_paste(self):
        cls, env = dictation_class(); d = cls.__new__(cls)
        d.voice_control = Mock(config={}); d.transcriber = Mock(name='Synthetic')
        d.transcriber.name = 'Synthetic'; d.transcriber.transcribe.return_value = 'words'
        d.db = Mock(); d.input_revision = 7; d.delivery_generation = 3
        d._transcribe_and_paste(np.zeros(16000), dict(app='Synthetic', voice=False, mode='dictation',
            target=self.target, input_revision=7, delivery_generation=2))
        d.db.commit.assert_called_once(); env['paste'].assert_not_called()


if __name__ == '__main__':
    unittest.main()
