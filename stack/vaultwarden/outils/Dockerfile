# Outils jetables de la brique vaultwarden (aucun service) : interface en ligne de commande
# officielle de Bitwarden « bw » (npm @bitwarden/cli), jq, et Python avec cryptography pour créer
# les données de démonstration (seed.py). Construite par stack/vaultwarden/hook.sh, lancée avec
# `docker run --rm`, sans volume persistant.
FROM node:22.23.5-alpine3.24
ARG BW_VERSION=2026.10.1
RUN apk add --no-cache python3 py3-cryptography jq \
 && npm install -g --omit=dev --no-audit --no-fund "@bitwarden/cli@${BW_VERSION}" \
 && npm cache clean --force \
 && bw --version
USER node
WORKDIR /home/node
