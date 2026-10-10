#!/usr/bin/env bash
# Chứng chỉ ký app cho App Store — chạy trên Windows bằng Git Bash (có sẵn openssl), không cần máy Mac.
# Mọi file bí mật nằm trong thư mục ~/lanplayer-signing (ngoài repo, KHÔNG đưa lên GitHub).
#
#   bash scripts/appstore-signing.sh csr  you@example.com "Ten Cua Anh"   → tạo khoá riêng + file CSR để tải lên Apple
#   bash scripts/appstore-signing.sh p12  ~/Downloads/distribution.cer    → ghép chứng chỉ Apple trả về thành .p12
#   bash scripts/appstore-signing.sh secrets                              → đưa các file vào GitHub Secrets (gh)
set -euo pipefail
DIR="$HOME/lanplayer-signing"
REPO="vanhau1303-hub/vlccustom-ios"
mkdir -p "$DIR"

case "${1:-}" in
  csr)
    EMAIL="${2:?email}"; NAME="${3:?ten}"
    openssl genrsa -out "$DIR/distribution.key" 2048
    openssl req -new -key "$DIR/distribution.key" -out "$DIR/distribution.csr" \
      -subj "/emailAddress=$EMAIL/CN=$NAME/C=VN"
    echo "Đã tạo $DIR/distribution.csr — tải file này lên developer.apple.com (Certificates → + → Apple Distribution)."
    ;;
  p12)
    CER="${2:?duong dan file .cer tai tu Apple}"
    openssl x509 -inform DER -in "$CER" -out "$DIR/distribution.pem"
    read -r -s -p "Đặt mật khẩu cho file .p12: " PASS; echo
    # -legacy: định dạng mà công cụ "security" của macOS (máy build của GitHub) đọc được.
    openssl pkcs12 -export -legacy -inkey "$DIR/distribution.key" -in "$DIR/distribution.pem" \
      -out "$DIR/distribution.p12" -passout "pass:$PASS"
    printf '%s' "$PASS" > "$DIR/p12-password.txt"
    echo "Đã tạo $DIR/distribution.p12"
    ;;
  secrets)
    command -v gh >/dev/null || { echo "Cần GitHub CLI (gh) đã đăng nhập."; exit 1; }
    need() { [ -f "$DIR/$1" ] || { echo "Thiếu $DIR/$1 — xem docs/APPSTORE-SETUP.md"; exit 1; }; }
    need distribution.p12; need p12-password.txt; need lanplayer.mobileprovision
    P8=$(ls "$DIR"/AuthKey_*.p8 2>/dev/null | head -1); [ -n "$P8" ] || { echo "Thiếu $DIR/AuthKey_XXXX.p8"; exit 1; }
    base64 -w0 "$DIR/distribution.p12" | gh secret set DIST_CERT_P12_BASE64 -R "$REPO"
    gh secret set DIST_CERT_PASSWORD -R "$REPO" < "$DIR/p12-password.txt"
    base64 -w0 "$DIR/lanplayer.mobileprovision" | gh secret set PROFILE_BASE64 -R "$REPO"
    base64 -w0 "$P8" | gh secret set ASC_KEY_P8_BASE64 -R "$REPO"
    KEY_ID=$(basename "$P8" .p8); KEY_ID="${KEY_ID#AuthKey_}"
    printf '%s' "$KEY_ID" | gh secret set ASC_KEY_ID -R "$REPO"
    read -r -p "Issuer ID (App Store Connect → Users and Access → Integrations): " ISSUER
    printf '%s' "$ISSUER" | gh secret set ASC_ISSUER_ID -R "$REPO"
    read -r -p "Team ID (developer.apple.com → Membership, 10 ký tự): " TEAM
    printf '%s' "$TEAM" | gh secret set TEAM_ID -R "$REPO"
    echo "Xong. Các khoá quảng cáo / OpenSubtitles: gh secret set ADMOB_APP_ID … (xem hướng dẫn)."
    ;;
  *)
    sed -n '2,8p' "$0"
    ;;
esac
