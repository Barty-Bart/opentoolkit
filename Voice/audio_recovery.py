"""Keep stopped dictation recoverable until its transcript is committed to history."""
import os
import uuid
from pathlib import Path


class PendingRecording:
    def __init__(self, audio, rate, directory=None):
        import soundfile as sf
        self.directory = Path(directory) if directory else Path.home() / 'Library/Application Support/Pico/Speech/Recovery'
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.directory.chmod(0o700)
        self.identifier = uuid.uuid4().hex
        self.audio = self.directory / (self.identifier + '.wav')
        self.text = self.directory / (self.identifier + '.txt')
        # Open owner-only before writing any speech, including during a crash.
        descriptor = os.open(self.audio, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'wb') as output:
            sf.write(output, audio, rate, format='WAV', subtype='FLOAT')
            output.flush()
            os.fsync(output.fileno())
        self._sync_directory()

    def save_text(self, text):
        temporary = self.text.with_suffix('.txt.pending')
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w', encoding='utf-8') as output:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, self.text)
        self._sync_directory()

    def complete(self):
        """Call only after the transcript's database transaction commits."""
        for path in (self.audio, self.text):
            path.unlink(missing_ok=True)
        self._sync_directory()

    def _sync_directory(self):
        descriptor = os.open(self.directory, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
