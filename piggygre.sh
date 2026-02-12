#!/usr/bin/env bash
set -euo pipefail

GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; NC="\033[0m"

SERVICE_NAME="piggy-gre1.service"
CONF_DIR="/etc/piggy"
CONF_FILE="/etc/piggy/gre1.conf"
SYSCTL_FILE="/etc/sysctl.d/99-piggy-gre.conf"
UP_SCRIPT="/usr/local/sbin/piggy-gre-up"
DOWN_SCRIPT="/usr/local/sbin/piggy-gre-down"
UNIT_FILE="/etc/systemd/system/piggy-gre1.service"
TUN_NAME="gre1"

# --- NEW: CLI command installer ---
INSTALL_SCRIPT_PATH="/usr/local/sbin/piggygre-manager"
CLI_CMD="/usr/local/bin/piggygre"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}✗ لطفاً با root اجرا کن (sudo -i)${NC}"
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

install_prereqs() {
  echo -e "${YELLOW}[*] نصب/بررسی پیش‌نیازها...${NC}"
  apt-get update -y >/dev/null
  apt-get install -y iproute2 kmod coreutils >/dev/null
  modprobe ip_gre 2>/dev/null || true
  modprobe gre 2>/dev/null || true
  echo -e "${GREEN}[+] پیش‌نیازها OK${NC}"
}

read_nonempty() {
  local prompt="$1"
  local var=""
  while true; do
    read -r -p "$prompt" var
    var="${var// /}"
    [[ -n "$var" ]] && { echo "$var"; return 0; }
    echo "خالی نباشه."
  done
}

ask_yes_no() {
  local prompt="$1"
  local ans=""
  while true; do
    read -r -p "$prompt (y/n): " ans
    ans="${ans,,}"
    [[ "$ans" == "y" || "$ans" == "yes" ]] && { echo "y"; return 0; }
    [[ "$ans" == "n" || "$ans" == "no" ]] && { echo "n"; return 0; }
  done
}

apply_sysctl() {
  echo -e "${YELLOW}[*] اعمال sysctl (rp_filter off + ip_forward)...${NC}"
  cat >"$SYSCTL_FILE" <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
  sysctl --system >/dev/null || true
  echo -e "${GREEN}[+] sysctl اعمال شد${NC}"
}

bring_down_tunnel() {
  if ip link show "$TUN_NAME" >/dev/null 2>&1; then
    ip link set "$TUN_NAME" down || true
    ip tunnel del "$TUN_NAME" || true
  fi
}

