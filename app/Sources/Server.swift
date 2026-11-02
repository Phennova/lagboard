import Foundation
import Network

/// Loopback-only WebSocket server the Chrome extension connects to.
final class BridgeServer {
    static let port: UInt16 = 47823

    private var listener: NWListener?
    private var conns: [ObjectIdentifier: NWConnection] = [:]
    private var statuses: [ObjectIdentifier: [String: Any]] = [:]
    private var latest: Data?

    /// (extension connections, meet tabs, video tracks hooked, audio tracks hooked, supported)
    var onStatus: ((Int, Int, Int, Int, Bool) -> Void)?

    func start() {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)

        do {
            listener = try NWListener(using: params)
        } catch {
            NSLog("LagBoard: listener failed: \(error)")
            retry()
            return
        }
        listener?.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener?.stateUpdateHandler = { [weak self] st in
            if case .failed(let e) = st {
                NSLog("LagBoard: listener error \(e)")
                self?.listener?.cancel()
                self?.retry()
            }
        }
        listener?.start(queue: .main)
    }

    private func retry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
    }

    private func accept(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        conns[id] = c
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready:
                if let d = self?.latest { self?.send(d, to: c) }
                self?.publish()
            case .failed, .cancelled:
                self?.conns[id] = nil
                self?.statuses[id] = nil
                self?.publish()
            default: break
            }
        }
        c.start(queue: .main)
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, ctx, _, err in
            guard let self else { return }
            if let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               meta.opcode == .close {
                c.cancel()
                return
            }
            if let data, !data.isEmpty,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["type"] as? String == "status" {
                self.statuses[ObjectIdentifier(c)] = obj
                self.publish()
            }
            if err == nil { self.receive(c) } else { c.cancel() }
        }
    }

    private func publish() {
        var tabs = 0, video = 0, audio = 0
        var supported = true
        for s in statuses.values {
            tabs += s["tabs"] as? Int ?? 0
            video += s["video"] as? Int ?? 0
            audio += s["audio"] as? Int ?? 0
            if s["supported"] as? Bool == false { supported = false }
        }
        onStatus?(conns.count, tabs, video, audio, supported)
    }

    func broadcast(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        latest = d
        for c in conns.values { send(d, to: c) }
    }

    private func send(_ d: Data, to c: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "msg", metadata: [meta])
        c.send(content: d, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }
}
