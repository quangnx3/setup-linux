#!/usr/bin/env bash
# install.sh - Cai dat Server Linux (Mang tang hinh)

set -euo pipefail

RED='\e[1;31m'; GRN='\e[1;32m'; YEL='\e[1;33m'; CYN='\e[1;36m'; RST='\e[0m'
log()   { echo -e "${GRN}[+]${RST} $*"; }
warn()  { echo -e "${YEL}[!]${RST} $*"; }
err()   { echo -e "${RED}[x]${RST} $*" >&2; }
ask()   { local p="$1" d="${2:-}"; local v; read -r -p "${CYN}? ${p}${d:+ [$d]}: ${RST}" v; echo "${v:-$d}"; }

[[ $EUID -eq 0 ]] || { err "Phai chay bang quyen root (sudo)"; exit 1; }

BACKUP_DIR="/root/relay-backup/$(date +%Y%m%d-%H%M%S)"

# Ham tinh IP bang python de tranh loi bash
ip_offset() {
    python3 -c "
import ipaddress, sys
net = ipaddress.IPv4Network(sys.argv[1], strict=False)
ip = net.network_address + int(sys.argv[2])
print(str(ip))
" "$1" "$2"
}

clear
echo -e "${CYN}=== CAI DAT SERVER RELAY ===${RST}"
warn "Backup se duoc luu tai: ${BACKUP_DIR}"
read -r -p "${YEL}Nhan ENTER de tiep tuc...${RST}" _

# 1. QUET CARD MANG
echo -e "\n${CYN}--- BUOC 1: CHON CARD MANG ---${RST}"
IFACES=($(ip -o link show | awk -F': ' '{print $2}' | grep -Ev '^(lo|tailscale.*|docker.*|veth.*|br-.*|virbr.*|tun.*|tap.*)$' | grep -v "br0"))

for i in "${!IFACES[@]}"; do
    echo "  $((i+1)). ${IFACES[$i]} (MAC: $(cat /sys/class/net/${IFACES[$i]}/address))"
done

read -p "Chon STT card INTERNET (ra ngoai): " IDX_INET
IF_INET="${IFACES[$((IDX_INET-1))]}"

REMAINING=()
for ifc in "${IFACES[@]}"; do [[ "$ifc" != "$IF_INET" ]] && REMAINING+=("$ifc"); done

echo -e "\nCac card con lai:"
for i in "${!REMAINING[@]}"; do echo "  $((i+1)). ${REMAINING[$i]}"; done

read -p "Chon STT card noi toi CLIENT (Windows): " IDX_CLI
BR_MEM1="${REMAINING[$((IDX_CLI-1))]}"

REMAINING2=()
for ifc in "${REMAINING[@]}"; do [[ "$ifc" != "$BR_MEM1" ]] && REMAINING2+=("$ifc"); done

echo -e "\nCard cuoi cung:"
for i in "${!REMAINING2[@]}"; do echo "  $((i+1)). ${REMAINING2[$i]}"; done

read -p "Chon STT card noi toi GATEWAY: " IDX_GW
BR_MEM2="${REMAINING2[$((IDX_GW-1))]}"

log "INTERNET: $IF_INET | CLIENT: $BR_MEM1 | GATEWAY: $BR_MEM2"

# 2. THONG TIN MANG
echo -e "\n${CYN}--- BUOC 2: THONG TIN MANG ---${RST}"
CLIENT_CIDR=$(ask "Dai IP noi bo CIDR" "10.248.74.128/28")
PREFIX="${CLIENT_CIDR#*/}"
HC=$(python3 -c "import ipaddress; print(ipaddress.IPv4Network('$CLIENT_CIDR', strict=False).num_addresses - 2)")

CLIENT_IP=$(ask "IP cua may CLIENT (Windows)" "$(ip_offset "$CLIENT_CIDR" 1)")
SERVER_IP=$(ask "IP cua may SERVER LINUX" "$(ip_offset "$CLIENT_CIDR" 2)")
GATEWAY_IP=$(ask "IP cua GATEWAY noi bo" "$(ip_offset "$CLIENT_CIDR" 3)")
UPSTREAM_DNS=$(ask "IP upstream DNS noi bo" "10.30.95.34")
CLIENT_MAC=$(ask "MAC cua Client (VD: 00:23:09:75:2C:E4)")
DOMAINS_RAW=$(ask "Domain noi bo (cach nhau phay)" "viettelpost.vn,viettel.vn,viettelgroup.viettelad.com")

