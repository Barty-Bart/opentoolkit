"""Synthetic accessibility trees: no real app text or clipboard access."""
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Voice'))
import voice_control as v


class FocusTests(unittest.TestCase):
    def setUp(self):
        self.tree = {
            'old': {'AXRole': 'AXTextArea', 'AXWindow': 'window', 'AXParent': 'parent', 'AXIdentifier': 'message', 'AXValue': ''},
            'new': {'AXRole': 'AXTextArea', 'AXWindow': 'window', 'AXParent': 'parent', 'AXIdentifier': 'message', 'AXValue': ''},
            'parent': {'AXChildren': ['old']},
        }
        self.spans = {'old': (0, 0), 'new': (0, 0)}
        self.ax = patch.object(v, 'ax', side_effect=lambda el, key: self.tree.get(el, {}).get(key)).start()
        patch.object(v, 'CFEqual', side_effect=lambda a, b: a == b).start()
        patch.object(v, 'selection_range', side_effect=lambda el: self.spans.get(el)).start()
        self.addCleanup(patch.stopall)

    def pair(self):
        old = v.FocusTarget(10, 'old', 'Test', 'test.app')
        self.tree['parent']['AXChildren'] = ['new']
        return old, v.FocusTarget(10, 'new', 'Test', 'test.app')

    def test_replaced_field_rebinds_only_with_stable_anchor_and_contents(self):
        old, new = self.pair()
        with patch.object(v, 'focus', return_value=new):
            self.assertTrue(v.same_focus(old))
            self.assertEqual(old[1], 'new')

    def test_same_words_are_not_enough_for_a_different_field(self):
        for attribute, value in [('window', 'other-window'), ('parent', 'other-parent'), ('index', 1),
                                 ('role', 'AXTextField'), ('identifier', 'other-message'),
                                 ('value', 'typed text'), ('span', (1, 0))]:
            with self.subTest(attribute=attribute):
                self.tree['parent']['AXChildren'] = ['old']
                old, new = self.pair()
                setattr(new, attribute, value)
                with patch.object(v, 'focus', return_value=new):
                    self.assertFalse(v.same_focus(old))
                    self.assertEqual(old[1], 'old')

    def test_missing_window_or_selection_never_rebinds(self):
        for attribute in ('window', 'parent', 'index', 'span'):
            self.tree['parent']['AXChildren'] = ['old']
            old, new = self.pair(); setattr(old, attribute, None)
            with patch.object(v, 'focus', return_value=new):
                self.assertFalse(v.same_focus(old))

    def test_changed_app_never_rebinds(self):
        old, new = self.pair(); new[0] = 11
        with patch.object(v, 'focus', return_value=new):
            self.assertFalse(v.same_focus(old))

    def test_focused_editor_inside_wrapper_is_supported(self):
        self.tree['wrapper'] = {'AXRole': 'AXGroup', 'AXChildren': ['old']}
        self.tree['old']['AXFocused'] = True
        self.assertEqual(v.editable_focus('wrapper'), 'old')

    def test_ambiguous_wrapper_and_unfocused_child_are_rejected(self):
        self.tree['wrapper'] = {'AXRole': 'AXGroup', 'AXChildren': ['old', 'new']}
        self.tree['old']['AXFocused'] = self.tree['new']['AXFocused'] = True
        self.assertIsNone(v.editable_focus('wrapper'))
        self.tree['wrapper']['AXChildren'] = ['old']; self.tree['old']['AXFocused'] = False
        self.assertIsNone(v.editable_focus('wrapper'))

    def test_window_and_secure_fields_are_never_inferred_as_editors(self):
        self.tree['window'] = {'AXRole': 'AXWindow', 'AXChildren': ['old']}
        self.tree['old']['AXSubrole'] = 'AXSecureTextField'
        self.assertIsNone(v.editable_focus('window'))
        self.assertIsNone(v.editable_focus('old'))

    def test_editable_combo_requires_text_selection(self):
        self.tree['old']['AXRole'] = 'AXComboBox'
        self.assertEqual(v.editable_focus('old'), 'old')
        self.spans['old'] = None
        self.assertIsNone(v.editable_focus('old'))


if __name__ == '__main__':
    unittest.main()


class UnreportedFocusTests(unittest.TestCase):
    """Synthetic AX values only."""
    def run_with(self, error, attrs, bundle='com.anthropic.claudefordesktop'):
        app = Mock(); app.bundleIdentifier.return_value = bundle; app.processIdentifier.return_value = 7
        workspace = Mock(); workspace.frontmostApplication.return_value = app
        with patch.object(v, 'NSWorkspace', Mock(sharedWorkspace=Mock(return_value=workspace))), \
                patch.object(v, 'AXUIElementCreateApplication', return_value='root'), \
                patch.object(v, 'AXUIElementSetMessagingTimeout'), patch.object(v, 'AXUIElementSetAttributeValue') as setter, \
                patch.object(v, 'AXUIElementCopyAttributeValue', return_value=(error, 'raw' if not error else None)), \
                patch.object(v, 'ax', side_effect=lambda el, key: attrs.get(key)):
            return v.unreported_focus(), setter

    def test_no_focused_element_reports_the_app_and_reenables_accessibility(self):
        result, setter = self.run_with(-25212, {})
        self.assertEqual(result, (7, 'com.anthropic.claudefordesktop'))
        setter.assert_called_once_with('root', 'AXManualAccessibility', True)

    def test_container_roles_count_as_unreported(self):
        for role in ('AXGroup', 'AXWebArea', 'AXScrollArea'):
            self.assertEqual(self.run_with(0, {'AXRole': role})[0], (7, 'com.anthropic.claudefordesktop'))

    def test_known_controls_password_fields_and_own_app_are_refused(self):
        self.assertIsNone(self.run_with(0, {'AXRole': 'AXButton'})[0])
        self.assertIsNone(self.run_with(0, {'AXRole': 'AXPopUpButton'})[0])
        self.assertIsNone(self.run_with(0, {'AXRole': 'AXGroup', 'AXSubrole': 'AXSecureTextField'})[0])
        self.assertIsNone(self.run_with(-25212, {}, bundle='local.pico')[0])
