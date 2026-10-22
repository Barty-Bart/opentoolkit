# Build only from the isolated, pinned packaging environment. No user data inputs.
import os
import sys
import importlib
import plistlib
from pathlib import Path
from PyInstaller.utils.hooks import collect_all, collect_data_files, copy_metadata

root = Path(SPECPATH).parent
model = Path(os.environ['OPENTOOLKIT_WAKE_MODEL'])
identity = os.environ.get('OPENTOOLKIT_SIGNING_IDENTITY')
identity = None if identity in (None, '-') else identity
datas = [(str(root/'Voice/library_schema.sql'), '.'),
         (str(root/'packaging/bundled-runtime.json'), '.')]
datas += [(str(path), model.name) for path in model.iterdir() if path.is_file()]
binaries = []
hiddenimports = [path.stem for path in (root/'Voice').glob('*.py')]
for package in ('mlx', 'parakeet_mlx', 'mlx_whisper', 'sherpa_onnx', 'sentencepiece',
                'faster_whisper', 'sounddevice', 'soundfile'):
    package_data, package_binaries, package_imports = collect_all(package)
    datas += package_data
    binaries += package_binaries
    hiddenimports += package_imports
for package in ('AppKit', 'Foundation', 'Quartz', 'ApplicationServices', 'AVFoundation',
                'CoreFoundation', 'CoreAudio', 'CoreMedia', 'CoreText', 'objc', 'PyObjCTools'):
    # PyObjC resolves metadata modules lazily.
    from PyInstaller.utils.hooks import collect_submodules
    hiddenimports += collect_submodules(package)
for distribution in ('parakeet-mlx', 'mlx', 'mlx-whisper', 'faster-whisper', 'sherpa-onnx'):
    datas += copy_metadata(distribution)
analysis = Analysis([str(root/'packaging/speech_entry.py')], pathex=[str(root/'Voice')],
                    binaries=binaries, datas=datas, hiddenimports=hiddenimports,
                    excludes=['pytest', 'IPython', 'tkinter', 'matplotlib'], optimize=0)
# Standalone CPython's sysconfig module can bake the builder's installation path
# into the frozen archive. These are build metadata, not runtime library paths.
from PyInstaller.config import CONF
cache = CONF['code_cache'].get(id(analysis.pure)) or {}
CONF['code_cache'][id(analysis.pure)] = cache
for name, path, kind in analysis.pure:
    if name.startswith('_sysconfigdata_'):
        config = importlib.import_module(name).build_time_vars
        clean = {key: value.replace(str(Path.home()), '/usr/local/opentoolkit-build')
                 if isinstance(value, str) else value for key, value in config.items()}
        cache[name] = compile('build_time_vars = '+repr(clean), name+'.py', 'exec')
archive = PYZ(analysis.pure)
executable = EXE(archive, analysis.scripts, [], exclude_binaries=True, name='OpenToolkitSpeech',
                 debug=False, strip=False, upx=False, console=True, target_arch='arm64',
                 codesign_identity=identity,
                 entitlements_file=str(root/'packaging/speech.entitlements.plist'))
collected = COLLECT(executable, analysis.binaries, analysis.datas, strip=False, upx=False, name='OpenToolkitSpeech')
info = plistlib.loads((root/'Helpers/Info.plist').read_bytes())
app = BUNDLE(collected, name='OpenToolkit Speech.app', bundle_identifier=info['CFBundleIdentifier'],
             info_plist=info)
