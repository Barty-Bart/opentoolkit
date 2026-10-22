"""Private local file IPC between the native shell and the speech worker."""
import json, os, re, time, queue, threading, logging, uuid, sqlite3
from CoreFoundation import CFEqual
from pathlib import Path
import numpy as np
import sounddevice as sd
from AppKit import NSWorkspace, NSTimer
from Foundation import NSDistributedNotificationCenter
from ApplicationServices import (AXUIElementCreateApplication, AXUIElementCopyAttributeValue,AXUIElementSetMessagingTimeout,AXUIElementPerformAction,AXUIElementSetAttributeValue,AXValueCreate,AXValueGetValue,kAXValueCFRangeType)
from PyObjCTools import AppHelper
from wake_engine import Detector, MODEL, validate_phrase, command_phrases, detector_phrases, migrate_voice_branding
from runtime_paths import speech_data, speech_resources
log=logging.getLogger('multitool.voice')
class RecoveryGesture:
    """Wait after tap two so a third tap opens history without pasting."""
    def __init__(self):
        self.key = None
        self.reset()
    def reset(self):
        self.down_at = None
        self.last_up = None
        self.count = 0
        self.blocked = False
    def feed(self, key, down, clean, now):
        if key != self.key or key == 'off':
            self.key = key; self.reset()
            if key == 'off': return None
        if not clean:
            self.reset()
            self.blocked = down
            return None
        if self.blocked:
            if not down: self.reset()
            return None
        if down:
            if self.last_up is not None and now-self.last_up > .45: self.reset()
            if self.down_at is None: self.down_at = now
            return None
        if self.down_at is None: return None
        short = now-self.down_at <= .30
        self.down_at = None
        if not short: self.reset(); return None
        self.count += 1; self.last_up = now
        if self.count == 3:
            self.reset(); return 'history'
        return 'pending' if self.count == 2 else None
    def finish(self, now):
        if self.count == 2 and self.down_at is None and now-self.last_up >= .45:
            self.reset(); return 'paste'
        return None


def ax(el, key):
    err, value = AXUIElementCopyAttributeValue(el, key, None)
    return None if err else value

def focus():
    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    if app is None:
        return None
    root = AXUIElementCreateApplication(app.processIdentifier())
    AXUIElementSetMessagingTimeout(root, 0.2)
    el = ax(root, 'AXFocusedUIElement')
    if el is None or ax(el, 'AXRole') not in ('AXTextArea', 'AXTextField'):
        return None
    if ax(el, 'AXSubrole') == 'AXSecureTextField':
        return None
    return (app.processIdentifier(), el, app.localizedName(), app.bundleIdentifier())

def same_focus(target):
    current = focus()
    return current is not None and target is not None and current[0] == target[0] and bool(CFEqual(current[1], target[1]))

def selection_range(element):
    value=ax(element,'AXSelectedTextRange')
    if value is None:return None
    ok, span=AXValueGetValue(value,kAXValueCFRangeType,None)
    return tuple(int(n) for n in span) if ok else None

def utf16len(text):return len(text.encode('utf-16-le'))//2

def split_utf16(text,start,length):
    raw=text.encode('utf-16-le')
    if start<0 or length<0 or 2*(start+length)>len(raw):raise ValueError('Invalid selection')
    return raw[:2*start].decode('utf-16-le'),raw[2*start:2*(start+length)].decode('utf-16-le'),raw[2*(start+length):].decode('utf-16-le')

