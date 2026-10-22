"""Typed English keyword spotting, running locally on one CPU thread."""
from pathlib import Path
import re, tempfile
import sentencepiece as spm
import sherpa_onnx
MODEL='sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01'
def validate_phrase(text):
    phrase=' '.join(str(text).strip().split())
    if not re.fullmatch(r"[A-Za-z]+(?:[' -][A-Za-z]+)*",phrase) or not 1<=len(phrase.split())<=8 or len(phrase)>80:
        raise ValueError('Use 1–8 English words, with letters and spaces.')
    return phrase
class Detector:
    def __init__(self,root,commands):
        root=Path(root);self.commands=commands
        sp=spm.SentencePieceProcessor(model_file=str(root/'bpe.model'))
        seen=set();lines=[]
        for label,phrase in commands.items():
            phrase=validate_phrase(phrase)
            if phrase.lower() in seen:raise ValueError('Each action needs a different phrase')
            seen.add(phrase.lower())
            lines.append(' '.join(sp.encode(phrase.upper(),out_type=str))+' @'+label)
        with tempfile.NamedTemporaryFile(mode='w',encoding='utf8',delete=False) as f:
            f.write('\n'.join(lines));keyword_path=f.name
        def model(p):return str(root/f'{p}-epoch-12-avg-2-chunk-16-left-64.onnx')
        try:
            self.kws=sherpa_onnx.KeywordSpotter(tokens=str(root/'tokens.txt'),encoder=model('encoder'),decoder=model('decoder'),joiner=model('joiner'),keywords_file=keyword_path,num_threads=1,provider='cpu',keywords_threshold=.35)
        finally:Path(keyword_path).unlink(missing_ok=True)
        self.reset()
    def reset(self):self.stream=self.kws.create_stream()
    def feed(self,audio):
        self.stream.accept_waveform(16000,audio)
        while self.kws.is_ready(self.stream):
            self.kws.decode_stream(self.stream)
            r=self.kws.get_result(self.stream)
            if r:self.reset();return r
        return None
