# LAN Player — nội dung để điền trong App Store Connect

## Thông tin chung
- **Tên:** LAN Player (tối đa 30 ký tự; nếu bị trùng: `LAN Player – SMB Video`)
- **Phụ đề (Subtitle, ≤30):** `Xem video từ máy tính qua Wi-Fi`
- **Danh mục:** chính là *Photo & Video*, phụ là *Entertainment*
- **URL hỗ trợ:** `https://vanhau1303-hub.github.io/vlccustom-ios/support.html`
- **URL chính sách quyền riêng tư:** `https://vanhau1303-hub.github.io/vlccustom-ios/privacy.html`
- **Độ tuổi:** trả lời "Không" cho mọi câu, kết quả là 4+. App không tự cung cấp nội dung; video là của người dùng.
- **Giá app:** Miễn phí. Bản Pro bán qua In-App Purchase `com.vanhau1303.lanplayer.pro`.

## Từ khoá (Keywords, ≤100 ký tự, phân cách bằng dấu phẩy)
```
smb,nas,mạng lan,video,phụ đề,subtitle,mkv,windows share,trình phát,player,wifi,phim,vietsub
```

## Mô tả (Tiếng Việt)
```
Xem phim và video lưu trên máy tính hoặc NAS ngay trên iPhone, qua Wi-Fi nhà bạn — không cần chép file, không cần cài thêm gì trên máy tính.

• Kết nối thư mục chia sẻ Windows / macOS / NAS (SMB), tự tìm máy trong mạng.
• Phát gần như mọi định dạng: MKV, MP4, AVI, TS, HEVC… kể cả phụ đề và nhiều luồng âm thanh trong file.
• Thumbnail cho từng video và thư mục, sắp xếp, tìm kiếm cả thư mục con, danh sách yêu thích.
• Xem tiếp đúng chỗ đã dừng, thanh tiến độ và dấu "đã xem" trên mỗi video, tự chuyển tập kế tiếp.
• Cử chỉ quen thuộc: vuốt để tua, chỉnh độ sáng, âm lượng; chạm hai lần tua nhanh; khoá cảm ứng.
• Tuỳ chỉnh phụ đề: cỡ chữ, màu, font, nền; chỉnh phụ đề sớm/trễ.

LAN PLAYER PRO (mua một lần, không thuê bao):
• Không quảng cáo.
• Phụ đề AI: nhận dạng lời nói ngay trên máy và dịch sang tiếng Việt.
• Tìm và tải phụ đề từ OpenSubtitles, tự dịch nếu không phải tiếng Việt.
• Thumbnail nền và thumbnail động cho cả thư mục.
• Khoá màn hình vẫn nghe tiếp tiếng của video.

LAN Player không có máy chủ riêng và không thu thập dữ liệu của bạn. Video của bạn ở nguyên trên máy tính của bạn.
```

## Description (English, nếu thêm ngôn ngữ English)
```
Watch the movies and videos stored on your computer or NAS right on your iPhone, over your home Wi-Fi — no copying, nothing to install on the computer.

• Connects to Windows / macOS / NAS shared folders (SMB) and finds them on your network.
• Plays nearly any format: MKV, MP4, AVI, TS, HEVC… including embedded subtitles and multiple audio tracks.
• Thumbnails for every video and folder, sorting, search through subfolders, favorites.
• Resume where you left off, progress bars and "watched" marks, next episode plays automatically.
• Familiar gestures: swipe to seek, brightness and volume; double-tap to skip; touch lock.
• Subtitle style: size, color, font, background; subtitle timing.

LAN PLAYER PRO (one-time purchase, no subscription): no ads, AI subtitles recognized on the device and translated, subtitles from OpenSubtitles, background and animated thumbnails, sound with the screen locked.
```

## App Privacy (mục "App Privacy" trong App Store Connect)
LAN Player tự nó không thu thập gì. **Google AdMob** (bản miễn phí) thì có, nên khai như sau:
- **Data Used to Track You:**
  - Identifiers → *Device ID*.
  - Usage Data → *Advertising Data*.
- **Data Linked to You:** không có.
- **Data Not Linked to You:**
  - Identifiers → *Device ID*: mục đích Third-Party Advertising.
  - Usage Data → *Product Interaction* và *Advertising Data*: mục đích Third-Party Advertising và Analytics.
  - Diagnostics → *Crash Data* và *Performance Data*: mục đích Third-Party Advertising. Google ghi số liệu này để phục vụ quảng cáo.
  - Location → *Coarse Location*, suy ra từ địa chỉ IP: mục đích Third-Party Advertising.

Tham khảo hướng dẫn của Google: <https://developers.google.com/admob/ios/privacy/data-disclosure>

## Ghi chú cho người duyệt (App Review Information → Notes)
```
LAN Player plays videos from SMB file shares on the user's own home network (a Windows/macOS/NAS shared folder).
App Review usually has no SMB server, so the app includes a sample video that needs no server:
  Mạng tab → "Xem thử video mẫu" (Apple's public HLS sample stream).
A screen recording showing browsing a real SMB share is attached / linked here: <LINK VIDEO>.

In-app purchase: "LAN Player Pro" (non-consumable) — Cài đặt (Settings) tab → "Nâng cấp LAN Player Pro".
"Khôi phục giao dịch đã mua" (Restore Purchases) is on the same screen.
Pro unlocks AI subtitles, OpenSubtitles search, background thumbnails, background audio and removes ads.

Ads (free version) use Google AdMob; the App Tracking Transparency prompt appears once before ads load.
Local network permission is used only to reach the user's own file shares.
```
*Tip: quay một video ngắn (1–2 phút), đưa lên YouTube ở chế độ "Không công khai" rồi dán link vào chỗ <LINK VIDEO>. Video cần cho thấy anh kết nối máy tính, duyệt thư mục, phát video, mở phụ đề.*

## Ảnh chụp màn hình gợi ý (6.9" và 6.5")
1. Màn duyệt thư mục dạng lưới, có thumbnail.
2. Trình phát đang chiếu video kèm phụ đề.
3. Bảng Phụ đề (Trong file / Tìm trên mạng / AI).
4. Màn Yêu thích hoặc Đang xem dở.
5. Màn bản Pro.
