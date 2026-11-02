import AVFoundation
import AppKit
import CoreMediaIO
import Foundation

// MARK: - OBS Virtual Camera sink

/// Feeds frames into the OBS Virtual Camera system extension through its CMIO sink
/// stream (the same mechanism OBS itself uses). OBS does not need to be running.
final class VirtualCamSink {
    static let deviceUID = "7626645E-4425-469E-9D8B-97E0FA59AC75"

    private var device: CMIOObjectID = 0
    private var sink: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var format: CMVideoFormatDescription?
    private(set) var isStarted = false

    private static func address(_ sel: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(sel),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func array<T>(_ obj: CMIOObjectID, _ sel: Int, _: T.Type) -> [T] {
        var addr = address(sel)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let n = Int(size) / MemoryLayout<T>.stride
        let buf = UnsafeMutablePointer<T>.allocate(capacity: n)
        defer { buf.deallocate() }
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(obj, &addr, 0, nil, size, &used, buf) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buf, count: n))
    }

    private static func uid(_ dev: CMIOObjectID) -> String {
        var addr = address(Int(kCMIODevicePropertyDeviceUID))
        var s: Unmanaged<CFString>?
        var used: UInt32 = 0
        CMIOObjectGetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &s)
        return (s?.takeRetainedValue() as String?) ?? ""
    }

    /// The OBS Virtual Camera device, if its extension is installed and enabled.
    static func findDevice() -> CMIOObjectID? {
        array(CMIOObjectID(kCMIOObjectSystemObject), Int(kCMIOHardwarePropertyDevices), CMIOObjectID.self)
            .first { uid($0).uppercased() == deviceUID }
    }

    static var isInstalled: Bool { findDevice() != nil }

    /// True when some app (e.g. Meet) is reading the virtual camera. Only meaningful
    /// while we are not feeding it ourselves.
    static func someoneIsWatching() -> Bool {
        guard let dev = findDevice() else { return false }
        return (array(dev, Int(kCMIODevicePropertyDeviceIsRunningSomewhere), UInt32.self).first ?? 0) != 0
    }

    func start() -> Bool {
        if isStarted { return true }
        guard let dev = Self.findDevice() else { return false }
        let streams = Self.array(dev, Int(kCMIODevicePropertyStreams), CMIOStreamID.self)
        guard streams.count >= 2 else { return false }
        device = dev
        sink = streams[1]
        var q: Unmanaged<CMSimpleQueue>?
        guard CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &q) == noErr, let q else { return false }
        queue = q.takeRetainedValue()
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCVPixelFormatType_32BGRA, width: 1280, height: 720,
                                       extensions: nil, formatDescriptionOut: &format)
        guard CMIODeviceStartStream(device, sink) == noErr else { queue = nil; return false }
        isStarted = true
        return true
    }

    func stop() {
        guard isStarted else { return }
        CMIODeviceStopStream(device, sink)
        isStarted = false
        queue = nil
    }

    func send(_ pb: CVPixelBuffer) {
        guard isStarted, let queue, let format else { return }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: nil, imageBuffer: pb, dataReady: true, makeDataReadyCallback: nil,
                                           refcon: nil, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sb)
        if let sb { CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sb).toOpaque()) }
    }
}

// MARK: - Camera capture

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "lagboard.video", qos: .userInteractive)
    private var session: AVCaptureSession?
    var onFrame: ((CVPixelBuffer) -> Void)?

    /// Real cameras only (no virtual cameras, no Desk View).
    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
            .filter {
                $0.uniqueID.uppercased() != VirtualCamSink.deviceUID
                    && !$0.localizedName.localizedCaseInsensitiveContains("OBS")
                    && !$0.localizedName.localizedCaseInsensitiveContains("Virtual")
                    && !$0.localizedName.localizedCaseInsensitiveContains("Desk View")
            }
    }

    var isRunning: Bool { session?.isRunning ?? false }

    func start(deviceID: String) -> Bool {
        stop()
        guard let dev = AVCaptureDevice(uniqueID: deviceID), let input = try? AVCaptureDeviceInput(device: dev) else { return false }
        let s = AVCaptureSession()
        s.beginConfiguration()
        if s.canSetSessionPreset(.hd1280x720) { s.sessionPreset = .hd1280x720 } else { s.sessionPreset = .high }
        guard s.canAddInput(input) else { return false }
        s.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(out) else { return false }
        s.addOutput(out)
        s.commitConfiguration()
        session = s
        queue.async { s.startRunning() }
        return true
    }

    func stop() {
        guard let s = session else { return }
        session = nil
        queue.async { s.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) { onFrame?(pb) }
    }
}

