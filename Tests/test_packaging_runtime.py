"""Packaging regressions tested with synthetic audio and disposable paths."""
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Voice'))
import runtime_paths
from speech_backend import GPUBackend


class RuntimeTests(unittest.TestCase):
    def test_writable_data_never_resolves_inside_bundle(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(Path, 'home', return_value=Path(directory)):
            self.assertEqual(runtime_paths.speech_data(), Path(directory)/'Library/Application Support/Pico/Speech')
            self.assertNotEqual(runtime_paths.speech_data(), runtime_paths.speech_resources())

    def test_long_audio_has_overlap_and_no_file_decoder(self):
        import numpy as np
        alignment = SimpleNamespace(merge_longest_contiguous=Mock(), merge_longest_common_subsequence=Mock(),
                                    tokens_to_sentences=Mock(), sentences_to_result=Mock())
        backend = GPUBackend.__new__(GPUBackend)
        backend.mx = SimpleNamespace(array=lambda values: values)
        backend.logmel = Mock(side_effect=lambda samples, config: samples)
        config = SimpleNamespace(sample_rate=16000, hop_length=160)
        first = SimpleNamespace(start=1., end=2., duration=1.)
        second = SimpleNamespace(start=2., end=3., duration=1.)
        backend.model = SimpleNamespace(preprocessor_config=config,
            generate=Mock(side_effect=[[SimpleNamespace(tokens=[first])], [SimpleNamespace(tokens=[second])]]))
        audio = np.zeros(181 * 16000, dtype=np.float32)
        with patch.dict(sys.modules, {'parakeet_mlx.alignment': alignment}), \
             patch.object(alignment, 'merge_longest_contiguous', return_value=[first, second]) as merge, \
             patch.object(alignment, 'tokens_to_sentences', return_value='sentences'), \
             patch.object(alignment, 'sentences_to_result', return_value=SimpleNamespace(text=' retained words ')):
            self.assertEqual(backend._long_parakeet(audio), 'retained words')
        lengths = [len(call.args[0]) for call in backend.logmel.call_args_list]
        self.assertEqual(lengths, [120 * 16000, 76 * 16000])
        self.assertEqual(second.start, 107.)
        merge.assert_called_once_with([first], [second], overlap_duration=15)


if __name__ == '__main__':
    unittest.main()
