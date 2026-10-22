"""No-microphone speech integration tests, using synthetic fixtures and mocked delivery.

Run with a test venv containing Pico's dependencies. These tests never open audio input, transcribe user
recordings, manipulate the clipboard, or press a real Send button.
"""
import ast
import copy
import json
import logging
from pathlib import Path
import queue
import sqlite3
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Voice"))
import numpy as np
import voice_control as v
import wake_engine as w


def dictation_class():
    """Load only the real class methods, without importing/initialising GPU or UI."""
    source = ast.parse((ROOT / "Voice" / "dictate.py").read_text())
    cls = next(node for node in source.body if isinstance(node, ast.ClassDef) and node.name == "Dictation")
    env = dict(np=np, queue=queue, threading=threading, time=time, log=logging.getLogger("voice-tests"),
               AppHelper=types.SimpleNamespace(callAfter=lambda f, *args: f(*args)),
               SAMPLE_RATE=16000, MIN_AUDIO_SECONDS=.35, TAP_SECONDS=.3,
               START_SOUND="start", STOP_SOUND="stop", play=Mock(), frontmost_app=Mock(return_value="Test"),
               apply_replacements=lambda text: text, AXIsProcessTrustedWithOptions=Mock(return_value=True), paste=Mock())
    exec(compile(ast.Module(body=[cls], type_ignores=[]), "dictate.py isolated class", "exec"), env)
    return env["Dictation"], env


class CorrectionBaselineTests(unittest.TestCase):
    def test_delivered_baseline_is_seen_before_first_tick(self):
        control=v.VoiceControl.__new__(v.VoiceControl);control.config={}
        with patch.object(v,'ax',return_value='prefix bear suffix'),patch.object(v.time,'monotonic',return_value=10):
            control.watch_correction((1,'field','Test','test'),'prefix ','bear',' suffix')
        watch=control.edit_watch[1]
        self.assertTrue(watch.seen)
        watch.poll('prefix Taylor suffix',10.01)
        self.assertEqual(watch.poll('prefix Taylor suffix',12),('bear','Taylor'))
    def test_undelivered_baseline_is_not_assumed(self):
        control=v.VoiceControl.__new__(v.VoiceControl);control.config={}
        with patch.object(v,'ax',return_value='previous text'):
            control.watch_correction((1,'field','Test','test'),'','bear','')
        self.assertFalse(control.edit_watch[1].seen)

class LiveInsertionTests(unittest.TestCase):
    def test_real_macos_selection_range_is_tuple_compatible(self):
        value=v.AXValueCreate(v.kAXValueCFRangeType,(6,3))
        with patch.object(v,'ax',return_value=value):
            self.assertEqual(v.selection_range('field'),(6,3))

    def test_replaces_only_owned_range_with_unicode_and_no_duplicates(self):
        state={'value':'Hi 😀 old end','span':(6,3)}
        target=(1,'field')
        def put(text):
            before,_,after=v.split_utf16(state['value'],*state['span'])
            start=state['span'][0];state['value']=before+text+after;state['span']=(start+v.utf16len(text),0)
        def select(el,key,value):state['span']=value;return 0
        with patch.object(v,'ax',side_effect=lambda e,k:state['value']),patch.object(v,'selection_range',side_effect=lambda e:state['span']),patch.object(v,'same_focus',return_value=True),patch.object(v,'AXValueCreate',side_effect=lambda t,r:r),patch.object(v,'AXUIElementSetAttributeValue',side_effect=select):
            live=v.LiveInsertion(target,put,Mock())
            self.assertTrue(live.update('new'))
            self.assertTrue(live.update('new words'))
            self.assertTrue(live.update('New words.'))
            self.assertEqual(state['value'],'Hi 😀 New words. end')
    def test_user_edit_or_cursor_move_prevents_replacement(self):
        for field in ['value','span']:
            state={'value':'draft','span':(5,0)};paste=Mock();status=Mock()
            with patch.object(v,'ax',side_effect=lambda e,k:state['value']),patch.object(v,'selection_range',side_effect=lambda e:state['span']),patch.object(v,'same_focus',return_value=True):
                live=v.LiveInsertion((1,'field'),paste,status)
                state[field]='edited' if field=='value' else (0,0)
                self.assertFalse(live.update('hello'));paste.assert_not_called();status.assert_called_once()
    def test_final_live_update_does_not_append_second_copy(self):
        cls,env=dictation_class();d=cls.__new__(cls);d.transcriber=Mock(name='transcriber');d.transcriber.name='test';d.transcriber.transcribe.return_value='Final text'
        d.db=Mock();d.voice_control=Mock();live=Mock();live.update.return_value=True
        with patch.object(v,'same_focus',return_value=True):
            d._transcribe_and_paste(np.zeros(16000),{'app':'test','voice':False,'target':(1,'field'),'mode':'dictation','send':False,'live':live})
        live.update.assert_called_once_with('Final text');env['paste'].assert_not_called();d.db.commit.assert_called_once()