// MARK: - Pipeline

/// Camera → NativeFX → OBS Virtual Camera. Starts the real camera automatically when an
/// app begins reading the virtual camera.
final class CamPipeline: ObservableObject {
    @Published var cameraID: String? = UserDefaults.standard.string(forKey: "cameraID") {
        didSet {
            UserDefaults.standard.set(cameraID, forKey: "cameraID")
            if live || previewing { restartCamera() }
        }
    }
    @Published private(set) var live = false
    @Published private(set) var obsInstalled = VirtualCamSink.isInstalled
    @Published private(set) var preview: CGImage?
    @Published private(set) var cameraError: String?

    let state = FXState()
    private let fx = NativeFX()
    private let sink = VirtualCamSink()
    private let camera = CameraCapture()
    private var watcher: Timer?
    private(set) var previewing = false
    private var lastPreview = 0.0
    private var pool: CVPixelBufferPool?
    private var manuallyStopped = false

    var onPreviewChange: (() -> Void)?

    var cameraName: String {
        guard let id = cameraID, let d = AVCaptureDevice(uniqueID: id) else { return "no camera" }
        return d.localizedName
    }

    init() {
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                      kCVPixelBufferWidthKey: 1280, kCVPixelBufferHeightKey: 720,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        camera.onFrame = { [weak self] pb in self?.handle(pb) }
    }

    /// Virtual Camera mode on/off.
    func setEnabled(_ on: Bool) {
        watcher?.invalidate()
        watcher = nil
        if on {
            watcher = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.watch() }
            watch()
        } else {
            goOffline()
        }
    }

    private func watch() {
        obsInstalled = VirtualCamSink.isInstalled
        if !live && !manuallyStopped && obsInstalled && VirtualCamSink.someoneIsWatching() { goLive() }
        if manuallyStopped && !VirtualCamSink.someoneIsWatching() { manuallyStopped = false }
    }

    func goLive() {
        guard !live, let id = cameraID else { return }
        manuallyStopped = false
        guard sink.start() else { cameraError = "Couldn't connect to OBS Virtual Camera"; return }
        guard camera.isRunning || camera.start(deviceID: id) else {
            sink.stop()
            cameraError = "Couldn't open \(cameraName)"
            return
        }
        cameraError = nil
        live = true
    }

    /// Stops the real camera; the call then sees OBS's placeholder until restarted.
    func goOffline(manual: Bool = false) {
        if manual { manuallyStopped = true }
        if !previewing { camera.stop() }
        sink.stop()
        live = false
        camera.queue.async { [fx] in fx.reset() }
    }

    /// Camera preview for the setup screen (does not feed the virtual camera).
    func setPreviewing(_ on: Bool) {
        previewing = on
        onPreviewChange?()
        if on, let id = cameraID, !camera.isRunning { _ = camera.start(deviceID: id) }
        if !on, !live { camera.stop(); preview = nil }
    }

    private func restartCamera() {
        guard let id = cameraID else { return }
        if !camera.start(deviceID: id) { cameraError = "Couldn't open \(cameraName)" }
    }

    // video queue
    private func handle(_ pb: CVPixelBuffer) {
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
        guard let cg else { return }
        let (active, intensity) = state.get()
        let out = fx.process(cg, active: active, intensity: intensity)

        if sink.isStarted, let pool {
            var obOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &obOut)
            if let ob = obOut {
                CVPixelBufferLockBaseAddress(ob, [])
                let dst = CVPixelBufferGetBaseAddress(ob)!.assumingMemoryBound(to: UInt8.self)
                let dbpr = CVPixelBufferGetBytesPerRow(ob)
                let src = out.bytes
                let sbpr = out.w * 4
                for y in 0..<out.h { memcpy(dst + y * dbpr, src + y * sbpr, sbpr) }
                CVPixelBufferUnlockBaseAddress(ob, [])
                sink.send(ob)
            }
        }

        let now = CACurrentMediaTime()
        if previewing && now - lastPreview > 1.0 / 15 {
            lastPreview = now
            let img = out.image()
            DispatchQueue.main.async { self.preview = img }
        }
    }
}
