import SwiftUI

/// Scans the local Wi-Fi subnet for open SMB (port 445) hosts and lets the user tap one to fill in the connect
/// form, instead of having to type the computer's IP address by hand.
struct NetworkScanSheet: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = true
    @State private var found: [SmbDiscovery.Found] = []
    @State private var progressText = ""

    var body: some View {
        NavigationStack {
            Group {
                if scanning && found.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Đang quét mạng…").font(.subheadline)
                        if !progressText.isEmpty {
                            Text(progressText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if found.isEmpty {
                    ContentUnavailableFallback(
                        title: "Không tìm thấy máy nào",
                        message: "Kiểm tra điện thoại và máy tính đang cùng mạng Wi-Fi, máy tính đã bật chia sẻ file, và đã cho phép VLCcustom truy cập mạng cục bộ (Cài đặt > Quyền riêng tư & Bảo mật > Mạng cục bộ)."
                    )
                } else {
                    List(found) { item in
                        Button {
                            onSelect(item.host)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "network")
                                Text(item.host)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Quét mạng")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
            }
            .task { await scan() }
        }
        .presentationDetents([.medium, .large])
    }

    private func scan() async {
        let results = await SmbDiscovery.scanLocalNetwork { checked, total in
            Task { @MainActor in progressText = "\(checked)/\(total)" }
        }
        found = results
        scanning = false
    }
}
