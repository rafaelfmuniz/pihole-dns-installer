#!/usr/bin/env bash
# =============================================================================
# Pi-hole + Unbound + CoreDNS + DoH-proxy (em sessões)
# Autor: você :)
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

# Força DNS temporário para garantir APT/curL mesmo se rede cair na troca de IP
ensure_temp_dns() {
  # alguns ambientes têm resolv.conf imutável -> tenta tornar gravável
  if [[ -L /etc/resolv.conf ]]; then
    # se for link, sobrescreve mesmo assim (systemd-resolved cuida depois)
    :
  fi
  printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf || true
}

# Instala ferramentas mínimas antes de detectar rede (ip, ipcalc, nc, curl…)
sess0_pacotes_minimos() {
  log "Sessão 0: instalando pacotes mínimos (iproute2, net-tools, ipcalc, curl, ca-certificates, netcat)…"
  ensure_temp_dns
  apt-get update -qq || true
  apt-get install -y iproute2 net-tools ipcalc curl ca-certificates netcat-traditional >/dev/null || true
}

# Detecta interface, gateway, IP/CIDR e máscara em notação pontilhada
detectar_rede() {
  DEF_IF=$(ip -o -4 route show to default | awk '{print $5}' | head -1 || true)
  DEF_GW=$(ip -o -4 route show to default | awk '{print $3}' | head -1 || true)
  CIDR=$(ip -o -4 addr show dev "${DEF_IF:-}" | awk '{print $4}' | head -1 || true)
  CUR_IP="${CIDR%%/*}"
  PREFIX="${CIDR##*/}"

  # Máscara correta (pontilhada)
  if cmd_exists ipcalc && [[ -n "${CIDR:-}" ]]; then
    SUBNET_MASK=$(ipcalc -m "$CIDR" 2>/dev/null | awk -F= '/NETMASK/{print $2}')
  fi
  [[ -z "${SUBNET_MASK:-}" ]] && SUBNET_MASK="255.255.255.0"

  log "Interface padrão: ${DEF_IF:-?}"
  log "Gateway padrão:   ${DEF_GW:-?}"
  log "IP atual:         ${CUR_IP:-?}"
  log "Máscara:          ${SUBNET_MASK}"

  if [[ -z "${DEF_IF:-}" || -z "${DEF_GW:-}" || -z "${CUR_IP:-}" ]]; then
    err "Não foi possível detectar rede automaticamente. Ajuste rede e tente novamente."
    exit 1
  fi
}

# ------------------------------- Sessão 1 ------------------------------------
# Configurar IP Fixo de forma segura (interfaces.d), sem quebrar o arquivo base
# -----------------------------------------------------------------------------
sess1_ip_fixo() {
  log "Sessão 1: configuração de IP fixo (opcional)."
  read -rp "[Opcional] Deseja configurar IP fixo agora? [s/N]: " ANS
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
  read -rp "Confirme o IP fixo desejado [$NEW_IP] (ENTER para aceitar): " CONF
  [[ -n "${CONF:-}" ]] && NEW_IP="$CONF"

  read -rp "Informe o(s) DNS local(is) a publicar (ENTER para padrão 1.1.1.1 8.8.8.8): " PUBL_DNS || true
  [[ -z "${PUBL_DNS:-}" ]] && PUBL_DNS="1.1.1.1 8.8.8.8"

  # Garante que /etc/network/interfaces inclui interfaces.d
  if [[ -f /etc/network/interfaces && ! -d /etc/network/interfaces.d ]]; then
    mkdir -p /etc/network/interfaces.d
  fi
  if [[ -f /etc/network/interfaces ]] && ! grep -qE '^\s*source(-directory)?\s+/etc/network/interfaces\.d' /etc/network/interfaces; then
    cp -a /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%s)"
    echo -e "\nsource-directory /etc/network/interfaces.d\n" >> /etc/network/interfaces
  fi

  local IF_FILE="/etc/network/interfaces.d/99-${DEF_IF}-static.cfg"
  cat > "$IF_FILE" <<EOF
# gerado por install.sh — sessão 1
auto ${DEF_IF}
iface ${DEF_IF} inet static
    address ${NEW_IP}
    netmask ${SUBNET_MASK}
    gateway ${DEF_GW}
    dns-nameservers ${PUBL_DNS}
