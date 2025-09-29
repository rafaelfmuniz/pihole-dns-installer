#!/usr/bin/env bash
set -Eeuo pipefail

# ===== util =====
log() { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
err() { echo -e "\e[1;31m[x]\e[0m $*" >&2; }
pause() { read -rp "Pressione ENTER para continuar..."; }

need_root() {
  if [[ $(id -u) -ne 0 ]]; then
    err "Execute como root."
    exit 1
  fi
}

cmd_exists() { command -v "$1" &>/dev/null; }

# ===== pacotes mínimos =====
install_nettools() {
  log "Instalando pacotes mínimos (iproute2, net-tools, ipcalc, curl, ca-certificates, netcat)..."
  apt-get update -qq
  apt-get install -y iproute2 net-tools ipcalc curl ca-certificates netcat-traditional >/dev/null || true
}

# ===== detecção de rede =====
detect_net() {
  DEF_IF=$(ip -o -4 route show to default | awk '{print $5}' | head -1 || true)
  DEF_GW=$(ip -o -4 route show to default | awk '{print $3}' | head -1 || true)
  CUR_IP=$(ip -o -4 addr show dev "$DEF_IF" | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
  CIDR=$(ip -o -4 addr show dev "$DEF_IF" | awk '{print $4}' | head -1 || true)

  # Pega prefixo e converte para máscara
  PREFIX=$(echo "$CIDR" | cut -d/ -f2)
  case $PREFIX in
    8)   SUBNET_MASK="255.0.0.0" ;;
    16)  SUBNET_MASK="255.255.0.0" ;;
    24)  SUBNET_MASK="255.255.255.0" ;;
    32)  SUBNET_MASK="255.255.255.255" ;;
    *)   SUBNET_MASK="255.255.255.0" ;;
  esac

  log "Interface padrão: $DEF_IF"
  log "Gateway padrão:   $DEF_GW"
  log "IP atual:         $CUR_IP"
  log "Máscara:          $SUBNET_MASK"

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

    if cmd_exists nmcli; then
      log "NetworkManager detectado. Ajustando IP fixo via nmcli..."
      CONN=$(nmcli -t -f NAME con show --active | head -1)
      nmcli con mod "$CONN" ipv4.method manual ipv4.addresses "${NEW_IP}/24" ipv4.gateway "$DEF_GW" ipv4.dns "$PUBL_DNS"
      nmcli con down "$CONN" || true
      nmcli con up "$CONN"
      CUR_IP="$NEW_IP"
      log "IP fixo aplicado via NetworkManager: $CUR_IP"
    elif [[ -f /etc/network/interfaces ]]; then
      log "ifupdown detectado. Vou preparar bloco estático para $DEF_IF."
      INTERF=/etc/network/interfaces
      cp -a "$INTERF" "${INTERF}.bak.$(date +%s)"
      sed -i "/^auto $DEF_IF$/,/^$/d" "$INTERF"
      cat >>"$INTERF" <<EOF

auto $DEF_IF
iface $DEF_IF inet static
    address $NEW_IP
    netmask $SUBNET_MASK
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
      warn "Nem NetworkManager nem ifupdown detectados. Pulei ajuste automático."
    fi
  else
    log "Mantendo IP atual (DHCP): $CUR_IP"
  fi
}

# ===== pacotes base =====
install_base() {
  log "Instalando pacotes base..."
  apt update -qq
  apt install -y curl wget git net-tools lsof bind9-dnsutils unzip tar golang iproute2 netcat-traditional pipx python3-venv unbound
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
  log "Instalando e configurando Unbound (porta 5335, localhost)..."

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

  # aguarda socket 5335
  for i in {1..30}; do nc -z 127.0.0.1 5335 && break; sleep 1; done

  log "Teste Unbound (127.0.0.1#5335):"
  dig @127.0.0.1 -p 5335 openai.com +timeout=2 +short || true
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

  systemctl daemon-reload
  systemctl enable --now pihole-FTL
  systemctl restart pihole-FTL

  # aguarda porta 53 responder
  for i in {1..30}; do nc -z 127.0.0.1 53 && break; sleep 1; done

  log "Teste Pi-hole (127.0.0.1#53):"
  dig @127.0.0.1 -p 53 openai.com +timeout=2 +short || true
}

# ===== CoreDNS (ouvindo em :8053) =====
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
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now coredns

  for i in {1..30}; do nc -z 127.0.0.1 8053 && break; sleep 1; done
}

# ===== DoH-Proxy (aiohttp) porta interna 8054 =====
install_doh_proxy() {
  log "Instalando DoH-proxy..."
  pipx install doh-proxy || true

  cat >/etc/systemd/system/doh-proxy.service <<EOF
[Unit]
Description=DoH HTTP Proxy (para NPM -> /dns-query)
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
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now doh-proxy

  for i in {1..30}; do nc -z "$CUR_IP" 8054 && break; sleep 1; done

  log "Teste DoH-proxy local:"
  curl -s -H 'accept: application/dns-json' \
    "http://${CUR_IP}:8054/dns-query?name=openai.com&type=A" || true
}

# ===== testes finais =====
final_tests() {
  echo
  log "Testes locais rápidos:"
  echo "1) Unbound: dig @127.0.0.1 -p 5335 openai.com +short"
  dig @127.0.0.1 -p 5335 openai.com +short || true
  echo
  echo "2) Pi-hole: dig @127.0.0.1 -p 53 openai.com +short"
  dig @127.0.0.1 -p 53 openai.com +short || true
  echo
  echo "3) CoreDNS (TCP/UDP :8053): dig @127.0.0.1 -p 8053 openai.com +short"
  dig @127.0.0.1 -p 8053 openai.com +short || true
  echo
  echo "4) DoH proxy HTTP (8054):"
  curl -s -H 'accept: application/dns-json' \
    "http://${CUR_IP}:8054/dns-query?name=openai.com&type=A" || true
  echo
}

# ===== instruções NPM =====
print_npm_instructions() {
cat <<EOF

============================================================
NPM (Nginx Proxy Manager) — CHECKLIST
============================================================

1) Certificado (Let's Encrypt):
   - Hosts → SSL Certificates → Add → Let's Encrypt
   - Domain Names: dns.seudominio.com
   - HTTP-01 (ou DNS-01)
   - Salvar

2) DoH (443 -> /dns-query):
   - Hosts → Proxy Hosts → Add Proxy Host
   - Domain Names: dns.seudominio.com
   - Scheme: http
   - Forward Hostname/IP: ${CUR_IP}
   - Forward Port: 8054
   - SSL: Enable → selecione o certificado
   - Force SSL: ON
   - HTTP/2: ON

3) DoT (853):
   - Hosts → Streams → Add Stream
   - Incoming port: 853
   - TCP: ON
   - Forward Host: ${CUR_IP}
   - Forward Port: 8053
   - SSL Certificate: dns.seudominio.com

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
echo "Depois do reboot:"
echo "  systemctl status unbound pihole-FTL coredns doh-proxy"
echo "  ss -lntup | grep -E ':53|:5335|:8053|:8054'"
