import SwiftUI

private let bg = Color(red: 0.07, green: 0.07, blue: 0.09)
private let card = Color(red: 0.12, green: 0.12, blue: 0.15)
private let videoTint = Color(red: 0.25, green: 0.85, blue: 1.0)
private let audioTint = Color(red: 1.0, green: 0.55, blue: 0.2)
private let scenarioTint = Color(red: 0.98, green: 0.3, blue: 0.45)

struct BoardView: View {
    @ObservedObject var board: Board
    @ObservedObject var cam: CamPipeline
    var onHide: () -> Void

    init(board: Board, onHide: @escaping () -> Void) {
        self.board = board
        self.cam = board.cam
        self.onHide = onHide
    }

    /// In Virtual Camera mode audio only works if the extension is also connected.
    private var audioAvailable: Bool { board.mode != .virtualCamera || board.extensionLinked }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            section("SCENARIOS") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                    ForEach(scenarios) { s in ScenarioButton(board: board, scenario: s) }
                    ChaosButton(board: board)
                }
            }
            section("VIDEO") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(videoEffects) { e in PadView(board: board, effect: e, tint: videoTint) }
                }
            }
            section(audioAvailable ? "AUDIO" : "AUDIO · NEEDS THE CHROME EXTENSION") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(audioEffects) { e in PadView(board: board, effect: e, tint: audioTint) }
                }
                .opacity(audioAvailable ? 1 : 0.35)
                .help(audioAvailable ? "" : "Virtual Camera mode carries video only. Install the Chrome extension too (menu bar → Setup) for audio effects.")
            }
            footer
        }
        .padding(16)
        .frame(width: 400)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.08)))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LAGBOARD")
                    .font(.system(size: 17, weight: .black, design: .monospaced))
                    .tracking(2)
                StatusLine(board: board, cam: cam)
            }
            Spacer()
            if board.mode == .virtualCamera {
                Button { cam.live ? cam.goOffline(manual: true) : cam.goLive() } label: {
                    Image(systemName: cam.live ? "video.fill" : "video.slash.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(cam.live ? Color.black : Color.white)
                        .frame(width: 26, height: 22)
                        .background(Capsule().fill(cam.live ? Color.green : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(cam.live ? "Turn the real camera off (the call sees a placeholder)" : "Start the virtual camera now")
            }
            Button(action: onHide) {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Hide panel (⌃⌥L to bring back)")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "wifi").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $board.intensity, in: 0...1)
                Image(systemName: "wifi.exclamationmark").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(Int(board.intensity * 100))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .frame(width: 36, alignment: .trailing)
            }
            Button(action: board.allClear) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("ALL CLEAR").tracking(1.5)
                    Spacer()
                    Text("⌃⌥0").opacity(0.6)
                }
                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 14)
                .frame(height: 38)
                .foregroundStyle(board.active.isEmpty ? Color.white.opacity(0.5) : Color.black)
                .background(RoundedRectangle(cornerRadius: 10).fill(board.active.isEmpty ? card : Color.green))
            }
            .buttonStyle(.plain)
            Text("⌃⌥1–5 scenarios · ⌃⌥C chaos · ⌃⌥F freeze · ⌃⌥M audio gone · ⌃⌥L hide/show")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

struct StatusLine: View {
    @ObservedObject var board: Board
    @ObservedObject var cam: CamPipeline

    var body: some View {
        let (color, text): (Color, String) = {
            if board.mode == .virtualCamera {
                if !cam.obsInstalled { return (.red, "OBS Virtual Camera missing · run Setup") }
                if cam.cameraID == nil { return (.orange, "No camera chosen · run Setup") }
                if let e = cam.cameraError { return (.red, e) }
                if cam.live { return (.green, "Virtual cam live · \(cam.cameraName)") }
                return (.orange, "Ready · choose OBS Virtual Camera")
            }
            if !board.extensionLinked { return (.red, "Waiting for Chrome extension…") }
            if !board.supported { return (.red, "Browser lacks insertable streams") }
            if board.meetTabs == 0 { return (.orange, "Extension linked · open a Meet tab") }
            if !board.camHooked && !board.micHooked { return (.orange, "Meet open · turn on camera/mic") }
            return (.green, "Meet hooked · cam \(board.camHooked ? "✓" : "–") · mic \(board.micHooked ? "✓" : "–")")
        }()
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
    }
}

struct PadView: View {
    @ObservedObject var board: Board
    let effect: Effect
    let tint: Color

    var body: some View {
        let latched = board.isLatched(effect.id)
        let active = board.isActive(effect.id)
        Button { board.toggle(effect.id) } label: {
            VStack(spacing: 6) {
                Image(systemName: effect.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(height: 20)
                Text(effect.title)
                    .font(.system(size: 9.5, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .foregroundStyle(latched ? Color.black : (active ? tint : Color.white.opacity(0.85)))
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(latched ? tint : (active ? tint.opacity(0.18) : card))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(active ? tint : Color.white.opacity(0.06), lineWidth: active ? 1.5 : 1)
            )
            .shadow(color: active ? tint.opacity(0.55) : .clear, radius: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(effect.blurb)
    }
}

struct ScenarioButton: View {
    @ObservedObject var board: Board
    let scenario: Scenario

    var body: some View {
        let progress = board.scenarioProgress[scenario.id]
        Button { board.run(scenario) } label: {
            HStack(spacing: 8) {
                Image(systemName: scenario.icon).font(.system(size: 13, weight: .semibold)).frame(width: 18)
                Text(scenario.title).font(.system(size: 12, weight: .bold))
                Spacer(minLength: 0)
                Text("⌃⌥\(scenario.hotkey)").font(.system(size: 9.5, design: .monospaced)).opacity(0.5)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .foregroundStyle(progress != nil ? Color.white : Color.white.opacity(0.85))
            .background(
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(card)
                        if let p = progress {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(scenarioTint.opacity(0.75))
                                .frame(width: geo.size.width * (1 - p))
                        }
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(progress != nil ? scenarioTint : Color.white.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

struct ChaosButton: View {
    @ObservedObject var board: Board

    var body: some View {
        Button { board.chaos.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "tornado").font(.system(size: 13, weight: .semibold)).frame(width: 18)
                Text(board.chaos ? "Chaos: ON" : "Chaos").font(.system(size: 12, weight: .bold))
                Spacer(minLength: 0)
                Text("⌃⌥C").font(.system(size: 9.5, design: .monospaced)).opacity(0.5)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .foregroundStyle(board.chaos ? Color.black : Color.white.opacity(0.85))
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(board.chaos ? Color.yellow : card))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help("Random realistic bad-connection events, scaled by the intensity slider")
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
