import AppKit

enum HandMaker {
    static let prompt = """
    Make a pointer image for AiHand, a Mac app that shows a toy hand on screen.

    Draw one cartoon right hand in this style: [describe your hand, e.g. knitted wool in mustard yellow]

    Rules:
    - We see the BACK of the hand. The palm faces away from us. The knuckles and the smooth back of the hand face the viewer.
    - The index finger points straight up. The other three fingers are folded down, so we only see their knuckles, never their fingertips or fingernails.
    - The raised index finger sits at the far left of the knuckle row, right next to the thumb. Three folded knuckles sit to its right. It must never look like a middle finger.
    - The thumb is tucked against the left side of the hand. Nothing crosses the front of the fist: no thumb, no fingertips, no fingernails, no palm.
    - The fingertip is the highest point of the image. Nothing above or beside it.
    - The hand ends at the bottom in a wrist cuff or a clean flat wrist, facing straight down, centred.
    - Upright, not tilted. Whole hand visible, nothing cropped.
    - Transparent background. No shadow, no floor, no outline glow, no text, no stick, no arm.
    - Soft 3D toy look, bright and readable at small sizes.
    - Portrait image, hand filling most of the height with a little empty space around it.
    """

    static func prompt(for idea: String) -> String {
        let trimmed = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        let style = trimmed.isEmpty ? "a soft vinyl toy in a bright colour" : trimmed
        return prompt.replacingOccurrences(of: "[describe your hand, e.g. knitted wool in mustard yellow]", with: style)
    }

    struct Problem: Error {
        let message: String
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let rgba: [UInt8]

        func alpha(_ x: Int, _ y: Int) -> UInt8 {
            rgba[(y * width + x) * 4 + 3]
        }
    }