EOF

  # Aplica sem derrubar tudo: força DNS temporário e troca IP
  ensure_temp_dns
  ip addr flush dev "${DEF_IF}" || true
  ifdown "${DEF_IF}" 2>/dev/null || true
  ifup   "${DEF_IF}" || {
    warn "ifup falhou; tentando trazer interface manualmente."
    ip addr add "${NEW_IP}/${PREFIX}" dev "${DEF_IF}" || true
    ip link set "${DEF_IF}" up || true
    ip route replace default via "${DEF_GW}" dev "${DEF_IF}" || true
  }

  CUR_IP="$NEW_IP"
  log "IP fixo aplicado: $CUR_IP (${SUBNET_MASK}) via ${DEF_IF}"
}

# ------------------------------- Sessão 2 ------------------------------------
# Conectividade: garantir DNS e acesso à internet para os próximos apt/instalações
# -----------------------------------------------------------------------------
sess2_conectividade() {
  log "Sessão 2: garantindo conectividade para APT/instalações…"
  ensure_temp_dns
  # Teste rápido
  if ! ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
    warn "Não consegui pingar 1.1.1.1; verificando rota padrão…"
    ip route show default || true
  fi
  # Teste DNS
  if ! getent hosts deb.debian.org >/dev/null 2>&1; then
    warn "Resolução ainda indisponível; mantendo DNS temporário no /etc/resolv.conf."
    ensure_temp_dns
  fi
  apt-get update || warn "apt-get update retornou aviso; seguindo com caches existentes."
}

# ------------------------------- Sessão 3 ------------------------------------
# Pacotes base (curl, git, dig, golang p/ coredns tarball, pipx p/ doh-proxy etc.)
# -----------------------------------------------------------------------------
sess3_pacotes_base() {
  log "Sessão 3: instalando pacotes base…"
  apt-get install -y \
    curl wget git net-tools lsof bind9-dnsutils unzip tar golang iproute2 \
    netcat-traditional pipx python3-venv >/dev/null
}

# ------------------------------- Sessão 4 ------------------------------------
# Pi-hole (instalador oficial). Mantemos interação mínima.
# -----------------------------------------------------------------------------
sess4_instalar_pihole() {
  log "Sessão 4: instalando Pi-hole (instalador oficial)."
  log "Durante a instalação pode aparecer UI; depois ajustaremos DNS upstream para Unbound (127.0.0.1#5335)."
  pause
  curl -sSL https://install.pi-hole.net | bash
}

# ------------------------------- Sessão 5 ------------------------------------
# Unbound (stub recursor local em 127.0.0.1:5335) + root hints + cron mensal
# -----------------------------------------------------------------------------
sess5_instalar_unbound() {
  log "Sessão 5: instalando e configurando Unbound (porta 5335)…"
  apt-get install -y unbound >/dev/null

  # Garante include do conf.d no unbound.conf principal (idempotente)
  if [[ ! -f /etc/unbound/unbound.conf ]]; then
    cat > /etc/unbound/unbound.conf <<'EOF'
server:
    # arquivo principal mínimo — inclui os *.conf
    include: "/etc/unbound/unbound.conf.d/*.conf"
EOF
  elif ! grep -q 'include:.*unbound\.conf\.d/\*\.conf' /etc/unbound/unbound.conf; then
    echo 'include: "/etc/unbound/unbound.conf.d/*.conf"' >> /etc/unbound/unbound.conf
  fi

  install -d -m 0755 /etc/unbound/unbound.conf.d
  cat > /etc/unbound/unbound.conf.d/pi-hole.conf <<'EOF'
server:
    verbosity: 1
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes

    # Root hints
    root-hints: "/var/lib/unbound/root.hints"

    # Endurecimento
    harden-glue: yes
    harden-dnssec-stripped: yes
    qname-minimisation: yes
    prefetch: yes
    hide-identity: yes
    hide-version: yes

    # Ajustes de MTU e cache
    edns-buffer-size: 1232
    cache-min-ttl: 240
    cache-max-ttl: 86400
EOF

  mkdir -p /var/lib/unbound
  wget -qO /var/lib/unbound/root.hints https://www.internic.net/domain/named.root || true
  cat > /etc/cron.monthly/unbound-root-hints <<'EOF'
#!/usr/bin/env bash
set -e
wget -qO /var/lib/unbound/root.hints https://www.internic.net/domain/named.root
systemctl restart unbound
EOF
  chmod +x /etc/cron.monthly/unbound-root-hints

  # Valida sintaxe e sobe serviço
  unbound-checkconf || { err "Configuração do Unbound inválida."; exit 1; }
  systemctl enable --now unbound || true

  # Espera porta 5335 responder
  for i in {1..30}; do nc -z 127.0.0.1 5335 && break; sleep 1; done
  if ! nc -z 127.0.0.1 5335; then
    warn "Unbound ainda não está escutando em 127.0.0.1:5335. Logs:"
    journalctl -u unbound --no-pager -n 80 || true
  else
    log "Teste Unbound (127.0.0.1#5335):"
    dig @127.0.0.1 -p 5335 openai.com +timeout=2 +short || true
  endfi
}

