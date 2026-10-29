import AppKit

/// Synthetic scrolling-capture checks: no screen capture or user files.
@main @MainActor struct ScrollingCaptureTests {
    static let width = 400, header = 40, footer = 90, window = 500
    static func context(_ height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
    /// A page of text-like lines, with one passage repeated further down as in a pasted list.
    static func page(height: Int) -> CGImage {
        let c = context(height); c.setFillColor(.white); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var seed: UInt64 = 42
        func random(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % n }
        var lines: [[(Int, Int)]] = []
        for _ in 0..<(height / 20) { var x = 10 + random(30), words: [(Int, Int)] = []; while x < width - 40 { let w = 12 + random(50); words.append((x, w)); x += w + 6 + random(6) }; lines.append(random(5) == 0 ? [] : words) }
        for n in 0..<20 where 60 + n < lines.count { lines[60 + n] = lines[30 + n] }
        for (n, words) in lines.enumerated() {
            // CGContext rows count from the bottom; page rows count from the top.
            let top = n * 20 + 4; c.setFillColor(CGColor(gray: 0.15, alpha: 1))
            for (x, w) in words { c.fill(CGRect(x: x, y: height - top - 10, width: w, height: 10)) }
        }
        return c.makeImage()!
    }
    /// What the screen shows with the page scrolled by `offset`: fixed header, content, fixed message box.
    static func view(_ page: CGImage, offset: Int, caret: Bool) -> CGImage {
        let height = header + window + footer, c = context(height)
        c.draw(page.cropping(to: CGRect(x: 0, y: offset, width: width, height: window))!, in: CGRect(x: 0, y: footer, width: width, height: window))
        c.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.8, alpha: 1)); c.fill(CGRect(x: 0, y: height - header, width: width, height: header))
        c.setFillColor(CGColor(gray: 0.93, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: width, height: footer))
        c.setFillColor(CGColor(gray: 0.4, alpha: 1)); for i in 0..<9 { c.fill(CGRect(x: 12 + i * 22, y: 14, width: 12, height: 12)) }
        if caret { c.setFillColor(.black); c.fill(CGRect(x: 30, y: 50, width: 2, height: 24)) }
        return c.makeImage()!
    }
    static func pixels(_ image: CGImage) -> [UInt8] {
        let c = context(image.height); c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, "FAIL: " + message); count += 1 }
        let full = page(height: 2400)
        let offsets = [0, 230, 410, 640, 820, 1100, 1330, 1560, 1800, 1900]
        let frames = offsets.enumerated().map { view(full, offset: $0.element, caret: $0.offset % 2 == 0) }
        let a = ScrollingCapture.gray(frames[0]), b = ScrollingCapture.gray(frames[1])
        let bands = ScrollingCapture.fixedBands(a, b, height: frames[0].height)
        check(bands.top == header && bands.bottom >= footer && bands.bottom < footer + 20, "fixed header and message box found despite the blinking caret")
        for n in 1..<frames.count {
            let match = ScrollingCapture.match(frames[n - 1], frames[n])
            check(match != nil && match!.rows == offsets[n] - offsets[n - 1] && match!.score < ScrollingCapture.reliable, "step \(n) moved \(offsets[n] - offsets[n - 1]) rows")
        }
        check(ScrollingCapture.match(frames[0], view(full, offset: 0, caret: false))?.rows == 0, "a view that didn't scroll counts as unchanged")
        let stitched = try ScrollingCapture.stitch(frames)
        let expected = context(header + offsets.last! + window + footer)
        let total = expected.height
        expected.draw(frames[0].cropping(to: CGRect(x: 0, y: 0, width: width, height: header))!, in: CGRect(x: 0, y: total - header, width: width, height: header))
        expected.draw(full.cropping(to: CGRect(x: 0, y: 0, width: width, height: offsets.last! + window))!, in: CGRect(x: 0, y: footer, width: width, height: offsets.last! + window))
        expected.draw(frames.last!.cropping(to: CGRect(x: 0, y: header + window, width: width, height: footer))!, in: CGRect(x: 0, y: 0, width: width, height: footer))
        check(stitched.height == total && stitched.width == width, "stitched height is header + whole page + one message box")
        check(pixels(stitched) == pixels(expected.makeImage()!), "stitched image matches the page exactly: no repeated message box or lines")
        let shifts = [0] + zip(offsets.dropFirst(), offsets).map { $0 - $1 }
        check(pixels(try ScrollingCapture.stitch(frames, shifts: shifts)) == pixels(stitched), "stored shifts give the same result")
        let far = view(full, offset: 1200, caret: false)
        check((ScrollingCapture.match(frames[0], far)?.score ?? 99) >= ScrollingCapture.reliable, "a jump with no overlap is rejected")
        let single = try ScrollingCapture.stitch([frames[0]])
        check(single.height == frames[0].height, "one view saves as is")
        print("Scrolling capture: \(count) checks passed with synthetic images.")
    }
}
