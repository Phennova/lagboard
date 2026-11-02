import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import VideoToolbox

// Native port of the extension's video effects (extension/inject.js), used by
// Virtual Camera mode. Coordinates are top-left based to mirror the canvas code.

private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
private func rnd(_ a: Double, _ b: Double) -> Double { Double.random(in: a..<max(b, a + 0.000001)) }
private func chance(_ p: Double) -> Bool { Double.random(in: 0..<1) < p }
private func even(_ n: Double) -> Int { max(16, Int((n / 2).rounded()) * 2) }

private func hash(_ x: Int, _ y: Int, _ s: UInt32) -> Double {
    var n = UInt32(truncatingIfNeeded: x) &* 374_761_393 &+ UInt32(truncatingIfNeeded: y) &* 668_265_263 &+ s &* 2_147_483_647
    n = (n ^ (n >> 13)) &* 1_274_126_177
    return Double(n ^ (n >> 16)) / 4_294_967_296
}

/// Thread-safe snapshot of which effects are on (written on main, read on the video queue).
final class FXState {
    private let lock = NSLock()
    private var active: Set<String> = []
    private var intensity = 0.7
    func set(_ a: Set<String>, _ i: Double) { lock.lock(); active = a; intensity = i; lock.unlock() }
    func get() -> (Set<String>, Double) { lock.lock(); defer { lock.unlock() }; return (active, intensity) }
}

/// A BGRA bitmap with top-left drawing helpers.
final class Surface {
    let w: Int, h: Int
    let ctx: CGContext
    init(_ w: Int, _ h: Int) {
        self.w = w
        self.h = h
        ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.interpolationQuality = .medium
    }
    private func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height) }
    func draw(_ img: CGImage, _ dst: CGRect) { ctx.draw(img, in: flip(dst)) }
    func draw(_ img: CGImage) { ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)) }
    /// drawImage(img, sx, sy, sw, sh, dx, dy, dw, dh) — source rect is clamped inside the image.
    func blit(_ img: CGImage, _ s: CGRect, _ d: CGRect) {
        let sx = min(max(0, s.minX), CGFloat(img.width) - s.width)
        let sy = min(max(0, s.minY), CGFloat(img.height) - s.height)
        guard let c = img.cropping(to: CGRect(x: sx, y: sy, width: s.width, height: s.height).integral) else { return }
        draw(c, d)
    }
    func fill(_ r: CGRect, _ color: CGColor) { ctx.setFillColor(color); ctx.fill(flip(r)) }
    func image() -> CGImage { ctx.makeImage()! }
    var bytes: UnsafeMutablePointer<UInt8> { ctx.data!.assumingMemoryBound(to: UInt8.self) }
}

/// Real low-bitrate H.264 round trip (encode → decode) for the "Potato Res" look.
final class Crunch {
    private var enc: VTCompressionSession?
    private var dec: VTDecompressionSession?
    private var key = ""
    private var lastEncode = 0.0
    private var nextKey = 0.0
    private var pool: CVPixelBufferPool?
    private let lock = NSLock()
    private var _latest: CGImage?
    private(set) var failed = false
    var lastUse = 0.0
    var isOpen: Bool { enc != nil }

    private var latest: CGImage? {
        get { lock.lock(); defer { lock.unlock() }; return _latest }
        set { lock.lock(); _latest = newValue; lock.unlock() }
    }

    func feed(_ src: CGImage, t: Double, I: Double) -> CGImage? {
        if failed { return nil }
        lastUse = t
        let cw = even(lerp(400, 640, I))
        let ch = even(Double(cw) * 9 / 16)
        let bitrate = Int(lerp(70, 20, I)) * 1000
        let fps = lerp(18, 7, I)
        let qp = Int(lerp(32, 45, I)) // forced harshness floor (H.264 QP, 51 = worst)
        let k = "\(cw)x\(ch)@\(bitrate)q\(qp)"
        if k != key || enc == nil {
            key = k
            setup(cw, ch, bitrate, fps, qp)
            if failed { return nil }
        }
        if t - lastEncode >= 1000 / fps || latest == nil, let enc, let pool {
            lastEncode = t
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut else { return latest }
            CVPixelBufferLockBaseAddress(pb, [])
            if let c = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: cw, height: ch, bitsPerComponent: 8,
                                 bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                c.interpolationQuality = .medium
                c.draw(src, in: CGRect(x: 0, y: 0, width: cw, height: ch))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            var props: CFDictionary?
            if t > nextKey {
                nextKey = t + rnd(2500, 6000)
                props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            }
            VTCompressionSessionEncodeFrame(enc, imageBuffer: pb, presentationTimeStamp: CMTime(seconds: t / 1000, preferredTimescale: 1000),
                                            duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sbuf in
                guard status == noErr, let sbuf, let self else { return }
                self.decode(sbuf)
            }
        }
        return latest
    }

