#!/usr/bin/env bash
# =============================================================================
# loadgen/install-load-tools.sh : installe les outils de la machine de charge.
# S'EXÉCUTE SUR : la machine de charge (Ubuntu), UNE SEULE FOIS.
# Installe : wrk, ApacheBench (ab), iperf3, jq, Docker (pour Prometheus/Grafana),
# Python (analyse) et compile wrk2 (latences à débit constant) depuis les sources.
# Crée aussi la clé SSH vers la cible si elle n'existe pas.
# =============================================================================
set -Eeuo pipefail
TAG=loadgen
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

[ "$(uname -s)" = "Linux" ] || die "À lancer dans l'Ubuntu de la machine de charge (VirtualBox ou clé live), pas sous Windows."
command -v apt-get >/dev/null || die "apt-get introuvable (Debian/Ubuntu requis)."

log "Installation des paquets"
${SUDO} apt-get update -qq
${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  wrk apache2-utils iperf3 jq curl openssh-client git tmux build-essential libssl-dev zlib1g-dev \
  docker.io docker-compose-v2 python3 python3-pip python3-pandas python3-matplotlib python3-scipy

${SUDO} systemctl enable --now docker 2>/dev/null || true
${SUDO} usermod -aG docker "${SUDO_USER:-${USER:-$(id -un)}}" || true

if ! command -v wrk2 >/dev/null; then
  log "Compilation de wrk2 (peut échouer sur certains systèmes : l'orchestrateur se rabat alors sur wrk)"
  tmp="$(mktemp -d)"
  if git clone --depth 1 https://github.com/giltene/wrk2.git "${tmp}/wrk2" \
     && make -C "${tmp}/wrk2" -j"$(nproc)" \
     && ${SUDO} install -m 0755 "${tmp}/wrk2/wrk" /usr/local/bin/wrk2; then
    log "wrk2 installé."
  else
    warn "Compilation de wrk2 échouée : wrk sera utilisé à la place (limite documentée dans le README)."
  fi
  rm -rf "${tmp}"
fi

if [ ! -f "${TARGET_SSH_KEY}" ]; then
  log "Création de la clé SSH ${TARGET_SSH_KEY}"
  mkdir -p "$(dirname "${TARGET_SSH_KEY}")"
  ssh-keygen -q -t ed25519 -N "" -f "${TARGET_SSH_KEY}"
fi

log "Versions installées :"
{ wrk -v 2>&1 | head -n1; ab -V 2>&1 | head -n1; iperf3 --version | head -n1; jq --version; command -v wrk2 || echo "wrk2 : absent"; } >&2 || true
cat >&2 <<MSG

Étapes manuelles restantes (une seule fois) :
  1. Reconnectez-vous (groupe docker), puis renseignez TARGET_HOST et TARGET_USER dans config.env.
  2. Copiez votre clé sur la cible :   ssh-copy-id -i ${TARGET_SSH_KEY}.pub ${TARGET_USER}@${TARGET_HOST}
  3. Testez :                          ssh -i ${TARGET_SSH_KEY} ${TARGET_USER}@${TARGET_HOST} 'echo ok'
MSG
