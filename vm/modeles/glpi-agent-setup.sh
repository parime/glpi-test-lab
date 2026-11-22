#!/bin/bash
# Installation de GLPI Agent sur la VM Ubuntu du labo (lancé au premier démarrage par cloud-init,
# relançable par vm\30-configurer.ps1). Installeur Linux officiel, version épinglée dans vms.psd1 ;
# options listées par « perl glpi-agent-<version>-linux-installer.pl --help » :
# https://glpi-agent.readthedocs.io/en/latest/installation/index.html#linux-installer
set -u
exec >>/var/log/lab-glpi-agent.log 2>&1
echo "=== $(date -Is) installation de GLPI Agent {{VERSION}}"

if systemctl is-active --quiet glpi-agent; then
    echo "GLPI Agent déjà actif."
    exit 0
fi

# Les dépendances Perl viennent des dépôts Ubuntu : attendre l'accès réseau (via pfSense).
for i in $(seq 1 60); do
    getent hosts archive.ubuntu.com >/dev/null && break
    echo "réseau indisponible, nouvel essai ($i/60)"
    sleep 10
done

cd /opt/lab || exit 1
echo '{{SHA256}}  {{AGENT_LINUX}}' | sha256sum -c - || exit 1
perl '{{AGENT_LINUX}}' --install --server='{{URL}}' --tag='{{TAG}}' --type='{{TYPE}}' --runnow --no-question --silent
code=$?
echo "installeur terminé (code $code)"
systemctl is-active glpi-agent
exit $code
