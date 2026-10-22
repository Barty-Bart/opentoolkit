import sys, unittest
from pathlib import Path
from unittest.mock import Mock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Voice'))
from speech_backend import Transcriber, WHISPER_MODELS, gpu_resource_error

class SpeechTests(unittest.TestCase):
    def test_cpu_never_loads_gpu(self):
        gpu=Mock(side_effect=AssertionError('GPU imported'));cpu=Mock()
        t=Transcriber({'computeMode':'cpu','cpuModel':'small'},gpu_factory=gpu,cpu_factory=cpu)
        t.transcribe('audio');gpu.assert_not_called();cpu.assert_called_once_with('small')
        cpu.return_value.transcribe.assert_called_once_with('audio');self.assertEqual(t.device,'cpu')
    def test_gpu_is_default(self):
        gpu=Mock();cpu=Mock();t=Transcriber(gpu_factory=gpu,cpu_factory=cpu)
        gpu.assert_called_once_with('parakeet','large-v3-turbo');cpu.assert_not_called();self.assertFalse(t.fallback)
    def test_explicit_gpu_does_not_fallback(self):
        cpu=Mock()
        with self.assertRaises(MemoryError):Transcriber(gpu_factory=Mock(side_effect=MemoryError()),cpu_factory=cpu)
        cpu.assert_not_called()
    def test_startup_gpu_failure(self):
        cpu=Mock();events=[]
        t=Transcriber({'computeMode':'gpu_fallback'},notify=events.append,gpu_factory=Mock(side_effect=RuntimeError('Metal is not available')),cpu_factory=cpu)
        cpu.assert_called_once_with('base');self.assertTrue(t.fallback);self.assertIn('GPU fallback',t.name)
        self.assertTrue(any('switching' in e for e in events))
    def test_same_audio_retried_once_and_cpu_sticky(self):
        gpu=Mock();gpu.transcribe.side_effect=RuntimeError('Metal out of memory')
        cpu=Mock();cpu.transcribe.return_value='saved words';factory=Mock(return_value=cpu)
        t=Transcriber({'computeMode':'gpu_fallback'},gpu_factory=lambda *a:gpu,cpu_factory=factory)
        audio=object();self.assertEqual(t.transcribe(audio),'saved words');t.transcribe('next')
        gpu.transcribe.assert_called_once_with(audio);gpu.close.assert_called_once()
        self.assertEqual(cpu.transcribe.call_args_list[0].args,(audio,));factory.assert_called_once()
    def test_cpu_error_is_not_retried(self):
        gpu=Mock();gpu.transcribe.side_effect=MemoryError()
        cpu=Mock();cpu.transcribe.side_effect=MemoryError()
        t=Transcriber({'computeMode':'gpu_fallback'},gpu_factory=lambda *a:gpu,cpu_factory=lambda *a:cpu)
        with self.assertRaises(MemoryError):t.transcribe('audio')
        cpu.transcribe.assert_called_once()
    def test_network_failure_not_masked(self):
        for error in (ConnectionError('download failed'),ValueError('invalid weights'),RuntimeError('unsupported operation')):
            cpu=Mock()
            with self.assertRaises(type(error)):Transcriber({'computeMode':'gpu_fallback'},gpu_factory=Mock(side_effect=error),cpu_factory=cpu)
            cpu.assert_not_called()
    def test_inference_bug_not_masked(self):
        gpu=Mock();gpu.transcribe.side_effect=ValueError('invalid shape');cpu=Mock()
        t=Transcriber({'computeMode':'gpu_fallback'},gpu_factory=lambda *a:gpu,cpu_factory=cpu)
        with self.assertRaises(ValueError):t.transcribe('audio')
        cpu.assert_not_called()
    def test_models_and_legacy_path(self):
        for key,repo in WHISPER_MODELS.items():
            gpu=Mock();t=Transcriber({'speechEngine':'whisper','whisperModel':repo},gpu_factory=gpu)
            gpu.assert_called_once_with('whisper',key)
        t=Transcriber({'whisperModel':'mlx-community/whisper-large-v3'},gpu_factory=Mock())
        self.assertEqual(t.whisper,'large-v3')
    def test_unknown_selection_fails_closed(self):
        for config in ({'computeMode':'cloud'},{'cpuModel':'custom'},{'whisperModel':'unknown'},{'speechEngine':'remote'}):
            with self.assertRaises(ValueError):Transcriber(config,gpu_factory=Mock(),cpu_factory=Mock())
    def test_no_fallback_on_arbitrary_metal_message(self):
        self.assertFalse(gpu_resource_error(RuntimeError('Metal unsupported operator')))

if __name__=='__main__':unittest.main()
