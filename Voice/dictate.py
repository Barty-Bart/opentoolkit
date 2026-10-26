"""Push-to-talk dictation with no menu or window, just a small listening pill.

Hold Fn: record while held, transcribe and paste on release.
Double-tap Fn: hands-free mode; double-tap Fn again to stop and paste. A single tap does nothing.
Fn combined with another key (Fn+arrow, Fn+F1, ...) cancels the recording.

Runs local GPU or CPU speech according to the selected backend. Every dictation is saved
to the shared OpenToolkit library in Application Support.
"""

import logging
import json
import math, wave, io, struct
import os
import queue
import re
import sqlite3
import subprocess
import tempfile
import threading
import time
from pathlib import Path

import numpy as np
import sounddevice as sd
import soundfile as sf
import AVFoundation
import objc
import Quartz
from AppKit import (
    NSApplication, NSApplicationActivationPolicyAccessory, NSBackingStoreBuffered, NSBezierPath,
    NSColor, NSEvent, NSPanel, NSPasteboard, NSPasteboardTypeString, NSScreen, NSStatusWindowLevel,
    NSSound, NSTimer, NSView, NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorFullScreenAuxiliary, NSWindowStyleMaskBorderless,
    NSWindowStyleMaskNonactivatingPanel, NSWorkspace,
)
from ApplicationServices import (
    AXIsProcessTrustedWithOptions, AXUIElementCopyAttributeValue,
    AXUIElementCopyParameterizedAttributeValue, AXUIElementCreateApplication,
    AXUIElementSetAttributeValue, AXUIElementSetMessagingTimeout, AXValueCreate, AXValueGetValue,
    kAXBoundsForRangeParameterizedAttribute, kAXFocusedUIElementAttribute, kAXPositionAttribute,
    kAXSelectedTextRangeAttribute, kAXSizeAttribute, kAXValueCFRangeType, kAXValueCGPointType,
    kAXValueCGRectType, kAXValueCGSizeType,
)
from Foundation import (
    NSData, NSActivityLatencyCritical, NSActivityUserInitiatedAllowingIdleSystemSleep, NSDictionary,
    NSMakeRect, NSPointInRect, NSProcessInfo,
)
from PyObjCTools import AppHelper

# --- settings -------------------------------------------------------------

try:
    _engine_config=json.loads((Path.home()/'Library/Application Support/Pico/VoiceBridge/config.json').read_text())
except (OSError,ValueError):_engine_config={}
TAP_SECONDS = 0.30        # shorter Fn press = tap
DOUBLE_TAP_SECONDS = 0.45 # gap between two Fn taps that toggles hands-free
MIN_AUDIO_SECONDS = 0.35  # ignore anything shorter
SAMPLE_RATE = 16000
LONG_AUDIO_SECONDS = 180  # longer recordings go through Parakeet's chunked path
START_SOUND = "/System/Library/Sounds/Tink.aiff"
STOP_SOUND = "/System/Library/Sounds/Pop.aiff"

from runtime_paths import speech_data
HOME = speech_data()
DB_PATH = HOME / "history.sqlite"
REPLACEMENTS_PATH = HOME / "replacements.txt"

DEBUG_KEYS = False  # Keystroke logging is disabled in distributable builds.

FN_KEYCODE = 63
V_KEYCODE = 9

log = logging.getLogger("dictate")


# --- transcription --------------------------------------------------------

from speech_backend import Transcriber


def load_replacements():
    """replacements.txt lines look like:  incorrect word => correct word"""
    rules = []
    from library_store import get_value
    content=get_value("manual_replacements",REPLACEMENTS_PATH,"")
    if content:
        for line in content.splitlines():
            if "=>" in line and not line.lstrip().startswith("#"):
                wrong, right = (s.strip() for s in line.split("=>", 1))
                if wrong:
                    rules.append((re.compile(rf"\b{re.escape(wrong)}\b", re.IGNORECASE), right))
    return rules


def apply_replacements(text: str) -> str:
    try:
        rules = load_replacements()
    except sqlite3.Error:
        # A busy library must not turn a finished dictation into a failure.
        log.warning("Manual replacements unavailable; preserving original transcript")
        rules = []
    for pattern, right in rules:
        text = pattern.sub(right, text)
    from corrections import RuleStore
    return RuleStore(Path.home()/"Library/Application Support/Pico/Speech/corrections.json").apply(text)


# --- history --------------------------------------------------------------

def open_db():
    from library_store import connect
    return connect(legacy=DB_PATH)


# --- output ---------------------------------------------------------------

