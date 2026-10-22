"""Branding updates preserve existing local storage and custom voice settings."""
import copy
import plistlib
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'Voice'))
from wake_engine import command_phrases, migrate_voice_branding
from runtime_paths import speech_data
from library_store import library_path


class BrandingTests(unittest.TestCase):
    def test_old_default_migrates_without_changing_other_settings_or_input(self):
        old={'wakePhrase':'Hey Pico','phrases':{'start':'hey pico start dictating','stop':'stop transcribing'},
             'liveEnabled':True,'recoveryKey':'option','indicatorColor':'blue'}
        original=copy.deepcopy(old)
        updated=migrate_voice_branding(old)
        self.assertEqual(updated['wakePhrase'],'hey open toolkit')
        self.assertEqual(updated['phrases']['start'],'start dictating')
        self.assertEqual(updated['recoveryKey'],'option')
        self.assertEqual(updated['indicatorColor'],'blue')
        self.assertTrue(updated['liveEnabled'])
        self.assertEqual(old,original)

    def test_pre_prefix_config_migrates(self):
        old={'phrases':{'start':'hey pico start dictating','note':'take a note'}}
        self.assertEqual(command_phrases(old)['start'],'hey open toolkit start dictating')
        self.assertEqual(command_phrases(old)['note'],'hey open toolkit take a note')

    def test_custom_wake_and_action_are_preserved(self):
        old={'wakePhrase':'hello pocket','phrases':{'start':'begin writing'}}
        updated=migrate_voice_branding(old)
        self.assertEqual(command_phrases(updated)['start'],'hello pocket begin writing')
        self.assertEqual(updated['phrases'],old['phrases'])

    def test_old_name_can_be_selected_after_migration(self):
        selected={'brandingVersion':1,'wakePhrase':'hey pico','phrases':{'start':'start dictating'}}
        self.assertEqual(migrate_voice_branding(selected),selected)
        self.assertEqual(command_phrases(selected)['start'],'hey pico start dictating')

    def test_storage_roots_are_stable(self):
        with patch.object(Path,'home',return_value=Path('/synthetic-home')):
            self.assertEqual(library_path(),Path('/synthetic-home/Library/Application Support/Pico/library.sqlite'))
            self.assertEqual(speech_data(),Path('/synthetic-home/Library/Application Support/Pico/Speech'))

    def test_visible_names_change_but_permission_identities_remain(self):
        for file,name,identifier,executable in [('Info.plist','OpenToolkit','local.pico','OpenToolkit'),
            ('Helpers/Info.plist','OpenToolkit Speech','local.pico.speech','OpenToolkitSpeech')]:
            info=plistlib.loads((ROOT/file).read_bytes())
            self.assertEqual(info['CFBundleName'],name)
            self.assertEqual(info['CFBundleIdentifier'],identifier)
            self.assertEqual(info['CFBundleExecutable'],executable)


if __name__=='__main__':unittest.main()
