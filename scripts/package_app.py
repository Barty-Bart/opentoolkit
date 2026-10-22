#!/usr/bin/env python3
"""Build a self-contained local DMG. Never install, notarize, upload or publish it."""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import urllib.request

from install import MODEL, MODEL_URL, MODEL_SHA256, extract_wake_model, check_system

ROOT = Path(__file__).resolve().parents[1]


def run(*arguments, **kwargs):
    subprocess.run([str(a) for a in arguments], check=True, **kwargs)


def sign(path, identity, entitlements=None):
    args = ['codesign', '--force', '--sign', identity]
    if identity == '-':
        args += ['--timestamp=none']
    else:
        args += ['--options', 'runtime', '--timestamp']
    if entitlements:
        args += ['--entitlements', str(entitlements)]
    run(*args, path)


def write_notices(destination):
    """Include installed dependency licenses without copying local package metadata."""
    destination.mkdir(parents=True)
    entries = []
    for dist in sorted(importlib.metadata.distributions(), key=lambda d: d.metadata['Name'].lower()):
        name, version = dist.metadata['Name'], dist.version
        entries.append({'name': name, 'version': version,
                        'license': dist.metadata.get('License-Expression') or dist.metadata.get('License', ''),
                        'homepage': dist.metadata.get('Home-page', '')})
        for file in dist.files or []:
            if any(word in file.name.lower() for word in ('license', 'copying', 'notice')) and '.dist-info' in str(file):
                source = Path(dist.locate_file(file))
                if source.is_file():
                    folder = destination / (name + '-' + version)
                    folder.mkdir(exist_ok=True)
                    # RECORD/direct_url.json are intentionally never copied.
                    shutil.copyfile(source, folder / (str(file).replace('/', '_')))
    (destination/'dependencies.json').write_text(json.dumps(entries, indent=2)+'\n')


def strip_build_metadata(app):
    """Do not distribute pip's installation paths or local file inventories."""
    for path in app.rglob('*'):
        if path.name not in {'direct_url.json', 'RECORD'}:
            continue
        if any(parent.name.endswith(('.dist-info', '.egg-info')) for parent in path.parents):
            if path.is_file() or path.is_symlink():
                path.unlink()


