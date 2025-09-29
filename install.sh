#!/usr/bin/env bash
set -Eeuo pipefail

# ===============================
# Utilidades
# ===============================
log()   { echo -e "\e[1;32m[+]\e[0m $*"; }
warn()  { echo -e "\e[1;33m[!]\e[0m $*"; }
err()   { echo -e "\e[1;31m[x]\e[0m $*" >&2; }
pause() { read -rp "➡️ Pressione ENTER para continuar..."; }

# Spinner (para mostrar progresso em comandos longos)
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
    err "Execute como root."
    exit 1
  fi
}

cmd_exists() { command -v "$1" &>/dev/null; }

# ===============================
# Sessão -1 — Verificação inicial
# ===============================
session_precheck() {
  if [[ -d /etc/pihole || -d /etc/unbound || -f /usr/local/bin/coredns ]]; then
    warn "🚨 Detectamos uma instalação existente!"
    echo "O que deseja fazer?"
    echo "1) Reinstalar (remove tudo e instala novamente)"
    echo "2) Atualizar pacotes (mantém configs)"
    echo "3) Cancelar"
    read -rp "Escolha [1/2/3]: " CHOICE
    case "$CHOICE" in
      1)
        log "Removendo instalação anterior..."
        systemctl stop pihole-FTL unbound coredns doh-proxy 2>/dev/null || true
        apt-get purge -y pihole unbound >/dev/null 2>&1 || true
        rm -rf /etc/pihole /etc/unbound /etc/coredns /opt/coredns /usr/local/bin/coredns
        rm -f /etc/systemd/system/{pihole-FTL.service,coredns.service,doh-proxy.service}
        systemctl daemon-reload
        log "Instalação anterior removida. Continuando..."
        ;;
      2)
        log "Atualizando pacotes..."
        apt-get update -qq && apt-get upgrade -y
        log "Atualização concluída. Encerrando."
        exit 0
        ;;
      3|*) log "Abortado."; exit 0 ;;
    esac
  fi
}

# ===============================
# Sessão 0 — Preparação mínima
# ===============================
session0_prep() {
  log "Sessão 0: Instalando pacotes mínimos (rede e utilitários)..."
  (apt-get update -qq && apt-get install -y iproute2 net-tools ipcalc curl ca-certificates netcat-traditional >/dev/null) &
  spinner
}

# ===============================
# Sessão 1 — Detecção de rede
# ===============================
session1_net() {
  log "Sessão 1: Detectando rede..."

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
  log "IP atual:  $CUR_IP"
  log "Máscara:   $SUBNET_MASK"
  echo
  warn "⚠️ Este IP ($CUR_IP) precisa ser FIXO para o ambiente funcionar corretamente."
  warn "➡️ Configure manualmente o IP fixo no seu host/VM/container antes de prosseguir."
  pause
}

# ===============================
# Sessão 2 — Instalação base
# ===============================
session2_base() {
  log "Sessão 2: Instalando pacotes base (compiladores, libs, Python, Go, etc)..."
  (apt-get install -y curl wget git lsof bind9-dnsutils unzip tar golang \
    iproute2 netcat-traditional pipx python3-venv >/dev/null) &
  spinner
}

# ===============================
# Sessão 3 — Pi-hole
# ===============================
session3_pihole() {
  log "Sessão 3: Instalando Pi-hole..."
  echo
  warn "⚠️ IMPORTANTE:"
  echo "Durante a instalação do Pi-hole, escolha:"
  echo "   → Upstream DNS Providers → 'Custom'"
  echo "   → Digite: 127.0.0.1#5335"
  echo
  pause
  curl -sSL https://install.pi-hole.net | bash
}

# ===============================
# Sessão 4 — Unbound
# ===============================
session4_unbound() {
  log "Sessão 4: Instalando e configurando Unbound..."
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
  log "➡️ Testando Unbound..."
  dig @127.0.0.1 -p 5335 openai.com +short || true
}

# ===============================
# Sessão 5 — Pi-hole -> Unbound
# ===============================
session5_pihole_conf() {
  log "Sessão 5: Ajustando Pi-hole para usar Unbound..."
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
# Sessão 6 — CoreDNS
# ===============================
session6_coredns() {
  log "Sessão 6: Instalando CoreDNS..."
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
Description=CoreDNS (porta 8053)
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
# Sessão 7 — DoH-proxy
# ===============================
session7_doh() {
  log "Sessão 7: Instalando DoH-proxy..."
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
# Sessão 8 — Testes finais
# ===============================
session8_tests() {
  log "Sessão 8: Testes locais de validação"
  echo "Unbound → "; dig @127.0.0.1 -p 5335 openai.com +short || true
  echo "Pi-hole → "; dig @127.0.0.1 -p 53 openai.com +short || true
  echo "CoreDNS → "; dig @127.0.0.1 -p 8053 openai.com +short || true
  echo "DoH-proxy → "; curl -s -H 'accept: application/dns-json' "http://${CUR_IP}:8054/dns-query?name=openai.com&type=A" || true
}

# ===============================
# Sessão 9 — Senha Pi-hole
# ===============================
session9_password() {
  read -rp "Deseja alterar a senha do painel do Pi-hole agora? [s/N]: " ANS
  ANS=${ANS:-N}
  if [[ "$ANS" =~ ^[sS]$ ]]; then
    read -rp "Informe a nova senha: " NEWPASS
    pihole setpassword "$NEWPASS"
    log "Senha do Pi-hole alterada com sucesso."
  else
    log "Mantida a senha gerada automaticamente pelo Pi-hole."
  fi
}

# ===============================
# Sessão final — Instruções NPM
# ===============================
final_msg() {
  echo
  log "✅ Instalação concluída!"
  echo "============================================================"
  echo " IP detectado: $CUR_IP"
  echo
  echo "➡️ Agora configure o Nginx Proxy Manager (NPM):"
  echo
  echo "1) DoH (DNS-over-HTTPS)"
  echo "   - Vá em Proxy Hosts → Add Proxy Host"
  echo "   - Domain Names: SEU_DOMINIO (ex.: dns.seusite.com)"
  echo "   - Scheme: http"
  echo "   - Forward Host/IP: $CUR_IP"
  echo "   - Forward Port: 8054"
  echo "   - Path: /dns-query"
  echo "   - SSL: Ative e selecione o certificado Let's Encrypt"
  echo "   - Force SSL: ON"
  echo
  echo "2) DoT (DNS-over-TLS)"
  echo "   - Vá em Streams → Add Stream"
  echo "   - Incoming port: 853"
  echo "   - Forward Host: $CUR_IP"
  echo "   - Forward Port: 8053"
  echo "   - SSL Certificate: selecione o mesmo domínio"
  echo
  echo "3) Testes externos:"
  echo "   - DoH: kdig @dns.seusite.com +https=/dns-query openai.com"
  echo "   - DoT: kdig @dns.seusite.com -p 853 +tls +tls-hostname=dns.seusite.com openai.com"
  echo
  echo "💡 Em celulares Android/iOS → configure DNS privado com seu domínio (DoT)."
  echo "💡 Em navegadores/Apps → configure https://dns.seusite.com/dns-query como DoH."
  echo "============================================================"
}

# ===============================
# Main
# ===============================
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
