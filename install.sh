#!/usr/bin/env bash
# =============================================================================
# Pi-hole + Unbound + CoreDNS + DoH-proxy (em sessões)
# Execução:
#   ./install.sh                      # roda TODAS as sessões na ordem
#   SESSOES="1,3,5" ./install.sh      # roda somente as sessões indicadas
# =============================================================================
set -Eeuo pipefail

# ------------------------------- Sessão 0 ------------------------------------
# Utilitários, detecção de rede, DNS temporário e menu de execução
# -----------------------------------------------------------------------------

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
err()  { echo -e "\e[1;31m[x]\e[0m $*" >&2; }
pause(){ read -rp "Pressione ENTER para continuar..."; }

trap 'err "Falha (linha $LINENO). Verifique a última ação."' ERR

need_root() {
  if [[ $(id -u) -ne 0 ]]; then
    err "Execute como root."
    exit 1
  fi
}

cmd_exists() { command -v "$1" &>/dev/null; }

ensure_temp_dns() {
  printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf || true
}

sess0_pacotes_minimos() {
  log "Sessão 0: instalando pacotes mínimos..."
  ensure_temp_dns
  apt-get update -qq || true
  apt-get install -y iproute2 net-tools ipcalc curl ca-certificates netcat-traditional >/dev/null || true
}

detectar_rede() {
  DEF_IF=$(ip -o -4 route show to default | awk '{print $5}' | head -1 || true)
  DEF_GW=$(ip -o -4 route show to default | awk '{print $3}' | head -1 || true)
  CIDR=$(ip -o -4 addr show dev "${DEF_IF:-}" | awk '{print $4}' | head -1 || true)
  CUR_IP="${CIDR%%/*}"
  PREFIX="${CIDR##*/}"

  if cmd_exists ipcalc && [[ -n "${CIDR:-}" ]]; then
    SUBNET_MASK=$(ipcalc -m "$CIDR" 2>/dev/null | awk -F= '/NETMASK/{print $2}')
  fi
  [[ -z "${SUBNET_MASK:-}" ]] && SUBNET_MASK="255.255.255.0"

  log "Interface padrão: ${DEF_IF:-?}"
  log "Gateway padrão:   ${DEF_GW:-?}"
  log "IP atual:         ${CUR_IP:-?}"
  log "Máscara:          ${SUBNET_MASK}"
}

# ------------------------------- Sessão 1 ------------------------------------
# Configurar IP Fixo
# -----------------------------------------------------------------------------
sess1_ip_fixo() {
  log "Sessão 1: configuração de IP fixo (opcional)."
  read -rp "Deseja configurar IP fixo agora? [s/N]: " ANS
  ANS=${ANS:-N}
  if [[ ! "$ANS" =~ ^[sS]$ ]]; then
    log "Mantendo IP atual por DHCP: $CUR_IP"
    return 0
  fi

  local base last_oct NEW_IP
  base=$(echo "$CUR_IP" | awk -F. '{print $1"."$2"."$3}')
  read -rp "Informe o último octeto do IP (ex.: 110 para ${base}.110): " last_oct
  [[ -z "$last_oct" ]] && { err "Octeto vazio."; exit 1; }

  NEW_IP="${base}.${last_oct}"
  CUR_IP="$NEW_IP"

  mkdir -p /etc/network/interfaces.d
  local IF_FILE="/etc/network/interfaces.d/99-${DEF_IF}-static.cfg"
  cat > "$IF_FILE" <<EOF
auto ${DEF_IF}
iface ${DEF_IF} inet static
    address ${NEW_IP}
    netmask ${SUBNET_MASK}
    gateway ${DEF_GW}
    dns-nameservers 1.1.1.1 8.8.8.8
EOF

  ensure_temp_dns
  ip addr flush dev "${DEF_IF}" || true
  ifdown "${DEF_IF}" 2>/dev/null || true
  ifup   "${DEF_IF}" || true

  log "IP fixo aplicado: $CUR_IP (${SUBNET_MASK}) via ${DEF_IF}"
}

# ------------------------------- Sessão 2 ------------------------------------
sess2_conectividade() {
  log "Sessão 2: garantindo conectividade..."
  ensure_temp_dns
  apt-get update || warn "APT update falhou, usando cache local."
}

# ------------------------------- Sessão 3 ------------------------------------
sess3_pacotes_base() {
  log "Sessão 3: instalando pacotes base..."
  apt-get install -y curl wget git lsof bind9-dnsutils unzip tar golang pipx python3-venv >/dev/null
}

