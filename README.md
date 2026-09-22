# VLCcustom (iOS)

Bản iOS của VLCcustom (xem bản Android tại [videothumnailvlc](https://github.com/vanhau1303-hub/videothumnailvlc), bản Windows tại [vlccustom-windows](https://github.com/vanhau1303-hub/vlccustom-windows)). Cùng cốt lõi: phát video bằng libVLC, duyệt thư mục trên máy và chia sẻ mạng SMB2/3.

**Mã nguồn này viết trên Windows** (Xcode chỉ chạy trên macOS — giới hạn của Apple, không của máy này) nhưng **đã build thành công qua GitHub Actions** (chạy trên máy ảo macOS miễn phí, xem bên dưới). File `.ipa` đầu tiên đã tải về và test cài đặt được. Ba lỗi gặp phải khi build lần đầu và cách sửa:
1. `MobileVLCKit ~> 3.6.1` không có trên CocoaPods trunk → bỏ ghim phiên bản, để CocoaPods tự chọn bản mới nhất.
2. XcodeGen mới nhất ghi project ở định dạng mà Xcode 15.4 (mặc định trên runner) không mở được ("future Xcode project file format") → thêm bước tự chọn bản Xcode mới nhất có sẵn trên runner (`Setup/../workflow`: `xcode-select -s $(ls -d /Applications/Xcode_*.app | sort -V | tail -1)`), đổi sang runner `macos-15`.
3. `AMSMB2 8.2.0` không tồn tại (đoán sai số phiên bản) → tra bằng `gh api repos/amosavian/AMSMB2/tags` ra bản thật (4.0.3), đồng thời viết lại `SmbConnection.swift` cho đúng API thật của AMSMB2 (đọc trực tiếp mã nguồn trên GitHub thay vì đoán): mỗi `SMB2Manager` chỉ gắn với **một** share tại một thời điểm (`connectShare(name:)` rồi các đường dẫn sau đó là tương đối so với gốc share đó), không có tham số `onShare:` trên từng lệnh như tôi đoán ban đầu.
4. `.onChange(of:initial:_:)` hai tham số chỉ có từ iOS 17, project nhắm iOS 16 → đổi sang overload một tham số cũ.

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

## Trạng thái: đã thêm phần lớn tính năng của bản Android — chưa test trên iPhone thật
- Tab "Video": chọn thư mục qua ứng dụng Tệp (giới hạn của iOS — không duyệt được toàn bộ ổ đĩa như Android/Windows), tìm kiếm, sắp xếp, thêm vào playlist, thumbnail (khung hình lấy qua `AVAssetImageGenerator`, có cache).
- Tab "Mạng (SMB)": nhập host/tài khoản/mật khẩu (mật khẩu lưu Keychain), duyệt thư mục, đánh dấu yêu thích, tìm kiếm/sắp xếp, thêm vào playlist.
- Tab "Nhạc": nhạc trong thư mục đã chọn + duyệt SMB riêng, phát nền (`AVAudioSession` category `.playback`, `UIBackgroundModes: audio`), điều khiển ở màn hình khóa/Control Center qua `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter`, trộn bài, lặp lại.
- Tab "Ảnh": lưới thumbnail (trên máy + SMB), xem toàn màn hình có zoom (chụm 2 ngón), vuốt chuyển ảnh, trình chiếu tự động.
- Tab "Playlist": playlist video và playlist nhạc riêng, tạo/xoá/thêm/bớt bài.
- Tab "Yêu thích": thư mục SMB đã đánh dấu sao, bấm vào tự kết nối lại và mở đúng thư mục.
- Trình phát video: play/pause, tua, tiến/lùi bài, toàn màn hình, **tốc độ phát** (0.5x–2x), **chọn track âm thanh/phụ đề**, **chỉnh màu** (tương phản/sáng/sắc độ/bão hòa/gamma qua `VLCAdjustFilter`), **khử sọc** (deinterlace), đổi **tỉ lệ khung hình**.

Chưa có (dự kiến làm dần — bị giới hạn công nghệ hoặc cần dự án con riêng):
- Phụ đề AI (nhận dạng giọng nói) và dịch tự động — cần build riêng một mô hình nhận dạng giọng nói cho iOS.
- Trình Explorer duyệt toàn bộ ổ đĩa — **không thể làm được trên iOS** do giới hạn sandbox của Apple, khác iOS không phải do thiếu công sức.
- Khoá ứng dụng, sao chép/di chuyển/đổi tên/xoá file, dịch vụ chạy nền giữ kết nối.

## Cấu trúc
```
project.yml       # XcodeGen: sinh VlcCustomIOS.xcodeproj
Podfile            # CocoaPods: MobileVLCKit
VlcCustomIOS/
  VlcCustomIOSApp.swift
  Models/           # VideoItem, SmbEntry, SmbServerProfile, AudioItem, ImageItem, Playlist, FavoriteFolder
  Services/         # SmbConnection (AMSMB2), SmbHttpProxy, LocalVideoService, SmbServerStore, PlaybackQueue,
                     # ThumbnailService, PlaylistStore, FavoritesStore, MusicPlayer (+MusicQueue), SmbUri
  Views/            # ContentView (TabView), LocalLibraryView, SmbBrowserView, MusicLibraryView, ImagesLibraryView,
                     # PlaylistsView, FavoritesView, PlayerScreen (+picture/track sheets), MusicPlayerScreen,
                     # NowPlayingBar, Sorting (search/sort helper), FolderPicker
```
