# pihole-dns-installer
Script para instalar Pi-hole + Unbound + CoreDNS (DoT) + DoH-proxy com integração ao NPM
# Pi-hole DNS Installer

Este script instala e configura automaticamente:

- **Pi-hole** (bloqueador de anúncios e tracker DNS)
- **Unbound** (resolver recursivo local)
- **CoreDNS** (para DoT, integrado ao NPM)
- **DoH-proxy** (para DoH via NPM)

## Uso

```bash
curl -fsSL https://raw.githubusercontent.com/rafaelfmuniz/pihole-dns-installer/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
