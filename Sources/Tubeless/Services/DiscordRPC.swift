import Foundation
import Darwin

// minimal Discord Rich Presence client speaking the local IPC protocol directly
// (unix socket at $TMPDIR/discord-ipc-{0..9}). no third-party dependency.
// needs a Discord application client id (created at discord.com/developers).
actor DiscordRPC {
    static let shared = DiscordRPC()

    private var fd: Int32 = -1
    private var connectedClientID: String?

    private var isOpen: Bool { fd >= 0 }

    // MARK: - public

    func updateNowPlaying(title: String, artist: String, imageURL: String?,
                          startEpoch: Double?, endEpoch: Double?, clientID: String) {
        guard !clientID.isEmpty else { return }
        if connectedClientID != clientID { disconnect() }
        if !isOpen { connect(clientID: clientID) }
        guard isOpen else { return }

        var activity: [String: Any] = [
            "type": 2, // Listening
            "details": pad(title),
            "state": pad(artist.isEmpty ? "Unknown artist" : artist),
        ]
        if let s = startEpoch, let e = endEpoch {
            activity["timestamps"] = ["start": Int(s), "end": Int(e)]
        }
        var assets: [String: Any] = ["large_text": "Tubeless"]
        if let imageURL { assets["large_image"] = imageURL }
        activity["assets"] = assets

        let frame: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "nonce": UUID().uuidString,
            "args": ["pid": ProcessInfo.processInfo.processIdentifier, "activity": activity],
        ]
        sendJSON(op: 1, frame)
        drain()
    }

    func clear() {
        guard isOpen else { return }
        let frame: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "nonce": UUID().uuidString,
            "args": ["pid": ProcessInfo.processInfo.processIdentifier],
        ]
        sendJSON(op: 1, frame)
        drain()
    }

    func disconnect() {
        if isOpen { close(fd) }
        fd = -1
        connectedClientID = nil
    }

    // MARK: - connection

    private func connect(clientID: String) {
        let base = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/"
        for i in 0..<10 {
            let dir = base.hasSuffix("/") ? base : base + "/"
            let path = "\(dir)discord-ipc-\(i)"
            let sock = socket(AF_UNIX, SOCK_STREAM, 0)
            if sock < 0 { continue }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            _ = withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
                tuplePtr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                    path.withCString { strncpy(dst, $0, 103) }
                }
            }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock, $0, len) }
            }
            if r == 0 {
                fd = sock
                connectedClientID = clientID
                sendJSON(op: 0, ["v": 1, "client_id": clientID]) // handshake
                drain()
                return
            }
            close(sock)
        }
    }

    // MARK: - framing

    private func sendJSON(op: UInt32, _ obj: [String: Any]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var frame = Data()
        var o = op.littleEndian
        var l = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &o) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &l) { frame.append(contentsOf: $0) }
        frame.append(payload)

        let ok = frame.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            var total = 0
            while total < frame.count {
                let n = write(fd, base + total, frame.count - total)
                if n <= 0 { return false }
                total += n
            }
            return true
        }
        if !ok { disconnect() } // socket died (Discord closed); reconnect next time
    }

    private func drain() {
        guard isOpen else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        _ = recv(fd, &buf, buf.count, MSG_DONTWAIT) // best-effort, ignore
    }

    private func pad(_ s: String) -> String {
        let trimmed = String(s.prefix(127))
        return trimmed.count >= 2 ? trimmed : (trimmed + "  ")
    }
}
