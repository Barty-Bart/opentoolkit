# Speech runtime

Pico builds its own runtime from open source packages; it does not copy another app's binary or environment.

| Selection | Backend | Models |
| --- | --- | --- |
| GPU | MLX | Parakeet English; Whisper Tiny, Base, Small, Medium, Large v3 Turbo, Large v3 |
| CPU | faster-whisper / CTranslate2, int8 | Whisper sizes above |
| GPU with CPU fallback | MLX, then faster-whisper | Selected GPU model; separately selected CPU Whisper model |

CPU mode does not import MLX. A recoverable GPU allocation/device error during model load or transcription triggers one CPU attempt in fallback mode. The same audio is retried, and the session remains on CPU until restart. General errors (including model-download failures) do not trigger fallback. The active backend is shown in Dictation settings and saved with each transcript.

No fixed memory amount is wired on the GPU. Setup reads the Metal device name/availability and physical shared memory. Under 12 GB it suggests Whisper Small; at 12 GB or more it suggests Parakeet for English. Bigger Macs see Medium / Large alternatives. CPU Base is the default fallback. These thresholds are conservative product heuristics, not measured guarantees; other apps share the memory.

GPU resource failures are exceptions we can handle. A frozen native driver, OS termination or exhausted whole-system memory cannot be repaired by a Python fallback. Restart speech manually in that case. First fallback may require a separate Whisper model download.

Wake phrases use the separate sherpa-onnx keyword detector on CPU; full transcription is not continuously running just to hear the wake phrase. It still requires microphone listening while enabled. Continuous notes are a separate opt-in feature.

Dependencies are version-pinned at the direct dependency level. Transitive dependencies are resolved at install time; this is not a fully locked reproducible environment.

Upstream documentation: [MLX Whisper](https://pypi.org/project/mlx-whisper/), [faster-whisper](https://github.com/SYSTRAN/faster-whisper), [Parakeet MLX](https://github.com/senstella/parakeet-mlx), [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx). Dependencies and model weights retain their own licenses; weights are downloaded, not bundled in this repository.
