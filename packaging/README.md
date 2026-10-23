# Local macOS packaging

The DMG build embeds a standalone Python speech helper inside the native app. It does not require Python, Homebrew, Xcode or a CLI installer on the receiving Mac. Speech model weights download on first use; the small checksum-verified wake model is bundled. Application data remains under the user's Application Support folder.

Build on Apple Silicon with Python 3.12 and Xcode command-line tools. Use a disposable environment containing `requirements.txt` plus `packaging/requirements-build.txt`. Do not use a personal speech environment as a packaging input.

For a macOS 14 baseline, explicitly select the macOS 14 wheels for both `mlx` and `mlx-metal` at the pinned version. Pip on a newer Mac otherwise selects newer-OS builds. Download with `pip download --no-deps --only-binary=:all: --platform macosx_14_0_arm64 --python-version 312 --implementation cp --abi cp312`, then install those wheels into the packaging environment with `--no-deps --force-reinstall`. The packager rejects any Mach-O dependency whose deployment target exceeds macOS 14.

```
python scripts/package_app.py --development --work-dir build/local-candidate --output dist/OpenToolkit-local-preview.dmg
```

This creates an explicitly labelled, ad-hoc signed local test package. It is not a notarized release. Each invocation requires a new build directory and output filename.

For a Developer ID candidate, supply a valid **Developer ID Application** identity from the local Keychain:

```
python scripts/package_app.py --identity 'Developer ID Application: …' --work-dir build/signed-candidate --output dist/OpenToolkit-candidate.dmg
```

The script signs the nested runtime, app and DMG, verifies the bundle, runs an offline storage/codec/recovery self-test using a disposable home, validates the disk image and writes a SHA-256 file manifest. The default self-test does not load speech models or open the microphone. Use `--full-runtime-check` only on a test machine or during an agreed maintenance window to also check model/library initialization. It never installs or uploads anything. Keep signing keys, notarization credentials and private data outside this repository. The app's display name can change independently of the developer certificate; stabilize bundle identifiers before public release.

Before any notarization upload, review the exact artifact and obtain the owner's approval under the contributor instructions. Only then submit that artifact to Apple's notarization service using credentials stored in Keychain. Inspect Apple's result, staple its ticket, verify Gatekeeper, and retest the mounted package. Public release is a separate approval.

Minimum OS declarations are not compatibility test results. Check native dependencies' deployment targets and run the app on every supported OS. Hardware, global shortcuts, live microphone/GPU inference and permission retention need physical-Mac testing. A successful import test alone does not establish those behaviors.

Third-party dependency notices accompany the app. OpenToolkit itself is MIT-licensed (see `LICENSE`); dependencies and downloaded model weights keep their own licenses.
