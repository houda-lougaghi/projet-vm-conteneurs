#!/usr/bin/env bash
# =============================================================================
# target/monitoring.sh : démarre ou arrête les exportateurs de supervision (cAdvisor, node_exporter).
# S'EXÉCUTE SUR : la machine cible. Usage : ./target/monitoring.sh up|down|status
# Ports : cAdvisor 18080, node_exporter 9100. À lancer AVANT les essais « avec supervision » ;
# ne pas les lancer pour les essais « sans supervision » (comparaison exigée par le CDC).
# =============================================================================
set -Eeuo pipefail
TAG=monitoring
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
F="${ROOT_DIR}/target/monitoring/docker-compose.yml"
if docker compose version >/dev/null 2>&1; then DC=(docker compose -f "${F}")
elif command -v docker-compose >/dev/null; then DC=(docker-compose -f "${F}")
else die "Ni 'docker compose' ni 'docker-compose' : sudo apt install docker-compose-v2"; fi
case "${1:-status}" in
  up)     "${DC[@]}" up -d; log "cAdvisor : http://<cible>:18080   node_exporter : http://<cible>:9100/metrics" ;;
  down)   "${DC[@]}" down ;;
  status) "${DC[@]}" ps ;;
  *)      echo "Usage : $0 up|down|status" >&2; exit 2 ;;
esac