class RecoveryTests(unittest.TestCase):
    def tap(self,g,t,key='shift'):
        g.feed(key,True,True,t)
        return g.feed(key,False,True,t+.08)
    def test_double_waits_then_pastes_once(self):
        g=v.RecoveryGesture()
        self.assertIsNone(self.tap(g,0))
        self.assertEqual(self.tap(g,.2),'pending')
        self.assertIsNone(g.finish(.5))
        self.assertEqual(g.finish(.75),'paste')
        self.assertIsNone(g.finish(1))
    def test_triple_opens_history_without_pasting(self):
        g=v.RecoveryGesture()
        self.tap(g,0);self.tap(g,.15)
        self.assertEqual(self.tap(g,.3),'history')
        self.assertIsNone(g.finish(1))
    def test_third_press_holds_off_pending_paste(self):
        g=v.RecoveryGesture();self.tap(g,0);self.tap(g,.15)
        g.feed('shift',True,True,.5)
        self.assertIsNone(g.finish(.7))
        self.assertEqual(g.feed('shift',False,True,.72),'history')
    def test_typing_shortcut_cancels_pending_paste(self):
        g=v.RecoveryGesture();self.tap(g,0);self.tap(g,.15)
        g.feed('shift',False,False,.3)
        self.assertIsNone(g.finish(1))
    def test_modifier_shortcuts_cannot_rearm_while_shift_is_still_held(self):
        g=v.RecoveryGesture()
        for t in (0,):
            g.feed('shift',True,True,t)
            g.feed('shift',True,False,t+.01)  # shortcut/typing while Shift held
            g.feed('shift',True,True,t+.02)   # another flags event, still held
            g.feed('shift',False,True,t+.08)
        self.assertIsNone(self.tap(g,.2))  # only one genuine standalone tap
        self.assertIsNone(g.finish(1))
        self.assertIsNone(self.tap(g,2))
        self.assertEqual(self.tap(g,2.2),'pending')
        self.assertEqual(g.finish(3),'paste')

    def test_mouse_click_cancels_pending_recovery(self):
        g=v.RecoveryGesture();self.tap(g,0);self.tap(g,.15)
        g.feed('shift',False,False,.3)
        self.assertIsNone(g.finish(1))

    def test_holds_disabled_slow_taps_and_key_changes_do_not_trigger(self):
        g=v.RecoveryGesture()
        g.feed('shift',True,True,0);g.feed('shift',False,True,1)
        self.assertIsNone(g.finish(2))
        self.assertIsNone(self.tap(g,3,'off'))
        self.assertIsNone(self.tap(g,4,'option'))
        self.assertIsNone(self.tap(g,5,'option'))
        self.assertIsNone(self.tap(g,5.2,'command'))
        self.assertIsNone(g.finish(6))

class RecoveryEventTapTests(unittest.TestCase):
    def test_real_callback_routes_only_standalone_modifier_taps(self):
        import Quartz
        callbacks=[];clock=[0.];d=types.SimpleNamespace(input_revision=0,fn_down=False,on_other_key=Mock(),on_fn=Mock())
        d.voice_control=types.SimpleNamespace(config={'recoveryKey':'shift'},emit=Mock(),recover_last=Mock())
        q=Mock(wraps=Quartz)
        for name in dir(Quartz):
            if name.startswith("kCG"):setattr(q,name,getattr(Quartz,name))
        q.CGEventGetFlags.side_effect=lambda e:e['flags']
        q.CGEventGetIntegerValueField.side_effect=lambda e,f:e.get('tag',0) if f==Quartz.kCGEventSourceUserData else e['code']
        q.CGEventTapCreate.side_effect=lambda a,b,c,m,cb,r:callbacks.append(cb) or 'tap'
        timers=[]
        timer=types.SimpleNamespace(scheduledTimerWithTimeInterval_repeats_block_=lambda delay,repeat,f:timers.append(f))
        env={'Quartz':q,'NSTimer':timer,'AppHelper':types.SimpleNamespace(callAfter=lambda f,*a:f(*a)),
             'time':types.SimpleNamespace(monotonic=lambda:clock[0],time=lambda:clock[0]),'log':logging.getLogger('test'),
             'DEBUG_KEYS':False,'FN_KEYCODE':63}
        tree=ast.parse((ROOT/'Voice/dictate.py').read_text());node=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='make_tap')
        exec(compile(ast.Module(body=[node],type_ignores=[]),'real event tap','exec'),env)
        env['make_tap'](d);cb=callbacks[0];shift=Quartz.kCGEventFlagMaskShift;ctrl=Quartz.kCGEventFlagMaskControl
        def event(t,code,flags,etype=Quartz.kCGEventFlagsChanged,tag=0):
            clock[0]=t;ev={'code':code,'flags':flags,'tag':tag}
            self.assertIs(cb(None,etype,ev,None),ev)
        # Two Shift-Control shortcuts must never become a recovery double tap.
        for t in (0,.2):
            event(t,56,shift);event(t+.01,59,shift|ctrl);event(t+.02,59,shift);event(t+.08,56,0)
        self.assertFalse(timers)
        # Capital-letter typing also does not arm recovery.
        for t in (1,1.2):
            event(t,56,shift);event(t+.02,0,shift,Quartz.kCGEventKeyDown);event(t+.08,56,0)
        self.assertFalse(timers)
        # Deliberate double tap still recovers exactly once.
        with patch.object(v,'focus',return_value=(1,'field')):
            for t in (2,2.2):event(t,56,shift);event(t+.08,56,0)
        clock[0]=3;timers.pop()(None);d.voice_control.recover_last.assert_called_once_with((1,'field'))
        # New typing cancels a pending recovery; our own paste events are ignored.
        d.voice_control.recover_last.reset_mock()
        with patch.object(v,'focus',return_value=(1,'field')):
            for t in (4,4.2):event(t,56,shift);event(t+.08,56,0)
        event(4.3,0,0,Quartz.kCGEventKeyDown)
        clock[0]=5;timers.pop()(None);d.voice_control.recover_last.assert_not_called()
        rev=d.input_revision
        event(6,9,Quartz.kCGEventFlagMaskCommand,Quartz.kCGEventKeyDown,0x4D4D5450)
        self.assertEqual(d.input_revision,rev)

class VoiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="multitool-voice-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.c = v.VoiceControl.__new__(v.VoiceControl)
        c = self.c
        c.root = self.base
        c.inbox = self.base / "inbox"; c.inbox.mkdir()
        c.events = self.base / "events"; c.events.mkdir()
        c.config_file = self.base / "config.json"
        c.paused_file = self.base / "disabled"
        c.config = copy.deepcopy(v.DEFAULTS)
        c._config_stamp = 0
        c.enabled = True; c.epoch = 4; c.mic_ready = False; c.detector_ready = False
        c.capture_mode = "dictation"; c.long_mode = None; c.send_after = False
        c.preview_pending = False; c.last_preview = 0.; c.queue = queue.Queue(maxsize=40)
        c.send_generation = 0; c.segment_lock = threading.RLock()
        c.status = "Test"; c.locked = False; c.last_command = 0.; c.session = "test-session"
        c.segment = []; c.segment_frames = 0; c.silent = 0; c.segment_pending = 0
        c.d = types.SimpleNamespace(jobs=queue.Queue(), transcriber=Mock(), audio_lock=threading.RLock(),
                                   recording=False, busy=False, chunks=[], audio_frames=0, level=0.,
                                   start=Mock(), stop=Mock(), preview=Mock())
        c.d.transcriber.name = "synthetic-test-model"
        c.db = Mock(); c.paste = Mock()
        self.emissions = []
        c.emit = lambda kind, **kw: self.emissions.append((kind, kw))
        self.after = patch.object(v.AppHelper, "callAfter", side_effect=lambda f, *args: f(*args))
        self.after.start(); self.addCleanup(self.after.stop)

    def test_defaults_do_not_listen_send_or_preview(self):
        for field in ("wakeEnabled", "liveEnabled", "sendEnabled", "standaloneSend"):
            self.assertFalse(v.DEFAULTS[field])

    def test_custom_phrase_normalises_and_rejects_keyword_syntax(self):
        self.assertEqual(w.validate_phrase("  Hey   Pico start dictating "), "Hey Pico start dictating")
        for bad in ("", "a/b", "start @send", "☀️", "one two three four five six seven eight nine"):
            with self.subTest(bad=bad), self.assertRaises(ValueError): w.validate_phrase(bad)

    def test_strip_only_trailing_custom_commands(self):
        self.c.config["phrases"]["stop"] = "please stop now"
        self.assertEqual(self.c.strip_command("Hello there. Please, stop now!"), "Hello there")
        self.assertEqual(self.c.strip_command("Please stop now is a phrase."), "Please stop now is a phrase.")
        self.assertEqual(self.c.strip_command("Hello there. Finish and send."), "Hello there")

    def test_stale_or_paused_detection_cannot_start_or_send(self):
        with patch.object(v, "AXUIElementPerformAction") as perform:
            self.c.accept("start", self.c.epoch - 1)
            self.c.enabled = False
            self.c.accept("send", self.c.epoch)
            self.c.d.start.assert_not_called(); perform.assert_not_called()

    def test_busy_detector_does_not_interrupt_transcription(self):
        self.c.d.busy = True
        self.c.accept("start", self.c.epoch)
        self.c.d.start.assert_not_called()

    def test_practice_mode_routes_result_without_requiring_ax_target(self):
        with patch.object(v,"focus",return_value=None):self.c.command("practice")
        self.assertEqual(self.c.capture_mode,"practice")
        self.c.d.start.assert_called_once_with(voice=True,target=None)
        self.assertFalse(self.c.send_after)

    def test_sound_audition_does_not_start_recording(self):
        self.c.d.preview_feedback=Mock()
        self.c.command("test_sound",{"cue":"startSound"})
        self.c.d.preview_feedback.assert_called_once_with("startSound")
        self.c.d.start.assert_not_called()

    def test_start_uses_target_or_live_fallback(self):
        target = (100, "field", "Test", "test.app")
        with patch.object(v, "focus", return_value=target): self.c.command("start")
        self.c.d.start.assert_called_once_with(voice=True, target=target)
        self.assertEqual(self.c.capture_mode, "dictation")
        self.c.d.start.reset_mock()
        with patch.object(v, "focus", return_value=None): self.c.command("start")
        self.assertEqual(self.c.capture_mode, "live")

    def test_recording_stop_cancel_and_disabled_send(self):
        self.c.d.recording = True
        self.c.accept("send", self.c.epoch)
        self.c.d.stop.assert_not_called()
        self.c.last_command = 0
        self.c.accept("cancel", self.c.epoch)
        self.c.d.stop.assert_called_once_with(False)

    def test_recording_send_requires_opt_in_and_dictation_mode(self):
        self.c.d.recording = True; self.c.config["sendEnabled"] = True
        self.c.capture_mode = "note"
        self.c.accept("send", self.c.epoch)
        self.c.d.stop.assert_not_called()
        self.c.last_command = 0; self.c.capture_mode = "dictation"
        self.c.accept("send", self.c.epoch)
        self.assertTrue(self.c.send_after); self.c.d.stop.assert_called_once()

    def test_standalone_send_disabled_by_default(self):
        with patch.object(v, "AXUIElementPerformAction") as perform:
            self.c.accept("send", self.c.epoch)
            perform.assert_not_called()

    def test_send_requires_unchanged_focus(self):
        target = (100, "field", "Test", "com.openai.codex")
        with patch.object(v, "same_focus", return_value=False):
            self.assertIsNone(v.send_button(target))

    def test_send_rejects_unapproved_app(self):
        target = (100, "field", "Test", "test.unapproved")
        with patch.object(v, "same_focus", return_value=True):
            self.assertIsNone(v.send_button(target))

    def test_send_finds_button_in_deeper_composer_container(self):
        target=(100,'field','Test','com.openai.codex')
        values={('field','AXValue'):'hello',('field','AXParent'):'g0'}
        for i in range(5):
            values[(f'g{i}','AXRole')]='AXGroup'
            values[(f'g{i}','AXParent')]=f'g{i+1}'
            values[(f'g{i}','AXChildren')]=['field' if i==0 else f'g{i-1}']
        values[('g4','AXChildren')].append('button')
        values.update({('button','AXRole'):'AXButton',('button','AXEnabled'):True,('button','AXTitle'):'Send prompt'})
        with patch.object(v,'same_focus',return_value=True),patch.object(v,'ax',side_effect=lambda el,k:values.get((el,k))):
            self.assertEqual(v.send_button(target),'button')
    def test_focus_uses_accessibility_equality_and_same_process(self):
        with patch.object(v,'focus',return_value=(100,'new-wrapper')),patch.object(v,'CFEqual',return_value=True):
            self.assertTrue(v.same_focus((100,'old-wrapper')))
            self.assertFalse(v.same_focus((200,'old-wrapper')))

    def test_send_rejects_ambiguous_buttons(self):
        target = (100, "field", "Test", "com.openai.codex")
        values = {("field", "AXValue"): "hello", ("field", "AXParent"): "group", ("group", "AXRole"): "AXGroup", ("group", "AXChildren"): ["a", "b"]}
        for button in ("a", "b"):
            values.update({(button, "AXRole"): "AXButton", (button, "AXEnabled"): True, (button, "AXTitle"): "Send"})
        with patch.object(v, "same_focus", return_value=True), patch.object(v, "ax", side_effect=lambda element, key: values.get((element, key))):
            self.assertIsNone(v.send_button(target))

    def test_send_timer_requires_verified_pasted_text(self):
        self.c.config["sendEnabled"] = True
        callback = []
        timer = types.SimpleNamespace(scheduledTimerWithTimeInterval_repeats_block_=lambda delay, repeat, f: callback.append(f))
        with patch.object(v, "NSTimer", timer), patch.object(v, "same_focus", return_value=True), patch.object(v, "ax", return_value="different text"), patch.object(v, "AXUIElementPerformAction") as perform:
            self.c.send_when_pasted((1, "field"), "hello")
            callback[0](None)
            perform.assert_not_called()

    def test_send_timer_cancelled_after_pause(self):
        callback = []
        self.c.config["sendEnabled"] = True
        timer = types.SimpleNamespace(scheduledTimerWithTimeInterval_repeats_block_=lambda delay, repeat, f: callback.append(f))
        with patch.object(v, "NSTimer", timer), patch.object(v, "same_focus", return_value=True), patch.object(v, "ax", return_value="hello"), patch.object(v, "send_button", return_value="fake-button"), patch.object(v, "AXUIElementPerformAction", return_value=0) as perform:
            self.c.send_when_pasted((1, "field"), "hello")
            self.c.command("pause")
            callback[0](None)
            perform.assert_not_called()

    def test_verified_send_uses_one_mocked_accessibility_press(self):
        self.c.config["sendEnabled"] = True
        callback = []
        timer = types.SimpleNamespace(scheduledTimerWithTimeInterval_repeats_block_=lambda delay, repeat, f: callback.append(f))
        with patch.object(v, "NSTimer", timer), patch.object(v, "same_focus", return_value=True), patch.object(v, "ax", return_value="hello"), patch.object(v, "send_button", return_value="fake-button"), patch.object(v, "AXUIElementPerformAction", return_value=0) as perform:
            self.c.send_when_pasted((1, "field"), "hello")
            callback[0](None)
            perform.assert_called_once_with("fake-button", "AXPress")
            self.assertEqual(self.c.status, "Send button pressed.")

    def test_send_retries_for_delayed_paste_then_presses_once(self):
        self.c.config['sendEnabled']=True
        callbacks=[]
        timer=types.SimpleNamespace(scheduledTimerWithTimeInterval_repeats_block_=lambda d,r,f:callbacks.append(f))
        with patch.object(v,'NSTimer',timer), patch.object(v,'same_focus',return_value=True), patch.object(v,'ax',side_effect=['','hello']), patch.object(v,'send_button',return_value='button'), patch.object(v,'AXUIElementPerformAction',return_value=0) as press:
            self.c.send_when_pasted((1,'field'),'hello')
            callbacks.pop(0)(None)
            press.assert_not_called()
            callbacks.pop(0)(None)
            press.assert_called_once()
    def test_send_failure_is_bounded_and_visible(self):
        self.c.config['sendEnabled']=True
        callbacks=[]
        timer=types.SimpleNamespace(scheduledTimerWithTimeInterval_repeats_block_=lambda d,r,f:callbacks.append(f))
        with patch.object(v,'NSTimer',timer), patch.object(v,'same_focus',return_value=True), patch.object(v,'ax',return_value='hello'), patch.object(v,'send_button',return_value=None), patch.object(v,'AXUIElementPerformAction') as press:
            self.c.send_when_pasted((1,'field'),'hello')
            for _ in range(6):callbacks.pop(0)(None)
            self.assertFalse(callbacks);press.assert_not_called()
            self.assertEqual(self.emissions[-1][0],'error')
    def test_recovery_reads_last_row_and_never_sends_or_starts_model(self):
        db=sqlite3.connect(':memory:');db.execute('create table dictations(id integer primary key,text text)')
        db.executemany('insert into dictations(text) values (?)',[('old',),('latest',)])
        with patch.object(v,'same_focus',return_value=True),patch.object(v.sqlite3,'connect',return_value=db),patch.object(v,'AXUIElementPerformAction') as press:
            self.c.recover_last((1,'field'))
            self.c.paste.assert_called_once_with('latest');press.assert_not_called()
            self.assertTrue(self.c.d.jobs.empty());self.c.d.start.assert_not_called()
        db.close()
    def test_recovery_refuses_focus_change(self):
        with patch.object(v,'same_focus',return_value=False):self.c.recover_last(None)
        self.c.paste.assert_not_called()

    def test_start_while_busy_does_not_mutate_current_capture(self):
        self.c.d.busy = True
        self.c.capture_mode = "dictation"
        self.c.command("note")
        self.c.d.start.assert_not_called()
        self.assertEqual(self.c.capture_mode, "dictation")
        self.assertEqual(self.emissions, [])

    def test_start_while_module_disabled_is_ignored(self):
        self.c.config["dictationEnabled"] = False
        self.c.command("start")
        self.c.d.start.assert_not_called()
        self.assertEqual(self.emissions, [])

    def test_long_mode_voice_stop_flushes_tail(self):
        self.c.long_mode = "meeting"
        self.c.segment = [np.full(16000, .1, dtype=np.float32)]; self.c.segment_frames = 16000
        self.c.accept("stop", self.c.epoch)
        self.assertIsNone(self.c.long_mode)
        self.assertEqual(self.c.d.jobs.qsize(), 1)
        self.assertEqual(self.emissions[-1][0], "session_stopped")

    def test_long_mode_cancel_discards_unsubmitted_tail(self):
        self.c.long_mode = "ambient"
        self.c.segment = [np.full(16000, .1, dtype=np.float32)]; self.c.segment_frames = 16000
        self.c.accept("cancel", self.c.epoch)
        self.assertIsNone(self.c.long_mode)
        self.assertTrue(self.c.d.jobs.empty())
        self.assertEqual(self.c.segment, [])

    def test_settings_validation_keeps_previous_valid_config(self):
        original = copy.deepcopy(self.c.config)
        self.c.config_file.write_text(json.dumps({"wakeEnabled": True, "phrases": {"start": "invalid @keyword"}}))
        self.c._read_config()
        self.assertEqual(self.c.config, original)
        self.assertIn("Invalid", self.c.status)

    def test_pause_marker_overrides_enabled_settings(self):
        self.c.paused_file.touch()
        self.c.config_file.write_text(json.dumps({**v.DEFAULTS, "wakeEnabled": True}))
        self.c._read_config()
        self.assertFalse(self.c.enabled)

    def test_stale_ipc_commands_are_discarded(self):
        (self.c.inbox / "old.json").write_text(json.dumps({"time": time.time() - 60, "action": "start"}))
        with patch.object(self.c, "command") as command: self.c.tick(); command.assert_not_called()
        self.assertFalse(list(self.c.inbox.glob("*.json")))
        self.assertEqual((self.base / "state.json").stat().st_mode & 0o777, 0o600)

    def test_live_preview_is_queued_not_run_on_audio_callback(self):
        self.c.enabled = False; self.c.config["liveEnabled"] = True; self.c.d.recording = True
        self.c._audio(np.full((16000, 1), .1, dtype=np.float32), 16000, None, None)
        self.c.d.preview.assert_not_called()
        job, _ = self.c.d.jobs.get_nowait()
        job()
        self.c.d.preview.assert_called_once()
        self.assertTrue(self.c.preview_pending)

    def test_idle_audio_never_queues_gpu_transcription(self):
        self.c._audio(np.full((1600, 1), .1, dtype=np.float32), 1600, None, None)
        self.assertTrue(self.c.d.jobs.empty())
        self.assertEqual(self.c.queue.qsize(), 1)
        self.assertEqual(self.emissions, [])

    def test_long_mode_segments_run_on_serial_worker(self):
        self.c.long_mode = "meeting"
        self.c.segment = [np.full(16000, .1, dtype=np.float32)]; self.c.segment_frames = 16000
        self.c.d.transcriber.transcribe.return_value = "Synthetic test segment."
        self.c.queue_segment()
        self.c.d.transcriber.transcribe.assert_not_called()
        job, _ = self.c.d.jobs.get_nowait()
        with patch.dict(sys.modules, {"dictate": types.SimpleNamespace(apply_replacements=lambda text: text)}): job()
        self.assertEqual(self.emissions[-1][0], "segment")
        self.assertEqual(self.emissions[-1][1]["session"], "test-session")
        self.assertEqual(self.c.segment_pending, 0)

    def test_segment_is_committed_to_sqlite_before_event(self):
        database = sqlite3.connect(":memory:")
        self.addCleanup(database.close)
        database.execute("CREATE TABLE dictations (text TEXT, app TEXT, audio_seconds REAL, transcribe_ms INTEGER, model TEXT)")
        self.c.db = database
        self.c.long_mode = "meeting"
        self.c.segment = [np.full(16000, .1, dtype=np.float32)]; self.c.segment_frames = 16000
        self.c.d.transcriber.transcribe.return_value = "A durable synthetic meeting chunk."
        order = []
        def event(kind, **data):
            if kind == "segment":
                self.assertFalse(database.in_transaction)
                self.assertEqual(database.execute("SELECT text, app, model FROM dictations").fetchone(),
                                 ("A durable synthetic meeting chunk.", "meeting", "synthetic-test-model"))
                order.append("committed-before-event")
        self.c.emit = event
        self.c.queue_segment()
        job, _ = self.c.d.jobs.get_nowait()
        with patch.dict(sys.modules, {"dictate": types.SimpleNamespace(apply_replacements=lambda text: text)}): job()
        self.assertEqual(order, ["committed-before-event"])
        self.assertEqual(self.c.segment_pending, 0)

    def test_segment_commit_failure_never_emits_success(self):
        self.c.long_mode = "meeting"
        self.c.segment = [np.full(16000, .1, dtype=np.float32)]; self.c.segment_frames = 16000
        self.c.d.transcriber.transcribe.return_value = "Synthetic chunk that cannot be saved."
        self.c.db.commit.side_effect = sqlite3.OperationalError("synthetic disk failure")
        self.c.queue_segment()
        job, _ = self.c.d.jobs.get_nowait()
        with self.assertLogs(v.log, level="ERROR"), patch.dict(sys.modules, {"dictate": types.SimpleNamespace(apply_replacements=lambda text: text)}): job()
        self.c.db.commit.assert_called_once()
        self.assertFalse(any(kind == "segment" for kind, _ in self.emissions))
        self.assertTrue(any(kind == "error" for kind, _ in self.emissions))
        self.assertEqual(self.c.segment_pending, 0)
        self.assertIsNone(self.c.long_mode)

    def test_system_audio_commit_precedes_segment_and_ack(self):
        import soundfile as sf
        allowed = self.base / "Library/Application Support/Pico/MeetingAudio"
        allowed.mkdir(parents=True)
        path = allowed / "synthetic.wav"
        sf.write(path, np.full(16000, .1, dtype=np.float32), 16000)
        self.c.d.transcriber.transcribe.return_value = "Synthetic system audio."
        order = []
        self.c.db.execute.side_effect = lambda *args: order.append("insert")
        self.c.db.commit.side_effect = lambda: order.append("commit")
        self.c.emit = lambda kind, **data: order.append(kind)
        with patch.object(v.Path, "home", return_value=self.base):
            self.c.transcribe_system({"path": str(path), "session": "system-test"})
        self.assertEqual(order, [])
        job, _ = self.c.d.jobs.get_nowait()
        with patch.dict(sys.modules, {"dictate": types.SimpleNamespace(apply_replacements=lambda text: text)}): job()
        self.assertEqual(order, ["insert", "commit", "segment", "system_audio_done"])
        self.assertTrue(path.exists(), "worker keeps WAV until native persistence acknowledgment")
        self.assertEqual(self.c.segment_pending, 0)

    def test_stop_and_cancel_wait_for_audio_segment_lock(self):
        original_concatenate = np.concatenate
        for discard in (False, True):
            with self.subTest(discard=discard):
                self.c.enabled = False; self.c.long_mode = "meeting"; self.c.segment_pending = 0
                self.c.d.jobs = queue.Queue()
                self.c.segment = [np.full(16000 * 12 - 1600, .1, dtype=np.float32)]
                self.c.segment_frames = 16000 * 12 - 1600
                audio_inside_lock = threading.Event(); release_audio = threading.Event(); stop_finished = threading.Event()
                def blocking_concatenate(*args, **kwargs):
                    audio_inside_lock.set()
                    if not release_audio.wait(2): raise RuntimeError("test synchronization timeout")
                    return original_concatenate(*args, **kwargs)
                def stop_capture():
                    self.c.stop_long(discard=discard)
                    stop_finished.set()
                with patch.object(v.np, "concatenate", side_effect=blocking_concatenate):
                    audio_thread = threading.Thread(target=lambda: self.c._audio(np.full((1600, 1), .1, dtype=np.float32), 1600, None, None))
                    audio_thread.start()
                    try:
                        self.assertTrue(audio_inside_lock.wait(2))
                        stop_thread = threading.Thread(target=stop_capture)
                        stop_thread.start()
                        self.assertFalse(stop_finished.wait(.03), "stop must wait for the in-flight audio buffer operation")
                    finally:
                        release_audio.set()
                        audio_thread.join(2)
                    stop_thread.join(2)
                self.assertFalse(audio_thread.is_alive()); self.assertFalse(stop_thread.is_alive())
                self.assertTrue(stop_finished.is_set())
                self.assertIsNone(self.c.long_mode)
                self.assertEqual(self.c.segment, [])
                self.assertEqual(self.c.segment_frames, 0)
                self.assertEqual(self.c.d.jobs.qsize(), 1, "completed segment is neither lost nor queued twice")

    def test_silence_not_saved_as_meeting_segment(self):
        self.c.long_mode = "meeting"
        self.c.segment = [np.zeros(16000, dtype=np.float32)]; self.c.segment_frames = 16000
        self.c.queue_segment()
        self.assertTrue(self.c.d.jobs.empty())

    def test_long_mode_backlog_is_bounded_and_reported(self):
        self.c.long_mode = "ambient"; self.c.segment_pending = 3
        self.c.segment = [np.full(16000, .1, dtype=np.float32)]; self.c.segment_frames = 16000
        self.c.queue_segment()
        self.assertTrue(self.c.d.jobs.empty())
        self.assertIsNone(self.c.long_mode)
        self.assertEqual(self.emissions[-1][0], "error")

    def test_start_and_loop_audio_respect_settings_and_stop(self):
        cls,env=dictation_class();env['feedback_sound']=Mock(return_value=Mock())
        d=cls.__new__(cls);d.voice_control=self.c;d.recording=True;d.feedback_started=False
        self.c.config.update(startSound='none',endSound='Ping',talkingSound='UFO',soundVolume=.2)
        d.start_audio_feedback()
        self.assertEqual(env['feedback_sound'].call_args_list[0].args,('none',.2))
        self.assertEqual(env['feedback_sound'].call_args_list[1].args,('UFO',.2*.35,True))
        d.start_audio_feedback();self.assertEqual(env['feedback_sound'].call_count,2)
        loop=d.loop_sound;d.stop_audio_feedback();loop.stop.assert_called_once()
        d.play_cue('end');self.assertEqual(env['feedback_sound'].call_args.args,('Ping',.2))

    def test_fn_session_resets_previous_note_mode(self):
        cls, env = dictation_class()
        d = cls.__new__(cls)
        d.recording = False; d.busy = False; d.audio_lock = threading.RLock()
        d.voice_control = self.c; d.jobs = queue.Queue(); d.indicator = Mock()
        self.c.d = d; self.c.capture_mode = "note"; self.c.send_after = True
        target = (100, "field", "Test", "com.openai.codex")
        with patch.object(v, "focus", return_value=target): d.start()
        self.assertEqual(d.target, target)
        self.assertEqual(self.c.capture_mode, "dictation")
        self.assertFalse(self.c.send_after)

    def test_delayed_transcript_after_typing_is_saved_without_paste_or_send(self):
        cls,env=dictation_class();d=cls.__new__(cls)
        d.voice_control=self.c;d.transcriber=Mock();d.transcriber.name='fake'
        d.transcriber.transcribe.return_value='Saved delayed dictation.';d.db=Mock()
        d.input_revision=5;self.c.send_when_pasted=Mock()
        with patch.object(v,'same_focus',return_value=True):
            d._transcribe_and_paste(np.zeros(16000),{'app':'Test','voice':False,'mode':'dictation','send':True,'target':(1,'field'),'input_revision':4})
        d.db.commit.assert_called_once();env['paste'].assert_not_called()
        self.c.send_when_pasted.assert_not_called()

    def test_fn_delivery_also_requires_original_focus(self):
        cls,env=dictation_class();d=cls.__new__(cls)
        d.voice_control=self.c;d.transcriber=Mock();d.transcriber.name='fake'
        d.transcriber.transcribe.return_value='Saved in original field.';d.db=Mock()
        with patch.object(v,'same_focus',return_value=False):
            d._transcribe_and_paste(np.zeros(16000),{'app':'Test','voice':False,'mode':'dictation','target':(1,'field')})
        d.db.commit.assert_called_once();env['paste'].assert_not_called()

    def test_fn_send_strips_command_and_preserves_target(self):
        cls, env = dictation_class()
        d = cls.__new__(cls); d.voice_control = self.c; d.transcriber = Mock()
        d.transcriber.name = "fake"; d.transcriber.transcribe.return_value = "Hello there. Finish and send."
        d.db = Mock(); self.c.send_when_pasted = Mock()
        target = (100, "field", "Test", "com.openai.codex")
        with patch.object(v, "same_focus", return_value=True):
            d._transcribe_and_paste(np.zeros(16000), {"app":"Test", "voice":False, "mode":"dictation", "send":True, "target":target})
        env["paste"].assert_called_once_with("Hello there")
        self.c.send_when_pasted.assert_called_once_with(target, "Hello there")
        d.db.commit.assert_called_once()

    def test_stale_preview_is_suppressed_and_pending_flag_cleared(self):
        cls, _ = dictation_class()
        d = cls.__new__(cls); d.transcriber = Mock(); d.transcriber.transcribe.return_value = "synthetic preview"
        d.voice_control = self.c; d.recording = True
        self.c.preview_pending = True
        d.preview(np.zeros(16000), self.c.epoch - 1)
        self.assertFalse(self.emissions)
        self.assertFalse(self.c.preview_pending)

    def test_worker_runs_preview_warmup_and_final_transcription_serially(self):
        cls, env = dictation_class()
        d = cls.__new__(cls)
        order = []; current_thread = threading.get_ident()
        class FakeQueue:
            def __init__(self): self.items = iter([(lambda: order.append(("preview", threading.get_ident())), None), (None, None), (np.zeros(16000), {})])
            def get(self): return next(self.items)
        d.jobs = FakeQueue(); d.ready = threading.Event()
        d._warm_up = lambda: order.append(("warmup", threading.get_ident()))
        d._finish = lambda *args: order.append(("final", threading.get_ident()))
        env["_engine_config"] = {}
        env["Transcriber"] = lambda *args: types.SimpleNamespace(name="fake")
        d.voice_control = self.c
        with self.assertRaises(StopIteration): d._worker()
        self.assertTrue(d.ready.is_set())
        self.assertEqual(order, [("preview", current_thread), ("warmup", current_thread), ("final", current_thread)])

    def test_model_load_failure_unblocks_startup_and_prevents_recording(self):
        cls, env = dictation_class()
        d = cls.__new__(cls); d.voice_control = self.c; d.ready = threading.Event()
        env["_engine_config"] = {}
        env["Transcriber"] = Mock(side_effect=RuntimeError("synthetic load failure"))
        d._worker()
        self.assertTrue(d.ready.is_set())
        self.assertIn("failed to load",d.model_error)
        d.start()
        self.assertFalse(hasattr(d,"recording"))

    def test_history_saved_before_delivery_and_non_dictation_never_pastes(self):
        cls, env = dictation_class()
        d = cls.__new__(cls); d.voice_control = self.c; d.transcriber = Mock()
        d.transcriber.name = "fake"; d.transcriber.transcribe.return_value = "A synthetic note."
        d.db = Mock(); order = []
        d.db.commit.side_effect = lambda: order.append("commit")
        self.c.emit = lambda *args, **kwargs: order.append("event")
        env["paste"].side_effect = lambda text: order.append("paste")
        d._transcribe_and_paste(np.zeros(16000), {"app": "Test", "voice": False, "mode": "note"})
        self.assertEqual(order, ["commit", "event"])
        env["paste"].assert_not_called()
        order.clear()
        with patch.object(v,"same_focus",return_value=True):
            d._transcribe_and_paste(np.zeros(16000), {"app": "Test", "voice": False, "mode": "dictation", "target":(1,"field")})
        self.assertEqual(order, ["commit", "event", "paste"])


if __name__=='__main__':unittest.main()