def play(sound):
    subprocess.Popen(["afplay", sound], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def ufo_wav():
    rate=22050;duration=2.0
    samples=[]
    for i in range(int(rate*duration)):
        t=i/rate
        phase=2*math.pi*180*t+5*math.sin(2*math.pi*2*t)
        value=.4*math.sin(phase)+.12*math.sin(2*phase)
        samples.append(int(32767*value))
    out=io.BytesIO()
    with wave.open(out,'wb') as w:
        w.setnchannels(1);w.setsampwidth(2);w.setframerate(rate)
        w.writeframes(struct.pack('<'+'h'*len(samples),*samples))
    return out.getvalue()

def feedback_sound(name,volume,loop=False):
    if name=='none' or name=='off':return None
    if name=='UFO':
        data=ufo_wav()
        sound=NSSound.alloc().initWithData_(NSData.dataWithBytes_length_(data,len(data)))
    elif name in ('Tink','Pop','Glass','Ping','Submarine','Blow','Purr'):
        sound=NSSound.alloc().initWithContentsOfFile_byReference_('/System/Library/Sounds/'+name+'.aiff',True)
    elif name.startswith('custom:'):
        filename=name.removeprefix('custom:')
        if Path(filename).name!=filename:return None
        path=Path.home()/'Library/Application Support/Pico/Sounds'/filename
        sound=NSSound.alloc().initWithContentsOfFile_byReference_(str(path),True)
    else:return None
    if sound is not None:
        sound.setVolume_(max(0,min(1,float(volume))))
        sound.setLoops_(loop);sound.play()
    return sound


def frontmost_app():
    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    return app.localizedName() if app else None


_clipboard_lock = threading.Lock()
_clipboard_pending = None  # the user's clipboard while an earlier paste awaits restore
CLIPBOARD_RESTORE_SECONDS = 1.0


def paste(text: str):
    """Put text on the clipboard, press Cmd+V, then restore the old clipboard."""
    global _clipboard_pending
    pb = NSPasteboard.generalPasteboard()
    with _clipboard_lock:
        if _clipboard_pending is not None:
            # Back-to-back pastes: keep the user's clipboard, not our earlier transcript.
            saved = _clipboard_pending['saved']
        else:
            saved = []
            for item in pb.pasteboardItems() or []:
                saved.append({t: item.dataForType_(t) for t in item.types() if item.dataForType_(t) is not None})
        pb.clearContents()
        pb.setString_forType_(text, NSPasteboardTypeString)
        change = pb.changeCount()
        token = object()
        _clipboard_pending = {'saved': saved, 'token': token}

    src = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateCombinedSessionState)
    for down in (True, False):
        ev = Quartz.CGEventCreateKeyboardEvent(src, V_KEYCODE, down)
        Quartz.CGEventSetIntegerValueField(ev, Quartz.kCGEventSourceUserData, 0x4D4D5450)
        Quartz.CGEventSetFlags(ev, Quartz.kCGEventFlagMaskCommand)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, ev)

    def restore():
        global _clipboard_pending
        # Slow targets handle Cmd-V late; restoring too early pastes the old clipboard.
        time.sleep(CLIPBOARD_RESTORE_SECONDS)
        with _clipboard_lock:
            if _clipboard_pending is None or _clipboard_pending['token'] is not token:
                return  # a later paste owns the restore
            _clipboard_pending = None
            if pb.changeCount() != change or not saved:
                return  # something else touched the clipboard; leave it alone
            from AppKit import NSPasteboardItem
            pb.clearContents()
            items = []
            for types in saved:
                item = NSPasteboardItem.alloc().init()
                for t, data in types.items():
                    item.setData_forType_(data, t)
                items.append(item)
            pb.writeObjects_(items)

    threading.Thread(target=restore, daemon=True).start()


# --- listening indicator --------------------------------------------------

PILL_W, PILL_H = 58, 22
BARS = 5


class PillView(NSView):
    """Red dot + live level bars while recording; pulsing dots while transcribing."""

    def initWithFrame_(self, frame):
        self = objc.super(PillView, self).initWithFrame_(frame)
        if self is not None:
            self.style = "waveform"
            self.tint = "cyan"
            self.busy = False
            self.levels = [0.0] * BARS
            self.phase = 0.0
        return self

    def isOpaque(self):
        return False

    def drawRect_(self, rect):
        b = self.bounds()
        if getattr(self,"style","waveform") != "waves":
            NSColor.colorWithCalibratedWhite_alpha_(0.08, 0.88).setFill()
            NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(b,b.size.height/2,b.size.height/2).fill()
        mid = b.size.height / 2
        colors={"cyan":(0.1,.8,1.),"blue":(.15,.4,1.),"orange":(1.,.55,.15),"pink":(1.,.35,.7),"purple":(.7,.4,1.),"green":(.2,1.,.5),"red":(1.,.3,.3)}
        red,green,blue=colors.get(getattr(self,"tint","cyan"),colors["cyan"])
        if getattr(self,"style","waveform") == "waves":
            NSColor.colorWithCalibratedRed_green_blue_alpha_(red,green,blue,1).setFill()
            for i,lv in enumerate(self.levels):
                h=3+lv*13 if not self.busy else 5+5*max(0,np.sin(self.phase-i*.8))
                NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(NSMakeRect(3+i*6,mid-h/2,3,h),1.5,1.5).fill()
            return
        if getattr(self,"style","waveform") in ("dot","orb"):
            lv=max(self.levels or [0])
            if self.busy:lv=.4+.3*np.sin(self.phase)
            diameter=8+lv*5 if self.style=="dot" else 14+lv*7
            if self.style=="orb":
                NSColor.colorWithCalibratedRed_green_blue_alpha_(red,green,blue,.2).setFill()
                NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(b.size.width/2-diameter/2-3,mid-diameter/2-3,diameter+6,diameter+6)).fill()
            NSColor.colorWithCalibratedRed_green_blue_alpha_(red,green,blue,1).setFill()
            NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(b.size.width/2-diameter/2,mid-diameter/2,diameter,diameter)).fill()
            return
        if self.busy:
            for i in range(3):
                a = 0.35 + 0.65 * max(0.0, np.sin(self.phase - i * 0.9))
                NSColor.colorWithCalibratedWhite_alpha_(1.0, a).setFill()
                NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(17 + i * 9, mid - 2.5, 5, 5)).fill()
            return
        NSColor.colorWithCalibratedRed_green_blue_alpha_(red,green,blue,1).setFill()
        NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(9, mid - 3.5, 7, 7)).fill()
        NSColor.whiteColor().setFill()
        for i, lv in enumerate(self.levels):
            h = 3 + lv * (PILL_H - 9)
            NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
                NSMakeRect(23 + i * 6, mid - h / 2, 3, h), 1.5, 1.5).fill()


def _ax(el, attr):
    err, val = AXUIElementCopyAttributeValue(el, attr, None)
    return None if err else val


_last_bounds_error = None


def _ax_rect_for_range(el, loc, length):
    global _last_bounds_error
    err, val = AXUIElementCopyParameterizedAttributeValue(
        el, kAXBoundsForRangeParameterizedAttribute, AXValueCreate(kAXValueCFRangeType, (loc, length)), None)
    if err or val is None:
        _last_bounds_error = err
        return None
    ok, r = AXValueGetValue(val, kAXValueCGRectType, None)
    _last_bounds_error = f"got {r.origin.x:.0f},{r.origin.y:.0f} {r.size.width:.0f}x{r.size.height:.0f}" if ok else "unreadable"
    if not ok or r.size.height <= 0 or (r.origin.x == 0 and r.origin.y == 0):
        return None
    return r


_ax_enabled_pids = {}
AX_REENABLE_SECONDS = 20  # Chromium switches accessibility off again when idle