# ------------------------------- Sessão 6 ------------------------------------
# Apontar Pi-hole para o Unbound + drop-in systemd (After/Requires + espera porta)
# -----------------------------------------------------------------------------
sess6_configurar_pihole_unbound() {
  log "Sessão 6: apontando Pi-hole para Unbound e adicionando dependência…"

  # setupVars (Pi-hole v6 ainda respeita isso)
  if [[ -f /etc/pihole/setupVars.conf ]]; then
    sed -i '/^PIHOLE_DNS_/d' /etc/pihole/setupVars.conf
    {
      echo "PIHOLE_DNS_1=127.0.0.1#5335"
      echo "PIHOLE_DNS_2="
    } >> /etc/pihole/setupVars.conf
  fi

  # Drop-in (não substitui o unit original)
  install -d /etc/systemd/system/pihole-FTL.service.d
  cat > /etc/systemd/system/pihole-FTL.service.d/override.conf <<'EOF'
[Unit]
After=network-online.target unbound.service
Requires=unbound.service
Wants=network-online.target

[Service]
ExecStartPre=/bin/bash -c 'for i in {1..30}; do nc -z 127.0.0.1 5335 && exit 0; sleep 1; done; exit 1'
EOF

  systemctl daemon-reload
  systemctl enable --now pihole-FTL || true
  systemctl restart pihole-FTL || true

  # Espera DNS local ficar de pé
  for i in {1..30}; do nc -z 127.0.0.1 53 && break; sleep 1; done
  log "Teste Pi-hole (127.0.0.1#53):"
  dig @127.0.0.1 -p 53 openai.com +timeout=2 +short || true
}

