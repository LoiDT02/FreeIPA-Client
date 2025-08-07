#!/bin/bash

# ====== Load Config từ file .env ======
if [ -f .env ]; then
  echo "[INIT] Đang nạp cấu hình từ .env..."
  source .env
else
  echo "Không tìm thấy file .env. Thoát."
  exit 1
fi

# ====== Kiểm tra các biến bắt buộc ======
REQUIRED_VARS=("IPA_SERVER_IP" "IPA_SERVER" "IPA_DOMAIN" "IPA_REALM" "HOSTNAME_FQDN")
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var}" ]; then
    echo "Thiếu biến cấu hình: $var. Vui lòng kiểm tra file .env"
    exit 1
  fi
done

# ====== Nhập thông tin tài khoản ======
read -p "Nhập username FreeIPA admin: " IPA_ADMIN_USER
read -s -p "Nhập password FreeIPA admin: " IPA_ADMIN_PASS
echo ""

# ====== [0/6] Đặt hostname đầy đủ ======
echo "[0/6] Đặt hostname đầy đủ (FQDN)..."

# Đặt lại hostname
sudo hostnamectl set-hostname "$HOSTNAME_FQDN"

# Đảm bảo /etc/hosts có thông tin hostname đầy đủ
if ! grep -q "$HOSTNAME_FQDN" /etc/hosts; then
  echo "127.0.1.1 $HOSTNAME_FQDN" | sudo tee -a /etc/hosts
  echo "Đã thêm $HOSTNAME_FQDN vào /etc/hosts"
fi

# ====== [1/6] Cài gói cần thiết ======
echo "[1/6] Cài đặt gói cần thiết..."
sudo apt update
sudo apt install -y freeipa-client sssd libnss-sss libpam-sss oddjob-mkhomedir adcli realmd

# ====== [2/6] Kiểm tra và cấu hình DNS ======
echo "[2/6] Cấu hình DNS với systemd-resolved..."

# Kiểm tra nếu đang dùng systemd-resolved
if systemctl is-active --quiet systemd-resolved; then
  INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)
  echo "Đang cấu hình DNS cho interface: $INTERFACE"
  sudo resolvectl dns $INTERFACE 8.8.8.8 1.1.1.1
  sudo resolvectl domain $INTERFACE ~$IPA_DOMAIN
else
  echo "Không dùng systemd-resolved. Tạo /etc/resolv.conf thủ công nếu cần..."
  if [ ! -f /etc/resolv.conf ] || ! grep -q "nameserver" /etc/resolv.conf; then
    echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" | sudo tee /etc/resolv.conf > /dev/null
  fi
fi


# ====== [3/6] Kiểm tra DNS tên miền FreeIPA ======
echo "[3/6] Kiểm tra DNS tên miền FreeIPA..."
if ! host "$IPA_SERVER"; then
  echo "Đang thêm vào /etc/hosts..."
  if ! grep -q "$IPA_SERVER" /etc/hosts; then
    echo "$IPA_SERVER_IP $IPA_SERVER" | sudo tee -a /etc/hosts > /dev/null
    echo "Đã thêm $IPA_SERVER vào /etc/hosts"
  else
    echo "$IPA_SERVER đã tồn tại trong /etc/hosts"
  fi
fi

# ====== [4/6] Join vào domain FreeIPA ======
echo "[4/6] Join vào domain FreeIPA..."
sudo ipa-client-install \
  --domain=$IPA_DOMAIN \
  --server=$IPA_SERVER \
  --realm=$IPA_REALM \
  --principal=$IPA_ADMIN_USER \
  --password=$IPA_ADMIN_PASS \
  --mkhomedir \
  --force-ntpd \
  --unattended

# ====== [5/6] Bật tính năng tạo home directory khi user đăng nhập ======
echo "[5/6] Bật mkhomedir..."
sudo sed -i '/pam_mkhomedir.so/!b;n;c\session required pam_mkhomedir.so skel=/etc/skel umask=0022' /etc/pam.d/common-session

# ====== [6/6] Restart SSH ======
echo "[6/6] Restart SSH..."
sudo systemctl restart ssh

echo "Đã hoàn tất. Cài đặt FreeIPA Client thành công!"