def enable_app_accessibility(pid):
    """Chromium/Electron apps (Claude, ChatGPT, Chrome, VS Code) only expose their
    text cursor to other apps after being asked to build their accessibility tree."""
    now = time.monotonic()
    if now - _ax_enabled_pids.get(pid, -AX_REENABLE_SECONDS) < AX_REENABLE_SECONDS:
        return
    _ax_enabled_pids[pid] = now
    app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.2)
    AXUIElementSetAttributeValue(app, "AXManualAccessibility", True)


def caret_rect():
    """(rect, how) for the text cursor in the focused app, top-left screen coordinates.
    Returns (None, reason) when the app does not expose a measurable caret."""
    try:
        front = NSWorkspace.sharedWorkspace().frontmostApplication()
        if front is None:
            return None, "no frontmost app"
        enable_app_accessibility(front.processIdentifier())
        app = AXUIElementCreateApplication(front.processIdentifier())
        AXUIElementSetMessagingTimeout(app, 0.15)
        el = _ax(app, kAXFocusedUIElementAttribute)
        if el is None:
            return None, "no focused element"

        rng = _ax(el, kAXSelectedTextRangeAttribute)
        role = _ax(el, "AXRole")
        detail = f"role={role}, range={'none' if rng is None else 'yes'}"
        if rng is not None:
            ok, cf = AXValueGetValue(rng, kAXValueCFRangeType, None)
            if ok:
                loc, length = cf
                detail += f", caret at {loc}+{length}"
                loc += length
                r = _ax_rect_for_range(el, loc, 0)
                if r is not None and 0 <= r.size.width < 4 and r.size.height <= 100:
                    return r, "caret"
                # Chromium returns nothing for an empty range: measure a neighbouring character.
                if loc > 0:
                    r = _ax_rect_for_range(el, loc - 1, 1)
                    if r is not None and 0 < r.size.width <= max(40,r.size.height*2) and r.size.height <= 100:
                        r.origin.x += r.size.width
                        r.size.width = 1
                        return r, "char before caret"
                r = _ax_rect_for_range(el, loc, 1)
                if r is not None and 0 < r.size.width <= max(40,r.size.height*2) and r.size.height <= 100:
                    r.size.width = 1
                    return r, "char after caret"

        return None, "app does not expose the text caret"
    except Exception as e:
        return None, f"error: {e}"


def focused_text_frame():
    """Actual focused input bounds, never a fabricated caret or whole window."""
    try:
        front=NSWorkspace.sharedWorkspace().frontmostApplication()
        if front is None:return None
        app=AXUIElementCreateApplication(front.processIdentifier())
        AXUIElementSetMessagingTimeout(app,0.15)
        el=_ax(app,kAXFocusedUIElementAttribute)
        for _ in range(4):
            if el is None:return None
            if _ax(el,'AXRole') in ('AXTextField','AXTextArea','AXComboBox'):
                pos=_ax(el,kAXPositionAttribute);size=_ax(el,kAXSizeAttribute)
                if pos is not None and size is not None:
                    ok,p=AXValueGetValue(pos,kAXValueCGPointType,None)
                    valid,sz=AXValueGetValue(size,kAXValueCGSizeType,None)
                    if ok and valid and sz.width>=20 and sz.height>=12:
                        return (p.x,p.y,sz.width,sz.height)
            el=_ax(el,'AXParent')
    except Exception:pass
    return None


class GlowView(NSView):
    def isOpaque(self):return False
    def drawRect_(self,rect):
        colors={'cyan':(0.1,.8,1.),'blue':(.15,.4,1.),'purple':(.7,.4,1.),'green':(.2,1.,.5)}
        red,green,blue=colors.get(getattr(self,'tint','cyan'),colors['cyan'])
        b=self.bounds()
        for inset,width,alpha in [(8,10,.10),(8,6,.22),(8,2,.9)]:
            NSColor.colorWithCalibratedRed_green_blue_alpha_(red,green,blue,alpha).setStroke()
            path=NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(NSMakeRect(inset,inset,max(1,b.size.width-2*inset),max(1,b.size.height-2*inset)),12,12)
            path.setLineWidth_(width);path.stroke()