# Backup
mkdir -p "$BACKUP_DIR"
cp /etc/resolv.conf /etc/dnsmasq.conf /etc/iptables/rules.v4 /etc/netplan/*.yaml "$BACKUP_DIR/" 2>/dev/null || true
cp -r /etc/netplan "$BACKUP_DIR/netplan-bak" 2>/dev/null || true

# 3. CAI DAT PACKAGE
echo -e "\n${CYN}--- BUOC 3: CAI DAT PACKAGE ---${RST}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y dnsmasq netfilter-persistent iptables-persistent curl nano iproute2 python3 bridge-utils net-tools

# 4. CAU HINH NETPLAN (BRIDGE)
echo -e "\n${CYN}--- BUOC 4: CAU HINH BRIDGE ---${RST}"
rm -f /etc/netplan/*.yaml
cat > /etc/netplan/99-relay.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $IF_INET:
      dhcp4: true
    $BR_MEM1:
      dhcp4: false
    $BR_MEM2:
      dhcp4: false
  bridges:
    br0:
      interfaces: [$BR_MEM1, $BR_MEM2]
      addresses: [$SERVER_IP/$PREFIX]
      parameters:
        stp: false
        forward-delay: 0
EOF
chmod 600 /etc/netplan/99-relay.yaml
netplan apply
sleep 3
log "Card br0 da co IP $SERVER_IP"

# 5. IP FORWARDING & DNS RESOLV
echo -e "\n${CYN}--- BUOC 5: CAU HINH SYSCTL & DNS ---${RST}"
cat > /etc/sysctl.d/99-forward.conf <<EOF
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null

systemctl disable --now systemd-resolved 2>/dev/null || true
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<EOF
nameserver $SERVER_IP
nameserver $CLIENT_IP
nameserver 8.8.8.8
EOF
chattr +i /etc/resolv.conf 2>/dev/null || true

# 6. DNSMASQ
echo -e "\n${CYN}--- BUOC 6: CAU HINH DNSMASQ ---${RST}"
{
    echo "listen-address=$SERVER_IP"
    echo "bind-interfaces"
    IFS=',' read -ra DOMAINS <<< "$DOMAINS_RAW"
    for d in "${DOMAINS[@]}"; do echo "server=/${d// /}/$CLIENT_IP"; done
    echo "server=/10.in-addr.arpa/$CLIENT_IP"
    echo "server=1.1.1.1"
    echo "server=8.8.8.8"
    echo "log-queries"
    echo "log-facility=/var/log/dnsmasq.log"
} > /etc/dnsmasq.conf

systemctl enable dnsmasq
systemctl restart dnsmasq
sleep 1

# 7. STATIC ROUTE
echo -e "\n${CYN}--- BUOC 7: STATIC ROUTE ---${RST}"
cat > /etc/systemd/system/add-route.service <<EOF
[Unit]
Description=Route to internal network
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip route replace 10.0.0.0/8 via $CLIENT_IP dev br0
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now add-route.service

# 8. IPTABLES
echo -e "\n${CYN}--- BUOC 8: IPTABLES ---${RST}"
iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -o br0 -j MASQUERADE

iptables -F INPUT
iptables -P INPUT DROP
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -i tailscale0 -j ACCEPT
iptables -A INPUT -s $CLIENT_CIDR -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -P FORWARD ACCEPT

netfilter-persistent save
log "Da luu IPTABLES"

# 9. TAILSCALE
echo -e "\n${CYN}--- BUOC 9: TAILSCALE ---${RST}"
if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi
log "Chay lenh sau de login Tailscale (neu chua):"
echo -e "${YEL}sudo tailscale up --advertise-routes=10.0.0.0/8 --accept-routes --hostname=relay-03${RST}"

echo -e "\n${GRN}=== HOAN TAT CAI DAT SERVER ===${RST}"