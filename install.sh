
```bash
#!/usr/bin/env bash
set -Eeuo pipefail

# ===============================
# Utilities
# ===============================
log()   { echo -e "\e[1;32m[+]\e[0m $*"; }
warn()  { echo -e "\e[1;33m[!]\e[0m $*"; }
err()   { echo -e "\e[1;31m[x]\e[0m $*" >&2; }
pause() { read -rp "➡️ Press ENTER to continue..."; }

# Spinner for long-running commands
spinner() {
  local pid=$!
  local delay=0.1
  local spinstr='|/-\'
  while ps -p $pid &>/dev/null; do
    local temp=${spinstr#?}
    printf " [%c]  " "$spinstr"
    spinstr=$temp${spinstr%"$temp"}
    sleep $delay
    printf "\b\b\b\b\b\b"
  done
}

need_root() {
  if [[ $(id -u) -ne 0 ]]; then
    err "Please run as root."
    exit 1
  fi
}

cmd_exists() { command -v "$1" &>/dev/null; }

# ===============================
# Session -1 — Initial verification
# ===============================
session_precheck() {
  if [[ -d /etc/pihole || -d /etc/unbound || -f /usr/local/bin/coredns ]]; then
    warn "🚨 Existing installation detected!"
    echo "What would you like to do?"
    echo "1) Reinstall (remove everything and fresh install)"
    echo "2) Update packages (keep configurations)"
    echo "3) Cancel"
    read -rp "Choose [1/2/3]: " CHOICE
    case "$CHOICE" in
      1)
        log "Removing previous installation..."
        systemctl stop pihole-FTL unbound coredns doh-proxy 2>/dev/null || true
        apt-get purge -y pihole unbound >/dev/null 2>&1 || true
        rm -rf /etc/pihole /etc/unbound /etc/coredns /opt/coredns /usr/local/bin/coredns
        rm -f /etc/systemd/system/{pihole-FTL.service,coredns.service,doh-proxy.service}
        systemctl daemon-reload
        log "Previous installation removed. Continuing..."
        ;;
      2)
        log "Updating packages..."
        apt-get update -qq && apt-get upgrade -y
        log "Update completed. Exiting."
        exit 0
        ;;
      3|*) log "Aborted."; exit 0 ;;
    esac
  fi
}

# ===============================
# Session 0 — Minimal preparation
# ===============================
session0_prep() {
  log "Session 0: Installing minimal packages (network and utilities)..."
  (apt-get update -qq && apt-get install -y iproute2 net-tools ipcalc curl ca-certificates netcat-traditional >/dev/null) &
  spinner
}

# ===============================
# Session 1 — Network detection
# ===============================
session1_net() {
  log "Session 1: Detecting network..."

  DEF_IF=$(ip -o -4 route show to default | awk '{print $5}' | head -1 || true)
  DEF_GW=$(ip -o -4 route show to default | awk '{print $3}' | head -1 || true)
  CUR_IP=$(ip -o -4 addr show dev "$DEF_IF" | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
  CIDR=$(ip -o -4 addr show dev "$DEF_IF" | awk '{print $4}' | head -1 || true)

  if cmd_exists ipcalc; then
    SUBNET_MASK=$(ipcalc "$CIDR" 2>/dev/null | awk -F= '/NETMASK/{print $2}')
  fi
  [[ -z "${SUBNET_MASK:-}" ]] && SUBNET_MASK="255.255.255.0"

  echo
  log "Interface: $DEF_IF"
  log "Gateway:   $DEF_GW"
  log "Current IP: $CUR_IP"
  log "Subnet Mask: $SUBNET_MASK"
  echo
  warn "⚠️ This IP ($CUR_IP) must be STATIC for the environment to work correctly."
  warn "➡️ Configure a static IP manually on your host/VM/container before proceeding."
  pause
}

# ===============================
# Session 2 — Base installation
# ===============================
session2_base() {
  log "Session 2: Installing base packages (compilers, libs, Python, Go, etc)..."
  (apt-get install -y curl wget git lsof bind9-dnsutils unzip tar golang \
    iproute2 netcat-traditional pipx python3-venv >/dev/null) &
  spinner
}

# ===============================
# Session 3 — Pi-hole installation
# ===============================
session3_pihole() {
  log "Session 3: Installing Pi-hole..."
  echo
  warn "⚠️ IMPORTANT:"
  echo "During Pi-hole installation, choose:"
  echo "   → Upstream DNS Providers → 'Custom'"
  echo "   → Enter: 127.0.0.1#5335"
  echo
  pause
  curl -sSL https://install.pi-hole.net | bash
}

# ===============================
# Session 4 — Unbound installation
# ===============================
session4_unbound() {
  log "Session 4: Installing and configuring Unbound..."
  (apt-get install -y unbound >/dev/null) &
  spinner

  install -d -m 0755 /etc/unbound/unbound.conf.d
  cat >/etc/unbound/unbound.conf.d/pi-hole.conf <<'EOF'
server:
    verbosity: 1
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    root-hints: "/var/lib/unbound/root.hints"
    harden-glue: yes
    harden-dnssec-stripped: yes
    qname-minimisation: yes
    prefetch: yes
    hide-identity: yes
    hide-version: yes
    edns-buffer-size: 1232
    cache-min-ttl: 240
    cache-max-ttl: 86400
EOF

  mkdir -p /var/lib/unbound
  wget -qO /var/lib/unbound/root.hints https://www.internic.net/domain/named.root || true
  systemctl enable --now unbound
  log "➡️ Testing Unbound..."
  dig @127.0.0.1 -p 5335 openai.com +short || true
}

# ===============================
# Session 5 — Pi-hole to Unbound integration
# ===============================
session5_pihole_conf() {
  log "Session 5: Configuring Pi-hole to use Unbound..."
  if [[ -f /etc/pihole/setupVars.conf ]]; then
    sed -i '/^PIHOLE_DNS_/d' /etc/pihole/setupVars.conf
    {
      echo "PIHOLE_DNS_1=127.0.0.1#5335"
      echo "PIHOLE_DNS_2="
    } >> /etc/pihole/setupVars.conf
  fi
  systemctl restart pihole-FTL
}

# ===============================
# Session 6 — CoreDNS installation
# ===============================
session6_coredns() {
  log "Session 6: Installing CoreDNS..."
  (cd /opt && \
    curl -fsSL -o coredns.tgz "https://github.com/coredns/coredns/releases/download/v1.11.3/coredns_1.11.3_linux_amd64.tgz" && \
    tar -xzf coredns.tgz && \
    install -m 0755 coredns /usr/local/bin/coredns) &
  spinner

  mkdir -p /etc/coredns
  cat >/etc/coredns/Corefile <<'EOF'
.:8053 {
    errors
    log
    cache 512
    forward . 127.0.0.1:53
}
EOF

  cat >/etc/systemd/system/coredns.service <<'EOF'
[Unit]
Description=CoreDNS (port 8053)
After=network.target pihole-FTL.service unbound.service
Requires=pihole-FTL.service unbound.service

[Service]
ExecStart=/usr/local/bin/coredns -conf /etc/coredns/Corefile
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now coredns
}

# ===============================
# Session 7 — DoH-proxy installation
# ===============================
session7_doh() {
  log "Session 7: Installing DoH-proxy..."
  (pipx install doh-proxy >/dev/null || true) &
  spinner

  cat >/etc/systemd/system/doh-proxy.service <<EOF
[Unit]
Description=DoH Proxy (:8054)
After=network.target pihole-FTL.service unbound.service
Requires=pihole-FTL.service unbound.service

[Service]
ExecStart=/root/.local/bin/doh-httpproxy \\
  --listen-address=${CUR_IP} \\
  --port=8054 \\
  --uri=/dns-query \\
  --upstream-resolver=127.0.0.1 \\
  --upstream-port=53
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now doh-proxy
}

# ===============================
# Session 8 — Final tests
# ===============================
session8_tests() {
  log "Session 8: Running local validation tests"
  echo "Unbound → "; dig @127.0.0.1 -p 5335 openai.com +short || true
  echo "Pi-hole → "; dig @127.0.0.1 -p 53 openai.com +short || true
  echo "CoreDNS → "; dig @127.0.0.1 -p 8053 openai.com +short || true
  echo "DoH-proxy → "; curl -s -H 'accept: application/dns-json' "http://${CUR_IP}:8054/dns-query?name=openai.com&type=A" || true
}

# ===============================
# Session 9 — Pi-hole password
# ===============================
session9_password() {
  read -rp "Do you want to change the Pi-hole admin password now? [y/N]: " ANS
  ANS=${ANS:-N}
  if [[ "$ANS" =~ ^[yY]$ ]]; then
    read -rp "Enter new password: " NEWPASS
    pihole setpassword "$NEWPASS"
    log "Pi-hole password changed successfully."
  else
    log "Keeping automatically generated Pi-hole password."
  fi
}

# ===============================
# Final session — NPM instructions
# ===============================
final_msg() {
  echo
  log "✅ Installation completed!"
  echo "============================================================"
  echo " Detected IP: $CUR_IP"
  echo
  echo "➡️ Now configure Nginx Proxy Manager (NPM):"
  echo
  echo "1) DoH (DNS-over-HTTPS)"
  echo "   - Go to Proxy Hosts → Add Proxy Host"
  echo "   - Domain Names: YOUR_DOMAIN (e.g.: dns.yoursite.com)"
  echo "   - Scheme: http"
  echo "   - Forward Host/IP: $CUR_IP"
  echo "   - Forward Port: 8054"
  echo "   - Path: /dns-query"
  echo "   - SSL: Enable and select Let's Encrypt certificate"
  echo "   - Force SSL: ON"
  echo
  echo "2) DoT (DNS-over-TLS)"
  echo "   - Go to Streams → Add Stream"
  echo "   - Incoming port: 853"
  echo "   - Forward Host: $CUR_IP"
  echo "   - Forward Port: 8053"
  echo "   - SSL Certificate: select same domain"
  echo
  echo "3) External tests:"
  echo "   - DoH: kdig @dns.yoursite.com +https=/dns-query openai.com"
  echo "   - DoT: kdig @dns.yoursite.com -p 853 +tls +tls-hostname=dns.yoursite.com openai.com"
  echo
  echo "💡 On Android/iOS phones → configure private DNS with your domain (DoT)."
  echo "💡 In browsers/Apps → configure https://dns.yoursite.com/dns-query as DoH."
  echo "============================================================"
}

# ===============================
# Main execution
# ===============================
main() {
  need_root
  session_precheck
  session0_prep
  session1_net
  session2_base
  session3_pihole
  session4_unbound
  session5_pihole_conf
  session6_coredns
  session7_doh
  session8_tests
  session9_password
  final_msg
}

# Run main function
main "$@"
