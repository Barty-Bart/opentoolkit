#!/usr/bin/env python3
"""Install a local source build. No sudo, telemetry, account scan or data import."""
import argparse, datetime, hashlib, json, os, platform, plistlib, shutil, subprocess, sys, tarfile, tempfile, time, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODEL = 'sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01'
MODEL_URL = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/' + MODEL + '.tar.bz2'
MODEL_SHA256 = 'f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a'
MODEL_FILES = {'bpe.model', 'tokens.txt'} | {name+'-epoch-12-avg-2-chunk-16-left-64.onnx' for name in ('encoder','decoder','joiner')}

def check_system(system, machine, version, python_version):
    if system != 'Darwin' or machine != 'arm64':
        raise ValueError('OpenToolkit currently supports Apple Silicon Macs only.')
    if tuple(int(n) for n in version.split('.')[:2]) < (14,0):
        raise ValueError('OpenToolkit requires macOS 14 or newer. Older versions are not supported.')
    if tuple(python_version[:2]) != (3,12):
        raise ValueError('Run this installer with Python 3.12 (for example: python3.12 scripts/install.py).')

def extract_wake_model(archive, destination, expected_hash=MODEL_SHA256):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected_hash:
        raise ValueError('Wake model checksum mismatch; no files extracted.')
    destination.mkdir(parents=True,exist_ok=True)
    with tarfile.open(archive,'r:bz2') as tar:
        members={m.name:m for m in tar.getmembers()}
        for name in MODEL_FILES:
            member=members.get(MODEL+'/'+name)
            if member is None or not member.isfile() or member.size>200_000_000:
                raise ValueError('Wake model archive has an unexpected layout.')
        for name in MODEL_FILES:
            with tar.extractfile(members[MODEL+'/'+name]) as source, (destination/name).open('wb') as output:
                shutil.copyfileobj(source,output)

def assert_idle(data, app):
    job=subprocess.run(["/bin/launchctl","print",f"gui/{os.getuid()}/local.pico.speech"],capture_output=True,text=True)
    if job.returncode == 0:
        raise ValueError("Stop OpenToolkit speech in Setup before updating, including while a model is loading.")
    state=data/'VoiceBridge/state.json'
    if state.exists():
        try:s=json.loads(state.read_text())
        except (ValueError,OSError):raise ValueError('Cannot read speech status. Quit OpenToolkit and stop its speech worker before updating.')
        if time.time()-s.get('time',0)<10:
            raise ValueError('OpenToolkit speech is running. Use Stop speech in Setup before updating.')
    # Check exact executable paths, without matching other applications.
    processes=subprocess.run(['/bin/ps','-axo','comm='],capture_output=True,text=True,check=True).stdout.splitlines()
    candidates={app/'Contents/MacOS/OpenToolkit',app.with_name('Pico.app')/'Contents/MacOS/Pico',
                Path('/Applications/Pico.app/Contents/MacOS/Pico'),
                Path.home()/'Applications/Pico.app/Contents/MacOS/Pico'}
    if {str(path) for path in candidates}.intersection(p.strip() for p in processes):
        raise ValueError('Quit OpenToolkit and any older Pico app before updating.')

def install_files(source, app, runtime):
    app.parent.mkdir(parents=True,exist_ok=True)
    backup=runtime.parent/'InstallBackups'/datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    backup.mkdir(parents=True,mode=0o700)
    if app.exists():shutil.copytree(app,backup/'OpenToolkit.app',symlinks=True)
    modules=list((ROOT/'Voice').glob('*.py'))+list((ROOT/'Voice').glob('*.sql'))
    for item in modules:
        if (runtime/item.name).exists():shutil.copy2(runtime/item.name,backup/item.name)
    staged=app.with_name('.OpenToolkit-install-'+backup.name+'.app')
    shutil.copytree(source,staged,symlinks=True)
    old=None
    try:
        for item in modules:
            temp=runtime/(item.name+'.new');shutil.copy2(item,temp);os.replace(temp,runtime/item.name)
        if app.exists():
            old=app.with_name('.OpenToolkit-previous-'+backup.name+'.app');app.rename(old)
        staged.rename(app)
    except Exception:
        if old and old.exists() and not app.exists():old.rename(app)
        for item in modules:
            if (backup/item.name).exists():shutil.copy2(backup/item.name,runtime/item.name)
        raise
    finally:
        if staged.exists():shutil.rmtree(staged)
    if old and old.exists():shutil.rmtree(old)  # full previous bundle is preserved in backup
    return backup

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check',action='store_true',help='Check prerequisites only; do not install or download')
    parser.add_argument('--native-only',action='store_true',help='Install screenshot/annotation app without speech dependencies')
    parser.add_argument('--no-open',action='store_true',help='Do not open OpenToolkit after installation')
    args=parser.parse_args()
    check_system(platform.system(),platform.machine(),platform.mac_ver()[0],sys.version_info)
    subprocess.run(['xcode-select','-p'],check=True,stdout=subprocess.DEVNULL)
    print('Supported Mac: Apple Silicon, macOS '+platform.mac_ver()[0]+', Python 3.12, Xcode command-line tools.')
    print('Speech: local Parakeet or Whisper, GPU/CPU options; wake phrases use a small CPU model. No other apps or models are scanned.')
    if args.check:return
    data=Path.home()/'Library/Application Support/Pico';runtime=data/'Speech';app=Path.home()/'Applications/OpenToolkit.app'
    assert_idle(data,app)
    print('Building a local app. Speech installation downloads Python dependencies and a verified wake model. The speech model downloads on first start.')
    with tempfile.TemporaryDirectory(prefix='opentoolkit-build-') as tmp:
        subprocess.run(['/bin/bash',str(ROOT/'build.sh'),tmp],check=True)
        source=Path(tmp)/'OpenToolkit.app'
        from signing_identity import validate_upgrade
        validate_upgrade(app, source)
        runtime.mkdir(parents=True,exist_ok=True,mode=0o700);data.chmod(0o700)
        if not args.native_only:
            python=runtime/'venv/bin/python'
            if not python.exists():subprocess.run([sys.executable,'-m','venv',str(runtime/'venv')],check=True)
            subprocess.run([str(python),'-m','pip','install','-r',str(ROOT/'requirements.txt')],check=True)
            model=runtime/MODEL
            if not all((model/n).is_file() for n in MODEL_FILES):
                archive=Path(tmp)/'wake.tar.bz2'
                with urllib.request.urlopen(MODEL_URL,timeout=60) as response,archive.open('wb') as output:
                    shutil.copyfileobj(response,output)
                extract_wake_model(archive,model)
        assert_idle(data,app)
        backup=install_files(source,app,runtime)
        subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
        print('Installed '+str(app)+'. Previous app/code preserved in '+str(backup))
    print('Your library is outside the checkout. Open Setup in OpenToolkit to enable speech and grant permissions.')
    if not args.no_open:subprocess.run(['open',str(app)],check=True)

if __name__=='__main__':
    try:main()
    except (ValueError,subprocess.CalledProcessError,OSError) as error:
        print('Installation stopped: '+str(error),file=sys.stderr);sys.exit(1)
