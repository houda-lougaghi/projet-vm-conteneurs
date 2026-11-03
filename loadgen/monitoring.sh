#!/usr/bin/env bash
# =============================================================================
# loadgen/monitoring.sh : démarre ou arrête Prometheus et Grafana.
# S'EXÉCUTE SUR : la machine de charge. Usage : ./loadgen/monitoring.sh up|down|status
# Grafana : http://localhost:3000 (identifiants initiaux admin / admin) ; la source de données
# Prometheus est préconfigurée. Tableaux de bord à importer par leur numéro : 1860 (Node Exporter
# Full), 14282 (cAdvisor).
# =============================================================================
set -Eeuo pipefail
TAG=monitoring
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
D="${ROOT_DIR}/loadgen/monitoring"
if docker compose version >/dev/null 2>&1; then DC=(docker compose -f "${D}/docker-compose.yml")
elif command -v docker-compose >/dev/null; then DC=(docker-compose -f "${D}/docker-compose.yml")
else die "Ni 'docker compose' ni 'docker-compose' : sudo apt install docker-compose-v2"; fi
case "${1:-status}" in
  up)     sed "s/__TARGET__/${TARGET_HOST}/g" "${D}/prometheus.yml.tpl" > "${D}/prometheus.generated.yml"
          "${DC[@]}" up -d
          log "Grafana : http://localhost:3000   Prometheus : http://localhost:9090" ;;
  down)   "${DC[@]}" down ;;
  status) "${DC[@]}" ps ;;
  *)      echo "Usage : $0 up|down|status" >&2; exit 2 ;;
esac
