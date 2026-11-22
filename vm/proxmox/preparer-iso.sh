#!/bin/bash
# Prépare l'ISO d'installation automatique de Proxmox VE, dans un conteneur Debian trixie lancé par
# vm\20-proxmox.ps1 (Docker Desktop, sans droits administrateur sur Windows).
#   $1 : nom de l'ISO officielle ; $2 : URL du dossier des ISO ; $3 : somme SHA-256 attendue
#   /travail (lecture seule) : answer.toml et premier-demarrage.sh générés
#   /sortie/proxmox-ve-auto.iso : ISO préparée, récupérée ensuite par « docker cp »
# Les gros fichiers restent dans le système de fichiers du conteneur : un dossier Windows monté
# dans le conteneur est très lent pour 1,7 Go.
# Outil officiel : https://pve.proxmox.com/wiki/Automated_Installation
# Dépôt et clé : https://pve.proxmox.com/wiki/Package_Repositories
set -eu
ISO="$1"
BASE="$2"
SOMME="$3"
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
proxmox-auto-install-assistant validate-answer /travail/answer.toml
mkdir -p /source /sortie
curl -fsSL -o "/source/$ISO" "$BASE$ISO"
echo "$SOMME  /source/$ISO" | sha256sum -c -
proxmox-auto-install-assistant prepare-iso "/source/$ISO" --fetch-from iso \
    --answer-file /travail/answer.toml --on-first-boot /travail/premier-demarrage.sh \
    --output /sortie/proxmox-ve-auto.iso
ls -la /sortie/proxmox-ve-auto.iso
echo "ISO préparée"
