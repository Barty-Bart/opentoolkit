import AppKit

/// Synthetic scrolling-capture checks: no screen capture or user files.
@main @MainActor struct ScrollingCaptureTests {
    static func page(width: Int, height: Int) -> CGImage {
        let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var seed: UInt64 = 42
        for y in stride(from: 0, to: height, by: 6) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let shade = CGFloat(seed >> 56) / 255
            c.setFillColor(CGColor(red: shade, green: 1 - shade, blue: shade * 0.5, alpha: 1)); c.fill(CGRect(x: 0, y: y, width: width, height: 6))
        }
        return c.makeImage()!
    }
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { precondition(value, "FAIL: " + message); count += 1 }
        let full = page(width: 320, height: 900), view = 300
        // Frames as a user scrolls down by 120 px each time (180 px overlap); cropping counts rows from the top.
        let frames = stride(from: 0, through: 900 - view, by: 120).map { offset in full.cropping(to: CGRect(x: 0, y: offset, width: 320, height: view))! }
        check(ScrollingCapture.difference(frames[0], frames[0]) < 0.01, "identical views count as no scroll")
        check(ScrollingCapture.difference(frames[0], frames[1]) > 1.5, "a scrolled view counts as movement")
        let match = ScrollingCapture.overlap(frames[0], frames[1])
        check(match != nil && abs(match!.size - 180) <= 2 && match!.score < 12, "overlap of 180 px found")
        let stitched = try ScrollingCapture.stitch(frames)
        let expected = view * frames.count - 180 * (frames.count - 1)
        check(abs(stitched.height - expected) <= 2 * frames.count && stitched.width == 320, "stitched height matches the scrolled content")
        let far = full.cropping(to: CGRect(x: 0, y: 600, width: 320, height: view))!
        check((ScrollingCapture.overlap(frames[0], far)?.score ?? 99) >= 12, "a jump with no overlap is rejected")
        print("Scrolling capture: \(count) checks passed with synthetic images.")
    }
}
