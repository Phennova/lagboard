import Foundation
import SwiftUI

enum Track { case video, audio }

struct Effect: Identifiable {
    let id: String
    let title: String
    let icon: String
    let track: Track
    let blurb: String
}

let videoEffects: [Effect] = [
    Effect(id: "lowres", title: "Potato Res", icon: "camera.aperture", track: .video, blurb: "Bandwidth drop: blurry low-res upscale"),
    Effect(id: "blocky", title: "Macroblocks", icon: "square.grid.3x3.fill", track: .video, blurb: "Bitrate-starved compression blocks"),
    Effect(id: "stutter", title: "Choppy FPS", icon: "tortoise.fill", track: .video, blurb: "Frame rate collapses with random hitches"),
    Effect(id: "freeze", title: "Freeze", icon: "snowflake", track: .video, blurb: "Frame stuck until released"),
    Effect(id: "smear", title: "Pixel Smear", icon: "scribble.variable", track: .video, blurb: "Lost reference frame: moving parts melt"),
    Effect(id: "glitch", title: "Corrupt", icon: "exclamationmark.triangle.fill", track: .video, blurb: "Grey/green half-frames, tears, streaks"),
    Effect(id: "lag", title: "Lag Catch-up", icon: "hare.fill", track: .video, blurb: "Freezes, then fast-forwards to catch up"),
    Effect(id: "blackout", title: "Video Drop", icon: "video.slash.fill", track: .video, blurb: "Video feed goes black"),
]

let audioEffects: [Effect] = [
    Effect(id: "drop", title: "Cut Outs", icon: "waveform.slash", track: .audio, blurb: "Audio drops out mid-sentence"),
    Effect(id: "robot", title: "Robot Voice", icon: "waveform.path", track: .audio, blurb: "Packet-loss concealment buzz"),
    Effect(id: "garble", title: "Low Bitrate", icon: "speaker.wave.1.fill", track: .audio, blurb: "Crunchy, muffled, underwater"),
    Effect(id: "achoppy", title: "Skipping", icon: "repeat", track: .audio, blurb: "Tiny chunks repeat like a scratched CD"),
    Effect(id: "desync", title: "Lip Desync", icon: "clock.arrow.circlepath", track: .audio, blurb: "Audio lags behind your mouth"),
    Effect(id: "mute", title: "Audio Gone", icon: "speaker.slash.fill", track: .audio, blurb: "Complete silence"),
]

let allEffects = videoEffects + audioEffects

/// A scripted sequence: (start offset, duration, effect ids).
struct Scenario: Identifiable {
    let id: String
    let title: String
    let icon: String
    let hotkey: String
    let steps: [(Double, Double, [String])]
    var length: Double { steps.map { $0.0 + $0.1 }.max() ?? 0 }
}

let scenarios: [Scenario] = [
    Scenario(id: "hiccup", title: "Hiccup", icon: "bolt.horizontal.fill", hotkey: "1", steps: [
        (0, 1.1, ["freeze", "mute"]),
        (1.1, 1.2, ["smear", "lowres"]),
    ]),
    Scenario(id: "spike", title: "Lag Spike", icon: "chart.line.uptrend.xyaxis", hotkey: "2", steps: [
        (0, 3.5, ["lag", "mute"]),
        (3.5, 2.5, ["lowres", "smear"]),
    ]),
    Scenario(id: "robot", title: "Robot Mode", icon: "person.wave.2.fill", hotkey: "3", steps: [
        (0, 5, ["robot", "stutter", "lowres"]),
        (1.5, 1.5, ["glitch"]),
    ]),
    Scenario(id: "badpatch", title: "Bad Patch", icon: "wifi.exclamationmark", hotkey: "4", steps: [
        (0, 10, ["lowres", "stutter"]),
        (0, 4, ["drop", "robot"]),
        (2.5, 1.2, ["freeze"]),
        (3.7, 1.2, ["smear", "glitch"]),
        (5, 3, ["blocky", "achoppy", "garble"]),
        (8, 2, ["robot"]),
    ]),
    Scenario(id: "lost", title: "Connection Lost", icon: "antenna.radiowaves.left.and.right.slash", hotkey: "5", steps: [
        (0, 1.6, ["freeze", "robot"]),
        (1.6, 6.4, ["freeze", "mute"]),
        (8, 1.2, ["glitch", "drop"]),
        (8, 5, ["lowres", "blocky", "smear"]),
        (13, 4, ["lowres", "stutter"]),
    ]),
]

enum Mode: String {
    case extensionMode = "extension"
    case virtualCamera = "virtual"
}

private struct Timed {
    let id: String
    let start: Date
    let end: Date
}