class LiveInsertion:
    """Own only the dictation range; stop if the user edits or changes focus."""
    def __init__(self,target,paste,status):
        self.target=target;self.paste=paste;self.status=status
        self.valid=False;self.changed=False;self.text=''
        if target is None:return
        value=ax(target[1],'AXValue');span=selection_range(target[1])
        if not isinstance(value,str) or span is None:return
        try:self.before,self.original,self.after=split_utf16(value,*span)
        except (ValueError,UnicodeError):return
        self.start=span[0];self.span=span;self.expected=value;self.valid=True
    def update(self,text):
        if not self.valid:return False
        if not same_focus(self.target) or ax(self.target[1],'AXValue')!=self.expected or selection_range(self.target[1])!=self.span:
            self.valid=False
            self.status('Live typing paused because the text box or selection changed. The final transcript will be saved in history.',True)
            return False
        if self.changed and text==self.text:return True
        selected=AXValueCreate(kAXValueCFRangeType,(self.start,utf16len(self.text if self.changed else self.original)))
        if AXUIElementSetAttributeValue(self.target[1],'AXSelectedTextRange',selected):
            self.valid=False
            self.status('This text box does not support live replacement. The transcript will be saved in history.',True)
            return False
        self.paste(text)
        self.text=text;self.changed=True;self.expected=self.before+text+self.after
        self.span=(self.start+utf16len(text),0)
        return True

def send_button(target):
    # Fail closed. Never use Enter or search an entire window for an unrelated Send.
    if not same_focus(target):
        return None
    if target[3] not in {'com.openai.codex', 'com.anthropic.claudefordesktop',
                         'com.tinyspeck.slackmacgap', 'com.apple.MobileSMS'}:
        return None
    value = ax(target[1], 'AXValue')
    if not isinstance(value, str) or not value.strip():
        return None
    parent = target[1]
    for _ in range(8):
        parent = ax(parent, 'AXParent')
        if parent is None or ax(parent, 'AXRole') in ('AXWindow', 'AXApplication'):
            return None
        todo = list(ax(parent, 'AXChildren') or [])
        candidates = []
        visited = 0
        while todo and visited < 120:
            el = todo.pop(0); visited += 1
            if ax(el, 'AXRole') == 'AXButton' and ax(el, 'AXEnabled'):
                labels = [ax(el, k) for k in ('AXTitle', 'AXDescription', 'AXHelp', 'AXIdentifier')]
                if any(isinstance(s,str) and s.strip().lower() in ('send','send message','send prompt','send now','send-button','send-message-button') for s in labels):
                    candidates.append(el)
            todo.extend(ax(el, 'AXChildren') or [])
        if todo:  # Incomplete inspection, possibly a larger page.
            return None
        if len(candidates) == 1:
            return candidates[0]
        if len(candidates) > 1:
            return None
    return None

DEFAULTS={'brandingVersion':2,'wakePhrase':'hey toolkit','dictationEnabled':True,'wakeEnabled':False,'liveEnabled':False,'sendEnabled':False,'standaloneSend':False,'organizerEnabled':False,'continuousEnabled':False,
 'phrases':{'start':'start dictating','stop':'stop transcribing','cancel':'cancel dictation','send':'finish and send','screenshot':'take a screenshot','annotate':'draw on screen','record':'record my screen','record_stop':'stop screen recording','note':'take a note','reminder':'make a reminder','meeting':'transcribe a meeting','summarize':'summarize into bullet points','email':'turn this into an email'}}