class Indicator:
    def __init__(self, dictation):
        self.dictation = dictation
        self.panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, PILL_W, PILL_H),
            NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel,
            NSBackingStoreBuffered, False)
        self.panel.setOpaque_(False)
        self.panel.setBackgroundColor_(NSColor.clearColor())
        self.panel.setLevel_(NSStatusWindowLevel)
        self.panel.setIgnoresMouseEvents_(True)
        self.panel.setHasShadow_(True)
        self.panel.setHidesOnDeactivate_(False)
        self.panel.setCollectionBehavior_(
            NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary)
        self.view = PillView.alloc().initWithFrame_(NSMakeRect(0, 0, PILL_W, PILL_H))
        self.panel.setContentView_(self.view)
        self.timer = None
        self.ticks = 0
        self.listening = False
        self.glow = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(NSMakeRect(0,0,100,40),NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel,NSBackingStoreBuffered,False)
        self.glow.setOpaque_(False);self.glow.setBackgroundColor_(NSColor.clearColor());self.glow.setLevel_(NSStatusWindowLevel)
        self.glow.setIgnoresMouseEvents_(True);self.glow.setHidesOnDeactivate_(False)
        self.glow.setCollectionBehavior_(NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary)
        self.glow_view=GlowView.alloc().initWithFrame_(NSMakeRect(0,0,100,40));self.glow.setContentView_(self.glow_view)

    def _place(self):
        from indicator_layout import place_indicator, place_near_field
        config=self.dictation.voice_control.config
        style=config.get('indicatorStyle') or 'waveform'
        width,height={'waveform':(58,22),'dot':(22,22),'orb':(32,32),'waves':(34,22)}.get(style,(58,22))
        self.view.style=style;self.view.tint=config.get('indicatorColor') or 'cyan'
        self.panel.setHasShadow_(style != "waves")
        self.panel.setContentSize_((width,height))
        screens=NSScreen.screens()
        if not screens:return
        frames=[(sc.visibleFrame().origin.x,sc.visibleFrame().origin.y,sc.visibleFrame().size.width,sc.visibleFrame().size.height) for sc in screens]
        mouse=NSEvent.mouseLocation();caret=None
        if (config.get('indicatorPosition') or 'text')=='text':
            r,_=caret_rect()
            if r is not None:
                primary=screens[0].frame()
                top=primary.origin.y+primary.size.height
                caret=(r.origin.x,top-r.origin.y-r.size.height,r.size.width,r.size.height)
        origin=place_indicator(frames,(mouse.x,mouse.y),caret,(width,height))
        if caret is None and (config.get('indicatorPosition') or 'text')=='text':
            field=focused_text_frame()
            if field:
                primary=screens[0].frame();top=primary.origin.y+primary.size.height
                x,y,w,h=field
                nearby=place_near_field(frames,(x,top-y-h,w,h),(width,height))
                if nearby is not None:origin=nearby
        self.panel.setFrameOrigin_(origin)

    def _show_glow(self):
        from voice_control import same_focus
        target=self.dictation.target
        config=self.dictation.voice_control.config
        if not config.get('glowEnabled',False) or not same_focus(target):self.glow.orderOut_(None);return
        pos=_ax(target[1],kAXPositionAttribute);size=_ax(target[1],kAXSizeAttribute)
        if pos is None or size is None:self.glow.orderOut_(None);return
        ok,p=AXValueGetValue(pos,kAXValueCGPointType,None);valid,sz=AXValueGetValue(size,kAXValueCGSizeType,None)
        if not ok or not valid or sz.width<20 or sz.height<12:self.glow.orderOut_(None);return
        if _ax(target[1],'AXRole') not in ('AXTextField','AXTextArea','AXComboBox'):self.glow.orderOut_(None);return
        from indicator_layout import glow_frame
        screens=NSScreen.screens()
        if not screens:self.glow.orderOut_(None);return
        primary=screens[0].frame();top=primary.origin.y+primary.size.height
        frames=[(sc.visibleFrame().origin.x,sc.visibleFrame().origin.y,sc.visibleFrame().size.width,sc.visibleFrame().size.height) for sc in screens]
        r,_=caret_rect();caret=None if r is None else (r.origin.x,top-r.origin.y-r.size.height,r.size.width,r.size.height)
        frame=glow_frame((p.x,top-p.y-sz.height,sz.width,sz.height),frames,caret)
        if frame is None:self.glow.orderOut_(None);return
        self.glow_view.tint=config.get('glowColor') or 'cyan'
        self.glow.setFrame_display_(NSMakeRect(*frame),True)
        self.glow_view.setNeedsDisplay_(True);self.glow.orderFrontRegardless()

    def show_listening(self):
        self.listening=True
        self.view.busy=False
        self.view.levels=[.15]*BARS
        self._place()
        self.panel.orderFrontRegardless()
        self.glow.orderOut_(None)
        self._start_timer()

    def show_recording(self):
        self.listening=False
        self.view.busy = False
        self.view.levels = [0.0] * BARS
        self._place()
        if self.dictation.voice_control.config.get("indicatorEnabled",True):self.panel.orderFrontRegardless()
        else:self.panel.orderOut_(None)
        self._show_glow()
        self._start_timer()

    def show_busy(self):
        self.listening=False
        self.view.busy = True
        self.glow.orderOut_(None)
        self._place()
        if self.dictation.voice_control.config.get("indicatorEnabled",True):self.panel.orderFrontRegardless()
        else:self.panel.orderOut_(None)
        self._start_timer()

    def hide(self):
        self.listening=False
        if self.timer:
            self.timer.invalidate()
            self.timer = None
        self.panel.orderOut_(None)
        self.glow.orderOut_(None)

    def _start_timer(self):
        if self.timer is None:
            self.timer = NSTimer.scheduledTimerWithTimeInterval_repeats_block_(1 / 30, True, lambda t: self._tick())

    def _tick(self):
        v = self.view
        self.ticks+=1
        if self.ticks%6==0:self._place()
        if self.ticks%15==0 and not v.busy and not self.listening:self._show_glow()
        if v.busy:
            v.phase += 0.25
        else:
            lv = max(.15 if self.listening else 0, min(1.0, self.dictation.level * 18))
            v.levels = v.levels[1:] + [lv]
        v.setNeedsDisplay_(True)


# --- recording + hotkey ---------------------------------------------------