# ------------------------------- Sessão 4 ------------------------------------
sess4_instalar_pihole() {
  log "Sessão 4: instalando Pi-hole..."
  pause
  curl -sSL https://install.pi-hole.net | bash
}

# ------------------------------- Sessão 5 ------------------------------------
sess5_instalar_unbound() {
  log "Sessão 5: instalando Unbound..."
  apt-get install -y unbound >/dev/null

  install -d -m 0755 /etc/unbound/unbound.conf.d
  cat > /etc/unbound/unbound.conf.d/pi-hole.conf <<'EOF'
server:
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
EOF

  mkdir -p /var/lib/unbound
  wget -qO /var/lib/unbound/root.hints https://www.internic.net/domain/named.root || true

  unbound-checkconf || { err "Erro no Unbound config"; exit 1; }
  systemctl enable --now unbound || true

  for i in {1..30}; do nc -z 127.0.0.1 5335 && break; sleep 1; done
  log "Teste Unbound:"
  dig @127.0.0.1 -p 5335 openai.com +short || true
}

# ------------------------------- Sessão 6 ------------------------------------
sess6_configurar_pihole_unbound() {
  log "Sessão 6: configurando Pi-hole -> Unbound"
  if [[ -f /etc/pihole/setupVars.conf ]]; then
    sed -i '/^PIHOLE_DNS_/d' /etc/pihole/setupVars.conf
    echo "PIHOLE_DNS_1=127.0.0.1#5335" >> /etc/pihole/setupVars.conf
  fi
  systemctl restart pihole-FTL || true
}

# ------------------------------- Sessão 7 ------------------------------------
sess7_instalar_coredns() {
  log "Sessão 7: instalando CoreDNS..."
  cd /opt
  curl -fsSL -o coredns.tgz https://github.com/coredns/coredns/releases/download/v1.11.3/coredns_1.11.3_linux_amd64.tgz
  tar -xzf coredns.tgz
  install -m 0755 coredns /usr/local/bin/coredns
  mkdir -p /etc/coredns

  cat > /etc/coredns/Corefile <<'EOF'
.:8053 {
    errors
    log
    cache 512
    forward . 127.0.0.1:53
}
EOF

  systemctl daemon-reload
  cat > /etc/systemd/system/coredns.service <<'EOF'
[Unit]
Description=CoreDNS
After=network.target
[Service]
ExecStart=/usr/local/bin/coredns -conf /etc/coredns/Corefile
Restart=always
[Install]
WantedBy=multi-user.target
EOF

  systemctl enable --now coredns
}

# ------------------------------- Sessão 8 ------------------------------------
sess8_instalar_doh_proxy() {
  log "Sessão 8: instalando DoH-proxy..."
  pipx install doh-proxy || true
  cat > /etc/systemd/system/doh-proxy.service <<EOF
[Unit]
Description=DoH Proxy
After=network.target
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

# ------------------------------- Sessão 9 ------------------------------------
sess9_testes() {
  log "Sessão 9: testes finais"
  dig @127.0.0.1 -p 5335 openai.com +short || true
  dig @127.0.0.1 -p 53 openai.com +short || true
  dig @127.0.0.1 -p 8053 openai.com +short || true
  curl -s "http://${CUR_IP}:8054/dns-query?name=openai.com&type=A" -H 'accept: application/dns-json' || true
}

# ========================== Orquestrador ==========================
run_sessions() {
  local ORDERED=("0" "1" "2" "3" "4" "5" "6" "7" "8" "9")
  local TO_RUN=()
  if [[ -n "${SESSOES:-}" ]]; then
    IFS=',' read -r -a TO_RUN <<< "$SESSOES"
  else
    TO_RUN=("${ORDERED[@]}")
  fi
  for s in "${TO_RUN[@]}"; do
    case "$s" in
      0) sess0_pacotes_minimos; detectar_rede ;;
      1) detectar_rede; sess1_ip_fixo; detectar_rede ;;
      2) sess2_conectividade ;;
      3) sess3_pacotes_base ;;
      4) sess4_instalar_pihole ;;
      5) sess5_instalar_unbound ;;
      6) sess6_configurar_pihole_unbound ;;
      7) sess7_instalar_coredns ;;
      8) sess8_instalar_doh_proxy ;;
      9) sess9_testes ;;
    esac
  done
}

# ================================ MAIN =============================
need_root
run_sessions
log "Instalação concluída!"
