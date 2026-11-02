import AVFoundation
import AppKit
import SwiftUI

private let bg = Color(red: 0.07, green: 0.07, blue: 0.09)
private let card = Color(red: 0.12, green: 0.12, blue: 0.15)
private let accent = Color(red: 0.25, green: 0.85, blue: 1.0)

/// Where the extension is copied so Chrome's "Load unpacked" can reach it.
enum ExtensionFiles {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LagBoard/extension", isDirectory: true)
    }

    /// Refreshes the copy from the app bundle (so rebuilding the app updates it too).
    static func prepare() {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("extension"),
              FileManager.default.fileExists(atPath: src.path) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: folder)
        try? fm.copyItem(at: src, to: folder)
    }
}

enum Browser {
    static let candidates = ["com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac"]
    static var app: URL? {
        candidates.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }
    static var name: String { app.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "Chrome" }

    static func open(_ url: String) {
        guard let u = URL(string: url) else { return }
        if let app {
            NSWorkspace.shared.open([u], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(u)
        }
    }
}

struct SetupView: View {
    @ObservedObject var board: Board
    @ObservedObject var cam: CamPipeline
    var onFinish: () -> Void

    enum Step { case choose, ext, virtual }
    @State var step: Step = .choose

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch step {
            case .choose: ChooseStep(cam: cam) { step = $0 }
            case .ext: ExtensionStep(board: board, back: { step = .choose }) {
                    board.allClear()
                    board.mode = .extensionMode
                    onFinish()
                }
            case .virtual: VirtualStep(board: board, cam: cam, back: { step = .choose }) {
                    board.allClear()
                    board.mode = .virtualCamera
                    onFinish()
                }
            }
        }
        .padding(28)
        .frame(width: 620, height: 640, alignment: .topLeading)
        .background(bg)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Step 1: choose

private struct ChooseStep: View {
    @ObservedObject var cam: CamPipeline
    var pick: (SetupView.Step) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("LAGBOARD").font(.system(size: 13, weight: .black, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
            Text("How should LagBoard get into your call?").font(.system(size: 24, weight: .bold))
            Text("Either way, your friend sees a terrible connection and your internet stays perfect. You can switch later from the menu bar icon → Setup.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            ModeCard(icon: "puzzlepiece.extension.fill", title: "Chrome Extension", badge: nil, bullets: [
                ("checkmark", "Video and audio effects"),
                ("checkmark", "Google Meet in Chrome, Arc, Edge or Brave"),
                ("checkmark", "One-time install, about a minute"),
            ]) { pick(.ext) }

            ModeCard(icon: "web.camera.fill", title: "Virtual Camera",
                     badge: cam.obsInstalled ? ("OBS Virtual Camera found", Color.green) : ("needs OBS Virtual Camera", Color.orange),
                     bullets: [
                         ("checkmark", "Works in any app: Meet, Zoom, FaceTime, Discord, Safari"),
                         ("checkmark", "Nothing to install in the browser"),
                         ("minus", "Video effects only (add the extension too for audio)"),
                     ]) { pick(.virtual) }
            Spacer()
        }
    }
}

private struct ModeCard: View {
    let icon: String
    let title: String
    let badge: (String, Color)?
    let bullets: [(String, String)]
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: icon).font(.system(size: 26)).foregroundStyle(accent).frame(width: 40)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(title).font(.system(size: 17, weight: .bold))
                        if let badge {
                            Text(badge.0).font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(badge.1.opacity(0.2))).foregroundStyle(badge.1)
                        }
                    }
                    ForEach(bullets, id: \.1) { b in
                        Label(b.1, systemImage: b.0).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.75))
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary).padding(.top, 4)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(hover ? card.opacity(1.6) : card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(hover ? accent.opacity(0.6) : Color.white.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Shared bits

private struct StepRow<Actions: View>: View {
    let n: Int
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(.system(size: 13, weight: .bold, design: .monospaced))
                .frame(width: 26, height: 26).background(Circle().fill(accent.opacity(0.18))).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) { actions }
            }
        }
    }
}

private struct SmallButton: View {
    let title: String
    let icon: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(card))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.1)))
        }.buttonStyle(.plain)
    }
}

private struct Check: View {
    let ok: Bool
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color.green : Color.white.opacity(0.35))
            Text(text).font(.system(size: 12.5)).foregroundStyle(ok ? .white : .secondary)
        }
    }
}