def validate_deployment_targets(app):
    from macholib.MachO import MachO
    from macholib.mach_o import LC_BUILD_VERSION, LC_VERSION_MIN_MACOSX
    magic = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
    for path in app.rglob('*'):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as file:
            if file.read(4) not in magic:
                continue
        for header in MachO(str(path)).headers:
            for command, details, data in header.commands:
                if command.cmd not in (LC_BUILD_VERSION, LC_VERSION_MIN_MACOSX):
                    continue
                value = details.minos if command.cmd == LC_BUILD_VERSION else details.version
                if value > (14 << 16):
                    raise ValueError('A bundled library requires newer than macOS 14: '+str(path.relative_to(app))+
                                     '. Install the macOS 14-compatible wheel before packaging.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, required=True, help='New, disposable build directory')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--identity', help='Developer ID Application signing identity or certificate fingerprint')
    parser.add_argument('--development', action='store_true', help='Create an explicitly unnotarized local test DMG')
    parser.add_argument('--full-runtime-check', action='store_true', help='Also load the wake model and GPU libraries; use only on a test machine or in an agreed maintenance window')
    args = parser.parse_args()
    import platform
    check_system(platform.system(), platform.machine(), platform.mac_ver()[0], sys.version_info)
    if args.development and args.identity:
        parser.error('Choose development packaging or Developer ID signing, not both.')
    if not args.development and not args.identity:
        parser.error('Release packaging requires --identity. Use --development for local tests only.')
    identity = '-' if args.development else args.identity
    if not args.development:
        identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
        if not any(identity in line and 'Developer ID Application:' in line for line in identities.splitlines()):
            parser.error('The selected Developer ID Application certificate and private key are not available.')
    work, output = args.work_dir.resolve(), args.output.resolve()
    if work.exists() or output.exists():
        parser.error('Use a new work directory and output filename; existing artifacts are never replaced.')
    work.mkdir(parents=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    if not args.development:
        # Fail at one small key-access check rather than prompting for each library.
        probe = work/'signing-probe'
        shutil.copyfile('/usr/bin/true', probe)
        sign(probe, identity)
        run('codesign', '--verify', '--strict', probe)
    archive = work/'wake.tar.bz2'
    with urllib.request.urlopen(MODEL_URL, timeout=60) as response, archive.open('wb') as target:
        shutil.copyfileobj(response, target)
    extract_wake_model(archive, work/MODEL)
    environment = dict(os.environ, OPENTOOLKIT_WAKE_MODEL=str(work/MODEL), OPENTOOLKIT_SIGNING_IDENTITY=identity,
                       PYINSTALLER_CONFIG_DIR=str(work/'pyinstaller-cache'))
    run(sys.executable, '-m', 'PyInstaller', '--noconfirm', '--distpath', work/'speech',
        '--workpath', work/'freeze', ROOT/'packaging/speech.spec', env=environment)
    run('/bin/bash', ROOT/'build.sh', work/'native', env=dict(environment, OPENTOOLKIT_SIGNING_IDENTITY='-'))
    app = work/'native/OpenToolkit.app'
    helper = app/'Contents/Helpers/OpenToolkit Speech.app'
    shutil.rmtree(helper)  # Replace only the just-built disposable launcher.
    shutil.copytree(work/'speech/OpenToolkit Speech.app', helper, symlinks=True)
    strip_build_metadata(app)
    validate_deployment_targets(app)
    write_notices(app/'Contents/Resources/ThirdPartyNotices')
    sign(helper, identity, ROOT/'packaging/speech.entitlements.plist')
    sign(app, identity, ROOT/'packaging/app.entitlements.plist')
    run('codesign', '--verify', '--deep', '--strict', app)
    test_home = work/'self-test-home'
    test_home.mkdir()
    test_env = dict(environment, HOME=str(test_home), PATH='/usr/bin:/bin:/usr/sbin:/sbin',
                    HF_HUB_OFFLINE='1', HF_HUB_DISABLE_IMPLICIT_TOKEN='1')
    for key in ('PYTHONHOME', 'PYTHONPATH', 'HF_TOKEN', 'HUGGING_FACE_HUB_TOKEN'):
        test_env.pop(key, None)
    run(helper/'Contents/MacOS/OpenToolkitSpeech', '--self-test-storage', env=test_env)
    if args.full_runtime_check:
        run(helper/'Contents/MacOS/OpenToolkitSpeech', '--self-test', env=test_env)
    run('codesign', '--verify', '--deep', '--strict', app)
    stage = work/'dmg'
    stage.mkdir()
    shutil.copytree(app, stage/'OpenToolkit.app', symlinks=True)
    (stage/'Applications').symlink_to('/Applications')
    status = 'LOCAL TEST BUILD — not notarized or ready for distribution.\n\n' if args.development else ''
    (stage/'Read Me.txt').write_text(status +
        'OpenToolkit for Apple Silicon\n\nDrag OpenToolkit into Applications, then open it there.\n'
        'The speech runtime is included; Python and developer tools are not required.\n'
        'First use downloads the selected speech model. Microphone, Accessibility and\n'
        'Screen Recording permissions are requested for the tools you enable.\n'
        'Your library and settings remain in your own Application Support folder.\n'
        'The intended minimum is macOS 14; older-OS acceptance testing is pending.\n')
    run('hdiutil', 'create', '-volname', 'OpenToolkit Preview' if args.development else 'OpenToolkit',
        '-srcfolder', stage, '-format', 'UDZO', '-ov', output)
    if not args.development:
        run('codesign', '--force', '--sign', identity, '--timestamp', output)
    run('hdiutil', 'verify', output)
    manifest = {str(p.relative_to(stage)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted(stage.rglob('*')) if p.is_file() and not p.is_symlink()}
    report = {'dmg': output.name, 'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
              'development': args.development, 'notarized': False, 'published': False,
              'wakeArchiveSHA256': MODEL_SHA256, 'files': manifest}
    output.with_suffix('.manifest.json').write_text(json.dumps(report, indent=2)+'\n')
    print('Prepared '+str(output)+'; not uploaded or notarized. Review before any upload.')


if __name__ == '__main__':
    main()
