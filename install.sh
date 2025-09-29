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

# ===== detecção de rede =====
detect_net() {
  DEF_IF=$(ip -o -4 route show to default | awk '{print $5}' | head -1 || true)
  DEF_GW=$(ip -o -4 route show to default | awk '{print $3}' | head -1 || true)
  CUR_IP=$(ip -o -4 addr show dev "$DEF_IF" | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
  CIDR=$(ip -o -4 addr show dev "$DEF_IF" | awk '{print $4}' | head -1 || true)
  SUBNET_MASK=$(ipcalc "$CIDR" 2>/dev/null | awk '/Netmask:/ {print $2}')

  log "Interface padrão: $DEF_IF"
  log "Gateway padrão:   $DEF_GW"
  log "IP atual:         $CUR_IP"
  log "Máscara:          ${SUBNET_MASK:-desconhecida}"

  if [[ -z "${CUR_IP:-}" || -z "${DEF_IF:-}" || -z "${DEF_GW:-}" ]]; then
    err "Não foi possível detectar rede automaticamente. Configure rede e execute novamente."
    exit 1
  fi
}

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

    read -rp "Informe o(s) DNS local(is) a publicar (ex.: nenhum / deixe em branco): " PUBL_DNS || true

    if cmd_exists nmcli; then
      log "NetworkManager detectado. Ajustando IP fixo via nmcli..."
      CONN=$(nmcli -t -f NAME con show --active | head -1)
      if [[ -z "$CONN" ]]; then
        err "Não encontrei conexão ativa no NM. Ajuste manualmente ou use ifupdown."
      else
        nmcli con mod "$CONN" ipv4.method manual ipv4.addresses "${NEW_IP}/24" ipv4.gateway "$DEF_GW"
        if [[ -n "${PUBL_DNS:-}" ]]; then
          nmcli con mod "$CONN" ipv4.dns "$PUBL_DNS"
        else
          nmcli con mod "$CONN" -ipv4.dns
        fi
        nmcli con down "$CONN" || true
        nmcli con up "$CONN"
        CUR_IP="$NEW_IP"
        log "IP fixo aplicado via NetworkManager: $CUR_IP"
      fi
    elif [[ -f /etc/network/interfaces ]]; then
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
EOF
      if [[ -n "${PUBL_DNS:-}" ]]; then
        echo "    dns-nameservers $PUBL_DNS" >>"$INTERF"
      fi
      systemctl restart networking || true
      ip addr flush dev "$DEF_IF" || true
      ifdown "$DEF_IF" || true
      ifup "$DEF_IF" || true
      CUR_IP="$NEW_IP"
      log "IP fixo aplicado via ifupdown: $CUR_IP"
    else
      warn "Nem NetworkManager nem ifupdown detectados. Pulei ajuste automático."
      warn "Se necessário, fixe IP manualmente e rode o script de novo."
    fi
  else
    log "Mantendo IP atual (DHCP): $CUR_IP"
  fi
}

# ===== pacotes base =====
install_base() {
  log "Instalando pacotes base..."
  apt update
  apt install -y curl wget git net-tools lsof dnsutils unzip python3-venv pipx build-essential tar golang iproute2 netcat-traditional ipcalc
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
  log "Instalando e configurando Unbound..."
  apt install -y unbound
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
    edns-buffer-size: 1232
    prefetch: yes
    qname-minimisation: yes
    cache-min-ttl: 240
    cache-max-ttl: 86400
    hide-identity: yes
    hide-version: yes
EOF

  mkdir -p /var/lib/unbound
  wget -qO /var/lib/unbound/root.hints https://www.internic.net/domain/named.root

  cat >/etc/cron.monthly/unbound-root-hints <<'EOF'
#!/usr/bin/env bash
set -e
wget -qO /var/lib/unbound/root.hints https://www.internic.net/domain/named.root
systemctl restart unbound
EOF
  chmod +x /etc/cron.monthly/unbound-root-hints

  systemctl enable --now unbound
  log "Testando Unbound local (127.0.0.1#5335)..."
  dig @127.0.0.1 -p 5335 openai.com +short || true
}

# ===== Ajuste Pi-hole para Unbound =====
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
  dig @127.0.0.1 -p 53 openai.com +short || true
}

# ===== CoreDNS =====
install_coredns() {
  log "Instalando CoreDNS..."
  cd /opt
  COREDNS_VER="1.11.3"
  curl -fsSL -o coredns.tgz "https://github.com/coredns/coredns/releases/download/v${COREDNS_VER}/coredns_${COREDNS_VER}_linux_amd64.tgz"
  tar -xzf coredns.tgz
  install -m 0755 coredns /usr/local/bin/coredns
  mkdir -p /etc/coredns

  # Corefile
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
Description=CoreDNS
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

# ===== DoH-Proxy =====
install_doh_proxy() {
  log "Instalando DoH-Proxy..."
  pipx install doh-proxy

  cat >/etc/systemd/system/doh-proxy.service <<EOF
[Unit]
Description=DoH Proxy
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

# ===== testes =====
final_tests() {
  log "Testando stack local..."
  dig @127.0.0.1 -p 5335 openai.com +short || true
  dig @127.0.0.1 -p 53 openai.com +short || true
  curl -s -H 'accept: application/dns-json' "http://${CUR_IP}:8054/dns-query?name=openai.com&type=A" || true
}

# ===== main =====
need_root
detect_net
choose_static_ip
install_base
install_pihole
install_unbound
configure_pihole_upstream
install_coredns
install_doh_proxy
final_tests

log "Concluído! Reboot recomendado para validar ordem de serviços."
