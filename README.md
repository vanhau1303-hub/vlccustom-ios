# VLCcustom (iOS)

Bản iOS của VLCcustom (xem bản Android tại [videothumnailvlc](https://github.com/vanhau1303-hub/videothumnailvlc), bản Windows tại [vlccustom-windows](https://github.com/vanhau1303-hub/vlccustom-windows)). Cùng cốt lõi: phát video bằng libVLC, duyệt thư mục trên máy và chia sẻ mạng SMB2/3.

**⚠️ Mã nguồn này viết trên Windows, chưa từng được biên dịch bằng Xcode thật.** iOS bắt buộc phải build bằng Xcode, chỉ chạy trên macOS — đây là giới hạn của Apple, máy Windows không thể tự tạo ra file `.ipa`. Lần build đầu tiên (qua GitHub Actions, xem bên dưới) nhiều khả năng sẽ báo vài lỗi biên dịch nhỏ; đọc log lỗi rồi báo lại để sửa tiếp.

## Công nghệ
- SwiftUI, iOS 16+
- [MobileVLCKit](https://code.videolan.org/videolan/VLCKit) (qua CocoaPods) — engine phát video, giống libVLC dùng trong bản Android/Windows.
- [AMSMB2](https://github.com/amosavian/AMSMB2) (qua Swift Package Manager) — client SMB2/3 thuần Swift.
- `Services/SmbHttpProxy.swift`: máy chủ HTTP nội bộ (loopback, viết bằng `Network` framework của Apple, không cần thư viện ngoài), phát lại nội dung file SMB theo Range request để VLCKit mở được bằng URL `http://127.0.0.1:port/...` — cùng cách làm với hai bản kia.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): dự án Xcode (`.xcodeproj`) được sinh ra từ `project.yml` thay vì lưu file `.pbxproj` (rất khó chỉnh tay), nên máy Windows này vẫn tạo được cấu hình project mà không cần Xcode.

## Build ra file .ipa — làm hết trên Windows
Máy Windows không build được, nhưng **GitHub Actions có máy ảo macOS miễn phí** làm việc đó thay, kích hoạt ngay từ Windows:
```bash
gh workflow run build-ipa.yml --repo vanhau1303-hub/vlccustom-ios
# đợi vài phút, rồi:
gh run list --repo vanhau1303-hub/vlccustom-ios --limit 1
gh run download <run-id> --repo vanhau1303-hub/vlccustom-ios -n VlcCustomIOS-unsigned-ipa
```
File `.ipa` tải về là **chưa ký** (unsigned) — bình thường, vì không cần tài khoản Apple Developer trả phí để build.

## Cài lên iPhone — không cần Mac
Dùng **[AltStore](https://altstore.io)**: cài `AltServer` trên chính máy Windows này, cắm iPhone bằng cáp (hoặc cùng Wi-Fi), rồi kéo file `.ipa` vào AltStore trên điện thoại. AltServer tự ký lại bằng Apple ID miễn phí của bạn khi cài. Giới hạn của Apple với tài khoản miễn phí: chữ ký hết hạn sau 7 ngày, AltServer sẽ tự làm mới nếu điện thoại và máy tính cùng mạng (hoặc dùng tính năng "AltStore mail relay" để làm mới qua Wi-Fi bất kỳ đâu).

## Trạng thái: bản đầu tiên (v0.1) — CHƯA XÁC NHẬN BUILD ĐƯỢC
Đã viết:
- Tab "Trên máy": chọn thư mục qua ứng dụng Tệp (giới hạn của iOS — không duyệt được toàn bộ ổ đĩa như Android/Windows), phát video.
- Tab "Mạng (SMB)": nhập host/tài khoản/mật khẩu (mật khẩu lưu trong Keychain), duyệt thư mục, phát video.
- Trình phát: play/pause, tua, tiến/lùi bài, toàn màn hình.

Chưa có (dự kiến làm dần):
- Thumbnail cho video, phụ đề AI, phụ đề song song, dịch tự động, thư viện Nhạc/Ảnh, Playlist, Yêu thích.

## Cấu trúc
```
project.yml       # XcodeGen: sinh VlcCustomIOS.xcodeproj
Podfile            # CocoaPods: MobileVLCKit
VlcCustomIOS/
  VlcCustomIOSApp.swift
  Models/           # VideoItem, SmbEntry, SmbServerProfile
  Services/         # SmbConnection (AMSMB2), SmbHttpProxy, LocalVideoService, SmbServerStore, PlaybackQueue
  Views/            # ContentView (TabView), LocalLibraryView, SmbBrowserView, PlayerScreen, FolderPicker
```
