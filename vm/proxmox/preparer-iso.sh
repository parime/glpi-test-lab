#!/bin/bash
# Prépare l'ISO d'installation automatique de Proxmox VE, dans un conteneur Debian trixie lancé par
# vm\20-proxmox.ps1 (Docker Desktop, sans droits administrateur sur Windows).
#   /iso      : ISO officielle de Proxmox VE (lecture seule)
#   /travail  : answer.toml et premier-demarrage.sh générés ; reçoit l'ISO préparée
# Outil officiel : https://pve.proxmox.com/wiki/Automated_Installation
# Dépôt et clé : https://pve.proxmox.com/wiki/Package_Repositories
set -eu
ISO="$1"
SORTIE="$2"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl xorriso >/dev/null
curl -fsSL -o /usr/share/keyrings/proxmox-archive-keyring.gpg \
    https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
echo '136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45  /usr/share/keyrings/proxmox-archive-keyring.gpg' | sha256sum -c -
cat >/etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
apt-get update -qq
apt-get install -y -qq proxmox-auto-install-assistant >/dev/null
proxmox-auto-install-assistant --version || true
proxmox-auto-install-assistant validate-answer /travail/answer.toml
cp "/iso/$ISO" /tmp/source.iso
proxmox-auto-install-assistant prepare-iso /tmp/source.iso --fetch-from iso \
    --answer-file /travail/answer.toml --on-first-boot /travail/premier-demarrage.sh \
    --output "/travail/$SORTIE"
rm -f /tmp/source.iso
ls -la "/travail/$SORTIE"
echo "ISO préparée : $SORTIE"
