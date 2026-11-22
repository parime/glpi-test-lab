#!/bin/bash
# Script de premier démarrage de Proxmox VE (« first-boot », source « from-iso »), embarqué dans
# l'ISO d'installation automatique par vm\20-proxmox.ps1. Modèle : les clés entre doubles
# accolades sont remplacées par le script.
#
# 1. Pont WAN vmbr1 en DHCP sur la carte reliée à « Default Switch » ; la passerelle du pont LAN
#    est retirée (route par défaut par le WAN).
#    Réseau de Proxmox : https://pve.proxmox.com/wiki/Network_Configuration
# 2. Dépôts : « pve-enterprise » et Ceph désactivés (sans abonnement), « pve-no-subscription » ajouté.
#    https://pve.proxmox.com/wiki/Package_Repositories
# 3. DHCP du LAN limité à une réservation : la carte « vEthernet (lab-interne) » de l'hôte Windows
#    reçoit 10.77.10.254, sans passerelle ni DNS (dnsmasq, paquet Debian).
# 4. Jeton d'API « root@pam!lab » (pveum), lu ensuite par l'hôte en SSH :
#    https://pve.proxmox.com/wiki/User_Management#pveum_tokens
set -eu
exec >>/var/log/lab-premier-demarrage.log 2>&1
echo "=== $(date -Is) premier démarrage du labo"

WAN_MAC='{{MAC_WAN_DEUX_POINTS}}'
WAN_IF=$(ip -o link | awk -F': ' -v mac="$WAN_MAC" 'tolower($0) ~ mac {print $2; exit}' | cut -d@ -f1)
if [ -z "$WAN_IF" ]; then echo "carte WAN introuvable ($WAN_MAC)"; exit 1; fi

if ! grep -q '^iface {{PONT_WAN}}' /etc/network/interfaces; then
    sed -i '/^\s*gateway /d' /etc/network/interfaces
    cat >>/etc/network/interfaces <<EOF

auto $WAN_IF
iface $WAN_IF inet manual

auto {{PONT_WAN}}
iface {{PONT_WAN}} inet dhcp
	bridge-ports $WAN_IF
	bridge-stp off
	bridge-fd 0
#WAN du labo (commutateur Hyper-V Default Switch)
EOF
    ifreload -a
fi

for i in $(seq 1 30); do getent hosts download.proxmox.com >/dev/null && break; sleep 5; done

for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do
    if [ -f "$f" ] && ! grep -q '^Enabled: no' "$f"; then echo 'Enabled: no' >>"$f"; fi
done
cat >/etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq

cat >/etc/dnsmasq.d/lab-hote.conf <<'EOF'
# DHCP du LAN du labo : uniquement la réservation de l'hôte Windows, sans DNS (port=0),
# sans passerelle (option 3 vide) ni serveur DNS annoncé (option 6 vide).
port=0
interface={{PONT_LAN}}
bind-interfaces
dhcp-range={{RESEAU_LAN}},static,{{MASQUE_LAN}},12h
dhcp-host={{MAC_HOTE}},{{IP_HOTE}}
dhcp-option=3
dhcp-option=6
dhcp-authoritative
EOF
systemctl enable dnsmasq
systemctl restart dnsmasq

if [ ! -s /root/lab-jeton.json ]; then
    pveum user token add root@pam lab --privsep 0 --output-format json >/root/lab-jeton.json
    chmod 600 /root/lab-jeton.json
fi

touch /root/lab-premier-demarrage.ok
echo "=== $(date -Is) terminé"
