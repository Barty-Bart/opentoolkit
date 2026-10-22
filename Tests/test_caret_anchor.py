import ast,types,unittest
from pathlib import Path
from unittest.mock import Mock

def isolated(bounds):
    tree=ast.parse((Path(__file__).resolve().parents[1]/'Voice/dictate.py').read_text())
    node=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='caret_rect')
    app=types.SimpleNamespace(processIdentifier=lambda:123)
    env=dict(NSWorkspace=types.SimpleNamespace(sharedWorkspace=lambda:types.SimpleNamespace(frontmostApplication=lambda:app)),enable_app_accessibility=Mock(),AXUIElementCreateApplication=Mock(return_value='app'),AXUIElementSetMessagingTimeout=Mock(),_ax=lambda el,key:{'focus':'field','range':'range','AXRole':'AXTextArea'}.get(key),kAXFocusedUIElementAttribute='focus',kAXSelectedTextRangeAttribute='range',AXValueGetValue=Mock(return_value=(True,(4,3))),kAXValueCFRangeType=1,_ax_rect_for_range=Mock(side_effect=bounds))
    exec(compile(ast.Module(body=[node],type_ignores=[]),'caret test','exec'),env)
    return env

def rect(width):return types.SimpleNamespace(origin=types.SimpleNamespace(x=120,y=200),size=types.SimpleNamespace(width=width,height=20))
class CaretTests(unittest.TestCase):
    def test_uses_empty_range_at_selection_end(self):
        env=isolated([rect(1)]);r,how=env['caret_rect']()
        self.assertEqual(how,'caret');env['_ax_rect_for_range'].assert_called_once_with('field',7,0)
    def test_does_not_treat_field_or_line_bounds_as_caret(self):
        env=isolated([rect(700),rect(700),rect(700)])
        r,how=env['caret_rect']();self.assertIsNone(r)
    def test_valid_character_bounds_provide_fallback(self):
        env=isolated([None,rect(10)]);r,how=env['caret_rect']()
        self.assertEqual(r.origin.x,130);self.assertEqual(how,'char before caret')
if __name__=='__main__':unittest.main()