    private func setup(_ cw: Int, _ ch: Int, _ bitrate: Int, _ fps: Double, _ qp: Int) {
        stopSessions()
        var session: VTCompressionSession?
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(cw), height: Int32(ch), codecType: kCMVideoCodecType_H264,
                                            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard st == noErr, let s = session else { failed = true; return }
        let set: (CFString, CFTypeRef) -> Void = { k, v in _ = VTSessionSetProperty(s, key: k, value: v) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_DataRateLimits, [bitrate / 8 * 3 / 2, 1] as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 600 as CFNumber)
        set(kVTCompressionPropertyKey_MinAllowedFrameQP, qp as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        enc = s
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                      kCVPixelBufferWidthKey: cw, kCVPixelBufferHeightKey: ch,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        nextKey = 0
    }

    private func decode(_ sbuf: CMSampleBuffer) {
        if dec == nil, let fmt = CMSampleBufferGetFormatDescription(sbuf) {
            let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
            var d: VTDecompressionSession?
            VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                         imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &d)
            dec = d
        }
        guard let dec else { return }
        VTDecompressionSessionDecodeFrame(dec, sampleBuffer: sbuf, flags: [], infoFlagsOut: nil) { [weak self] status, _, img, _, _ in
            guard status == noErr, let img, let self else { return }
            var cg: CGImage?
            VTCreateCGImageFromCVPixelBuffer(img, options: nil, imageOut: &cg)
            if let cg { self.latest = cg }
        }
    }

    private func stopSessions() {
        if let enc { VTCompressionSessionInvalidate(enc) }
        if let dec { VTDecompressionSessionInvalidate(dec) }
        enc = nil
        dec = nil
    }

    func close() {
        stopSessions()
        key = ""
        latest = nil
    }
}

/// The effects engine. All calls happen on the video queue.
final class NativeFX {
    static let videoIDs: Set<String> = ["lowres", "blocky", "stutter", "freeze", "smear", "glitch", "lag", "blackout"]
    let W = 1280, H = 720

    private let input: Surface
    private let main: Surface
    private let work: Surface
    private var prevImage: CGImage?
    private var small: Surface?
    private var tiny: Surface?
    private let motion = Surface(32, 18)
    private let crunch = Crunch()

    private var hasContent = false
    private var nextStutter = 0.0
    private var lagBuf: [CGImage] = []
    private var lastMotion: [UInt8]?
    private var smearVec = (0.0, 0.0)
    private var smearVecUntil = 0.0
    private var nextKeyframe = 0.0
    private var glitch: (kind: String, until: Double, y0: Double, band: (Double, Double), shift: Double)?
    private var blockEpoch = 0.0
    private var blockSeed: UInt32 = 1
    private var active: Set<String> = []
    private var I = 0.7

    init() {
        input = Surface(W, H)
        main = Surface(W, H)
        work = Surface(W, H)
    }

    private func on(_ id: String) -> Bool { active.contains(id) }

