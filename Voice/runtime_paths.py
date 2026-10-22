"""Keep writable speech state outside the signed application bundle."""
from pathlib import Path


def speech_data():
    return Path.home() / 'Library/Application Support/Pico/Speech'


def speech_resources():
    # Also works inside PyInstaller: resource files are adjacent to frozen modules.
    return Path(__file__).resolve().parent
