# Installation and compatibility

## Install the Mac app

When a release is published, download the DMG from [GitHub Releases](https://github.com/Barty-Bart/opentoolkit/releases), open it and drag OpenToolkit into Applications. Open OpenToolkit there, select the tools you want, and grant their macOS permissions. The speech runtime is included; Python, Homebrew and developer tools are not required. The selected dictation model downloads on first use.

## Update

Choose **Check for Updates…** in the menu bar (or Settings). When a newer release exists, click **Download & install**. OpenToolkit waits until you're not dictating or recording, downloads the release DMG from this repository's GitHub releases, and installs it only if Apple notarized it and it's signed by the same developer. It then quits, replaces itself in place, and reopens. The previous version is kept in `~/Library/Application Support/Pico/InstallBackups` for rollback. Your history, settings and permissions are unchanged.

Updating manually also works: quit OpenToolkit, replace the app with the one from the new DMG, and reopen it. Switching from an ad-hoc development build to a Developer ID release may need a fresh permission grant; releases keep the same signing identity.

## Install from the CLI

Install Xcode Command Line Tools (`xcode-select --install`) and Python 3.12, then clone this repository and run from its folder:

```sh
python3.12 scripts/install.py --check
python3.12 scripts/install.py
```

The installer builds `~/Applications/OpenToolkit.app`, with both a Dock icon and menu-bar access. It creates a separate speech environment and downloads dependencies plus the small wake detector. Setup lets you choose tools, a speech model, and GPU / CPU / GPU with CPU fallback. Speech weights download on first use; several GB of disk space and an internet connection are needed for setup. Recognition then runs on your Mac.

Use `--native-only` to skip speech dependencies, or `--no-open` to install without opening the app. Rerun the installer to update a source build after stopping speech in Setup and quitting OpenToolkit. The installer refuses to overwrite a signed release with an ad-hoc build or a different signing identity; use the signed release instead. Previous app/code versions are backed up locally. The installer never imports another app's library.


## Existing models

OpenToolkit uses MLX Parakeet/Whisper for GPU transcription and faster-whisper for CPU transcription. Already cached copies of the exact supported model format can be reused by those libraries. There is no arbitrary model-file importer yet. A WhisperKit model or a whisper.cpp model is not an MLX model.

For AI bullet summaries or email drafts, start an existing local text model in LM Studio, then use Dictation → Local AI → Find models. Select it and enable local AI. Only loopback endpoints are accepted; Parakeet itself does not summarize.

MacWhisper offers a [local command-line interface](https://docs.macwhisper.com/article/57-macwhisper-command-line-tool) that can transcribe using its installed models. An OpenToolkit adapter could use that interface without copying MacWhisper files. Such an adapter is not included in this version.

For a fresh onboarding test, use another macOS user or a test Mac. Replacing the app preserves the existing library and does not simulate a first-time user.

## Permissions and signed updates

Open Settings → Permissions for live status. Screen & System Audio Recording belongs to **OpenToolkit**. Dictation Microphone and Accessibility belong to **OpenToolkit Speech**. The Fn listener uses Accessibility; it does not need a separate Input Monitoring grant. Optional video voiceover uses the main app's Microphone permission.

Each user grants access on their own Mac. The app cannot silently grant these permissions. After returning from System Settings, status refreshes automatically. If macOS requests a relaunch, finish recording before quitting and reopening. If speech access was enabled while the worker was running, use Restart speech.

Release builds retain the app and helper bundle IDs and Developer ID team. The installer compares their signing requirements before replacement; packaging rejects mismatched identities. This prevents accidental identity changes that make macOS forget grants. An OS security change, permission reset, or transition from an old development build may still require approval again. See [Apple's explanation of signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

For release acceptance, test first launch on a clean macOS user and an update from the previous signed release. Verify screen capture, Microphone, Fn and insertion without resetting permissions between versions. Test at least the minimum supported OS and the current OS; VM checks do not replace real-hardware microphone/GPU testing.
