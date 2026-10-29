#!/bin/bash

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
    echo "[-] Lỗi: Vui lòng chạy script này với quyền sudo (sudo ./install.sh)"
    exit 1
fi

echo "=================================================="
echo "[*] BẮT ĐẦU CÀI ĐẶT HỆ THỐNG RELAY & GATEWAY LINUX"
echo "=================================================="

# 1. Quét và liệt kê danh sách card mạng kèm số thứ tự
echo "[+] Đang quét các card mạng vật lý có sẵn trên hệ thống..."
INTERFACES=($(ip -o link show | awk -F': ' '$2 != "lo" {print $2}'))
CARD_COUNT=${#INTERFACES[@]}

echo "Danh sách card mạng hiện có trên máy:"
for i in "${!INTERFACES[@]}"; do
    echo "  [$((i+1))] ${INTERFACES[$i]}"
done
echo "--------------------------------------------------"

if [ "$CARD_COUNT" -lt 3 ]; then
    echo "[!] CẢNH BÁO: Hệ thống phát hiện có ít hơn 3 card mạng (yêu cầu tối thiểu 3 card)."
    read -p "Bạn có muốn tiếp tục không? (y/n): " choice
    if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
        echo "[-] Hủy cài đặt."
        exit 1
    fi
fi

# 2. Chọn card bằng số thứ tự (tránh gõ sai tên dài)
echo "[+] GÁN VAI TRÒ CHO CÁC CARD MẠNG (Nhập số thứ tự tương ứng):"

while true; do
    read -p "Chọn số thứ tự cho card nội bộ (DrayTek): " idx_draytek
    if [[ "$idx_draytek" =~ ^[0-9]+$ ]] && [ "$idx_draytek" -ge 1 ] && [ "$idx_draytek" -le "$CARD_COUNT" ]; then
        CARD_DRAYTEK="${INTERFACES[$((idx_draytek-1))]}"
        break
    fi
    echo "[!] Lựa chọn không hợp lệ, vui lòng nhập lại số trong danh sách."
done

while true; do
    read -p "Chọn số thứ tự cho card kết nối máy Client: " idx_client
    if [[ "$idx_client" =~ ^[0-9]+$ ]] && [ "$idx_client" -ge 1 ] && [ "$idx_client" -le "$CARD_COUNT" ]; then
        CARD_CLIENT="${INTERFACES[$((idx_client-1))]}"
        break
    fi
    echo "[!] Lựa chọn không hợp lệ, vui lòng nhập lại số trong danh sách."
done

while true; do
    read -p "Chọn số thứ tự cho card kết nối Internet: " idx_internet
    if [[ "$idx_internet" =~ ^[0-9]+$ ]] && [ "$idx_internet" -ge 1 ] && [ "$idx_internet" -le "$CARD_COUNT" ]; then
        CARD_INTERNET="${INTERFACES[$((idx_internet-1))]}"
        break
    fi
    echo "[!] Lựa chọn không hợp lệ, vui lòng nhập lại số trong danh sách."
done

# 3. Nhập các thông số IP cấu hình
echo "--------------------------------------------------"
echo "[+] NHẬP CÁC THÔNG SỐ IP & GATEWAY:"
read -p "Nhập IP khai thác/nội bộ muốn gán (Ví dụ: 10.248.74.123): " TARGET_IP
read -p "Nhập địa chỉ IP Gateway muốn gán cho Bridge (Ví dụ: 10.248.74.255): " GW_ASSIGN
read -p "Nhập Gateway cấp trên (Default Gateway cao nhất, ví dụ: 10.248.74.150): " UPSTREAM_GW
read -p "Nhập dải IP quảng bá Subnet (Mặc định: 10.0.0.0/8): " SUBNET_ROUTE
SUBNET_ROUTE=${SUBNET_ROUTE:-10.0.0.0/8}

echo "--------------------------------------------------"
echo "[*] Tóm tắt cấu hình hệ thống:"
echo "    - Card DrayTek   : $CARD_DRAYTEK"
echo "    - Card Client    : $CARD_CLIENT"
echo "    - Card Internet  : $CARD_INTERNET"
echo "    - IP Khai thác   : $TARGET_IP"
echo "    - IP Gateway gán : $GW_ASSIGN"
echo "    - Upstream GW    : $UPSTREAM_GW"
echo "    - Subnet Route   : $SUBNET_ROUTE"
echo "--------------------------------------------------"
read -p "Các thông số trên đã chính xác chưa? Bấm Enter để tiếp tục thực thi hoặc Ctrl+C để hủy."

# 4. Cài đặt các gói phần mềm cần thiết
echo "[+] Đang cập nhật và cài đặt iproute2, iptables, dnsmasq..."
apt update && apt install -y iproute2 iptables dnsmasq tar > /dev/null 2>&1

# 5. Tạo Bridge br0
if ! ip link show br0 &>/dev/null; then
    echo "[+] Đang tạo interface bridge br0..."
    ip link add name br0 type bridge
    ip link set dev br0 up
else
    echo "[*] Bridge br0 đã tồn tại."
fi

# 6. Đưa các card mạng vào bridge br0
for dev in "$CARD_DRAYTEK" "$CARD_CLIENT" "$CARD_INTERNET"; do
    if ip link show "$dev" &>/dev/null; then
        echo "[+] Đưa card $dev vào br0..."
        ip link set dev "$dev" master br0 2>/dev/null || true
        ip link set dev "$dev" up
    else
        echo "[!] Không tìm thấy card $dev, bỏ qua bước gom bridge."
    fi
done

# 7. Gán IP Gateway vào bridge br0
echo "[+] Cấu hình IP Gateway ($GW_ASSIGN) và IP khai thác ($TARGET_IP) vào br0..."
ip addr add "$GW_ASSIGN/24" dev br0 2>/dev/null || true
ip addr add "$TARGET_IP/24" dev br0 2>/dev/null || true

# 8. Thiết lập Routing
echo "[+] Thiết lập tuyến đường (Routing) cho dải $SUBNET_ROUTE qua Gateway $UPSTREAM_GW..."
ip route add "$SUBNET_ROUTE" via "$UPSTREAM_GW" dev br0 2>/dev/null || true

# 9. Bật Kernel IP Forwarding và iptables NAT
echo "[+] Bật IP Forwarding và cấu hình iptables MASQUERADE..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null
iptables -A FORWARD -i br0 -o br0 -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -o br0 -j MASQUERADE

# 10. Tích hợp file backup trạng thái nếu có
if [ -f "./net-backup.sh" ]; then
    echo "[+] Đang cài đặt script backup vào /usr/local/bin/..."
    cp ./net-backup.sh /usr/local/bin/net-backup.sh
    chmod +x /usr/local/bin/net-backup.sh
fi

echo "=================================================="
echo "[+] HOÀN TẤT CÀI ĐẶT TOÀN BỘ HỆ THỐNG THÀNH CÔNG!"
echo "=================================================="
