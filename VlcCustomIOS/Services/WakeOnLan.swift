import Darwin
import Foundation
import Network

/// How to wake one saved SMB server (keyed by its host): its network card's MAC address, where to send the magic
/// packet on the home network, and — from outside — the DDNS name and UDP port the router forwards.
struct WakeTarget: Codable, Equatable {
    var mac = ""
    /// The PC's address in the home network ("192.168.1.242"): the packet is also sent straight to it.
    var lanAddress = ""
    /// From outside (4G, another Wi-Fi): the router's DDNS name ("nhabadiem.duckdns.org"); the router has to forward
    /// `wanPort` (UDP) to the PC or to the LAN's broadcast address.
    var wanHost = ""
    var wanPort = 9
    /// Wake it on its own when it does not answer, then connect.
    var autoWake = true

    var isConfigured: Bool { WakeOnLan.macBytes(mac) != nil }
}

/// Wake-on-LAN settings per server, in UserDefaults.
enum WakeTargetStore {
    private static let key = "wol_targets"

    private static var all: [String: WakeTarget] {
        get {
            UserDefaults.standard.data(forKey: key)
                .flatMap { try? JSONDecoder().decode([String: WakeTarget].self, from: $0) } ?? [:]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    static func target(for host: String) -> WakeTarget? { all[host.lowercased()] }

    static func save(_ target: WakeTarget, for host: String) {
        var all = self.all
        all[host.lowercased()] = target
        self.all = all
    }

    /// A configured target that wakes on its own when the server does not answer.
    static func autoTarget(for host: String) -> WakeTarget? {
        guard let target = target(for: host), target.isConfigured, target.autoWake else { return nil }
        return target
    }
}

/// Wake-on-LAN: the "magic packet" (6 × 0xFF, then the MAC address 16 times) over UDP.
///
/// Sent every way that can reach the PC, since each works in different situations:
/// - the LAN broadcast (255.255.255.255 and the Wi-Fi subnet's, ports 9 and 7) — the classic way; iOS may refuse
///   broadcasts from an app without Apple's multicast permission, so it is not the only one;
/// - straight to the PC's LAN address — works while the router still remembers where that address is;
/// - to the DDNS name and port — from outside, and from inside too when the router loops it back; the router
///   forwards that UDP port to the PC (or to 192.168.1.255).
enum WakeOnLan {
    /// "50-EB-F6-5B-7A-48", "50:eb:f6:5b:7a:48", "50EBF65B7A48" → 6 bytes.
    static func macBytes(_ text: String) -> [UInt8]? {
        let hex = text.uppercased().filter { $0.isHexDigit }
        guard hex.count == 12 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    static func packet(_ mac: [UInt8]) -> Data {
        var data = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { data.append(contentsOf: mac) }
        return data
    }

    /// Sends the packet every way (three times each, a moment apart) and says what went out.
    static func wake(_ target: WakeTarget) async -> [String] {
        guard let mac = macBytes(target.mac) else { return ["MAC không hợp lệ"] }
        let data = packet(mac)
        var routes: [(host: String, port: UInt16, broadcast: Bool, label: String)] = [
            ("255.255.255.255", 9, true, "LAN broadcast"),
            ("255.255.255.255", 7, true, "LAN broadcast :7"),
        ]
        if let subnet = wifiBroadcastAddress() {
            routes.append((subnet, 9, true, "LAN \(subnet)"))
        }
        let lan = target.lanAddress.trimmingCharacters(in: .whitespaces)
        if !lan.isEmpty { routes.append((lan, 9, false, "máy \(lan)")) }
        let wan = target.wanHost.trimmingCharacters(in: .whitespaces)
        if !wan.isEmpty {
            routes.append((wan, UInt16(clamping: max(1, min(65535, target.wanPort))), false, "\(wan):\(target.wanPort)"))
        }

        return await Task.detached(priority: .userInitiated) { () -> [String] in
            var report: [String] = []
            for round in 0..<3 {
                for route in routes {
                    let error = send(data, to: route.host, port: route.port, broadcast: route.broadcast)
                    if round == 0 { report.append("\(route.label): \(error ?? "đã gửi")") }
                }
                usleep(300_000)
            }
            PlaybackDiagnostics.append("wol: " + report.joined(separator: " · "))
            return report
        }.value
    }

    /// One UDP datagram; nil when it went out, else the reason.
    private static func send(_ data: Data, to host: String, port: UInt16, broadcast: Bool) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else { return "không tìm được địa chỉ" }
        defer { freeaddrinfo(info) }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return "không mở được socket" }
        defer { close(fd) }
        if broadcast {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        let sent = data.withUnsafeBytes { raw in
            sendto(fd, raw.baseAddress, data.count, 0, first.pointee.ai_addr, first.pointee.ai_addrlen)
        }
        return sent == data.count ? nil : "lỗi \(String(cString: strerror(errno)))"
    }

    /// The Wi-Fi subnet's broadcast address ("192.168.1.255"), from the phone's own address and netmask.
    private static func wifiBroadcastAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == "en0",
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = entry.pointee.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            var broadcast = in_addr(s_addr: ip | ~netmask)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &broadcast, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        }
        return nil
    }

