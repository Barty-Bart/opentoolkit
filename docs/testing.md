# Private preview validation

Validation performed on an Apple Silicon Mac running macOS 26.5.1. Test data was synthetic and temporary. No real microphone recording or real Send button was used in these tests.

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
- End-to-end onboarding permission attribution for the new Pico speech helper; the original app's permissions do not transfer automatically.
- Visual acceptance of the new Setup controls: the native UI inspection connection failed. The app launched, but this was not a successful visual check.
- Every application's editable text field, Send button, caret and drag/drop handling. Accessibility support varies.
- Notarization, durable signing identity, Intel Macs, automatic updates, and consumer-ready packaging.

This is a current-development snapshot, not a claim that every idea on the roadmap is finished. Deferred: LLM bullet summaries, semantic Notes search, cloud sync, a camera overlay, and public release packaging.
