"""Entry point for the bundled speech helper (no external Python installation)."""
import os
import sys

os.environ.setdefault('TOKENIZERS_PARALLELISM', 'false')


def storage_test():
    """Verify bundled storage/codec/recovery code without loading any speech model."""
    import json
    import tempfile
    from pathlib import Path
    import numpy as np
    import soundfile as sf
    from library_store import connect
    from audio_recovery import PendingRecording
    with tempfile.TemporaryDirectory(prefix='opentoolkit-storage-check-') as temporary:
        root = Path(temporary)
        db = connect(root / 'check.sqlite')
        assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        pending = PendingRecording(np.zeros(16000, dtype=np.float32), 16000, root / 'Recovery')
        assert len(sf.read(pending.audio)[0]) == 16000
        pending.save_text('Synthetic recovery test.')
        db.execute('INSERT INTO dictations(text) VALUES (?)', ('Synthetic recovery test.',))
        db.commit()
        pending.complete()
        assert not list((root / 'Recovery').iterdir())
        db.close()
    print(json.dumps({'ok': True, 'frozen': bool(getattr(sys, 'frozen', False)),
                      'checks': ['SQLite', 'audio codec', 'audio recovery'],
                      'speechModelsLoaded': False, 'microphoneOpened': False}), flush=True)


def self_test():
    """Offline dependency/resource check. Never open a microphone or user library."""
    import importlib
    import json
    import tempfile
    from pathlib import Path
    for name in ('numpy', 'sounddevice', 'soundfile', 'AVFoundation', 'ApplicationServices',
                 'Quartz', 'AppKit', 'Foundation', 'PyObjCTools.AppHelper', 'mlx.core',
                 'parakeet_mlx', 'mlx_whisper', 'faster_whisper', 'sherpa_onnx',
                 'sentencepiece', 'dictate', 'voice_control'):
        importlib.import_module(name)
    import numpy as np
    import soundfile as sf
    from library_store import connect
    from runtime_paths import speech_resources
    from wake_engine import Detector, MODEL
    detector = Detector(speech_resources() / MODEL, {'start': 'hey open toolkit start dictating'})
    assert detector.feed(np.zeros(16000, dtype=np.float32)) is None
    with tempfile.TemporaryDirectory(prefix='opentoolkit-runtime-check-') as temporary:
        db = connect(Path(temporary) / 'check.sqlite')
        assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        db.close()
        audio = Path(temporary) / 'silence.wav'
        sf.write(audio, np.zeros(16000, dtype=np.float32), 16000)
        assert len(sf.read(audio)[0]) == 16000
    print(json.dumps({'ok': True, 'python': sys.version.split()[0], 'frozen': bool(getattr(sys, 'frozen', False)),
                      'checks': ['imports', 'wake detector', 'SQLite schema', 'audio codec']}), flush=True)


if __name__ == '__main__':
    import multiprocessing
    multiprocessing.freeze_support()
    if sys.argv[1:] == ['--self-test-storage']:
        storage_test()
    elif sys.argv[1:] == ['--self-test']:
        self_test()
    elif len(sys.argv) == 3 and sys.argv[1] == '--self-test-audio':
        # An explicit developer check, using only the supplied synthetic WAV.
        # Honors HF_HUB_OFFLINE so release checks need not download anything.
        import json
        import soundfile as sf
        from speech_backend import Transcriber
        samples, rate = sf.read(sys.argv[2], dtype='float32')
        if rate != 16000 or samples.ndim != 1:
            raise SystemExit('Test audio must be mono 16 kHz WAV')
        engine = Transcriber({'computeMode': 'cpu', 'cpuModel': 'tiny'})
        print(json.dumps({'text': engine.transcribe(samples), 'device': engine.device}), flush=True)
    elif sys.argv[1:]:
        raise SystemExit('Unknown speech helper option')
    else:
        import runpy
        runpy.run_module('dictate', run_name='__main__')
