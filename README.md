# Pi-hole DNS Installer with Unbound & CoreDNS

A comprehensive automated installer for Pi-hole DNS server with Unbound resolver, CoreDNS, and DoH proxy support.

## 🚀 Features

- **Pi-hole** - Network-wide ad blocking DNS server
- **Unbound** - Recursive DNS resolver for enhanced privacy
- **CoreDNS** - Flexible DNS server with plugin support
- **DoH Proxy** - DNS-over-HTTPS proxy for secure queries
- **Cross-platform** - Supports Linux distributions
- **Automated Setup** - Hands-free installation and configuration

## 📋 Prerequisites

- Linux system (Ubuntu/Debian recommended)
- Root/sudo access
- Static IP address configured
- Internet connection

## 🛠️ Installation

```bash

# Run as root
curl -fsSL https://raw.githubusercontent.com/rafaelfmuniz/pihole-dns-installer/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
