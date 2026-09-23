# Bàn giao — VLCcustom cho iOS

Tài liệu này tóm tắt toàn bộ quá trình làm bản iOS để mang sang session mới (session cũ dùng cho bản Android tại `H:\VLCcustom`). Mở session mới, trỏ thư mục làm việc vào `H:\VLCcustom-iOS`, rồi đưa file này cho Claude đọc là đủ ngữ cảnh tiếp tục.

## Vị trí & liên kết

- Thư mục code: `H:\VLCcustom-iOS`
- Repo GitHub: https://github.com/vanhau1303-hub/vlccustom-ios (nhánh `master`)
- Bản Android (tham chiếu): `H:\VLCcustom`, repo `videothumnailvlc`
- Bản Windows (tham chiếu): `H:\VLCcustom-Windows`, repo `vlccustom-windows`
- Release mới nhất: **v0.8** — https://github.com/vanhau1303-hub/vlccustom-ios/releases/tag/v0.8
- Mỗi bản build ra được release kèm `.ipa` (unsigned) trên GitHub, tag tăng dần v0.1 → v0.8.

## Vì sao làm được trên máy Windows (không có Mac)

Xcode chỉ chạy trên macOS, nhưng **GitHub Actions có máy ảo macOS miễn phí**. Toàn bộ build (kể cả archive ra `.ipa` và chụp ảnh demo trên Simulator) chạy qua đó, kích hoạt bằng `git push` (workflow tự chạy khi đổi code) hoặc `gh workflow run`.

- `.github/workflows/build-ipa.yml` — build `.ipa` chưa ký (unsigned), tải về bằng `gh run download <run-id> -n VlcCustomIOS-unsigned-ipa`.
- `.github/workflows/simulator-screenshot.yml` — build cho Simulator, chụp ảnh demo từng tab (dùng biến `DEMO_TAB` đọc trong `ContentView.swift` để tự mở đúng tab, vì không có iPhone thật để bấm tay qua từng màn hình).

Quy trình chuẩn mỗi khi sửa code:
```bash
git add -A && git commit -m "..." && git push
# đợi ~15s cho workflow bắt đầu, rồi:
gh run list --repo vanhau1303-hub/vlccustom-ios --limit 2
gh run watch <run-id> --repo vanhau1303-hub/vlccustom-ios --exit-status
# LƯU Ý: nếu pipe qua `| tail`, mã thoát bị che mất — luôn gh run view --json conclusion để xác nhận thật
gh run download <run-id> --repo vanhau1303-hub/vlccustom-ios -n VlcCustomIOS-unsigned-ipa -D dist
```
Cài lên iPhone qua **AltStore** hoặc **Sideloadly** (không cần tài khoản Apple Developer trả phí) — xem `README.md` trong repo.

## Công nghệ dùng

- SwiftUI, deployment target iOS 16.0
- **MobileVLCKit** (CocoaPods, unpinned → thực tế cài bản **3.7.3**) — engine phát video
- **AMSMB2** (SPM) — client SMB2/3
- **WhisperKit** (SPM, Argmax) — nhận dạng giọng nói on-device (Core ML) cho phụ đề AI
- **XcodeGen** — sinh `.xcodeproj` từ `project.yml` (không có Xcode trên máy này để tạo/sửa project trực tiếp)
- `Services/SmbHttpProxy.swift` — HTTP proxy nội bộ (loopback, `Network` framework) để VLCKit phát file SMB qua URL `http://127.0.0.1:port/...`

## Đã làm xong (tính năng)

- Video: trên máy (qua Files app picker) + SMB, thumbnail thật, tìm kiếm/sắp xếp, chế độ Lưới/Danh sách, playlist.
- Nhạc: local + SMB, phát nền, điều khiển màn hình khoá (MPNowPlayingInfoCenter/MPRemoteCommandCenter).
- Ảnh: local + SMB, lưới thumbnail, xem toàn màn hình có zoom/vuốt/trình chiếu.
- Playlist (video & nhạc riêng), Yêu thích (thư mục SMB đánh dấu sao).
- Trình phát: tốc độ phát, chọn track âm thanh/phụ đề, chỉnh màu (VLCAdjustFilter), khử sọc, tỉ lệ khung hình.
- **Phụ đề AI**: WhisperKit nhận dạng giọng nói theo cửa sổ 30s, lưu `.srt` + file coverage để xem tiếp không làm lại; dịch qua LibreTranslate, có chế độ song ngữ.
- **Quét mạng tìm SMB server** (`SmbDiscovery.swift`) — quét cổng 445 trên dải /24 vì Windows share không tự phát tín hiệu Bonjour.
- **Cử chỉ trong trình phát** (giống Android): vuốt ngang tua, vuốt dọc trái/phải chỉnh sáng/âm lượng, chạm đúp tua ±10s / play-pause. **Chưa xác nhận hoạt động tốt trên máy thật** (user báo "animation giật" nhưng chưa rõ chỗ nào).
- Icon app dùng đúng hình từ bản Android (`Assets.xcassets/AppIcon.appiconset`).
- Bàn phím tự ẩn khi chạm ra ngoài ô nhập SMB.
- Sau khi kết nối SMB xong, form nhập host/user/pass tự ẩn, chỉ còn giao diện duyệt file (nút mũi tên quay lại để đổi server).

