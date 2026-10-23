import AppKit
import Vision

/// One recognised line of text and the box of each word, in document points (origin bottom-left).
struct TextLine: Equatable {
    var frame: CGRect
    var words: [CGRect]
    func mapped(into rect: CGRect) -> TextLine {
        func map(_ r: CGRect) -> CGRect { CGRect(x: rect.minX + r.minX * rect.width, y: rect.minY + r.minY * rect.height, width: r.width * rect.width, height: r.height * rect.height) }
        return TextLine(frame: map(frame), words: words.map(map))
    }
}

/// The smart highlighter: a stroke that starts and ends on text snaps to whole words,
/// spanning lines the way a text selection does. Anything else stays freehand.
enum TextSnap {
    static func highlightRects(for stroke: [CGPoint], lines: [TextLine]) -> [CGRect]? {
        guard let a = stroke.first, let b = stroke.last, !lines.isEmpty else { return nil }
        func line(at p: CGPoint) -> Int? {
            lines.indices.filter { let f = lines[$0].frame; return f.insetBy(dx: -f.height * 0.4, dy: -f.height * 0.3).contains(p) }
                .min { abs(lines[$0].frame.midY - p.y) < abs(lines[$1].frame.midY - p.y) }
        }
        guard let ia = line(at: a), let ib = line(at: b) else { return nil }
        func band(_ line: TextLine, _ words: [CGRect]) -> CGRect? {
            guard let minX = words.map(\.minX).min(), let maxX = words.map(\.maxX).max() else { return nil }
            let padX = line.frame.height * 0.15, padY = line.frame.height * 0.12
            return CGRect(x: minX - padX, y: line.frame.minY - padY, width: maxX - minX + padX * 2, height: line.frame.height + padY * 2)
        }
        if ia == ib {
            let lo = min(a.x, b.x), hi = max(a.x, b.x)
            return band(lines[ia], lines[ia].words.filter { $0.maxX >= lo && $0.minX <= hi }).map { [$0] }
        }
        // Reading order: the higher line (larger y) is where the selection starts.
        let (top, start, bottom, end) = lines[ia].frame.midY >= lines[ib].frame.midY ? (lines[ia], a, lines[ib], b) : (lines[ib], b, lines[ia], a)
        let column = top.frame.union(bottom.frame)
        let middle = lines.filter { $0.frame.midY < top.frame.midY && $0.frame.midY > bottom.frame.midY && $0.frame.maxX > column.minX && $0.frame.minX < column.maxX && $0 != top && $0 != bottom }
            .sorted { $0.frame.midY > $1.frame.midY }
        let rects = [band(top, top.words.filter { $0.maxX >= start.x })] + middle.map { band($0, $0.words) } + [band(bottom, bottom.words.filter { $0.minX <= end.x })]
        let result = rects.compactMap { $0 }
        return result.isEmpty ? nil : result
    }

    /// Runs on-device Vision text recognition; boxes are normalised to the image (0–1, origin bottom-left).
    static func recognizeLines(in image: CGImage) -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string
            var words: [CGRect] = []
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, range, _, _ in
                if let box = try? candidate.boundingBox(for: range)?.boundingBox, box.width > 0 { words.append(box) }
            }
            return TextLine(frame: observation.boundingBox, words: words.isEmpty ? [observation.boundingBox] : words)
        }
    }
}
