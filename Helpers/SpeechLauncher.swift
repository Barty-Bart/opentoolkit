import Foundation
import Darwin

// The helper remains inside a named app bundle for macOS permission attribution.
let runtime = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pico/Speech")
let python = runtime.appendingPathComponent("venv/bin/python").path
let script = runtime.appendingPathComponent("dictate.py").path
guard FileManager.default.isExecutableFile(atPath: python), FileManager.default.fileExists(atPath: script) else {
    fputs("OpenToolkit speech is not installed. Run scripts/install.py from the source checkout.\n", stderr)
    exit(1)
}
let arguments = [python, "-u", script]
let pointers = arguments.map { strdup($0) } + [nil]
pointers.withUnsafeBufferPointer { buffer in _ = execv(python, buffer.baseAddress!) }
fputs("OpenToolkit could not start its speech runtime.\n", stderr)
exit(1)