## ⚠️ VẤN ĐỀ CHƯA GIẢI QUYẾT — QUAN TRỌNG NHẤT

**Phát video/thumbnail qua SMB vẫn KHÔNG hoạt động trên iPhone thật** (đã test iPhone 14 Pro Max, iOS 27), dù đã qua nhiều vòng sửa:

1. **v0.3**: sửa crash khi mở app (thiếu `embed: true` cho AMSMB2 trong `project.yml` — SPM package không được nhúng vào `.ipa` khi archive, dù build Simulator vẫn chạy bình thường nên không phát hiện ra sớm hơn).
2. **v0.5-0.6**: nghi thumbnail tranh băng thông với player (`PlaybackActivity` gate) — chưa đủ.
3. **v0.6**: tìm ra AMSMB2's `contents(atPath:range:) -> Data` mở **file handle mới cho MỖI lần gọi** (SMB2 CREATE/READ/CLOSE mỗi 1MB) → cực chậm. Sửa dùng `contents(atPath:range:) -> AsyncThrowingStream<Data, Error>` (mở file 1 lần, đọc tuần tự) — xem `SmbConnection.readStream(_:)`. **Vẫn chưa hết lỗi.**
4. **v0.7**: nghi lỗi giống Android từng gặp ("Failed to acquire credits in time" — tranh credit SMB2 giữa nhiều lượt đọc đồng thời). Thêm "read gate" (`SmbConnection.acquireReadSlot()/releaseReadSlot()`) chỉ cho 1 lượt đọc cùng lúc trên toàn kết nối. **User báo vẫn chưa đọc được file.**
5. **v0.8**: user nói "vẫn chưa đọc được file, check lại codec" — nghi ngờ đổi hướng: có thể ĐÃ hết treo/lag, giờ lỗi thật xuất hiện nhanh (VLC báo lỗi rõ ràng thay vì treo vô hạn), và đó mới đúng là lý do user nhắc tới "codec". Nhưng KHÔNG có bằng chứng cụ thể (không có log/ảnh lỗi). Thay vì đoán tiếp, đã thêm **log chẩn đoán thật**:
   - `Services/PlaybackDiagnostics.swift` — bật `VLCFileLogger` (log gốc của libVLC, mức debug) + tự ghi thêm log vòng đời request/response của `SmbHttpProxy` và state của `VlcPlayerController`.
   - Cài đặt (tab More) → nút "Chia sẻ log chẩn đoán" (dùng `ShareLink`) để user gửi file log thật.

**➡️ VIỆC CẦN LÀM TIẾP THEO**: đợi user gửi file log (`vlc_diagnostics.log`, nằm trong Caches directory, share qua ShareLink trong app). Đọc log để biết chính xác:
- VLC có báo lỗi demux/codec cụ thể không (ví dụ thiếu decoder cho định dạng gì)?
- Hay proxy vẫn không gửi đủ byte / bị timeout / bị lỗi kết nối SMB thật?

**Đừng đoán tiếp mà chưa có log** — đã đoán sai 3-4 lần liên tiếp trong session trước, tốn nhiều vòng build/release vô ích.

## Bài học quan trọng (để không lặp lại lỗi)

1. **CocoaPods `MobileVLCKit` (unpinned) cài bản 3.7.3**, KHÔNG phải bản mới nhất trên git chính (main branch của `videolan/vlckit` có API mới hơn nhiều — ví dụ `VLCMediaPlayerTrack`, `VLCVideoFitMode` KHÔNG có trong 3.7.3). Luôn tra API theo đúng tag `3.7.3`:
   ```bash
   gh api repos/videolan/vlckit/contents/Headers/Public/<File>.h?ref=3.7.3 --jq '.content' | base64 -d
   ```
   API track thật ở 3.7.3: `audioTrackNames`/`audioTrackIndexes` + `currentAudioTrackIndex` (mảng song song tên/index, không phải object track), `videoSubTitlesNames`/`videoSubTitlesIndexes` + `currentVideoSubTitleIndex`. Không có `videoFitMode` — dùng `videoAspectRatio` (char*, qua `strdup`).
