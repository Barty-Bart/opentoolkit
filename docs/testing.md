# Preview validation

Validation performed on an Apple Silicon Mac running macOS 26.5.1. Test data was synthetic and temporary. No real microphone recording or real Send button was used in these tests. These results describe specific checks, not complete application acceptance.

## Repaired DMG candidate

- 151 Python tests passed with isolated test data, including long-audio chunking, recovery on recognition/database failure, shared wake-prefix routing, runtime resource paths and OpenToolkit migration.
- 12 native settings checks verified the renamed default, preservation of custom wake phrases and settings, and saving/reloading the migration. The app and helper retain their original bundle identifiers and data paths.
- Synthetic spoken “Hey OpenToolkit” commands passed through the real CPU keyword detector: all 11 actions were detected, and 10 negative phrases produced no activation. This is not a guarantee of recognition for every speaker or noisy room.
- A real 202.29-second synthetic Parakeet GPU transcription succeeded with the former file/FFmpeg decoder path blocked. Both long and short transcripts committed to a disposable database. This exercised the repaired speech implementation; it was not a fresh-device end-to-end DMG test.
- The bundled helper passed SQLite, audio codec and durable-recovery checks offline, with no speech model or microphone opened.
- Developer ID signatures, hardened runtime and timestamps verified for the native app and bundled helper. The DMG signature and integrity verified. A mounted copy matched the packaged-file manifest, passed storage checks and retained a valid signature.
- All bundled Mach-O deployment targets are at or below macOS 14. That does not establish compatibility on an older OS.
- Apple notarization is pending for this candidate. Signing and notarization are separate steps.

## Earlier component checks

- 133 Python tests: corrections, cursor geometry, dictation delivery and recovery gestures, local database migration/search, formatting, CPU/GPU selection and fallback, installer platform checks and safe model extraction.
- 21 native library checks: search, folder preservation, migration, edit/delete indexing, transaction rollback, failed writes and recovery.
- 52 native organizer checks: reminders, note persistence, concurrent meeting edits, failed saves, local review behavior and private file permissions.
- Four speech recommendation profiles: low/high memory and GPU availability.
- Meeting-audio tests: synthetic stereo-to-mono resampling, stop flush, acknowledgment, silence and bounded backlog.
- Recording tests: synthetic MP4 tracks, audio mixing, dimensions, empty recordings and cancellation cleanup. macOS encoder access required running these outside the development sandbox.
- Isolated dependency installation succeeded; `pip check` reported no broken requirements.
- Real Parakeet GPU and Whisper Tiny CPU/GPU inference transcribed the same generated English sentence correctly. CPU mode loaded no MLX runtime.
- Injected GPU memory failure successfully retried that sentence through the real CPU backend. This tests the fallback path; it does not intentionally exhaust system memory.
- Native app and nested helper compiled and passed strict code-signature verification with ad-hoc signing.
- The actual CLI native installer completed into a disposable workspace destination without opening the app. Full speech dependencies and inference were tested separately; this was not a clean-device end-to-end install.

## Repeat automated tests

After installing speech dependencies into a test virtual environment:

```sh
python -m unittest discover -s Tests -p 'test_*.py'
bash Tests/run-recording-tests.sh
bash Tests/run-meeting-audio-tests.sh
```

The native library/organizer harnesses compile with `Sources/LibraryDatabase.swift` and `Sources/OrganizerTools.swift`; each corresponding `Tests/*Tests.swift` is its own executable. The recommendation harness uses only `Sources/SpeechRecommendation.swift`.

## Not yet validated for distribution

- A clean second Mac and the minimum macOS 14 release. Screen recording with microphone requires macOS 15+.
- Real inference for every offered Whisper size, or performance under competing GPU workloads. Recommendations are heuristics.
- End-to-end onboarding permission attribution for the new OpenToolkit speech helper; the original app's permissions do not transfer automatically.
- Visual acceptance of the new Setup controls: the native UI inspection connection failed. The app launched, but this was not a successful visual check.
- Every application's editable text field, Send button, caret and drag/drop handling. Accessibility support varies.
- Apple notarization of the current candidate, Intel Macs, automatic updates, and full fresh-device acceptance of the packaged app.

This is a current-development snapshot, not a claim that every idea on the roadmap is finished. Deferred: LLM bullet summaries, semantic Notes search, cloud sync and a camera overlay.