    /// Takes a camera frame and returns the bitmap to send (1280×720 BGRA).
    func process(_ camera: CGImage, active: Set<String>, intensity: Double) -> Surface {
        self.active = active
        I = intensity
        let t = CACurrentMediaTime() * 1000

        // normalise the camera into 1280×720 (aspect fill)
        let s = max(Double(W) / Double(camera.width), Double(H) / Double(camera.height))
        let dw = Double(camera.width) * s, dh = Double(camera.height) * s
        input.ctx.interpolationQuality = .medium
        input.draw(camera, CGRect(x: (Double(W) - dw) / 2, y: (Double(H) - dh) / 2, width: dw, height: dh))

        if !on("lowres") && crunch.isOpen && t - crunch.lastUse > 4000 { crunch.close() }
        let anyOn = !active.isDisjoint(with: Self.videoIDs) || !lagBuf.isEmpty
        if !anyOn {
            hasContent = false
            lastMotion = nil
            return input
        }
        var source = input.image()

        // lag spike: freeze while recording, then fast-forward through the backlog at 3x
        var hold = false
        if on("lag") {
            if lagBuf.count < 150 { lagBuf.append(snapshot(source)) }
            hold = hasContent
        } else if !lagBuf.isEmpty {
            lagBuf.append(snapshot(source))
            for _ in 0..<2 where lagBuf.count > 1 { lagBuf.removeFirst() }
            source = lagBuf.removeFirst()
            if lagBuf.count <= 1 { lagBuf.removeAll() }
        }
        if on("freeze") { hold = hold || hasContent }
        if on("stutter") && !hold && hasContent {
            if t < nextStutter { hold = true } else {
                let hitch = chance(0.12) ? rnd(500, 1300) * (0.4 + I) : 0
                nextStutter = t + rnd(70, 110 + 420 * I) + hitch
            }
        }

        if on("blackout") {
            main.fill(CGRect(x: 0, y: 0, width: W, height: H), CGColor(gray: 0, alpha: 1))
            hasContent = false
        } else if !hold || !hasContent {
            render(source, t)
        }
        return main
    }

    private func snapshot(_ img: CGImage) -> CGImage {
        let s = Surface(W / 2, H / 2)
        s.ctx.interpolationQuality = .low
        s.draw(img)
        return s.image()
    }

    private func render(_ source: CGImage, _ t: Double) {
        if hasContent && (on("smear") || on("glitch")) { prevImage = main.image() }

        // 1. degrade into work
        let crunched = on("lowres") ? crunch.feed(source, t: t, I: I) : nil
        if let crunched {
            work.ctx.interpolationQuality = .high
            work.draw(crunched)
            if on("blocky") { macroblocks(source, t) }
        } else if on("lowres") || on("blocky") {
            let f = on("lowres") ? lerp(3, 6, I) : 2.2
            let sw = max(16, Int(Double(W) / f)), sh = max(9, Int(Double(H) / f))
            if small?.w != sw || small?.h != sh { small = Surface(sw, sh) }
            small!.draw(source)
            work.ctx.interpolationQuality = .high
            work.draw(small!.image())
            if on("blocky") { macroblocks(source, t) }
        } else {
            work.draw(source)
        }

        // 2. compose into main (+ smear)
        main.draw(work.image())
        if on("smear") && hasContent { smear(source, t) } else { lastMotion = nil }

        // 3. corruption bursts
        if on("glitch") && hasContent { corrupt(t) } else { glitch = nil }
        hasContent = true
    }

    private func macroblocks(_ source: CGImage, _ t: Double) {
        let B = max(8, Int((lerp(10, 22, I) * Double(W) / 1280).rounded()) * 2)
        let cols = (W + B - 1) / B, rows = (H + B - 1) / B
        if tiny?.w != cols || tiny?.h != rows { tiny = Surface(cols, rows) }
        tiny!.draw(source)
        if t > blockEpoch {
            blockEpoch = t + rnd(180, 650)
            blockSeed = UInt32.random(in: 0..<1_000_000_000)
        }
        let p = lerp(0.12, 0.42, I)
        var rects: [CGRect] = []
        for by in 0..<rows {
            for bx in 0..<cols {
                let n = hash(bx >> 1, by >> 1, blockSeed) * 0.6 + hash(bx, by, blockSeed &+ 7) * 0.4
                if n < p { rects.append(CGRect(x: bx * B, y: H - (by + 1) * B, width: B, height: B)) }
            }
        }
        guard !rects.isEmpty else { return }
        let c = work.ctx
        c.saveGState()
        c.clip(to: rects)
        c.setAlpha(lerp(0.6, 0.9, I))
        c.interpolationQuality = .none
        work.draw(tiny!.image(), CGRect(x: 0, y: 0, width: cols * B, height: rows * B))
        c.restoreGState()
    }

