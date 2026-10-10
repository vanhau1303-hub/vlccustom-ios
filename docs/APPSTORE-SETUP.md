# Đưa LAN Player lên App Store — hướng dẫn từng bước (không cần máy Mac)

Code của bản App Store nằm ở nhánh `appstore`. Máy build của GitHub sẽ build, ký và tải app lên App Store Connect. Anh chỉ cần làm các bước dưới đây một lần trên Windows và trình duyệt.

Các file bí mật (chứng chỉ, khoá) để trong thư mục `~/lanplayer-signing` trên máy anh. Thư mục này nằm **ngoài repo**: tuyệt đối không đưa lên GitHub. GitHub chỉ giữ chúng ở dạng *Secrets*, ai xem repo cũng không thấy.

## 1. Tài khoản Apple Developer (99 USD/năm)
- Đăng ký ở <https://developer.apple.com/programs/enroll/> bằng Apple ID của anh, chọn loại **Cá nhân**.
- Đợi Apple duyệt (thường 1–2 ngày).
- Vào **Membership** để lấy **Team ID** (10 ký tự).

## 2. Mã nhận dạng app (App ID)
- developer.apple.com → Certificates, Identifiers & Profiles → **Identifiers** → `+` → App IDs → App.
- Phần Description ghi `LAN Player`. Phần Bundle ID chọn **Explicit** và điền `com.vanhau1303.lanplayer`.
- Mục In-App Purchase đã được bật sẵn. Bấm Continue → Register.

## 3. Chứng chỉ phân phối (Apple Distribution)
Mở **Git Bash** trong thư mục repo:
```bash
bash scripts/appstore-signing.sh csr email-cua-anh@example.com "Ten Cua Anh"
```
- Vào **Certificates** → `+` → **Apple Distribution**, rồi tải lên file `~/lanplayer-signing/distribution.csr`.
- Tải file `distribution.cer` mà Apple trả về, rồi chạy lệnh dưới. Lệnh này hỏi một mật khẩu cho file .p12, anh tự đặt.
```bash
bash scripts/appstore-signing.sh p12 ~/Downloads/distribution.cer
```

## 4. Hồ sơ phân phối (Provisioning Profile)
- **Profiles** → `+` → **App Store Connect**.
- Chọn App ID `com.vanhau1303.lanplayer`, rồi chọn chứng chỉ vừa tạo.
- Đặt tên `LAN Player App Store`.
- Tải về và đổi tên file thành `~/lanplayer-signing/lanplayer.mobileprovision`.

## 5. App trong App Store Connect
<https://appstoreconnect.apple.com> → **Apps** → `+` → New App:
- Platform iOS, Name `LAN Player`. Nếu tên đã có người dùng, thử `LAN Player – SMB Video`.
- Ngôn ngữ chính: Tiếng Việt. Bundle ID `com.vanhau1303.lanplayer`. SKU: `lanplayer`.

Sau đó làm tiếp:
- **Bản Pro:** vào app → Monetization → **In-App Purchases** → `+` → **Non-Consumable**.
  - Product ID: `com.vanhau1303.lanplayer.pro`
  - Tên hiển thị: `LAN Player Pro`
  - Chọn giá, ví dụ 99.000đ.
  - Thêm mô tả và một ảnh chụp màn hình bản Pro.
- **Hợp đồng và thanh toán:** vào **Business** (Agreements, Tax, Banking), ký hợp đồng **Paid Apps**, khai tài khoản ngân hàng và thông tin thuế. Chưa có hợp đồng này thì không bán được bản Pro.
- **Giảm phí Apple:** đăng ký **App Store Small Business Program** (<https://developer.apple.com/app-store/small-business-program/>) để Apple chỉ thu 15% thay vì 30%.

## 6. Khoá API App Store Connect (để GitHub tải app lên)
- App Store Connect → **Users and Access** → **Integrations** → App Store Connect API → `+`.
- Đặt tên `GitHub`, quyền **App Manager**.
- Tải file `AuthKey_XXXXXXXXXX.p8` (Apple chỉ cho tải **một lần**) vào `~/lanplayer-signing/`.
- Ghi lại **Issuer ID**, hiện ở đầu trang.

## 7. Đưa vào GitHub Secrets
```bash
bash scripts/appstore-signing.sh secrets
```
Lệnh này hỏi Issuer ID và Team ID, rồi tự cất tất cả vào Secrets của repo.

## 8. Quảng cáo (AdMob) — khi muốn có doanh thu thật
- Tạo tài khoản ở <https://admob.google.com>, thêm app iOS `LAN Player`.
- Tạo 2 đơn vị quảng cáo: **Banner** và **Interstitial** (quảng cáo toàn màn hình).
- Trong AdMob → Privacy & messaging, tạo thông báo **GDPR**. Đây là màn hỏi đồng ý cho người dùng ở châu Âu.
- Cất các mã vào GitHub:
```bash
gh secret set ADMOB_APP_ID -R vanhau1303-hub/vlccustom-ios            # ca-app-pub-xxxx~yyyy
gh secret set ADMOB_BANNER_UNIT -R vanhau1303-hub/vlccustom-ios       # ca-app-pub-xxxx/zzzz
gh secret set ADMOB_INTERSTITIAL_UNIT -R vanhau1303-hub/vlccustom-ios # ca-app-pub-xxxx/wwww
```
Chưa có mã thật thì app hiện quảng cáo thử của Google. Như vậy vẫn đưa lên TestFlight được, nhưng **đừng nộp duyệt** khi còn dùng mã thử.

## 9. OpenSubtitles
- Tạo tài khoản miễn phí ở <https://www.opensubtitles.com>.
- Vào **API Consumers** → New consumer, tên app `LANPlayer`. Đây là chỗ cấp khoá API miễn phí.
- Cất khoá vào GitHub:
```bash
gh secret set OPENSUBTITLES_API_KEY -R vanhau1303-hub/vlccustom-ios
```
Người dùng app đăng nhập tài khoản OpenSubtitles miễn phí của chính họ để tải phụ đề, nên anh không tốn tiền.

## 10. Build và tải lên
```bash
gh workflow run appstore.yml --ref appstore
```
Khoảng 15–25 phút sau, bản build hiện trong App Store Connect → **TestFlight**. Anh cài thử bằng app TestFlight trên iPhone, kể cả mua thử bản Pro bằng tài khoản Sandbox.

## 11. Nộp duyệt
Nội dung để điền khi nộp nằm trong `docs/APPSTORE-LISTING.md`: mô tả, từ khoá, câu trả lời về quyền riêng tư, ghi chú cho người duyệt.
- **Chính sách quyền riêng tư:** link là `https://vanhau1303-hub.github.io/vlccustom-ios/privacy.html`. Link này chạy được sau khi bật GitHub Pages cho thư mục `docs` của nhánh `appstore`.
- **Ảnh chụp màn hình:** cần ảnh cho iPhone 6.9 inch (1320×2868) và 6.5 inch (1284×2778), mỗi cỡ 3–10 ảnh.