    static func make(from url: URL) throws -> (image: CGImage, ink: UInt32) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Problem(message: "That file isn't an image AiHand can read.")
        }
        let pixels = try read(image)
        try check(pixels)
        guard let composed = compose(image, pixels) else {
            throw Problem(message: "AiHand couldn't put that hand on a stick.")
        }
        return (composed, ink(pixels))
    }

    private static func read(_ image: CGImage) throws -> Pixels {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            throw Problem(message: "The image needs a transparent background. Save it as a PNG with transparency.")
        default:
            break
        }
        let w = image.width
        let h = image.height
        guard w >= 64, h >= 64 else {
            throw Problem(message: "The image is too small. Use one at least 512 pixels tall.")
        }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Problem(message: "That file isn't an image AiHand can read.")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Pixels(width: w, height: h, rgba: rgba)
    }

    private static func check(_ p: Pixels) throws {
        let w = p.width
        let h = p.height
        var edge = 0
        var edgeSolid = 0
        for x in 0..<w {
            edge += 2
            edgeSolid += (p.alpha(x, 0) > 32 ? 1 : 0) + (p.alpha(x, h - 1) > 32 ? 1 : 0)
        }
        for y in 0..<h {
            edge += 2
            edgeSolid += (p.alpha(0, y) > 32 ? 1 : 0) + (p.alpha(w - 1, y) > 32 ? 1 : 0)
        }
        if Double(edgeSolid) / Double(edge) > 0.02 {
            throw Problem(message: "The background isn't transparent, or the hand touches the edge of the image.")
        }

        let step = max(1, min(w, h) / 256)
        let gw = w / step
        let gh = h / step
        var grid = [Bool](repeating: false, count: gw * gh)
        for gy in 0..<gh {
            for gx in 0..<gw where p.alpha(gx * step, gy * step) > 128 {
                grid[gy * gw + gx] = true
            }
        }
        var seen = [Bool](repeating: false, count: gw * gh)
        var sizes: [Int] = []
        for start in 0..<grid.count where grid[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var n = 0
            while let i = stack.popLast() {
                n += 1
                let x = i % gw
                let y = i / gw
                for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] where nx >= 0 && ny >= 0 && nx < gw && ny < gh {
                    let j = ny * gw + nx
                    if grid[j] && !seen[j] {
                        seen[j] = true
                        stack.append(j)
                    }
                }
            }
            sizes.append(n)
        }
        guard let biggest = sizes.max() else {
            throw Problem(message: "The image is empty.")
        }
        if Double(biggest) / Double(sizes.reduce(0, +)) < 0.97 {
            throw Problem(message: "The image has more than one thing in it. Use a single hand.")
        }

        guard let box = bounds(p) else {
            throw Problem(message: "The image is empty.")
        }
        let bw = box.maxX - box.minX + 1
        let bh = box.maxY - box.minY + 1
        let aspect = Double(bh) / Double(bw)
        if aspect < 1.05 || aspect > 2.8 {
            throw Problem(message: "The hand should stand upright, taller than it is wide.")
        }
        if Double(bh) / Double(h) < 0.5 {
            throw Problem(message: "The hand is too small in the image. Crop it closer.")
        }

        let topBand = max(2, bh * 8 / 100)
        var fingerMin = w
        var fingerMax = 0
        for y in box.minY..<(box.minY + topBand) {
            for x in box.minX...box.maxX where p.alpha(x, y) > 128 {
                fingerMin = min(fingerMin, x)
                fingerMax = max(fingerMax, x)
            }
        }
        if Double(fingerMax - fingerMin + 1) / Double(bw) > 0.4 {
            throw Problem(message: "The top of the image should be a single finger pointing up.")
        }

        let base = bottomSpan(p, box)
        if Double(base.width) / Double(bw) < 0.2 {
            throw Problem(message: "The hand should end in a flat wrist or cuff at the bottom.")
        }

        var soft = 0
        var any = 0
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) {
                let a = p.alpha(x, y)
                if a > 20 {
                    any += 1
                    if a < 200 {
                        soft += 1
                    }
                }
            }
        }
        if Double(soft) / Double(max(1, any)) > 0.08 {
            throw Problem(message: "The hand has a soft shadow or glow around it. Ask for no shadow.")
        }
    }

    private static func bounds(_ p: Pixels) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = p.width
        var minY = p.height
        var maxX = -1
        var maxY = -1
        for y in 0..<p.height {
            for x in 0..<p.width where p.alpha(x, y) > 128 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : (minX, minY, maxX, maxY)
    }

    private static func bottomSpan(_ p: Pixels, _ box: (minX: Int, minY: Int, maxX: Int, maxY: Int)) -> (width: Int, center: Double) {
        let bh = box.maxY - box.minY + 1
        var lo = p.width
        var hi = -1
        for y in max(box.minY, box.maxY - max(2, bh * 4 / 100))...box.maxY {
            for x in box.minX...box.maxX where p.alpha(x, y) > 128 {
                lo = min(lo, x)
                hi = max(hi, x)
            }
        }
        return hi < 0 ? (0, Double(box.minX + box.maxX) / 2) : (hi - lo + 1, Double(lo + hi) / 2)
    }

    private static func compose(_ image: CGImage, _ p: Pixels) -> CGImage? {
        guard let box = bounds(p) else {
            return nil
        }
        let canvasW = 1024
        let canvasH = 1536
        let handTop: CGFloat = 150
        let handHeight: CGFloat = 560
        let bw = CGFloat(box.maxX - box.minX + 1)
        let bh = CGFloat(box.maxY - box.minY + 1)
        let scale = min(handHeight / bh, 700 / bw)
        let drawW = CGFloat(p.width) * scale
        let drawH = CGFloat(p.height) * scale
        let wristX = (bottomSpan(p, box).center + 0.5) * Double(scale)
        let originX = CGFloat(canvasW) / 2 - CGFloat(wristX)
        let originTop = handTop - CGFloat(box.minY) * scale
        let handBottom = handTop + bh * scale

        guard let ctx = CGContext(data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .high

        let rodW = min(76, max(54, bw * scale * 0.18))
        let rodTop = handBottom - 30
        let rodBottom: CGFloat = 1462
        let rod = CGRect(x: CGFloat(canvasW) / 2 - rodW / 2, y: CGFloat(canvasH) - rodBottom,
                         width: rodW, height: rodBottom - rodTop)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rod, cornerWidth: rodW / 2, cornerHeight: rodW / 2, transform: nil))
        ctx.clip()
        let colors = [Ink.hex(0x000000), Ink.hex(0x121214), Ink.hex(0x3A3A3E), Ink.hex(0x121214), Ink.hex(0x000000)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                     locations: [0, 0.22, 0.45, 0.75, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rod.minX, y: 0), end: CGPoint(x: rod.maxX, y: 0), options: [])
        }
        ctx.restoreGState()

        ctx.draw(image, in: CGRect(x: originX, y: CGFloat(canvasH) - originTop - drawH, width: drawW, height: drawH))
        return ctx.makeImage()
    }

    private static func ink(_ p: Pixels) -> UInt32 {
        var best: (score: Double, r: Double, g: Double, b: Double) = (-1, 0.53, 0.33, 0.95)
        var buckets: [Int: (n: Int, r: Double, g: Double, b: Double)] = [:]
        for y in stride(from: 0, to: p.height, by: 3) {
            for x in stride(from: 0, to: p.width, by: 3) {
                let i = (y * p.width + x) * 4
                let a = Double(p.rgba[i + 3])
                guard a > 200 else {
                    continue
                }
                let r = Double(p.rgba[i]) / a
                let g = Double(p.rgba[i + 1]) / a
                let b = Double(p.rgba[i + 2]) / a
                let key = Int(r * 5) * 36 + Int(g * 5) * 6 + Int(b * 5)
                var e = buckets[key] ?? (0, 0, 0, 0)
                e.n += 1
                e.r += r
                e.g += g
                e.b += b
                buckets[key] = e
            }
        }
        for e in buckets.values {
            let r = e.r / Double(e.n)
            let g = e.g / Double(e.n)
            let b = e.b / Double(e.n)
            let hi = max(r, g, b)
            let lo = min(r, g, b)
            let sat = hi == 0 ? 0 : (hi - lo) / hi
            let lum = 0.3 * r + 0.59 * g + 0.11 * b
            let score = Double(e.n) * (0.25 + sat) * (lum > 0.12 && lum < 0.85 ? 1 : 0.15)
            if score > best.score {
                best = (score, r, g, b)
            }
        }
        let hi = max(best.r, best.g, best.b)
        let lo = min(best.r, best.g, best.b)
        var r = best.r
        var g = best.g
        var b = best.b
        if hi - lo < 0.08 {
            r = 0.42
            g = 0.45
            b = 0.5
        } else if hi > 0.82 {
            r *= 0.82 / hi
            g *= 0.82 / hi
            b *= 0.82 / hi
        }
        return UInt32(min(255, r * 255)) << 16 | UInt32(min(255, g * 255)) << 8 | UInt32(min(255, b * 255))
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Problem(message: "AiHand couldn't save the hand.")
        }
        try data.write(to: url, options: .atomic)
    }
}

