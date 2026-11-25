import SwiftUI

/// Cài đặt → Wake-on-LAN: the saved servers, each opening its wake settings.
struct WakeOnLanListView: View {
    @State private var profiles: [SmbServerProfile] = []

    var body: some View {
        List {
            Section {
                if profiles.isEmpty {
                    Text("Chưa có máy chủ nào được lưu. Kết nối một lần ở tab Mạng là máy chủ được lưu lại.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(profiles) { profile in
                    NavigationLink {
                        WakeOnLanView(host: profile.host)
                    } label: {
                        HStack {
                            Label(profile.host, systemImage: "server.rack")
                            Spacer()
                            if WakeTargetStore.target(for: profile.host)?.isConfigured == true {
                                Text("Đã cài").font(.footnote).foregroundStyle(.green)
                            }
                        }
                    }
                }
            } footer: {
                Text("Bật máy tính đang ngủ / tắt từ xa để xem video qua SMB: trong nhà gửi qua mạng LAN, ở ngoài gửi qua tên miền DDNS và cổng UDP mà router chuyển tiếp.")
            }
        }
        .navigationTitle("Wake-on-LAN")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { profiles = SmbServerStore.load() }
    }
}

/// Wake settings of one server + "Đánh thức ngay".
struct WakeOnLanView: View {
    let host: String
    @State private var target = WakeTarget()
    @State private var report: [String] = []
    @State private var waking = false
    @State private var status: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("Địa chỉ MAC (vd 50-EB-F6-5B-7A-48)", text: $target.mac)
                    .autocorrectionDisabled().textInputAutocapitalization(.characters)
                    .font(.body.monospaced())
                if !target.mac.isEmpty && !target.isConfigured {
                    Text("MAC phải có 12 ký tự 0-9, A-F (dấu - hoặc : tuỳ ý).").font(.footnote).foregroundStyle(.red)
                }
                TextField("IP của máy trong LAN (vd 192.168.1.242)", text: $target.lanAddress)
                    .keyboardType(.numbersAndPunctuation).autocorrectionDisabled().textInputAutocapitalization(.never)
            } header: {
                Text("Trong nhà (LAN)")
            } footer: {
                Text("Trên máy tính Windows: mở Command Prompt, gõ ipconfig /all → dòng \"Physical Address\" là MAC, \"IPv4 Address\" là IP của card mạng đang cắm.")
            }

            Section {
                TextField("Tên miền DDNS (vd nhabadiem.duckdns.org)", text: $target.wanHost)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                HStack {
                    Text("Cổng UDP")
                    Spacer()
                    TextField("9", value: $target.wanPort, format: .number.grouping(.never))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
                }
            } header: {
                Text("Ở ngoài (WAN)")
            } footer: {
                Text("Trên router: chuyển tiếp (Port Forwarding / NAT) cổng UDP này tới IP của máy tính (hoặc 192.168.1.255 nếu router cho phép) — cổng 9 là thông dụng. Tên miền DDNS phải trỏ đúng IP nhà (DuckDNS, No-IP… hoặc DDNS có sẵn trong router).")
            }

            Section {
                Toggle("Tự đánh thức khi không kết nối được", isOn: $target.autoWake)
            } footer: {
                Text("Mở thư mục hay video trên máy chủ này mà máy không trả lời: app tự gửi lệnh đánh thức rồi chờ máy khởi động (tối đa 2 phút) và kết nối tiếp.")
            }

            Section {
                Button {
                    wakeNow()
                } label: {
                    HStack {
                        Label("Đánh thức ngay", systemImage: "power")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if waking { ProgressView() }
                    }
                }
                .disabled(!target.isConfigured || waking)
                if let status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(report, id: \.self) { line in
                    Text(line).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Máy tính cũng cần bật Wake-on-LAN: trong BIOS (Wake on LAN / Power on by PCI-E), và trong Windows → Device Manager → card mạng → Power Management + Advanced → \"Wake on Magic Packet\". Nên tắt \"Fast Startup\" của Windows để máy tắt hẳn vẫn đánh thức được.")
            }
        }
        .navigationTitle(host)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: target) { if loaded { WakeTargetStore.save($0, for: host) } }
    }

    private func load() {
        guard !loaded else { return }
        if let saved = WakeTargetStore.target(for: host) {
            target = saved
        } else {
            // A DDNS name as the server itself: use it from outside too.
            let isIP = host.split(separator: ".").count == 4 && host.allSatisfy { $0.isNumber || $0 == "." }
            if isIP { target.lanAddress = host } else { target.wanHost = host }
        }
        loaded = true
    }

    private func wakeNow() {
        waking = true
        status = "Đang gửi lệnh đánh thức…"
        report = []
        let target = target
        Task {
            report = await WakeOnLan.wake(target)
            status = "Đã gửi. Đang chờ máy trả lời qua SMB…"
            let up = await WakeOnLan.waitForSmb(host: host, timeout: 120) { seconds in
                status = "Đã gửi. Đang chờ máy trả lời qua SMB… \(seconds) giây"
            }
            status = up ? "Máy đã bật — kết nối được." : "Sau 2 phút máy vẫn chưa trả lời. Kiểm tra lại cài đặt Wake-on-LAN trên máy tính / router."
            waking = false
        }
    }
}