2. **XcodeGen SPM package**: `embed: true` cần thiết cho package tạo ra `.framework` thật (AMSMB2) để `xcodebuild archive` nhúng đúng vào `.ipa` — nhưng KHÔNG được đặt `embed: true` cho package tạo thư viện tĩnh (WhisperKit) vì sẽ làm archive lỗi ("No such file" tìm build product không tồn tại). Chỉ biết được sự khác biệt này qua thử nghiệm thật (archive fail), không đoán được trước.
3. **AMSMB2 `contents(atPath:range:) -> Data`** mở file mới mỗi lần gọi — chỉ dùng cho đọc một lần (thumbnail, ảnh nhỏ). Đọc tuần tự dài (stream video) PHẢI dùng `contents(atPath:range:) -> AsyncThrowingStream<Data, Error>`.
4. Build Simulator (`xcodebuild build`) và build Archive thật (`xcodebuild archive`, dùng cho `.ipa` thật) **có thể cho kết quả khác nhau** (embed framework, code signing) — test trên Simulator KHÔNG đảm bảo app chạy đúng trên máy thật. Đây là lý do crash v0.1-v0.2 không bị phát hiện qua nhiều vòng test Simulator.
5. Luôn `gh run view --json status,conclusion` để xác nhận kết quả CI thật — nếu pipe `gh run watch | tail`, mã thoát của `tail` sẽ che mất mã thoát thật của `gh run watch`, dễ tưởng build xanh trong khi nó đỏ.

## Vấn đề khác đang chờ phản hồi user (chưa đủ thông tin để sửa)

- **"Animation khá giật khi chuyển"** — user chưa nói rõ chuyển ở đâu (chuyển tab dưới cùng? mở trình phát? vuốt cử chỉ trong trình phát?). Cần hỏi lại cụ thể trước khi sửa mò.
- Cử chỉ trong trình phát (`PlayerScreen.swift`: `playerDragGesture`, `handleDoubleTap`) — code đã viết theo đúng API thật (`SpatialTapGesture`, `.exclusively(before:)`, `DragGesture`), nhưng **chưa test được trên máy thật lần nào** — cần user xác nhận có hoạt động đúng không (vuốt tua có mượt, chạm đúp có nhận đúng vị trí trái/giữa/phải không).

## Việc chưa làm (đã nói rõ với user là không làm / để sau)

- Explorer duyệt toàn bộ ổ đĩa: **không thể làm trên iOS** do sandbox của Apple — không phải thiếu công sức.
- Thao tác file (copy/move/rename/delete): không làm (theo yêu cầu user bỏ khỏi danh sách).
- Khoá ứng dụng: chưa làm, để sau.
- Ghép 2 file phụ đề độc lập có tự căn chỉnh khung hình (như bản Android's `DualSubtitles` case ghép file+file): chưa làm — chỉ có bản song ngữ từ chính phụ đề AI (gốc+dịch trong cùng 1 cue).

## Cấu trúc thư mục

```
project.yml          # XcodeGen spec — sửa xong phải git push để CI generate lại project
Podfile               # CocoaPods: MobileVLCKit
VlcCustomIOS/
  VlcCustomIOSApp.swift
  Assets.xcassets/AppIcon.appiconset/   # icon app
  Models/            # VideoItem, SmbEntry, AudioItem, ImageItem, Playlist, FavoriteFolder, LiveCue, SpeechModels
  Services/          # SmbConnection, SmbHttpProxy, SmbDiscovery, LocalVideoService, SmbServerStore,
                      # PlaybackQueue, ThumbnailService, PlaylistStore, FavoritesStore, MusicPlayer,
                      # WhisperEngine, AudioPcmExtractor, LiveSubtitles, SubtitleLayout, Srt, SubtitleTranslator,
                      # SpeechSettings, LibrarySettings, PlaybackActivity, PlaybackDiagnostics, SmbUri
  Views/             # ContentView (TabView 7 tab), LocalLibraryView, SmbBrowserView, MusicLibraryView,
                      # ImagesLibraryView, PlaylistsView, FavoritesView, PlayerScreen (+ picture/track/speech
                      # sheets), MusicPlayerScreen, NowPlayingBar, MediaThumbnails, Sorting, NetworkScanSheet,
                      # KeyboardDismiss, FolderPicker
.github/workflows/
  build-ipa.yml               # build .ipa thật (device, unsigned)
  simulator-screenshot.yml    # build + chụp ảnh demo Simulator (dùng DEMO_TAB)
```

## Tài khoản / thông tin liên quan

- Git author cho repo này: `vanhau1303-hub <vanhau1303@gmail.com>` (cần truyền `-c user.name -c user.email` vì máy không có git config mặc định).
- GitHub `gh` CLI đã có `workflow` scope (cần cho push sửa file trong `.github/workflows/`).