gen_auto_subnet_30() {
  local a="$1" b="$2" s=""
  if [[ "$a" < "$b" ]]; then s="${a}|${b}"; else s="${b}|${a}"; fi

  local hex
  hex="$(printf "%s" "$s" | sha256sum | awk '{print $1}')"

  local bx="${hex:0:2}" by="${hex:2:2}" bz="${hex:4:2}"
  local x=$((16#$bx)) y=$((16#$by)) z=$((16#$bz))

  x=$(( (x % 254) + 1 ))
  y=$(( (y % 254) + 1 ))
  z=$(( (z % 252) ))
  z=$(( (z / 4) * 4 ))

  echo "10.${x}.${y}.${z}"
}

create_gre() {
  local LOCAL_PUBLIC="$1" REMOTE_PUBLIC="$2" LOCAL_TUN_CIDR="$3"

  bring_down_tunnel

  echo -e "${YELLOW}[*] ساخت GRE: local=${LOCAL_PUBLIC}  remote=${REMOTE_PUBLIC}${NC}"
  ip tunnel add "$TUN_NAME" mode gre local "${LOCAL_PUBLIC}" remote "${REMOTE_PUBLIC}" ttl 255
  ip link set "$TUN_NAME" up
  ip addr add "${LOCAL_TUN_CIDR}" dev "$TUN_NAME"
  echo -e "${GREEN}[+] GRE ساخته شد و IP ست شد روی ${TUN_NAME}${NC}"
}

add_routes_interactive() {
  local add_routes
  add_routes="$(ask_yes_no "می‌خوای Route هم اضافه کنم؟")"
  [[ "$add_routes" == "n" ]] && return 0

  echo -e "${YELLOW}مثال: 192.168.50.0/24 یا 1.1.1.1/32 (برای پایان: done)${NC}"
  while true; do
    local route_cidr
    route_cidr="$(read_nonempty "CIDR مقصد (یا done): ")"
    [[ "${route_cidr,,}" == "done" ]] && break
    ip route replace "${route_cidr}" dev "$TUN_NAME"
    echo -e "${GREEN}[+] route اضافه شد: ${route_cidr} -> ${TUN_NAME}${NC}"
  done
}

save_config() {
  local ROLE="$1" LOCAL_PUBLIC="$2" REMOTE_PUBLIC="$3" BASE_NET="$4" LOCAL_CIDR="$5"
  mkdir -p "$CONF_DIR"
  cat >"$CONF_FILE" <<EOF
ROLE="${ROLE}"
LOCAL_PUBLIC="${LOCAL_PUBLIC}"
REMOTE_PUBLIC="${REMOTE_PUBLIC}"
BASE_NET="${BASE_NET}"
TUN_LOCAL_CIDR="${LOCAL_CIDR}"
EOF
  echo -e "${GREEN}[+] کانفیگ ذخیره شد: ${CONF_FILE}${NC}"
}

create_systemd_service() {
  cat >"$UP_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/piggy/gre1.conf"
[[ -f "$CONF" ]] || { echo "Missing $CONF"; exit 1; }

# shellcheck disable=SC1090
source "$CONF"

modprobe ip_gre 2>/dev/null || true
modprobe gre 2>/dev/null || true

cat >/etc/sysctl.d/99-piggy-gre.conf <<'EOT'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOT
sysctl --system >/dev/null || true

if ip link show gre1 >/dev/null 2>&1; then
  ip link set gre1 down || true
  ip tunnel del gre1 || true
fi

ip tunnel add gre1 mode gre local "${LOCAL_PUBLIC}" remote "${REMOTE_PUBLIC}" ttl 255
ip link set gre1 up
ip addr add "${TUN_LOCAL_CIDR}" dev gre1
EOF

  cat >"$DOWN_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if ip link show gre1 >/dev/null 2>&1; then
  ip link set gre1 down || true
  ip tunnel del gre1 || true
fi
EOF

  chmod +x "$UP_SCRIPT" "$DOWN_SCRIPT"

  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Piggy GRE Tunnel gre1
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${UP_SCRIPT}
ExecStop=${DOWN_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
  systemctl restart "$SERVICE_NAME"
  echo -e "${GREEN}[+] سرویس فعال شد: ${SERVICE_NAME}${NC}"
}

show_status() {
  echo -e "${YELLOW}[*] Service status:${NC}"
  systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1 && echo "enabled: yes" || echo "enabled: no"
  systemctl is-active  "$SERVICE_NAME" >/dev/null 2>&1 && echo "active:  yes" || echo "active:  no"
  echo

  if ip link show "$TUN_NAME" >/dev/null 2>&1; then
    echo -e "${YELLOW}[*] Tunnel interface:${NC}"
    ip link show "$TUN_NAME" | sed 's/^/  /'
    echo -e "${YELLOW}[*] Tunnel IP:${NC}"
    ip -br addr show "$TUN_NAME" | sed 's/^/  /'
  else
    echo -e "${RED}[-] ${TUN_NAME} وجود ندارد.${NC}"
  fi

  if [[ -f "$CONF_FILE" ]]; then
    echo
    echo -e "${YELLOW}[*] Saved config:${NC} ${CONF_FILE}"
    cat "$CONF_FILE" | sed 's/^/  /'
  fi

  echo
  if [[ -x "$CLI_CMD" ]]; then
    echo -e "${GREEN}[+] Command installed:${NC} piggygre"
  else
    echo -e "${YELLOW}[*] Command not installed yet.${NC}"
  fi
}

# --- NEW: self install so `piggygre` command exists ---
install_cli_command() {
  # copy script to a fixed path (so wrapper can call it)
  local self_path
  self_path="$(realpath "$0" 2>/dev/null || echo "$0")"

  mkdir -p "$(dirname "$INSTALL_SCRIPT_PATH")"

  if [[ "$self_path" != "$INSTALL_SCRIPT_PATH" ]]; then
    cp -f "$self_path" "$INSTALL_SCRIPT_PATH"
    chmod +x "$INSTALL_SCRIPT_PATH"
  else
    chmod +x "$INSTALL_SCRIPT_PATH" || true
  fi

  mkdir -p "$(dirname "$CLI_CMD")"
  cat >"$CLI_CMD" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${EUID}" -ne 0 ]]; then
  exec sudo bash "$INSTALL_SCRIPT_PATH"
else
  exec bash "$INSTALL_SCRIPT_PATH"
fi
EOF
  chmod +x "$CLI_CMD"

  echo -e "${GREEN}[+] دستور ساخته شد: ${NC}piggygre"
  echo -e "${YELLOW}از این به بعد می‌تونی فقط بنویسی:${NC} piggygre"
}

full_remove() {
  echo -e "${RED}⚠️ حذف کامل: تونل + IP لوکال + سرویس + فایل‌ها پاک می‌شود.${NC}"
  local ok
  ok="$(ask_yes_no "مطمئنی؟")"
  [[ "$ok" == "n" ]] && { echo "لغو شد."; return 0; }

  # Stop/disable service
  systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true

  # Remove interface (this removes the local tunnel IP too)
  bring_down_tunnel

  # Remove files
  rm -f "$UNIT_FILE" "$UP_SCRIPT" "$DOWN_SCRIPT" "$SYSCTL_FILE" "$CONF_FILE" >/dev/null 2>&1 || true

  # Remove CLI command + installed script
  rm -f "$CLI_CMD" "$INSTALL_SCRIPT_PATH" >/dev/null 2>&1 || true

  # Keep /etc/piggy dir only if empty
  rmdir "$CONF_DIR" >/dev/null 2>&1 || true

  systemctl daemon-reload || true
  sysctl --system >/dev/null || true

  echo -e "${GREEN}[✓] حذف کامل انجام شد. (gre1 و IP لوکال هم حذف شد)${NC}"
}

setup_gre() {
  install_prereqs

  echo
  echo "روی کدوم سرور هستی؟"
  echo "1) سرور ایران (IP داخل تونل = .1)"
  echo "2) سرور خارج (IP داخل تونل = .2)"
  local choice=""
  while true; do
    read -r -p "انتخاب (1/2): " choice
    [[ "$choice" == "1" || "$choice" == "2" ]] && break
  done

  local ROLE="IRAN"
  [[ "$choice" == "2" ]] && ROLE="FOREIGN"

  echo
  local LOCAL_PUBLIC
  LOCAL_PUBLIC="$(read_nonempty "LOCAL public IP (IP عمومی همین سرور): ")"

  local REMOTE_PUBLIC
  REMOTE_PUBLIC="$(read_nonempty "REMOTE public IP (IP عمومی سرور مقابل): ")"

  apply_sysctl

  local BASE_NET
  BASE_NET="$(gen_auto_subnet_30 "$LOCAL_PUBLIC" "$REMOTE_PUBLIC")"

  local LOCAL_TUN_IP="" PEER_TUN_IP=""
  if [[ "$ROLE" == "IRAN" ]]; then
    LOCAL_TUN_IP="${BASE_NET%.*}.1"
    PEER_TUN_IP="${BASE_NET%.*}.2"
  else
    LOCAL_TUN_IP="${BASE_NET%.*}.2"
    PEER_TUN_IP="${BASE_NET%.*}.1"
  fi

  local LOCAL_CIDR="${LOCAL_TUN_IP}/30"

  echo
  echo -e "${GREEN}[AUTO] subnet تونل: ${BASE_NET}/30${NC}"
  echo -e "${GREEN}[AUTO] IP این سرور داخل تونل: ${LOCAL_TUN_IP}/30${NC}"
  echo -e "${GREEN}[AUTO] IP سرور مقابل داخل تونل: ${PEER_TUN_IP}${NC}"

  create_gre "$LOCAL_PUBLIC" "$REMOTE_PUBLIC" "$LOCAL_CIDR"
  add_routes_interactive

  save_config "$ROLE" "$LOCAL_PUBLIC" "$REMOTE_PUBLIC" "$BASE_NET" "$LOCAL_CIDR"
  create_systemd_service

  echo
  echo -e "${YELLOW}[*] تست:${NC} ping -c 3 ${PEER_TUN_IP}"
  echo -e "${YELLOW}[*] اگر لگ/پکت‌لاس داشتی MTU رو کم کن:${NC} ip link set gre1 mtu 1400"
}

menu() {
  while true; do
    echo
    echo -e "${GREEN}=== PIGGY GRE MANAGER ===${NC}"
    echo "1) Setup / Reconfigure GRE (auto IP)"
    echo "2) Status (show gre1 + IP)"
    echo -e "${RED}3) Full Remove (delete everything)${NC}"
    echo "4) Exit"
    read -r -p "Choose [1-4]: " c
    case "$c" in
      1) setup_gre ;;
      2) show_status ;;
      3) full_remove ;;
      4) exit 0 ;;
      *) echo "Invalid." ;;
    esac
  done
}

need_root
install_cli_command
menu