class Dictation:
    def wake_feedback(self):
        config=self.voice_control.config
        self.cue_sound=feedback_sound(config.get('wakeSound') or 'Tink',config.get('soundVolume') if config.get('soundVolume') is not None else .25)
        self.indicator.show_listening()

    def end_wake_feedback(self):
        if self.recording:self.indicator.show_recording()
        elif self.busy:self.indicator.show_busy()
        else:self.indicator.hide()

    def preview_feedback(self,cue):
        if cue not in ('startSound','endSound','talkingSound','wakeSound'):return
        sound=getattr(self,'preview_sound',None)
        if sound:sound.stop()
        config=self.voice_control.config
        defaults={'startSound':'Tink','endSound':'Pop','talkingSound':'off','wakeSound':'Tink'}
        self.preview_sound=feedback_sound(config.get(cue) or defaults[cue],config.get('soundVolume',.25),loop=False)

    def __init__(self, db):
        self.db = db
        self.transcriber = None
        self.jobs = queue.Queue()
        self.ready = threading.Event()
        self.level = 0.0
        self.indicator = None
        threading.Thread(target=self._worker, daemon=True).start()
        self.stream = None
        self.audio_lock = threading.Lock()
        self.audio_frames = 0
        self.busy = False
        self.voice_session = False
        self.target = None
        self.loop_sound = None
        self.cue_sound = None
        self.feedback_started = False
        self.chunks = []
        self.recording = False
        self.hands_free = False
        self.fn_down = False
        self.fn_down_at = 0.0
        self.combo = False
        self.app = None

    # audio
    def _on_audio(self, indata, frames, t, status):
        samples = indata[:, 0].copy()
        self.chunks.append(samples)
        self.level = float(np.sqrt(np.mean(samples * samples)))

    def start(self, voice=False, target=None):
        if getattr(self,"model_error",None):
            self.voice_control.label(self.model_error);return
        if self.recording or self.busy or not self.voice_control.config.get("dictationEnabled", True) or self.voice_control.long_mode:
            return
        if not voice:
            self.voice_control.capture_mode="dictation"
            self.voice_control.send_after=False
            self.voice_control.writing_override=None
        self.session_writing_mode=getattr(self.voice_control,"writing_override",None) or self.voice_control.config.get("writingMode","verbatim")
        with self.audio_lock:
            self.chunks = []
            self.audio_frames = 0
            self.app = frontmost_app()
            self.voice_session = voice
            from voice_control import focus, unreported_focus
            self.target = target if voice else focus()
            # Apps that hide their text box from Accessibility may still be pasted into
            # later, but only if the same app stays in front and nothing is typed or clicked.
            self.fallback_app = unreported_focus() if self.target is None and not voice else None
            self.delivery_revision = getattr(self, 'input_revision', 0)
            self.delivery_generation = getattr(self, 'delivery_generation', 0) + 1
            self.recording = True
            self.feedback_started = False
            self.preview_offset = 0
            self.live_prefix = ''
            from voice_control import LiveInsertion
            self.live_insertion = LiveInsertion(self.target, paste, self.voice_control.delivery_status) if self.voice_control.config.get('liveEnabled') and self.voice_control.capture_mode=='dictation' and self.session_writing_mode not in ('summary','email_ai') else None
        if self.live_insertion is not None and not self.live_insertion.valid:
            self.live_insertion=None
            self.voice_control.delivery_status('This field does not support live typing. Final text will be pasted when you stop.',True)
        self.voice_control.epoch += 1
        self.voice_control.label()
        self.recovery_error = None
        self.jobs.put((None, None))
        if self.voice_control.mic_ready:
            self.start_audio_feedback()
        self.indicator.show_recording()
        log.info("recording started (%s)", "wake" if voice else "Fn")

    def stop(self, keep=True, voice_end=False, deliver=True):
        with self.audio_lock:
            if not self.recording:
                return
            self.recording = False
            self.hands_free = False
            audio = np.concatenate(self.chunks) if self.chunks else np.zeros(0, dtype=np.float32)
            self.chunks = []
            context = {'app': self.app, 'voice': self.voice_session, 'voice_end': voice_end, 'deliver': deliver, 'target': self.target, 'mode':self.voice_control.capture_mode, 'send':self.voice_control.send_after, 'live':getattr(self,'live_insertion',None), 'fallback_app':getattr(self,'fallback_app',None), 'input_revision':getattr(self,'delivery_revision',0),'delivery_generation':getattr(self,'delivery_generation',0),'writing_mode':getattr(self,'session_writing_mode','verbatim'),'writing_config':dict(self.voice_control.config)}
            self.voice_control.send_after=False
            self.voice_session = False
            self.target = None
        self.stop_audio_feedback()
        self.voice_control.epoch += 1
        if not keep or len(audio) < MIN_AUDIO_SECONDS * SAMPLE_RATE:
            self.voice_control.capture_mode="dictation"
            self.indicator.hide()
            self.voice_control.label()
            return
        self.busy = True
        self.busy_since = time.monotonic()
        self.play_cue("end")
        self.indicator.show_busy()
        self.voice_control.label()
        self.jobs.put((audio, context))

    def play_cue(self,stage):
        config=self.voice_control.config
        name=config.get('startSound' if stage=='start' else 'endSound') or ('Tink' if stage=='start' else 'Pop')
        self.cue_sound=feedback_sound(name,config.get('soundVolume') if config.get('soundVolume') is not None else .25)

    def start_audio_feedback(self):
        if not self.recording or getattr(self,'feedback_started',False):return
        self.feedback_started=True
        self.play_cue('start')
        config=self.voice_control.config
        if config.get('talkingSound') not in (None,'off','none'):
            self.loop_sound=feedback_sound(config['talkingSound'],(config.get('soundVolume') if config.get('soundVolume') is not None else .25)*.35,True)

    def stop_audio_feedback(self):
        sound=getattr(self,'loop_sound',None)
        if sound is not None:sound.stop()
        self.loop_sound=None;self.feedback_started=False

    # A first-launch download can be interrupted (sleep, Wi-Fi). Retry by itself;
    # Hugging Face resumes partial files, so each attempt continues the download.
    LOAD_RETRY_SECONDS = (15, 30, 60, 120, 300)

    def _worker(self):
        # MLX state is per thread, so this one thread loads the model and does every transcription.
        attempts = len(self.LOAD_RETRY_SECONDS) + 1
        for attempt in range(attempts):
            try:
                t = time.time()
                self.transcriber = Transcriber(_engine_config, lambda text: AppHelper.callAfter(lambda: self.voice_control.label(text)))
                log.info("loaded %s in %.1fs", self.transcriber.name, time.time() - t)
                break
            except Exception:
                log.exception("could not load the model (attempt %d of %d)", attempt + 1, attempts)
                if attempt + 1 == attempts:
                    self.model_error = "Speech model failed to load after several tries. Check your internet connection, then use Restart speech."
                    self.ready.set()
                    AppHelper.callAfter(lambda: self.voice_control.label(self.model_error))
                    return
                delay = self.LOAD_RETRY_SECONDS[attempt]
                self.load_status = f"Speech model download was interrupted. Retrying in {delay} s (attempt {attempt + 2} of {attempts})…"
                time.sleep(delay)
                self.load_status = None
        self.ready.set()
        while True:
            audio, app = self.jobs.get()
            if callable(audio):
                try:
                    audio()
                except Exception:
                    log.exception("voice command job failed")
            elif audio is None:
                self._warm_up()
            else:
                self._finish(audio, app)

    def _warm_up(self):
        # After a while idle, macOS powers down the GPU and pages out the model, so the
        # first transcription took seconds. Waking it while you talk hides that cost.
        t = time.time()
        try:
            self.transcriber.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32))
        except Exception:
            log.exception("warm-up failed")
        log.info("warm-up took %d ms", (time.time() - t) * 1000)

    def preview(self, audio, epoch):
        try:
            text = apply_replacements(self.transcriber.transcribe(audio))
            if self.recording and epoch == self.voice_control.epoch:
                combined = ' '.join(part for part in (getattr(self,'live_prefix',''),text) if part)
                if len(audio)>=25*SAMPLE_RATE:
                    self.live_prefix=combined;self.preview_offset+=len(audio)
                def deliver_live():
                    if not self.recording or epoch!=self.voice_control.epoch:return
                    insertion=getattr(self,'live_insertion',None)
                    if insertion is not None and text:insertion.update(combined)
                    self.voice_control.emit('preview',text=combined,mode=self.voice_control.capture_mode)
                AppHelper.callAfter(deliver_live)
        except Exception:
            log.exception('Live transcription failed')
        finally:
            self.voice_control.preview_pending=False

    def _finish(self, audio, app):
        try:
            self._transcribe_and_paste(audio, app)
        except Exception:
            log.exception("Could not finish dictation; recording retained for recovery")
            self.recovery_error = "Dictation failed. Your recording is retained in Pico/Speech/Recovery."
        finally:
            AppHelper.callAfter(self._completed)

    def _completed(self):
        self.busy = False
        self.indicator.hide()
        self.voice_control.epoch += 1
        self.voice_control.capture_mode="dictation"
        self.voice_control.label(getattr(self, "recovery_error", None))

    def _transcribe_and_paste(self, audio, context):
        app = context['app']
        t = time.time()
        from audio_recovery import PendingRecording
        try:
            pending = PendingRecording(audio, SAMPLE_RATE, getattr(self, "recovery_directory", None))
        except Exception:
            # Still transcribe: dropping the in-memory audio here would lose the dictation.
            log.exception("Could not preserve recording before transcription")
            pending = None
        try:
            original_text = self.transcriber.transcribe(audio)
            if pending is not None:
                pending.save_text(original_text)
            text = apply_replacements(original_text)
        except Exception:
            log.exception("transcription failed; recording retained for recovery")
            self.recovery_error = ("Transcription failed. Your recording is retained in Pico/Speech/Recovery." if pending is not None
                                   else "Transcription failed, and the recording could not be saved for recovery. Check free disk space.")
            return
        log.info('finish mode=%s send=%s target=%s', context['mode'], bool(context.get('send')), bool(context.get('target')))
        if context['voice'] or context.get('send') or context.get('voice_end'):
            text = self.voice_control.strip_command(text)
        from text_formatting import format_text
        writing_mode=context.get('writing_mode') or (self.voice_control.config.get('writingMode','verbatim') if context['mode'] in ('dictation','practice') else 'verbatim')
        text=format_text(text,self.voice_control.config.get('spokenFormatting',False),writing_mode,self.voice_control.config.get('messageSentences',2))
        if writing_mode in ('summary','email_ai'):
            from local_writing import rewrite, WritingUnavailable
            AppHelper.callAfter(self.voice_control.label,'Summarizing locally…' if writing_mode=='summary' else 'Drafting your email locally…')
            try:
                text=rewrite(text,writing_mode,context.get('writing_config',self.voice_control.config))
            except WritingUnavailable as error:
                self.recovery_error='Original transcript saved. '+str(error)
                context['send']=False
                AppHelper.callAfter(self.voice_control.delivery_status,self.recovery_error,True)
                writing_mode='verbatim'

        ms = int((time.time() - t) * 1000)
        secs = len(audio) / SAMPLE_RATE
        log.info("%.1fs audio -> %d ms, %d chars", secs, ms, len(text))
        if not text:
            self.recovery_error = "No text was recognized. Your recording is retained in Pico/Speech/Recovery."
            return
        self.db.execute(
            "insert into dictations (text, app, audio_seconds, transcribe_ms, model,original_text,writing_mode) values (?, ?, ?, ?, ?, ?, ?)",
            (text, app, round(secs, 2), ms, self.transcriber.name,original_text,writing_mode))
        self.db.commit()
        try:
            if pending is not None:
                pending.complete()
        except OSError:
            log.exception("Transcript saved; could not remove its recovery copy")
        self.voice_control.emit('transcript',text=text,mode=context['mode'],final=True)
        def deliver():
            from voice_control import same_focus
            if context['mode'] != 'dictation':
                return
            if not context.get('deliver', True):
                self.voice_control.delivery_status('Dictation stopped while paused or locked. The transcript is saved in history; nothing was pasted.', True)
                return
            if is_filler_only(text, secs):
                # An accidental Fn tap or a murmur ("Okay.", "Mm-hmm.") must not land mid-sentence.
                log.info("delivery: short filler-only transcript kept in history, not pasted")
                self.voice_control.delivery_status(f'Only heard “{text.strip()}”, so it wasn\'t pasted. Double-tap Shift if you meant it.', True)
                return
            if (context.get('delivery_generation', getattr(self, 'delivery_generation', 0)) != getattr(self, 'delivery_generation', 0)
                    or getattr(self, 'recording', False)):
                self.voice_control.delivery_status('A new dictation started; the earlier transcript is saved in history.', True)
                return
            if not AXIsProcessTrustedWithOptions(None):
                self.voice_control.delivery_status('Saved to history; Accessibility permission is needed to paste.', True)
                return
            if context.get('input_revision',getattr(self,'input_revision',0)) != getattr(self,'input_revision',0):
                self.voice_control.delivery_status('Typing or selection changed — transcription saved in history; automatic paste cancelled.', True)
                return
            if context['target'] is None and context.get('fallback_app'):
                from voice_control import unreported_focus
                if unreported_focus() == context['fallback_app']:
                    paste(text)
                    log.info('pasted without field report bundle=%s', context['fallback_app'][1])
                    self.voice_control.delivery_status('Pasted. This app does not report its text box, so the paste was not double-checked; automatic sending and correction watching were skipped.')
                    return
            if not same_focus(context['target']):
                reason = 'No editable text box was detected when dictation started.' if context['target'] is None else 'The original text box could not be verified.'
                self.voice_control.delivery_status(reason+' Transcription saved in history. Double-tap your recovery key in the text box to paste it.', True)
                return
            from voice_control import focus,ax,selection_range,split_utf16
            edit_target=focus();edit_parts=None
            insertion=context.get('live')
            if insertion is not None:
                edit_parts=(insertion.before,insertion.after)
                edit_target=insertion.target
            elif edit_target is not None:
                value=ax(edit_target[1],'AXValue');span=selection_range(edit_target[1])
                if isinstance(value,str) and span:
                    try:
                        before,_,after=split_utf16(value,*span);edit_parts=(before,after)
                    except (ValueError,UnicodeError):pass
            if insertion is not None:
                if not insertion.update(text):
                    self.voice_control.delivery_status('Final transcript saved. Double-tap your recovery key to paste it into the chosen box.',True)
                    return
            else:
                paste(text)
                if edit_parts is not None:
                    self.voice_control.confirm_paste(edit_target, edit_parts[0], text, edit_parts[1],
                        context.get('input_revision', getattr(self, 'input_revision', 0)),
                        context.get('delivery_generation', getattr(self, 'delivery_generation', 0)),
                        send=bool(context.get('send')))
                else:
                    self.voice_control.delivery_status('Paste requested, but this field does not expose text for verification. The transcript is saved in history; automatic sending and correction watching were skipped.', True)
                return
            if edit_parts is not None and not context.get('send'):
                self.voice_control.watch_correction(edit_target,edit_parts[0],text,edit_parts[1])
            if context.get('send'):
                self.voice_control.send_when_pasted(context['target'],text)
        AppHelper.callAfter(deliver)

    # Fn key
    def on_fn(self, down: bool, now: float):
        if not self.voice_control.config.get("dictationEnabled", True) or self.voice_control.long_mode:
            return
        # Hold Fn to dictate. A single tap does nothing (an accidental tap used to start
        # recording); double-tap Fn to start hands-free recording, and double-tap again to stop.
        last_tap = getattr(self, 'fn_tap_at', None)
        if down and not self.fn_down:
            self.fn_down, self.fn_down_at, self.combo = True, now, False
            if self.hands_free and self.recording:
                if last_tap is not None and now - last_tap <= DOUBLE_TAP_SECONDS:
                    self.fn_tap_at = None
                    self.stop()             # second tap of a double tap ends hands-free mode
                    self.fn_down = False    # so the matching release is ignored
            else:
                self.hands_free = False  # a refused earlier tap must not swallow this press
                self.start()
        elif not down and self.fn_down:
            self.fn_down = False
            if self.combo:
                self.stop(keep=False)
            elif now - self.fn_down_at < TAP_SECONDS:
                if self.hands_free and self.recording:
                    self.fn_tap_at = now            # first tap of the double tap that stops
                elif self.recording and last_tap is not None and now - last_tap <= DOUBLE_TAP_SECONDS + TAP_SECONDS:
                    self.fn_tap_at = None
                    self.hands_free = True          # second tap: keep listening hands-free
                else:
                    self.stop(keep=False)           # a single tap: discard, paste nothing
                    self.fn_tap_at = now
            else:
                self.fn_tap_at = None
                self.stop()

    def on_other_key(self):
        if self.fn_down:
            self.combo = True