    /// Waits until `host` answers on the SMB port (445), up to `timeout`; `progress` gets the seconds waited.
    static func waitForSmb(host: String, timeout: TimeInterval, progress: @escaping @MainActor (Int) -> Void) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if Task.isCancelled { return false }
            if await portOpen(host: host, port: 445, within: 3) { return true }
            await progress(Int(Date().timeIntervalSince(start)))
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
    }

    /// A TCP connection to `host:port` succeeds within `seconds`.
    static func portOpen(host: String, port: UInt16, within seconds: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: true) }
                    connection.cancel()
                case .failed, .cancelled:
                    if once.claim() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.claim() { continuation.resume(returning: false) }
                connection.cancel()
            }
        }
    }
}

/// Fills a server's Wake-on-LAN settings by itself once it has been reached, so nothing has to be typed:
/// - its LAN address: the host itself when it is a private address (or a name the home network resolves to one);
/// - its MAC address: asked from Windows with a NetBIOS "node status" query (UDP 137) — the answer carries the
///   network card's address;
/// - its DDNS name: the host itself when it resolves to a public address;
/// - what is still missing comes from another saved server with the same login (the same PC reached by IP at
///   home and by DDNS outside).
/// Only empty fields are filled; what the user typed is kept.
enum WakeAutoFill {
    private static let lock = NSLock()
    private static var done: Set<String> = []

    static func learn(host: String, username: String) {
        let key = host.lowercased()
        lock.lock()
        let first = done.insert(key).inserted
        lock.unlock()
        guard first else { return }
        Task.detached(priority: .utility) {
            var target = WakeTargetStore.target(for: host) ?? WakeTarget()
            let before = target
            let address = resolveIPv4(host)
            if let address, isPrivate(address) {
                if target.lanAddress.isEmpty { target.lanAddress = address }
                if target.mac.isEmpty, let mac = netbiosMAC(address) { target.mac = mac }
            } else if target.wanHost.isEmpty, !isIPv4(host) {
                target.wanHost = host
            }
            // The same PC saved under its other address (same login): share what each one knows.
            for profile in SmbServerStore.load()
            where profile.host.lowercased() != key && profile.username.lowercased() == username.lowercased() {
                guard var other = WakeTargetStore.target(for: profile.host) else { continue }
                if target.mac.isEmpty, other.isConfigured { target.mac = other.mac }
                if target.lanAddress.isEmpty, !other.lanAddress.isEmpty { target.lanAddress = other.lanAddress }
                if target.wanHost.isEmpty, !other.wanHost.isEmpty { target.wanHost = other.wanHost }
                let otherBefore = other
                if other.mac.isEmpty, target.isConfigured { other.mac = target.mac }
                if other.lanAddress.isEmpty, !target.lanAddress.isEmpty { other.lanAddress = target.lanAddress }
                if other.wanHost.isEmpty, !target.wanHost.isEmpty { other.wanHost = target.wanHost }
                if other != otherBefore { WakeTargetStore.save(other, for: profile.host) }
            }
            if target != before {
                WakeTargetStore.save(target, for: host)
                PlaybackDiagnostics.append("wol: learned \(host) — mac \(target.mac.isEmpty ? "?" : target.mac), lan \(target.lanAddress.isEmpty ? "?" : target.lanAddress), wan \(target.wanHost.isEmpty ? "?" : target.wanHost)")
            }
        }
    }

    static func isIPv4(_ text: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, text, &addr) == 1
    }

    /// 10.x, 172.16–31.x, 192.168.x, 169.254.x.
    static func isPrivate(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254)
    }

    static func resolveIPv4(_ host: String) -> String? {
        if isIPv4(host) { return host }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info, let sa = first.pointee.ai_addr else { return nil }
        defer { freeaddrinfo(info) }
        var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }

    /// NetBIOS node status (RFC 1002): the reply lists the PC's names followed by its 6-byte MAC address.
    static func netbiosMAC(_ ip: String) -> String? {
        var query: [UInt8] = [0x13, 0x37, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20]
        // "*" padded with zeros to 16 bytes, each byte split into two letters 'A' + nibble.
        let name: [UInt8] = [0x2A] + Array(repeating: 0, count: 15)
        for byte in name { query += [0x41 + (byte >> 4), 0x41 + (byte & 0x0F)] }
        query += [0x00, 0x00, 0x21, 0x00, 0x01] // end of name, type NBSTAT, class IN

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 1, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var to = sockaddr_in()
        to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = in_port_t(137).bigEndian
        guard inet_pton(AF_INET, ip, &to.sin_addr) == 1 else { return nil }

        var reply = [UInt8](repeating: 0, count: 1024)
        for _ in 0..<2 {
            let sent = withUnsafePointer(to: &to) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, query, query.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard sent == query.count else { return nil }
            let count = recv(fd, &reply, reply.count, 0)
            guard count > 57 else { continue }
            // Header 12 + name 34 + type/class 4 + TTL 4 + length 2 = 56, then the number of names.
            let names = Int(reply[56])
            let macStart = 57 + names * 18
            guard macStart + 6 <= count else { continue }
            let mac = Array(reply[macStart..<(macStart + 6)])
            guard mac.contains(where: { $0 != 0 }) else { return nil }
            return mac.map { String(format: "%02X", $0) }.joined(separator: "-")
        }
        return nil
    }
}
