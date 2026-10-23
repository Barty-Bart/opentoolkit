# Preview validation

Validation performed on an Apple Silicon Mac running macOS 26.5.1. Test speech and images were synthetic. These results describe specific checks on different builds, not complete application acceptance. No real Send button was exercised.

## Release 0.3.0 — 23 October 2026

- 208 Python tests and the native library, organizer, editor (17), voice-settings, recording and meeting-audio harnesses pass with isolated synthetic data.
- Updater checks (10) use local DMGs and temporary folders: only a notarized DMG from this repository, signed by the same team and newer than the installed app, is accepted; a different developer, an older version and an un-notarized DMG are refused; the swap step replaces the app, keeps the previous version and relaunches.
- Dictation delivery was exercised in real use on the development Mac in Chrome and an Electron chat app, including editors that report an empty box as a single line break and apps that temporarily stop reporting their focused text box. Exact-match verification gates automatic Send and correction watching; recognition alone is not counted as delivery.
- Drawing tool shortcuts are registered only while drawing is on. Capture, menu-bar and Shortcuts-settings changes were inspected in the running app.
- Not yet validated: clean-account first launch, macOS 14 hardware, a second Mac, and every application's text fields.

The tests below document earlier packages and isolated component runs. Their results do not automatically apply to a changed binary.

## Earlier repaired DMG — superseded

- 151 Python tests passed with isolated test data, including long-audio chunking, recovery on recognition/database failure, shared wake-prefix routing, runtime resource paths and OpenToolkit migration.
- 12 native settings checks verified the renamed default, preservation of custom wake phrases and settings, and saving/reloading the migration. The app and helper retain their original bundle identifiers and data paths.
- Synthetic spoken “Hey OpenToolkit” commands passed through the real CPU keyword detector: all 11 actions were detected, and 10 negative phrases produced no activation. This is not a guarantee of recognition for every speaker or noisy room.
- A real 202.29-second synthetic Parakeet GPU transcription succeeded with the former file/FFmpeg decoder path blocked. Both long and short transcripts committed to a disposable database. This exercised the repaired speech implementation; it was not a fresh-device end-to-end DMG test.
- The bundled helper passed SQLite, audio codec and durable-recovery checks offline, with no speech model or microphone opened.
- Developer ID signatures, hardened runtime and timestamps verified for the native app and bundled helper. The DMG signature and integrity verified. A mounted copy matched the packaged-file manifest, passed storage checks and retained a valid signature.
- All bundled Mach-O deployment targets are at or below macOS 14. That does not establish compatibility on an older OS.
- Apple accepted the repaired candidate with no reported issues. Its DMG ticket was stapled and validated, Gatekeeper accepted the DMG and enclosed app as Notarized Developer ID, and all 3,918 packaged files still matched the reviewed manifest. This covers the repaired candidate, not subsequent source changes.

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
- First-time permission attribution and onboarding on a clean user account, plus upgrades between distributable signed releases. Existing-user local testing is not a clean-install test.
- Text insertion in the actual foreground browser/native field, including focus changes, live replacement and correction detection. Recognition/history success alone is insufficient.
- Every application's editable text field, Send button, caret and drag/drop handling. Accessibility support varies.
- Intel Macs and full fresh-device acceptance of the packaged app.

This is a current-development snapshot, not a claim that every idea on the roadmap is finished. Deferred: semantic Notes search, cloud sync and a camera overlay. The new local AI writing integration needs real-model and microphone acceptance testing.

## Editor and command flow — earlier isolated development checks

- 166 Python tests passed with temporary data. Added wake-window expiry/epoch/single-use routing, localhost-only AI HTTP, refusal of remote URLs/redirects, original/draft persistence, failure cancelling Send, and typing during inference cancelling automatic paste. AI capture does not queue live-preview inference.
- 12 native settings checks passed. Existing custom prefixes, action phrases, and recovery settings survive migration to the new default.
- 28 synthetic speech cases passed through the actual CPU detector: all 16 keyword labels, four wake-plus-command sequences with a pause, five non-wake conversational phrases, and three bare action phrases. Bare actions are detected acoustically but cannot execute without the separately tested wake window. Continuous “Hey Toolkit start transcribing” without a pause was not reliable; wait for the cue. This test is one synthetic voice, not real-speaker/noise acceptance.
- 16 native renderer checks passed: output dimensions at multiple zoom levels, opaque redaction, transparent highlight, fill color, crop/undo/redo, horizontal/vertical combination, and dirty-state reset after saving.
- Isolated native editor UI: arrow drawing and movement, text insertion, crop application and undo, compact layout after status changes, Save as, and Done were exercised with synthetic images. Save as and Done produced matching edited PNG bytes. The drag handle exported an original-resolution PNG with private file permissions; drops into every external app have not been validated.
- The local AI integration was tested against a synthetic HTTP server. Actual LM Studio model quality, latency, memory use, and microphone-to-final-draft operation remain unverified. No live GPU model, user recordings, production app, or user database was used for this development test run.

Keyword tuning follows the [sherpa-onnx keyword-file documentation](https://k2-fsa.github.io/sherpa/onnx/kws/index.html). The detector preserves buffered audio between the wake phrase and action, and initializes fresh streams with silence context.