def make_tap(dictation):
    mouse_events = (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventRightMouseDown, Quartz.kCGEventOtherMouseDown)
    mask = Quartz.CGEventMaskBit(Quartz.kCGEventFlagsChanged) | Quartz.CGEventMaskBit(Quartz.kCGEventKeyDown)
    for event_type in mouse_events: mask |= Quartz.CGEventMaskBit(event_type)
    dictation.input_revision = 0
    holder = {}
    from voice_control import RecoveryGesture
    recovery = RecoveryGesture()
    def handle_recovery(key, down, clean, now):
        result = recovery.feed(key, down, clean, now)
        if result == 'history':
            dictation.voice_control.emit('action', action='recover')
        elif result == 'pending':
            from voice_control import focus
            target = focus()
            revision = dictation.input_revision
            def finish(timer):
                if recovery.finish(time.monotonic()) == 'paste' and revision == dictation.input_revision:
                    dictation.voice_control.recover_last(target)
            NSTimer.scheduledTimerWithTimeInterval_repeats_block_(.46,False,finish)

    def callback(proxy, etype, event, refcon):
        if etype in (Quartz.kCGEventTapDisabledByTimeout, Quartz.kCGEventTapDisabledByUserInput):
            log.warning("macOS paused the key listener; re-enabling")
            Quartz.CGEventTapEnable(holder["tap"], True)
            return event
        # Keep this callback instant: every keystroke on the Mac waits for it.
        # The real work (audio, cursor lookup, drawing) runs right after on the main loop.
        try:
            # Our own live insertion must not count as new user typing.
            if Quartz.CGEventGetIntegerValueField(event, Quartz.kCGEventSourceUserData) == 0x4D4D5450:
                return event
            if etype == Quartz.kCGEventKeyDown or etype in mouse_events:
                dictation.input_revision += 1
            if DEBUG_KEYS:
                log.info("event type=%s keycode=%s flags=%#x", etype,
                         Quartz.CGEventGetIntegerValueField(event, Quartz.kCGKeyboardEventKeycode),
                         Quartz.CGEventGetFlags(event))
            recovery_key = dictation.voice_control.config.get('recoveryKey') or 'shift'
            masks = {'shift': Quartz.kCGEventFlagMaskShift, 'command': Quartz.kCGEventFlagMaskCommand, 'option': Quartz.kCGEventFlagMaskAlternate}
            flags = Quartz.CGEventGetFlags(event)
            selected = masks.get(recovery_key, 0)
            modifiers = Quartz.kCGEventFlagMaskShift | Quartz.kCGEventFlagMaskCommand | Quartz.kCGEventFlagMaskAlternate | Quartz.kCGEventFlagMaskControl | Quartz.kCGEventFlagMaskSecondaryFn
            code = Quartz.CGEventGetIntegerValueField(event, Quartz.kCGKeyboardEventKeycode)
            keycodes = {'shift': (56,60), 'command': (55,54), 'option': (58,61)}
            clean = etype == Quartz.kCGEventFlagsChanged and code in keycodes.get(recovery_key, ()) and not (flags & modifiers & ~selected)
            AppHelper.callAfter(handle_recovery, recovery_key, bool(flags & selected), clean, time.monotonic())
            if etype == Quartz.kCGEventFlagsChanged:
                code = Quartz.CGEventGetIntegerValueField(event, Quartz.kCGKeyboardEventKeycode)
                if code == FN_KEYCODE:
                    down = bool(Quartz.CGEventGetFlags(event) & Quartz.kCGEventFlagMaskSecondaryFn)
                    AppHelper.callAfter(dictation.on_fn, down, time.time())
                elif dictation.fn_down:
                    AppHelper.callAfter(dictation.on_other_key)  # Fn + Shift/Cmd/... is a shortcut
            elif etype == Quartz.kCGEventKeyDown:
                AppHelper.callAfter(dictation.on_other_key)
        except Exception:
            log.exception("hotkey handler failed")
        return event

    # A default (filtering) tap only needs Accessibility; listen-only needs Input
    # Monitoring, which macOS won't grant reliably to this bundle. Events always pass through.
    tap = Quartz.CGEventTapCreate(
        Quartz.kCGSessionEventTap, Quartz.kCGHeadInsertEventTap,
        Quartz.kCGEventTapOptionDefault, mask, callback, None)
    holder["tap"] = tap
    return tap


