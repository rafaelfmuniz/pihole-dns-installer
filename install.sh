#!/usr/bin/env bash
set -Eeuo pipefail

# ===== utils =====
log() { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
err() { echo -e "\e[1;31m[x]\e[0m $*" >&2; }
pause() { read -rp "Pressione ENTER para continuar..."; }
cmd_exists() { command -v "$1" &>/dev/null; }

need_root() {
  if [[ $(id -u) -ne 0 ]]; then
    err "Execute como root."
    exit 1
  fi
}

# ===== pacotes mínimos =====
install_nettools() {
  log "Instalando pacotes mínimos (iproute2, net-tools, ipcalc, curl, ca-certificates, netcat)..."
  apt-get update -qq
  apt-get install -y iproute2 net-tools ipcalc curl ca-certificates netcat-traditional >/dev/null
}

# ===== detecção de rede =====
detect_net() {
  DEF_IF=$(ip -o -4 route show to default | awk '{print $5}' | head -1 || true)
  DEF_GW=$(ip -o -4 route show to default | awk '{print $3}' | head -1 || true)
  CUR_IP=$(ip -o -4 addr show dev "$DEF_IF" | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
  CIDR=$(ip -o -4 addr show dev "$DEF_IF" | awk '{print $4}' | head -1 || true)

  if cmd_exists ipcalc; then
    SUBNET_MASK=$(ipcalc "$CIDR" 2>/dev/null | awk -F= '/Netmask:/ {print $2}')
  fi
  [[ -z "${SUBNET_MASK:-}" ]] && SUBNET_MASK="255.255.255.0"

  log "Interface padrão: $DEF_IF"
  log "Gateway padrão:   $DEF_GW"
  log "IP atual:         $CUR_IP"
  log "Máscara:          ${SUBNET_MASK:-desconhecida}"

  if [[ -z "${CUR_IP:-}" || -z "${DEF_IF:-}" || -z "${DEF_GW:-}" ]]; then
    err "Não foi possível detectar rede automaticamente. Configure rede e execute novamente."
    exit 1
  fi
}

# ===== escolha de IP fixo =====
choose_static_ip() {
  echo
  log "Recomendação: usar IP FIXO (a instalação irá referenciar este IP)."
  read -rp "Deseja configurar IP fixo agora? [s/N]: " ANS
  ANS=${ANS:-N}
  if [[ "$ANS" =~ ^[sS]$ ]]; then
    local base
    base=$(echo "$CUR_IP" | awk -F. '{print $1"."$2"."$3}')
    read -rp "Informe o último octeto do IP (ex.: 110 para ${base}.110): " LAST
    [[ -z "$LAST" ]] && err "Valor vazio." && exit 1
    NEW_IP="${base}.${LAST}"
    read -rp "Confirme o IP fixo desejado [$NEW_IP] (ENTER para aceitar): " CONF
    [[ -n "${CONF:-}" ]] && NEW_IP="$CONF"

    read -rp "Informe o(s) DNS local(is) a publicar (ENTER para padrão): " PUBL_DNS || true
    [[ -z "${PUBL_DNS:-}" ]] && PUBL_DNS="1.1.1.1 8.8.8.8"

    if [[ -f /etc/network/interfaces ]]; then
      log "ifupdown detectado. Vou preparar bloco estático para $DEF_IF."
      INTERF=/etc/network/interfaces
      cp -a "$INTERF" "${INTERF}.bak.$(date +%s)"
      sed -i "/^auto $DEF_IF$/,/^$/d" "$INTERF"
      cat >>"$INTERF" <<EOF

auto $DEF_IF
iface $DEF_IF inet static
    address $NEW_IP
    netmask ${SUBNET_MASK:-255.255.255.0}
    gateway $DEF_GW
    dns-nameservers $PUBL_DNS
EOF
      systemctl restart networking || true
      ip addr flush dev "$DEF_IF" || true
      ifdown "$DEF_IF" || true
      ifup "$DEF_IF" || true
      CUR_IP="$NEW_IP"
      log "IP fixo aplicado via ifupdown: $CUR_IP"
    else
      warn "ifupdown não detectado. Pulei ajuste automático."
    fi
  else
    log "Mantendo IP atual (DHCP): $CUR_IP"
  fi
}

# ===== pacotes base =====
install_base() {
  log "Instalando pacotes base..."
  apt-get update -qq
  apt-get install -y curl wget git net-tools lsof bind9-dnsutils unzip tar golang iproute2 netcat-traditional pipx python3-venv unbound
}

# ===== Pi-hole =====
install_pihole() {
  log "Instalando Pi-hole (instalação interativa oficial)..."
  log "Durante a instalação você poderá definir DNS upstream, mas ajustaremos depois para Unbound (127.0.0.1#5335)."
  pause
  curl -sSL https://install.pi-hole.net | bash
}

# ===== Unbound =====
install_unbound() {
  log "Configurando Unbound (porta 5335, localhost)..."

  mkdir -p /var/lib/unbound
  wget -qO /var/lib/unbound/root.hints https://www.internic.net/domain/named.root

  cat >/etc/unbound/unbound.conf <<'EOF'
server:
    directory: "/etc/unbound"
include: "/etc/unbound/unbound.conf.d/*.conf"
EOF

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

  if ! unbound-checkconf; then
    err "Configuração inválida do Unbound."
    exit 1
  fi

  systemctl daemon-reexec
  systemctl enable --now unbound || {
    err "Unbound falhou ao iniciar. Logs:"
    journalctl -xeu unbound.service | tail -n 20
    exit 1
  }

  for i in {1..30}; do nc -z 127.0.0.1 5335 && break; sleep 1; done
  log "Teste Unbound (127.0.0.1#5335):"
  dig @127.0.0.1 -p 5335 openai.com +short || true
}

# ===== Ajuste Pi-hole para usar Unbound =====
configure_pihole_upstream() {
  log "Apontando Pi-hole para Unbound (127.0.0.1#5335)..."
  if [[ -f /etc/pihole/setupVars.conf ]]; then
    sed -i '/^PIHOLE_DNS_/d' /etc/pihole/setupVars.conf
    {
      echo "PIHOLE_DNS_1=127.0.0.1#5335"
      echo "PIHOLE_DNS_2="
    } >> /etc/pihole/setupVars.conf
  fi
  systemctl restart pihole-FTL
}

# ===== CoreDNS =====
install_coredns() {
  log "Instalando CoreDNS..."
  cd /opt
  local COREDNS_VER="1.11.3"
  curl -fsSL -o coredns.tgz "https://github.com/coredns/coredns/releases/download/v${COREDNS_VER}/coredns_${COREDNS_VER}_linux_amd64.tgz"
  tar -xzf coredns.tgz
  install -m 0755 coredns /usr/local/bin/coredns
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
Description=CoreDNS (listens on :8053)
After=network.target pihole-FTL.service unbound.service
Requires=pihole-FTL.service unbound.service

[Service]
ExecStart=/usr/local/bin/coredns -conf /etc/coredns/Corefile
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now coredns
}

# ===== DoH-proxy =====
install_doh_proxy() {
  log "Instalando DoH-proxy..."
  pipx install doh-proxy || true

  cat >/etc/systemd/system/doh-proxy.service <<EOF
[Unit]
Description=DoH HTTP Proxy
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

# ===== testes finais =====
final_tests() {
  echo
  log "Testes locais rápidos:"
  dig @127.0.0.1 -p 5335 openai.com +short || true
  dig @127.0.0.1 -p 53 openai.com +short || true
  dig @127.0.0.1 -p 8053 openai.com +short || true
  curl -s -H 'accept: application/dns-json' \
    "http://${CUR_IP}:8054/dns-query?name=openai.com&type=A" || true
}

# ===== instruções NPM =====
print_npm_instructions() {
cat <<EOF

============================================================
NPM (Nginx Proxy Manager) — CHECKLIST
============================================================
1) DoH → Proxy Host
   Domain: dns.seudominio.com
   Forward: ${CUR_IP}:8054 (/dns-query)
   SSL ativo
2) DoT → Stream
   Porta 853 → ${CUR_IP}:8053
   SSL com certificado do domínio
============================================================

EOF
}

# ===== main =====
need_root
install_nettools
detect_net
choose_static_ip
install_base
install_pihole
install_unbound
configure_pihole_upstream
install_coredns
install_doh_proxy
final_tests
print_npm_instructions
log "Concluído! Reboot recomendado."
