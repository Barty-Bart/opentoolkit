"""Typed English keyword spotting, running locally on one CPU thread."""
from pathlib import Path
import re, tempfile
import sentencepiece as spm
import sherpa_onnx
MODEL='sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01'
DEFAULT_WAKE_PHRASE='hey toolkit'

def migrate_voice_branding(config):
    """Upgrade the former default once; preserve all user-selected settings."""
    result={**config,'phrases':dict(config.get('phrases',{}))}
    version=result.get('brandingVersion') or 0
    if version >= 2:
        return result
    old=' '.join(str(result.get('wakePhrase') or 'hey pico').split()).casefold()
    if (version == 0 and old == 'hey pico') or old == 'hey open toolkit':
        result['wakePhrase']=DEFAULT_WAKE_PHRASE
        for key,phrase in result['phrases'].items():
            normalized=' '.join(phrase.split())
            if normalized.casefold().startswith(old+' '):
                result['phrases'][key]=normalized[len(old)+1:]
    result['brandingVersion']=2
    return result

def validate_phrase(text):
    phrase=' '.join(str(text).strip().split())
    if not re.fullmatch(r"[A-Za-z]+(?:[' -][A-Za-z]+)*",phrase) or not 1<=len(phrase.split())<=8 or len(phrase)>80:
        raise ValueError('Use 1–8 English words, with letters and spaces.')
    return phrase
def command_phrases(config):
    """Build one explicit wake-prefix + action phrase for every command."""
    config=migrate_voice_branding(config)
    prefix=validate_phrase(config.get('wakePhrase') or DEFAULT_WAKE_PHRASE)
    commands={}
    for label,action in config['phrases'].items():
        action=validate_phrase(action)
        # Older versions stored the prefix inside the Start action.
        if action.casefold().startswith(prefix.casefold()+' '):
            action=action[len(prefix):].strip()
        commands[label]=validate_phrase(prefix+' '+action)
    if len({p.casefold() for p in commands.values()})!=len(commands):
        raise ValueError('Each action needs a different phrase')
    return commands

def detector_phrases(config):
    """One small detector hears a prefix or an action; CommandSession gates execution."""
    config=migrate_voice_branding(config)
    prefix=validate_phrase(config.get('wakePhrase') or DEFAULT_WAKE_PHRASE)
    complete=command_phrases(config)
    actions={key:phrase[len(prefix)+1:] for key,phrase in complete.items()}
    if prefix.casefold() in {value.casefold() for value in actions.values()}:
        raise ValueError('The wake phrase must differ from each action')
    aliases={}
    for label,phrase in [('start_transcribing','start transcribing'),('screenshot_short','take screenshot')]:
        base='start' if label=='start_transcribing' else 'screenshot'
        if actions.get(base) in ('start dictating','take a screenshot') and phrase not in actions.values():
            aliases[label]=phrase
    return {'wake':prefix,**actions,**aliases}

class Detector:
    def __init__(self,root,commands):
        root=Path(root);self.commands=commands
        sp=spm.SentencePieceProcessor(model_file=str(root/'bpe.model'))
        seen=set();lines=[]
        for label,phrase in commands.items():
            phrase=validate_phrase(phrase)
            if phrase.lower() in seen:raise ValueError('Each action needs a different phrase')
            seen.add(phrase.lower())
            # Short prefixes need a lower acoustic threshold than longer commands.
            # Keep action thresholds unchanged; CommandSession still requires both.
            tuning=' #0.05' if label=='wake' else ''
            lines.append(' '.join(sp.encode(phrase.upper(),out_type=str))+tuning+' @'+label)
            if label=='wake' and phrase.casefold()=='hey toolkit':
                # The product name can align as one or two spoken words.
                lines.append(' '.join(sp.encode('HEY TOOL KIT',out_type=str))+tuning+' @wake')
        with tempfile.NamedTemporaryFile(mode='w',encoding='utf8',delete=False) as f:
            f.write('\n'.join(lines));keyword_path=f.name
        def model(p):return str(root/f'{p}-epoch-12-avg-2-chunk-16-left-64.onnx')
        try:
            self.kws=sherpa_onnx.KeywordSpotter(tokens=str(root/'tokens.txt'),encoder=model('encoder'),decoder=model('decoder'),joiner=model('joiner'),keywords_file=keyword_path,num_threads=1,provider='cpu',keywords_score=2.0,keywords_threshold=.1,max_active_paths=16)
        finally:Path(keyword_path).unlink(missing_ok=True)
        self.reset()
    def reset(self):
        self.stream=self.kws.create_stream()
        # Give a fresh stream left context, even when speech starts immediately.
        self.stream.accept_waveform(16000,[0.0]*3200)
    def feed(self,audio):
        self.stream.accept_waveform(16000,audio)
        while self.kws.is_ready(self.stream):
            self.kws.decode_stream(self.stream)
            r=self.kws.get_result(self.stream)
            if r:
                # Reset keyword decoding without dropping buffered audio after
                # the wake phrase; it may already contain the next command.
                self.kws.reset_stream(self.stream)
                return r
        return None