# --- permissions ----------------------------------------------------------

# Words that, alone in a short recording, are a murmur or an accidental Fn tap rather than dictation.
FILLER_WORDS = {'ok', 'okay', 'yeah', 'yes', 'yep', 'no', 'mm', 'mmm', 'hmm', 'mm-hmm', 'mhm', 'uh', 'um', 'uh-huh', 'ah', 'oh', 'so', 'right', 'thanks', 'thank', 'you', 'bye', 'cool', 'nice', 'alright'}
FILLER_MAX_SECONDS = 4.0


def is_filler_only(text, seconds):
    """True for a short recording whose transcript is only filler (e.g. "Okay.", "Mm-hmm.", "Thank you.")."""
    words = re.findall(r"[a-z]+(?:-[a-z]+)*", text.lower())
    return bool(words) and len(words) <= 3 and seconds < FILLER_MAX_SECONDS and all(w in FILLER_WORDS for w in words)


def model_download_bytes(cache=None):
    """Bytes of partial model downloads in the Hugging Face cache (0 when nothing is downloading)."""
    if cache is None:
        cache = Path(os.environ.get('HF_HUB_CACHE') or Path(os.environ.get('HF_HOME', Path.home() / '.cache/huggingface')) / 'hub')
    total = 0
    for part in Path(cache).rglob('*.incomplete'):
        try:
            total += part.stat().st_size
        except OSError:
            pass
    return total


