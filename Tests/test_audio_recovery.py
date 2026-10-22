import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock
import numpy as np
import soundfile as sf
from test_voice import dictation_class
from audio_recovery import PendingRecording


class AudioRecoveryTests(unittest.TestCase):
    def test_exact_audio_survives_until_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            samples=np.linspace(-.5,.5,16000,dtype=np.float32)
            pending=PendingRecording(samples,16000,Path(directory)/'recovery')
            loaded,rate=sf.read(pending.audio,dtype='float32')
            np.testing.assert_array_equal(loaded,samples)
            self.assertEqual(rate,16000)
            self.assertEqual(pending.audio.stat().st_mode & 0o777,0o600)
            self.assertEqual(pending.directory.stat().st_mode & 0o777,0o700)
            pending.save_text('A recoverable transcript.')
            self.assertEqual(pending.text.read_text(),'A recoverable transcript.')
            self.assertEqual(pending.text.stat().st_mode & 0o777,0o600)
            pending.complete()
            self.assertEqual(list(pending.directory.iterdir()),[])

    def run_pipeline(self,error=None,commit_error=None,recognized='Recovered words.'):
        cls,env=dictation_class()
        d=cls.__new__(cls)
        d.transcriber=Mock(name='Test engine')
        d.transcriber.name='Synthetic engine'
        d.transcriber.transcribe=Mock(return_value=recognized,side_effect=error)
        d.db=Mock()
        d.db.commit.side_effect=commit_error
        d.voice_control=Mock(config={})
        context={'app':'Test','mode':'practice','voice':False,'send':False,'target':None}
        return d,env,context

    def test_recognition_failure_retains_audio(self):
        d,env,context=self.run_pipeline(error=RuntimeError('synthetic failure'))
        d._transcribe_and_paste(np.zeros(16000,dtype=np.float32),context)
        self.assertEqual(len(list(Path(d.recovery_directory).glob('*.wav'))),1)
        d.db.commit.assert_not_called()
        self.assertIn('retained',d.recovery_error)

    def test_database_failure_retains_audio_and_recognized_text(self):
        d,env,context=self.run_pipeline(commit_error=OSError('synthetic disk error'))
        with self.assertRaises(OSError):
            d._transcribe_and_paste(np.zeros(16000,dtype=np.float32),context)
        self.assertEqual(len(list(Path(d.recovery_directory).glob('*.wav'))),1)
        self.assertEqual(next(Path(d.recovery_directory).glob('*.txt')).read_text(),'Recovered words.')

    def test_success_removes_recovery_only_after_history_commit(self):
        d,env,context=self.run_pipeline()
        def commit():
            self.assertEqual(len(list(Path(d.recovery_directory).glob('*.wav'))),1)
        d.db.commit.side_effect=commit
        d._transcribe_and_paste(np.zeros(16000,dtype=np.float32),context)
        self.assertEqual(list(Path(d.recovery_directory).iterdir()),[])
        d.db.commit.assert_called_once()

    def test_empty_recognition_keeps_audio(self):
        d,env,context=self.run_pipeline(recognized='')
        d._transcribe_and_paste(np.zeros(16000,dtype=np.float32),context)
        self.assertEqual(len(list(Path(d.recovery_directory).glob('*.wav'))),1)
        d.db.commit.assert_not_called()


if __name__=='__main__':
    unittest.main()