class VoiceControl:
    def __init__(self,dictation,paste,play,db):
        self.d=dictation;self.db=db;self.paste=paste
        self.root=Path.home()/'Library/Application Support/Pico/VoiceBridge'
        self.inbox=self.root/'inbox';self.events=self.root/'events'
        for p in (self.root,self.inbox,self.events):p.mkdir(parents=True,exist_ok=True);p.chmod(0o700)
        self.config_file=self.root/'config.json';self.config=dict(DEFAULTS)
        self.enabled=False;self.epoch=0;self.mic_ready=False;self.detector_ready=False
        self.capture_mode='dictation';self.long_mode=None;self.send_after=False
        self.preview_pending=False;self.last_preview=0.;self.queue=queue.Queue(maxsize=40)
        self.status='Speech worker ready';self.locked=False;self.last_command=0.;self.session=''
        self.segment=[];self.segment_frames=0;self.silent=0;self.segment_pending=0;self.segment_lock=threading.RLock();self.send_generation=0
        self.paused_file=speech_data()/'voice-commands.disabled'
        from command_session import CommandSession
        self.command_session=CommandSession()
        self.writing_override=None
        self._config_stamp=0;self._read_config()
        self.timer=NSTimer.scheduledTimerWithTimeInterval_repeats_block_(.3,True,lambda t:self.tick())
        center=NSDistributedNotificationCenter.defaultCenter()
        self._lock_observer=center.addObserverForName_object_queue_usingBlock_('com.apple.screenIsLocked',None,None,lambda n:AppHelper.callAfter(self.pause_for_lock))
        threading.Thread(target=self._microphone,daemon=True).start()
        threading.Thread(target=self._detect,daemon=True).start()
        self.emit('ready')
    def emit(self,kind,**data):
        obj={'id':str(uuid.uuid4()),'kind':kind,'time':time.time(),**data}
        p=self.events/(f'{time.time_ns()}-'+obj['id']+'.json')
        temp=p.with_suffix('.tmp');temp.write_text(json.dumps(obj));temp.chmod(0o600);temp.replace(p)
    def label(self,text=None):
        self.status=text or ('Recording' if self.d.recording else 'Transcribing' if self.d.busy else 'Meeting transcription' if self.long_mode=='meeting' else 'Continuous notes active' if self.long_mode else 'Listening for commands' if self.enabled else 'Fn ready · wake phrases off')
    def _read_config(self):
        try:
            stamp=self.config_file.stat().st_mtime_ns
            if stamp==self._config_stamp:return
            c=json.loads(self.config_file.read_text());c=migrate_voice_branding({**c,'phrases':c.get('phrases',DEFAULTS['phrases'])});phrases=c['phrases']
            detector_phrases({**DEFAULTS,**c,'phrases':{**DEFAULTS['phrases'],**phrases}})
            self.send_generation+=1
            self.config={**DEFAULTS,**c,'phrases':{**DEFAULTS['phrases'],**phrases}};self._config_stamp=stamp;self.epoch+=1
            self.enabled=bool(c.get('wakeEnabled',False)) and not self.paused_file.exists()
            self.label()
        except FileNotFoundError:pass
        except Exception:self.label('Invalid phrase settings; previous settings retained')
    def watch_correction(self,target,prefix,text,suffix):
        from corrections import EditWatch
        if not self.config.get('learnCorrections',True) or target is None:return
        watch=EditWatch(prefix,text,suffix,time.monotonic())
        # Capture an already delivered baseline immediately: a fast edit can
        # happen before the next polling tick.
        watch.seen=ax(target[1],'AXValue')==watch.expected
        self.edit_watch=(target,watch)
    def poll_correction(self):
        entry=getattr(self,'edit_watch',None)
        if not entry:return
        target,watch=entry
        if not self.config.get('learnCorrections',True) or self.d.recording:
            self.edit_watch=None;return
        # Selecting/replacing text can briefly remove AX focus. Pause reads rather
        # than permanently cancelling on a single missing-focus sample.
        if not same_focus(target):
            if not watch.focus_available(False,time.monotonic()):self.edit_watch=None
            return
        if not watch.focus_available(True,time.monotonic()):
            self.edit_watch=None;return
        result=watch.poll(ax(target[1],'AXValue'),time.monotonic())
        if watch.done:
            self.edit_watch=None
            self.label('Correction watch finished' if result else 'Correction watch expired or text moved outside the dictated range')
        if result:
            old,new=result
            from corrections import RuleStore
            store=RuleStore(Path.home()/'Library/Application Support/Pico/Speech/corrections.json')
            if any(r['wrong'].casefold()==old.casefold() for r in store.read()):return
            identifier=str(uuid.uuid4());self.pending_correction=(identifier,old,new,time.monotonic())
            self.label('Correction found: confirm it in the correction prompt')
            self.emit('correction_suggestion',action=identifier,text=old,message=new)
    def tick(self):
        self._read_config()
        if self.command_session.expire(time.monotonic(),self.epoch):
            self.d.end_wake_feedback();self.label()
        try:self.poll_correction()
        except Exception:
            self.edit_watch=None
            self.label('Correction suggestions paused; could not read correction rules')
        for path in sorted(self.inbox.glob('*.json'))[:10]:
            try:
                c=json.loads(path.read_text())
                # Old start commands must not unexpectedly record after a delayed restart.
                if c.get('action')=='system_audio' or time.time()-c.get('time',0)<30:self.command(c.get('action',''),c)
            except Exception:log.exception('voice control request failed')
            finally:path.unlink(missing_ok=True)
        state={'time':time.time(),'status':self.status,'recording':self.d.recording,'busy':self.d.busy,'wake':self.enabled,'awaitingCommand':self.command_session.active(time.monotonic(),self.epoch),'microphone':self.mic_ready,'detectorReady':self.detector_ready,'mode':self.long_mode or self.capture_mode,'level':float(self.d.level),'segmentPending':self.segment_pending}
        state['keyListenerReady']=bool(getattr(self.d,'key_listener_ready',False))
        if not state['keyListenerReady'] and not self.d.recording and not self.d.busy:
            state['status']='Fn unavailable — enable OpenToolkit Speech in System Settings → Privacy & Security → Accessibility'
        transcriber=getattr(self.d,'transcriber',None)
        state['compute']=getattr(transcriber,'name','Loading speech model…')
        state['fallback']=bool(getattr(transcriber,'fallback',False))
        if self.d.busy and time.monotonic()-getattr(self.d,'busy_since',time.monotonic())>45:state['status']='Transcription is taking longer than usual. Reset speech if needed.'
        tmp=self.root/'state.tmp';tmp.write_text(json.dumps(state));tmp.chmod(0o600);tmp.replace(self.root/'state.json')
    def command(self,action,c=None):
        c=c or {}
        if action=='watch_practice':
            target=focus();text=c.get('text','')
            if target and target[3]=='local.pico' and isinstance(text,str) and text:
                value=ax(target[1],'AXValue')
                if isinstance(value,str) and value.endswith(text):
                    self.watch_correction(target,value[:-len(text)],text,'');self.label('Correction test ready: edit the example within 30 seconds')
                else:self.label('Correction test: the focused field did not expose matching text')
            else:self.label('Correction test: click the practice text box first')
            return
        if action.startswith('correction_'):
            from corrections import RuleStore
            store=RuleStore(Path.home()/'Library/Application Support/Pico/Speech/corrections.json')
            identifier=c.get('rule','')
            if action=='correction_save':
                pending=getattr(self,'pending_correction',None)
                if pending and identifier==pending[0] and time.monotonic()-pending[3]<120:
                    item=store.save(pending[1],pending[2]);self.pending_correction=None
                    if item:self.emit('correction_saved',action=item['id'],text=item['wrong'],message=item['right'])
            elif action in ('correction_undo','correction_enable','correction_disable'):
                store.change(identifier,action.removeprefix('correction_'))
                self.emit('correction_changed')
            elif action=='correction_dismiss':self.pending_correction=None
            return
        if action in ('pause','cancel','wake_off'):self.send_generation+=1
        if action in ('meeting','ambient') and not self.config.get('continuousEnabled',True):
            self.delivery_status('Enable meeting capture in Settings before using this command.',True);return
        if action in ('note','reminder') and not self.config.get('organizerEnabled',True):
            self.delivery_status('Enable Notes in Settings before using this command.',True);return
        if action=='ai_probe':
            def probe():
                from local_writing import available_models, WritingUnavailable
                try:
                    models=available_models(self.config.get('aiWritingEndpoint') or 'http://127.0.0.1:1234/v1')
                    self.emit('ai_models',models=models,message='Choose a loaded local text model.' if models else 'No local text model is loaded.')
                except WritingUnavailable as error:self.emit('ai_models',models=[],message=str(error))
            self.d.jobs.put((probe,None));return
        if action=='test_sound':
            if not self.d.recording:self.d.preview_feedback(c.get('cue'))
            return
        if action=='system_audio':
            self.transcribe_system(c);return
        if action=='pause':
            self.enabled=False;self.paused_file.touch();self.epoch+=1;self.stop_long();self.d.stop(False);self.label();return
        if action=='wake_on':
            self.paused_file.unlink(missing_ok=True);self.enabled=True;self.epoch+=1;self.label();return
        if action=='wake_off':self.enabled=False;self.paused_file.touch();self.epoch+=1;self.label();return
        if action in ('meeting','ambient'):
            if self.long_mode:self.stop_long();return
            if self.d.recording or self.d.busy:self.label('Finish the current dictation first');return
            self.long_mode=action;self.session=str(uuid.uuid4());self.segment=[];self.segment_frames=0;self.silent=0;self.epoch+=1;self.label();self.emit('session_started',mode=action,session=self.session);return
        if action=='stop':
            if self.long_mode:self.stop_long()
            else:self.d.stop()
            return
        if action=='cancel':
            if self.long_mode:self.stop_long(discard=True)
            else:self.d.stop(False)
            return
        if action in ('start','live','note','reminder','practice','summarize','email'):
            if self.d.recording or self.d.busy or not self.config.get('dictationEnabled',True):return
            if self.long_mode:self.label('Stop continuous capture before starting dictation');return
            target=focus() if action in ('start','practice','summarize','email') else None
            self.capture_mode='dictation' if action in ('start','summarize','email') else action
            self.writing_override={'summarize':'summary','email':'email_ai'}.get(action)
            if action in ('start','summarize','email') and target is None:self.capture_mode='live'
            self.send_after=False;self.d.start(voice=True,target=target)
            self.emit('capture_started',mode=self.capture_mode)
    def pause_for_lock(self):
        self.enabled=False;self.paused_file.touch();self.stop_long();self.d.stop(False);self.epoch+=1;self.label('Paused when screen locked — enable wake phrases to resume')
    def _audio(self,data,frames,clock,status):
        samples=data[:,0].copy();rms=float(np.sqrt(np.mean(samples*samples)))
        with self.d.audio_lock:
            if self.d.recording:
                self.d.chunks.append(samples);self.d.audio_frames+=len(samples);self.d.level=rms
                if self.d.audio_frames>=16000*300:AppHelper.callAfter(self.d.stop)
                if self.config.get('liveEnabled') and getattr(self.d,'session_writing_mode','verbatim') not in ('summary','email_ai') and not self.preview_pending and time.monotonic()-self.last_preview>=2.5 and self.d.audio_frames>=16000:
                    self.preview_pending=True;self.last_preview=time.monotonic()
                    offset=getattr(self.d,'preview_offset',0)
                    audio=np.concatenate(self.d.chunks)[offset:offset+16000*25];epoch=self.epoch
                    self.d.jobs.put((lambda a=audio,e=epoch:self.d.preview(a,e),None))
        with self.segment_lock:
            if self.long_mode:
                self.segment.append(samples);self.segment_frames+=len(samples);self.silent=self.silent+1 if rms<.008 else 0
                self.d.level=rms
                if (self.segment_frames>=16000*3 and self.silent>=7) or self.segment_frames>=16000*12:
                    self.queue_segment()
        if self.enabled and not self.d.busy and self.long_mode!='ambient':
            try:self.queue.put_nowait((self.epoch,samples))
            except queue.Full:self.epoch+=1
    def queue_segment(self):
        audio=np.concatenate(self.segment) if self.segment else np.zeros(0,dtype=np.float32)
        self.segment=[];self.segment_frames=0;self.silent=0
        if len(audio)<8000 or float(np.sqrt(np.mean(audio*audio)))<.003:return
        if self.segment_pending>=3:
            # Bounded inference backlog. Pause capture, preserving already queued segments.
            AppHelper.callAfter(self.overload);return
        self.segment_pending+=1;mode=self.long_mode;session=self.session
        def transcribe():
            try:
                from dictate import apply_replacements
                text=apply_replacements(self.d.transcriber.transcribe(audio))
                if text:
                    self.save_segment(text,mode,len(audio)/16000)
                    self.emit('segment',text=text,mode=mode,session=session)
            except Exception:log.exception('segment transcription failed');self.emit('error',message='A transcript segment failed; capture has paused');AppHelper.callAfter(self.stop_long)
            finally:self.segment_pending-=1
        self.d.jobs.put((transcribe,None))
    def overload(self):
        self.long_mode=None;self.epoch+=1;self.label('Continuous capture paused: transcription cannot keep up');self.emit('error',message=self.status)
    def stop_long(self,discard=False):
        with self.segment_lock:self._stop_long(discard)
    def _stop_long(self,discard=False):
        if not self.long_mode:return
        mode=self.long_mode;session=self.session
        if not discard:self.queue_segment()
        self.long_mode=None;self.segment=[];self.segment_frames=0;self.epoch+=1;self.label();self.emit('session_stopped',mode=mode,session=session)
    def _microphone(self):
        stream=None
        while True:
            wanted=self.enabled or self.d.recording or self.long_mode is not None
            try:
                if wanted and stream is None:
                    stream=sd.InputStream(samplerate=16000,channels=1,dtype='float32',blocksize=1600,callback=self._audio)
                    stream.start();self.mic_ready=True;AppHelper.callAfter(self.label)
                    if self.d.recording:
                        AppHelper.callAfter(self.d.start_audio_feedback)
                elif not wanted and stream is not None:
                    self.mic_ready=False;stream.stop();stream.close();stream=None
            except Exception:
                log.exception('microphone unavailable');self.mic_ready=False;self.enabled=False;stream=None
                AppHelper.callAfter(self.d.stop,False);AppHelper.callAfter(self.stop_long);AppHelper.callAfter(self.label,'Microphone unavailable — reset speech')
            time.sleep(.05)
    def _detect(self):
        detector=None;previous=-1
        while True:
            epoch,samples=self.queue.get()
            if epoch!=self.epoch or not self.enabled or self.d.busy:continue
            try:
                commands=detector_phrases(self.config)
                if detector is None or detector.commands!=commands:
                    detector=Detector(speech_resources()/MODEL,dict(commands));self.detector_ready=True
                if epoch!=previous:detector.reset();previous=epoch
                result=detector.feed(samples)
                if result:AppHelper.callAfter(self.heard,result,epoch)
            except Exception:
                log.exception('keyword detector failed');self.enabled=False;self.detector_ready=False;AppHelper.callAfter(self.label,'Wake detector unavailable — Fn is still available')
    def heard(self,result,epoch):
        if epoch!=self.epoch or not self.enabled or self.d.busy:return
        now=time.monotonic()
        if result=='wake':
            if not self.command_session.active(now,epoch):
                self.command_session.arm(now,epoch)
                self.d.wake_feedback()
                self.label('Listening for your command…')
            return
        if not self.command_session.consume(now,epoch):return
        self.d.end_wake_feedback()
        result={'start_transcribing':'start','screenshot_short':'screenshot'}.get(result,result)
        self.accept(result,epoch)
        self.label()

    def accept(self,result,epoch):
        if epoch!=self.epoch or not self.enabled or self.d.busy:return
        if self.long_mode:
            if result=='stop':self.stop_long()
            elif result=='cancel':self.stop_long(discard=True)
            return
        if time.monotonic()-self.last_command<1.5:return
        self.last_command=time.monotonic()
        log.info('voice action=%s recording=%s mode=%s', result, self.d.recording, self.capture_mode)
        if self.d.recording:
            if result=='stop':self.d.stop()
            elif result=='cancel':self.d.stop(False)
            elif result=='send' and self.config.get('sendEnabled') and self.capture_mode=='dictation':self.send_after=True;self.d.stop()
        else:
            if result in ('start','note','reminder','meeting','summarize','email'):self.command(result)
            elif result in ('screenshot','annotate','record','record_stop'):self.emit('action',action=result)
            elif result=='send' and self.config.get('sendEnabled') and self.config.get('standaloneSend'):
                target=focus();button=send_button(target) if target else None
                if button is not None:AXUIElementPerformAction(button,'AXPress')
                else:self.label('No supported Send button found')
    def strip_command(self,text):
        for name in ('stop','send','cancel'):
            phrase=command_phrases(self.config).get(name,'')
            pattern=r'[\s,.!?;:—-]*\b'+r'[\s,]+'.join(re.escape(w) for w in phrase.split())+r'[\s.!?,]*$'
            # ASR may render the product name as one word or two.
            pattern=pattern.replace(r'open[\s,]+toolkit',r'open[\s,]*toolkit')
            text=re.sub(pattern,'',text,flags=re.I).strip()
        return text
    def delivery_status(self, message, error=False):
        self.label(message)
        log.info('delivery: %s', message)
        self.emit('error' if error else 'delivery', message=message)

    def recover_last(self, target):
        if not same_focus(target):
            self.delivery_status('Click a text box, then double-tap to paste the last transcription.', True)
            return
        try:
            from library_store import library_path
            path=library_path()
            with sqlite3.connect(path.as_uri()+'?mode=ro', uri=True, timeout=.5) as db:
                row=db.execute('SELECT text FROM dictations ORDER BY id DESC LIMIT 1').fetchone()
            if not row or not row[0]:
                self.delivery_status('No saved transcription to recover yet.', True); return
            if not same_focus(target):
                self.delivery_status('Focus changed. Recovery did not paste.', True); return
            self.paste(row[0])
            self.delivery_status('Last saved transcription pasted. Nothing was sent.')
        except Exception:
            log.exception('Recovery failed')
            self.delivery_status('Could not read speech history. Triple-tap to open history.', True)

    def send_when_pasted(self,target,text):
        generation=self.send_generation
        attempts=[0]
        def attempt(timer):
            if generation!=self.send_generation or not self.config.get('sendEnabled') or not self.enabled:
                self.delivery_status('Send cancelled because voice settings changed.', True); return
            if not same_focus(target):
                self.delivery_status('Focus changed — text saved in Speech history; not sent.', True); return
            attempts[0]+=1
            value=ax(target[1],'AXValue')
            inserted=isinstance(value,str) and ' '.join(text.split()) in ' '.join(value.split())
            button=send_button(target) if inserted else None
            if button is None:
                if attempts[0]<6:
                    NSTimer.scheduledTimerWithTimeInterval_repeats_block_(.25,False,attempt); return
                self.delivery_status('Text inserted, but no supported Send button was found. Send it manually.' if inserted else 'Could not verify the pasted text. Double-tap your recovery key to paste it again.', True)
                return
            err=AXUIElementPerformAction(button,'AXPress')
            self.delivery_status('Send button pressed.' if not err else 'Send failed. Your text is still saved in Speech history.', bool(err))
        NSTimer.scheduledTimerWithTimeInterval_repeats_block_(.25,False,attempt)

    def transcribe_system(self,c):
        # Accept only worker-owned WAVs inside the private meeting chunk directory.
        import soundfile as sf
        path=Path(str(c.get('path',''))).resolve()
        allowed=(Path.home()/'Library/Application Support/Pico/MeetingAudio').resolve()
        if not path.is_relative_to(allowed) or path.suffix!='.wav':return
        session=c.get('session',self.session)
        if self.segment_pending>=3:
            self.emit('system_audio_done',path=str(path),success=False)
            self.emit('error',message='System audio transcription backlog: capture should pause')
            return
        self.segment_pending+=1
        def transcribe():
            try:
                audio,sr=sf.read(path,dtype='float32')
                if sr!=16000 or audio.ndim!=1:raise ValueError('Invalid system audio format')
                from dictate import apply_replacements
                text=apply_replacements(self.d.transcriber.transcribe(audio))
                if text:
                    self.save_segment(text,'meeting system audio',len(audio)/16000)
                    self.emit('segment',text='[System audio] '+text,mode='meeting',session=session,path=str(path))
                self.emit('system_audio_done',path=str(path),success=True,empty=not bool(text))
            except Exception:
                log.exception('System audio transcription failed')
                self.emit('system_audio_done',path=str(path),success=False)
            finally:self.segment_pending-=1
        self.d.jobs.put((transcribe,None))

    def save_segment(self,text,mode,seconds):
        self.db.execute('insert into dictations (text,app,audio_seconds,transcribe_ms,model) values (?,?,?,?,?)',(text,mode,seconds,0,self.d.transcriber.name))
        self.db.commit()
