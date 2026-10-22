"""Local speech engines. GPU fallback is explicit and retries the same audio once."""
import gc
import os
import sys
import tempfile

WHISPER_MODELS = {
    'tiny': 'mlx-community/whisper-tiny-mlx',
    'base': 'mlx-community/whisper-base-mlx',
    'small': 'mlx-community/whisper-small-mlx',
    'medium': 'mlx-community/whisper-medium-mlx',
    'large-v3-turbo': 'mlx-community/whisper-large-v3-turbo',
    'large-v3': 'mlx-community/whisper-large-v3-mlx',
}
PARAKEET = 'mlx-community/parakeet-tdt-0.6b-v2'


def gpu_resource_error(error):
    # Network, corrupt weights, unsupported operations and arbitrary bugs must surface.
    message = str(error).lower()
    return isinstance(error, MemoryError) or any(term in message for term in (
        'metal is not available', 'no metal device', 'metal device unavailable',
        'metal out of memory', 'out of memory', 'failed to allocate',
        'insufficient memory', 'command buffer execution failed',
    ))


class GPUBackend:
    def __init__(self, engine, whisper):
        import mlx.core as mx
        self.mx = mx
        if not mx.metal.is_available():
            raise RuntimeError('Metal is not available')
        # Do not wire a fixed 3 GB on every Mac or pin memory against other apps.
        self.engine = engine
        self.whisper = whisper
        if engine == 'parakeet':
            from parakeet_mlx import from_pretrained
            from parakeet_mlx.audio import get_logmel
            self.model = from_pretrained(PARAKEET)
            self.logmel = get_logmel
        else:
            import mlx_whisper
            self.module = mlx_whisper
        import numpy as np
        self.transcribe(np.zeros(16000, dtype=np.float32))

    def transcribe(self, audio):
        if self.engine == 'whisper':
            return self.module.transcribe(audio, path_or_hf_repo=WHISPER_MODELS[self.whisper], language='en')['text'].strip()
        if len(audio) > 180 * 16000:
            import soundfile as sf
            with tempfile.NamedTemporaryFile(suffix='.wav') as file:
                sf.write(file.name, audio, 16000)
                return self.model.transcribe(file.name, chunk_duration=120, overlap_duration=15).text.strip()
        mel = self.logmel(self.mx.array(audio), self.model.preprocessor_config)
        return self.model.generate(mel)[0].text.strip()

    def close(self):
        self.model = None
        if hasattr(self, 'module'):
            # mlx-whisper caches its single loaded model at module scope.
            from mlx_whisper.transcribe import ModelHolder
            ModelHolder.model = None
            ModelHolder.model_path = None
        gc.collect()
        self.mx.clear_cache()


class CPUBackend:
    def __init__(self, model):
        from faster_whisper import WhisperModel
        self.model = WhisperModel(model, device='cpu', compute_type='int8',
                                  cpu_threads=max(1, min(8, (os.cpu_count() or 2) - 1)))

    def transcribe(self, audio):
        segments, _ = self.model.transcribe(audio, language='en', beam_size=1, condition_on_previous_text=False)
        return ' '.join(segment.text.strip() for segment in segments).strip()


class Transcriber:
    def __init__(self, config=None, notify=None, gpu_factory=GPUBackend, cpu_factory=CPUBackend):
        config = config or {}
        self.notify = notify or (lambda text: None)
        self.mode = config.get('computeMode') or 'gpu'
        if self.mode not in ('gpu', 'cpu', 'gpu_fallback'):
            raise ValueError('Unknown speech compute mode')
        self.engine = config.get('speechEngine') or 'parakeet'
        if self.engine not in ('parakeet', 'whisper'):
            raise ValueError('Unknown speech engine')
        value = config.get('whisperModel') or WHISPER_MODELS['large-v3-turbo']
        # Accept previous GPU model path spelling without changing saved settings.
        self.whisper = next((key for key, repo in WHISPER_MODELS.items() if value in (key, repo)), None)
        if value == 'mlx-community/whisper-large-v3':self.whisper = 'large-v3'
        if self.whisper is None:raise ValueError('Unknown Whisper model')
        self.cpu_model = config.get('cpuModel') or 'base'
        if self.cpu_model not in WHISPER_MODELS:raise ValueError('Unknown CPU Whisper model')
        self.cpu_factory = cpu_factory
        self.backend = None
        self.fallback = False
        self.device = 'cpu' if self.mode == 'cpu' else 'gpu'
        if self.device == 'cpu':
            self._cpu(False)
        else:
            try:
                self.notify('Loading GPU speech model…')
                self.backend = gpu_factory(self.engine, self.whisper)
                self.name = 'GPU · ' + ('Parakeet' if self.engine == 'parakeet' else 'Whisper ' + self.whisper)
            except Exception as error:
                if self.mode != 'gpu_fallback' or not gpu_resource_error(error):raise
                # Discard exception frames holding partially loaded GPU tensors.
                error.__traceback__ = None
                self._cpu(True)
        self.notify(self.name + ' ready')

    def _cpu(self, fallback):
        old, self.backend = self.backend, None
        if old is not None:
            try:old.close()
            except Exception:pass  # A failed GPU must not prevent the CPU attempt.
        del old
        # Also release the module cache after a constructor/warm-up failure.
        module = sys.modules.get('mlx_whisper.transcribe')
        if module is not None:
            module.ModelHolder.model = None
            module.ModelHolder.model_path = None
        gc.collect()
        mx = sys.modules.get('mlx.core')
        if mx is not None:
            try:mx.clear_cache()
            except Exception:pass
        self.device = 'cpu'
        self.fallback = fallback
        self.name = 'CPU · Whisper ' + self.cpu_model + (' · GPU fallback' if fallback else '')
        self.notify(('GPU unavailable; switching to ' if fallback else 'Loading ') + 'CPU Whisper ' + self.cpu_model + '…')
        self.backend = self.cpu_factory(self.cpu_model)

    def transcribe(self, audio):
        try:
            return self.backend.transcribe(audio)
        except Exception as error:
            if self.mode != 'gpu_fallback' or self.device != 'gpu' or not gpu_resource_error(error):raise
            error.__traceback__ = None
            self._cpu(True)
            result = self.backend.transcribe(audio)
            self.notify(self.name + ' ready')
            return result