private struct Footer: View {
    let back: () -> Void
    let finishTitle: String
    let finishEnabled: Bool
    let finish: () -> Void
    var body: some View {
        HStack {
            Button(action: back) { Label("Back", systemImage: "chevron.left").font(.system(size: 13, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            Spacer()
            Button(action: finish) {
                Text(finishTitle).font(.system(size: 13, weight: .bold))
                    .padding(.horizontal, 18).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(finishEnabled ? accent : card))
                    .foregroundStyle(finishEnabled ? Color.black : Color.white.opacity(0.6))
            }.buttonStyle(.plain)
        }
    }
}

private func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

// MARK: - Step 2a: extension walkthrough

private struct ExtensionStep: View {
    @ObservedObject var board: Board
    var back: () -> Void
    var finish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Install the Chrome extension").font(.system(size: 22, weight: .bold))
            StepRow(n: 1, title: "Open the Extensions page in \(Browser.name)", detail: "") {
                SmallButton(title: "Open Extensions page", icon: "arrow.up.forward.app") { Browser.open("chrome://extensions") }
                SmallButton(title: "Copy chrome://extensions", icon: "doc.on.doc") { copy("chrome://extensions") }
            }
            StepRow(n: 2, title: "Turn on Developer mode", detail: "It's the toggle in the top-right corner of that page.") { EmptyView() }
            StepRow(n: 3, title: "Click “Load unpacked” and choose the LagBoard extension folder",
                    detail: "In the file picker, press ⌘⇧G, paste the path, and press Return, then click Select.") {
                SmallButton(title: "Copy folder path", icon: "doc.on.doc") { copy(ExtensionFiles.folder.path) }
                SmallButton(title: "Show in Finder", icon: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ExtensionFiles.folder])
                }
            }
            StepRow(n: 4, title: "Open Google Meet (or reload it if it's already open)",
                    detail: "The extension hooks your camera and mic when Meet loads.") {
                SmallButton(title: "Open Google Meet", icon: "video") { Browser.open("https://meet.google.com") }
            }
            VStack(alignment: .leading, spacing: 8) {
                Check(ok: board.extensionLinked, text: "Extension connected to LagBoard")
                Check(ok: board.meetTabs > 0, text: "Google Meet tab detected")
                Check(ok: board.camHooked || board.micHooked,
                      text: "Camera & mic hooked" + (board.camHooked || board.micHooked ? " (cam \(board.camHooked ? "✓" : "–"), mic \(board.micHooked ? "✓" : "–"))" : " — turn them on in Meet"))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(card))
            Spacer()
            Footer(back: back, finishTitle: board.extensionLinked ? "Finish" : "Finish anyway",
                   finishEnabled: board.extensionLinked, finish: finish)
        }
    }
}

// MARK: - Step 2b: virtual camera

private struct VirtualStep: View {
    @ObservedObject var board: Board
    @ObservedObject var cam: CamPipeline
    var back: () -> Void
    var finish: () -> Void
    @State private var auth = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var devices = CameraCapture.devices()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up the virtual camera").font(.system(size: 22, weight: .bold))
            if !cam.obsInstalled {
                obsMissing
            } else if auth != .authorized {
                permission
            } else {
                picker
            }
            Spacer(minLength: 0)
            Footer(back: back, finishTitle: "Finish",
                   finishEnabled: cam.obsInstalled && auth == .authorized && cam.cameraID != nil) {
                if cam.obsInstalled && auth == .authorized && cam.cameraID != nil { finish() }
            }
        }
        .onAppear(perform: startPreview)
        .onDisappear { cam.setPreviewing(false) }
    }

    private func startPreview() {
        if cam.cameraID == nil || !devices.contains(where: { $0.uniqueID == cam.cameraID }) {
            cam.cameraID = (devices.first { $0.deviceType == .builtInWideAngleCamera } ?? devices.first)?.uniqueID
        }
        if auth == .authorized && cam.obsInstalled { cam.setPreviewing(true) }
    }

    private var obsMissing: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LagBoard sends its video through OBS's virtual camera driver. macOS only allows Apple-certified camera drivers, and OBS's is free and certified.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            StepRow(n: 1, title: "Install OBS Studio (free)", detail: "") {
                SmallButton(title: "Download OBS", icon: "arrow.down.circle") { NSWorkspace.shared.open(URL(string: "https://obsproject.com/download")!) }
            }
            StepRow(n: 2, title: "Open OBS and click “Start Virtual Camera”",
                    detail: "Approve it if macOS asks (System Settings → General → Login Items & Extensions → Camera Extensions). Then quit OBS; you never need to open it again.") { EmptyView() }
            StepRow(n: 3, title: "Come back here", detail: "") {
                SmallButton(title: "Check again", icon: "arrow.clockwise") { cam.objectWillChange.send(); cam.setEnabled(board.mode == .virtualCamera) }
            }
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LagBoard needs to see your real camera so it can wreck it.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if auth == .denied || auth == .restricted {
                SmallButton(title: "Open Camera privacy settings", icon: "gear") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
                Text("Turn LagBoard on, then reopen this window.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                SmallButton(title: "Allow camera access", icon: "camera") {
                    AVCaptureDevice.requestAccess(for: .video) { _ in
                        DispatchQueue.main.async {
                            auth = AVCaptureDevice.authorizationStatus(for: .video)
                            devices = CameraCapture.devices()
                            startPreview()
                        }
                    }
                }
            }
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Which camera should LagBoard use?").font(.system(size: 14, weight: .semibold))
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(devices, id: \.uniqueID) { d in
                        Button { cam.cameraID = d.uniqueID } label: {
                            HStack(spacing: 8) {
                                Image(systemName: cam.cameraID == d.uniqueID ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(cam.cameraID == d.uniqueID ? accent : .secondary)
                                Text(d.localizedName).font(.system(size: 12.5)).lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 8).fill(cam.cameraID == d.uniqueID ? accent.opacity(0.12) : card))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if devices.isEmpty { Text("No cameras found.").font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                .frame(width: 210)
                VStack(alignment: .leading, spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(Color.black)
                        if let p = cam.preview {
                            Image(decorative: p, scale: 1).resizable().aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: 338, height: 190)
                    HStack(spacing: 6) {
                        Text("Try:").font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach([("lowres", "Potato"), ("smear", "Smear"), ("freeze", "Freeze"), ("glitch", "Corrupt")], id: \.0) { e in
                            Button { board.toggle(e.0) } label: {
                                Text(e.1).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8).frame(height: 22)
                                    .background(Capsule().fill(board.isLatched(e.0) ? accent : card))
                                    .foregroundStyle(board.isLatched(e.0) ? Color.black : .white)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("In your call, pick **OBS Virtual Camera** as the camera", systemImage: "1.circle")
                Label("Meet: ⋮ → Settings → Video → Camera. Zoom: ^ next to Stop Video.", systemImage: "2.circle")
                    .foregroundStyle(.secondary)
                Label("LagBoard turns your real camera on automatically when the call starts using it.", systemImage: "3.circle")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(card))
        }
    }
}