# ------------------------------- Sessão 7 ------------------------------------
# CoreDNS (escuta em :8053 e encaminha para 127.0.0.1:53)
# -----------------------------------------------------------------------------
sess7_instalar_coredns() {
  log "Sessão 7: instalando CoreDNS (porta 8053)…"
  local COREDNS_VER="1.11.3"
  cd /opt
  curl -fsSL -o coredns.tgz "https://github.com/coredns/coredns/releases/download/v${COREDNS_VER}/coredns_${COREDNS_VER}_linux_amd64.tgz"
  tar -xzf coredns.tgz
  install -m 0755 coredns /usr/local/bin/coredns
  mkdir -p /etc/coredns

  # Corefile validado por você (funcional)
  cat > /etc/coredns/Corefile <<'EOF'
# CoreDNS config para DoH + DoT via NPM
.:8053 {
    errors
    log
    cache 512

    # Encaminhar consultas ao Pi-hole/Unbound
    forward . 127.0.0.1:53
}
EOF

  # Unit simples
  cat > /etc/systemd/system/coredns.service <<'EOF'
[Unit]
Description=CoreDNS (ouve em :8053)
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

# ------------------------------- Sessão 8 ------------------------------------
# DoH-proxy (porta interna 8054) para NPM publicar /dns-query em HTTPS
# -----------------------------------------------------------------------------
sess8_instalar_doh_proxy() {
  log "Sessão 8: instalando DoH-proxy (porta interna 8054)…"
  pipx install doh-proxy || true

  # Service com caminho absoluto (pipx instala em /root/.local/bin)
  cat > /etc/systemd/system/doh-proxy.service <<EOF
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
  for i in {1..30}; do nc -z "${CUR_IP}" 8054 && break; sleep 1; done

  log "Teste DoH-proxy local (JSON):"
  curl -s -H 'accept: application/dns-json' \
    "http://${CUR_IP}:8054/dns-query?name=openai.com&type=A" || true
}

# ------------------------------- Sessão 9 ------------------------------------
# Testes finais e instruções para publicar pelo Nginx Proxy Manager (NPM)
# -----------------------------------------------------------------------------
sess9_testes_e_dicas() {
  echo
  log "Sessão 9: testes rápidos locais…"
  echo "1) Unbound: dig @127.0.0.1 -p 5335 openai.com +short"
  dig @127.0.0.1 -p 5335 openai.com +short || true
  echo
  echo "2) Pi-hole: dig @127.0.0.1 -p 53 openai.com +short"
  dig @127.0.0.1 -p 53 openai.com +short || true
  echo
  echo "3) CoreDNS (8053): dig @127.0.0.1 -p 8053 openai.com +short"
  dig @127.0.0.1 -p 8053 openai.com +short || true
  echo
  echo "4) DoH (8054): curl http://${CUR_IP}:8054/dns-query?name=openai.com&type=A -H 'accept: application/dns-json'"
  curl -s -H 'accept: application/dns-json' \
    "http://${CUR_IP}:8054/dns-query?name=openai.com&type=A" || true
  echo

  cat <<EOF

============================================================
NPM (Nginx Proxy Manager) — CHECKLIST
============================================================

Pré-requisito: seu domínio (ex.: dns.seudominio.com) aponta para o IP público do NPM.
Encaminhe as portas externas 80/443/853 para o host do NPM.

1) Certificado (Let's Encrypt):
   - Hosts → SSL Certificates → Add → Let's Encrypt
   - Domain Names: dns.seudominio.com
   - HTTP-01 (ou DNS-01)
   - Salvar

2) DoH (HTTPS /dns-query):
   - Hosts → Proxy Hosts → Add Proxy Host
   - Domain Names: dns.seudominio.com
   - Scheme: http
   - Forward Hostname/IP: ${CUR_IP}
   - Forward Port: 8054
   - Block Common Exploits: ON
   - Websockets: ON (opcional)
   - SSL: Enable → selecione o certificado
   - Force SSL: ON
   - HTTP/2: ON
   - Salvar
   Teste externo:
     kdig @dns.seudominio.com +https=/dns-query openai.com

3) DoT (853):
   - Hosts → Streams → Add Stream
   - Incoming port: 853
   - TCP: ON / UDP: OFF
   - Forward Host: ${CUR_IP}
   - Forward Port: 8053
   - SSL Certificate: dns.seudominio.com  (terminar TLS na stream)
   - Salvar
   Teste externo:
     kdig openai.com @dns.seudominio.com -p 853 +tls +tls-hostname=dns.seudominio.com

Observações:
- Se sua build do NPM não permitir “Enable SSL” em Streams,
  o 853 ficará como TCP puro → isso NÃO é DoT. Alternativa: terminar TLS no próprio CoreDNS (plugin tls).
- Em Android (DNS privado/DoT): use apenas o hostname (dns.seudominio.com).
- Para DoH em apps (ex.: Intra): https://dns.seudominio.com/dns-query

============================================================

EOF
}

# ======================= ORQUESTRADOR DE SESSÕES =============================
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
      1) detectar_rede; sess1_ip_fixo; detectar_rede ;; # re-detecta após IP fixo
      2) sess2_conectividade ;;
      3) sess3_pacotes_base ;;
      4) sess4_instalar_pihole ;;
      5) sess5_instalar_unbound ;;
      6) sess6_configurar_pihole_unbound ;;
      7) sess7_instalar_coredns ;;
      8) sess8_instalar_doh_proxy ;;
      9) sess9_testes_e_dicas ;;
      *) warn "Sessão desconhecida: $s (ignorando)";;
    esac
  done
}

# ================================ MAIN =======================================
need_root
run_sessions
log "Concluído! Reboot recomendado para validar ordem de serviços."
echo "Depois do reboot:"
echo "  systemctl status unbound pihole-FTL coredns doh-proxy"
echo "  ss -lntup | grep -E ':53|:5335|:8053|:8054'"