    private func smear(_ source: CGImage, _ t: Double) {
        motion.draw(source)
        let d = motion.bytes
        var lum = [UInt8](repeating: 0, count: 32 * 18)
        for i in 0..<lum.count {
            let b = Int(d[i * 4]), g = Int(d[i * 4 + 1]), r = Int(d[i * 4 + 2])
            lum[i] = UInt8((r * 3 + g * 6 + b) / 10)
        }
        let last = lastMotion
        lastMotion = lum
        guard let last, let prev = prevImage else { return }
        if t > nextKeyframe {
            nextKeyframe = t + rnd(1200, 3800) * (0.5 + I)
            return
        }
        if t > smearVecUntil {
            smearVecUntil = t + rnd(300, 1100)
            let s = lerp(2, 9, I) * Double(W) / 1280
            smearVec = (rnd(-s, s), rnd(-s * 0.3, s * 1.2))
        }
        let bw = Double(W) / 32, bh = Double(H) / 18
        let thr = lerp(16, 7, I), refresh = lerp(0.12, 0.03, I)
        for gy in 0..<18 {
            for gx in 0..<32 {
                let i = gy * 32 + gx
                if abs(Double(lum[i]) - Double(last[i])) < thr || chance(refresh) { continue }
                let x = Double(gx) * bw, y = Double(gy) * bh
                let jx = smearVec.0 + rnd(-1, 1), jy = smearVec.1 + rnd(-1, 1)
                main.blit(prev, CGRect(x: x - jx, y: y - jy, width: bw + 1, height: bh + 1),
                          CGRect(x: x, y: y, width: bw + 1, height: bh + 1))
            }
        }
    }

    private func corrupt(_ t: Double) {
        guard let prev = prevImage else { return }
        let w = Double(W), h = Double(H)
        if glitch == nil || t > glitch!.until {
            glitch = nil
            if !chance(lerp(0.03, 0.14, I)) { return }
            let kinds = ["grey", "green", "streak", "streak", "tear", "shuffle"]
            glitch = (kinds.randomElement()!, t + rnd(120, 260 + 600 * I), (h * rnd(0.25, 0.85)).rounded(),
                      ((h * rnd(0, 0.7)).rounded(), (h * rnd(0.05, 0.3)).rounded()),
                      (w * rnd(0.04, 0.22) * (chance(0.5) ? 1 : -1)).rounded())
        }
        let g = glitch!
        let B = max(8.0, (w / 40).rounded())
        switch g.kind {
        case "grey", "green":
            let col = g.kind == "grey" ? CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1) : CGColor(red: 0, green: 0.54, blue: 0.27, alpha: 1)
            main.fill(CGRect(x: 0, y: g.y0, width: w, height: h - g.y0), col)
            var x = 0.0
            while x < w { if chance(0.5) { main.fill(CGRect(x: x, y: g.y0 - B, width: B, height: B), col) }; x += B }
        case "streak":
            main.blit(prev, CGRect(x: 0, y: g.y0 - 2, width: w, height: 2), CGRect(x: 0, y: g.y0, width: w, height: h - g.y0))
        case "tear":
            main.blit(prev, CGRect(x: 0, y: g.band.0, width: w, height: g.band.1), CGRect(x: g.shift, y: g.band.0, width: w, height: g.band.1))
        default:
            let n = Int(lerp(8, 50, I))
            for _ in 0..<n {
                let sx = Double(Int.random(in: 0...Int(w / B) - 2)) * B, sy = Double(Int.random(in: 0...Int(h / B) - 1)) * B
                let dx = Double(Int.random(in: 0...Int(w / B) - 2)) * B, dy = Double(Int.random(in: 0...Int(h / B) - 1)) * B
                main.blit(prev, CGRect(x: sx, y: sy, width: B * 2, height: B), CGRect(x: dx, y: dy, width: B * 2, height: B))
            }
        }
    }

    func reset() {
        crunch.close()
        lagBuf.removeAll()
        hasContent = false
        lastMotion = nil
    }
}