final class Board: ObservableObject {
    @Published private(set) var latched: Set<String> = []
    @Published private(set) var active: Set<String> = []
    @Published private(set) var scenarioProgress: [String: Double] = [:]
    @Published var intensity: Double = 0.7 { didSet { push(force: true) } }
    @Published var chaos = false { didSet { if chaos { nextChaos = Date() } else { clearChaos() } } }

    @Published var extensionLinked = false
    @Published var meetTabs = 0
    @Published var camHooked = false
    @Published var micHooked = false
    @Published var supported = true

    /// nil until the user finishes setup.
    @Published var mode: Mode? = Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") {
        didSet {
            UserDefaults.standard.set(mode?.rawValue, forKey: "mode")
            applyMode()
        }
    }
    let cam = CamPipeline()

    private var timed: [Timed] = []
    private var running: [String: (Date, Double)] = [:]
    private var nextChaos = Date()
    private var lastSent: (Set<String>, Double)?
    private var ticker: Timer?
    let server = BridgeServer()

    init() {
        server.onStatus = { [weak self] conns, tabs, video, audio, supported in
            guard let self else { return }
            self.extensionLinked = conns > 0
            self.meetTabs = tabs
            self.camHooked = video > 0
            self.micHooked = audio > 0
            self.supported = supported
        }
        server.start()
        cam.onPreviewChange = { [weak self] in self?.push(force: true) }
        applyMode()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    func toggle(_ id: String) {
        if latched.contains(id) { latched.remove(id) } else { latched.insert(id) }
        tick()
    }

    func run(_ s: Scenario) {
        let now = Date()
        // restarting a scenario replaces its previous run
        timed.removeAll { $0.id.hasPrefix("\(s.id):") }
        for (off, dur, ids) in s.steps {
            for e in ids {
                timed.append(Timed(id: "\(s.id):\(e)", start: now + off, end: now + off + dur))
            }
        }
        running[s.id] = (now, s.length)
        tick()
    }

    func allClear() {
        chaos = false
        latched.removeAll()
        timed.removeAll()
        running.removeAll()
        tick()
    }

    func isLatched(_ id: String) -> Bool { latched.contains(id) }
    func isActive(_ id: String) -> Bool { active.contains(id) }

    private func clearChaos() {
        timed.removeAll { $0.id.hasPrefix("chaos:") }
        tick()
    }

    private func tick() {
        let now = Date()
        if chaos { chaosStep(now) }
        timed.removeAll { $0.end <= now }
        var a = latched
        for t in timed where t.start <= now {
            a.insert(String(t.id.split(separator: ":").last!))
        }
        var prog: [String: Double] = [:]
        for (id, (start, len)) in running {
            let p = now.timeIntervalSince(start) / len
            if p < 1 { prog[id] = p }
        }
        running = running.filter { prog[$0.key] != nil }
        if prog != scenarioProgress { scenarioProgress = prog }
        if a != active { active = a }
        push(force: false)
    }

    /// Fires realistic random trouble while Chaos is on.
    private func chaosStep(_ now: Date) {
        guard now >= nextChaos else { return }
        let I = intensity
        let menu: [(Double, ClosedRange<Double>, [String])] = [
            (5, 2...6, ["stutter"]),
            (4, 3...8, ["lowres"]),
            (3, 0.4...1.8, ["freeze"]),
            (3, 0.8...3.5, ["drop"]),
            (3, 1...3, ["robot"]),
            (2, 0.8...2.0, ["smear", "lowres"]),
            (2, 0.4...1.4, ["glitch"]),
            (2, 2...5, ["blocky", "lowres"]),
            (1.5, 1...3, ["achoppy"]),
            (1, 2...4, ["garble"]),
            (I > 0.5 ? 1 : 0.3, 2...4.5, ["lag", "mute"]),
        ]
        let total = menu.reduce(0) { $0 + $1.0 }
        var r = Double.random(in: 0..<total)
        for (w, dur, ids) in menu {
            r -= w
            if r < 0 {
                let d = Double.random(in: dur) * (0.6 + I * 0.7)
                for e in ids { timed.append(Timed(id: "chaos:\(e)", start: now, end: now + d)) }
                break
            }
        }
        let meanGap = 4.5 - 3.3 * I
        nextChaos = now + Double.random(in: meanGap * 0.4...meanGap * 1.6)
    }

    private func applyMode() {
        cam.setEnabled(mode == .virtualCamera)
        push(force: true)
    }

    private func push(force: Bool) {
        if !force, let l = lastSent, l.0 == active, l.1 == intensity { return }
        lastSent = (active, intensity)
        // Virtual Camera mode: video effects are rendered natively; the extension (if
        // installed) only handles audio.
        let virtual = mode == .virtualCamera
        cam.state.set(virtual || cam.previewing ? active : [], intensity)
        let toExtension = virtual ? active.subtracting(NativeFX.videoIDs) : active
        server.broadcast(["type": "state", "active": Array(toExtension).sorted(), "intensity": intensity])
    }
}
