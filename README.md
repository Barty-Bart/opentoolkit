# Pico

A local Mac toolkit for dictation, screenshots, annotation and quick screen recordings. Notes and meeting transcripts are experimental and off by default.

**Private preview · Apple Silicon · macOS 14 or newer.** Built and tested on macOS 26; the macOS 14 minimum still needs testing on a separate machine. This is a source installation for early testing, not a notarized consumer release.

## Install from the CLI

Install Xcode Command Line Tools (`xcode-select --install`) and Python 3.12, then clone this repository and run from its folder:

```sh
python3.12 scripts/install.py --check
python3.12 scripts/install.py
```

The installer builds `~/Applications/Pico.app`, with both a Dock icon and menu-bar access. It creates a separate speech environment and downloads dependencies plus the small wake detector. Setup lets you choose tools, a speech model, and GPU / CPU / GPU with CPU fallback. Speech weights download on first use; several GB of disk space and an internet connection are needed for setup. Recognition then runs on your Mac.

Use `--native-only` to skip speech dependencies, or `--no-open` to install without opening the app. Rerun the installer to update after stopping speech in Setup and quitting Pico. Previous app/code versions are backed up locally. The installer never imports another app's library.

## Use

- **Dictation:** hold Fn, or tap Fn to start/stop hands-free dictation. Configure live typing, sounds, indicators, writing modes and correction suggestions in Dictation.
- **Recover:** double-tap Shift to paste the latest saved transcript; triple-tap for history. Choose another recovery key or turn this off in settings.
- **Screenshots:** Command–Shift–4 for a freeform region, Command–Shift–3 for full screen, Command–Shift–5 for capture options including fixed dimensions, scrolling captures and video/GIF. All shortcuts are configurable; macOS or other capture tools may already own them.
- **Preview:** edit, crop, copy, save, dismiss or drag a capture into another app. Temporary captures stay in Pico's local cache until expiry; Save exports a file.
- **Notes:** optional folders, keyword search, voice notes and meeting/daily sessions in one library. Dictation has its own history. No embeddings or model/account discovery.

Pico requests permissions for enabled tools. Screen capture uses Screen & System Audio Recording. Speech needs Microphone and Accessibility, and macOS may request Input Monitoring. Local ad-hoc builds can need permission again after updates; a CLI installer does not remove this macOS restriction.

## Privacy and preview limits

Data lives in `~/Library/Application Support/Pico`, outside the checkout. There is no telemetry, sign-in, sync, email watcher or remote transcription. Model downloads contact their hosts. Never commit your library, custom corrections, sounds, captures, credentials or speech environment.

English recognition is configured in this preview. Parakeet uses MLX on the GPU; Whisper supports MLX GPU or faster-whisper CPU. Recommendations are hardware heuristics, not performance promises. CPU fallback is optional and cannot recover an OS-killed or hung worker. Exact caret placement and correction detection depend on what the target app exposes through macOS Accessibility.

Writing modes format text; bullet mode splits sentences and **does not summarize**. Notes summaries with an LLM, semantic search, sync, a camera overlay for recordings, notarization and a DMG are future work. Wake phrases and sending are off by default. Review the [test results and limitations](docs/testing.md) before relying on this preview.