def loading_status(retry_message=None, cache=None):
    if retry_message:
        return retry_message
    downloaded = model_download_bytes(cache)
    if downloaded:
        return f'Downloading the speech model (first launch only)… {downloaded // 1_000_000:,} MB so far'
    return 'Preparing speech: loading the speech model (the first launch downloads it)…'


def ensure_permissions():
    AVFoundation.AVCaptureDevice.requestAccessForMediaType_completionHandler_(
        AVFoundation.AVMediaTypeAudio, lambda granted: log.info("microphone access: %s", granted))
    # The Fn listener uses a filtering event tap and requires Accessibility.
    # Do not request unrelated Input Monitoring access for a listen-only tap.
    trusted = AXIsProcessTrustedWithOptions(NSDictionary.dictionaryWithDictionary_({"AXTrustedCheckOptionPrompt": True}))
    log.info("accessibility (paste) access: %s", trusted)


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)
    ensure_permissions()

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
    # Without this, App Nap throttles us in the background (transcription took 10s instead of 0.1s).
    global _no_app_nap
    _no_app_nap = NSProcessInfo.processInfo().beginActivityWithOptions_reason_(
        NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical,
        "Push-to-talk dictation must respond instantly")

    dictation = Dictation(open_db())
    dictation.indicator = Indicator(dictation)

    def on_activate(note):
        running = note.userInfo()["NSWorkspaceApplicationKey"]
        enable_app_accessibility(running.processIdentifier())
    ws = NSWorkspace.sharedWorkspace()
    ws.notificationCenter().addObserverForName_object_queue_usingBlock_(
        "NSWorkspaceDidActivateApplicationNotification", None, None, on_activate)
    for running in ws.runningApplications():
        if running.activationPolicy() == 0:  # regular apps with windows
            enable_app_accessibility(running.processIdentifier())
    # Report permissions while the model loads (the first launch downloads it), so the
    # app's permission rows update at once and nobody needs to restart speech mid-download.
    def early_heartbeat():
        from voice_control import microphone_access, write_state
        from ApplicationServices import AXIsProcessTrusted
        root = Path.home() / 'Library/Application Support/Pico/VoiceBridge'
        root.mkdir(parents=True, exist_ok=True)
        while not dictation.ready.is_set():
            try:
                write_state(root, {'time': time.time(), 'status': loading_status(getattr(dictation, 'load_status', None)),
                                   'recording': False, 'busy': False, 'wake': False, 'microphone': False, 'detectorReady': False,
                                   'mode': 'dictation', 'level': 0.0, 'keyListenerReady': False, 'loading': True,
                                   'accessibilityGranted': bool(AXIsProcessTrusted()), 'microphoneAccess': microphone_access(),
                                   'compute': 'Loading speech model…'})
            except OSError:
                log.exception('Could not report speech status')
            dictation.ready.wait(1)
    threading.Thread(target=early_heartbeat, daemon=True).start()
    dictation.ready.wait()

    from voice_control import VoiceControl
    dictation.voice_control = VoiceControl(dictation, paste, play, dictation.db)
    taps = []
    dictation.key_listener_ready = False
    def install_tap():
        if taps: return
        tap = make_tap(dictation)
        if tap is None:
            log.warning('Fn shortcut unavailable; grant Accessibility in System Settings')
            return
        source = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
        Quartz.CFRunLoopAddSource(Quartz.CFRunLoopGetMain(), source, Quartz.kCFRunLoopCommonModes)
        Quartz.CGEventTapEnable(tap, True)
        taps.extend([tap,source])
        dictation.key_listener_ready = bool(Quartz.CGEventTapIsEnabled(tap))
        dictation.voice_control.label()
        log.info('key listener enabled: %s',dictation.key_listener_ready)
    install_tap()
    _tap_retry = NSTimer.scheduledTimerWithTimeInterval_repeats_block_(5,True,lambda timer:install_tap())
    AppHelper.runEventLoop(installInterrupt=True)


if __name__ == "__main__":
    import fcntl
    # Hold this file descriptor for process lifetime; reopening the launcher is harmless.
    HOME.mkdir(parents=True, exist_ok=True, mode=0o700)
    _instance_lock = open(HOME / 'dictate.lock', 'a')
    try:
        fcntl.flock(_instance_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit(0)
    import sys
    sys.modules["dictate"] = sys.modules[__name__]
    main()