struct CustomHand: Codable {
    let id: String
    var name: String
    let ink: UInt32
}

enum CustomHands {
    static let changed = Notification.Name("AiHandCustomHandsChanged")

    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["TH_HANDS_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return AppSupport.directory(subpath: "Hands")
    }

    private static var listURL: URL {
        directory.appendingPathComponent("hands.json")
    }

    private static var loaded: [CustomHand]?

    static var all: [CustomHand] {
        if let loaded = loaded {
            return loaded
        }
        let list = (try? Data(contentsOf: listURL)).flatMap { try? JSONDecoder().decode([CustomHand].self, from: $0) } ?? []
        loaded = list
        return list
    }

    static func hand(_ id: String) -> CustomHand? {
        guard id.hasPrefix("custom-") else {
            return nil
        }
        return all.first { $0.id == id }
    }

    @discardableResult
    static func add(_ image: CGImage, ink: UInt32, name: String) throws -> PointerStyle {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = "custom-" + UUID().uuidString.prefix(8).lowercased()
        try HandMaker.write(image, to: directory.appendingPathComponent("\(id).png"))
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = all
        list.append(CustomHand(id: id, name: trimmed.isEmpty ? "My hand \(list.count + 1)" : String(trimmed.prefix(16)), ink: ink))
        try save(list)
        guard let style = PointerStyle(rawValue: id) else {
            throw HandMaker.Problem(message: "AiHand couldn't add that hand.")
        }
        return style
    }

    static func remove(_ style: PointerStyle) {
        guard let assetName = style.assetName, style.isCustom else {
            return
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(assetName).png"))
        HandAsset.forget(assetName)
        try? save(all.filter { $0.id != style.rawValue })
    }

    private static func save(_ list: [CustomHand]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(list).write(to: listURL, options: .atomic)
        loaded = list
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func suggestedName(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let words = base.split(separator: " ").prefix(2).joined(separator: " ")
        guard !words.isEmpty, words.count <= 16, !words.lowercased().hasPrefix("chatgpt image") else {
            return "My hand \(all.count + 1)"
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
