import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            LocalLibraryView()
                .tabItem { Label("Trên máy", systemImage: "internaldrive") }
            SmbBrowserView()
                .tabItem { Label("Mạng (SMB)", systemImage: "network") }
            SettingsView()
                .tabItem { Label("Cài đặt", systemImage: "gearshape") }
        }
    }
}

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Bản đầu tiên: phát video trên máy (chọn thư mục trong ứng dụng Tệp) và trên chia sẻ mạng SMB. " +
                         "Các tính năng khác của bản Android (thumbnail động, phụ đề AI, nhạc, ảnh...) sẽ được thêm dần.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("VLCcustom cho iOS")
        }
    }
}

#Preview {
    ContentView()
}
