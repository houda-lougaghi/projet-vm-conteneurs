#!/usr/bin/env bash
# =============================================================================
# target/deploy-container.sh : gère un lot de N conteneurs Docker identiques,
# avec les mêmes ressources que les VM (profils de config.env).
# S'EXÉCUTE SUR : la machine cible (Linux).
#
# Usage : ./target/deploy-container.sh <action> [-n N] [-p A|B] [--fast]
#   up        s'assure que N conteneurs tournent (crée les manquants, supprime les surnuméraires)
#   down      supprime tous les conteneurs
#   redeploy  down puis up
#   status    état des conteneurs
#   check     vérifie seulement Docker
# Options : -n N (défaut 1) ; -p A|B (profil) ; --fast (pas de vérification des prérequis,
#           et pas de reconstruction de l'image si elle existe déjà).
# Écrit work/instances-docker.csv, lu par l'orchestrateur.
# =============================================================================
set -Eeuo pipefail
TAG=docker
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

usage() { sed -n '2,17p' "${BASH_SOURCE[0]}"; }

ACTION="${1:-status}"
if [ $# -gt 0 ]; then shift; fi
N=1; PROFILE_OPT="${PROFILE}"; FAST=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n) N="$2"; shift 2 ;;
    -p|--profile) PROFILE_OPT="$2"; shift 2 ;;
    --fast) FAST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Argument inconnu : $1" ;;
  esac
done
case "${ACTION}" in -h|--help|help) usage; exit 0 ;; esac
resolve_profile "${PROFILE_OPT}"

CSV="${WORKDIR}/instances-docker.csv"
mkdir -p "${WORKDIR}"
ctr_name() { echo "${CTR_PREFIX}-$1"; }
existing_indices() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | sed -n "s/^${CTR_PREFIX}-\([0-9][0-9]*\)$/\1/p" | sort -n || true
}

check_host() {
  [ "$(uname -s)" = "Linux" ] || die "Un hôte Linux est nécessaire : sous Windows/macOS, Docker Desktop exécute les conteneurs Linux dans une VM, ce qui fausserait la comparaison."
  command -v docker >/dev/null || die "Docker absent. Lancez d'abord : ./target/prepare-host.sh install"
  command -v curl   >/dev/null || die "curl absent. Lancez d'abord : ./target/prepare-host.sh install"
  docker info >/dev/null 2>&1 || die "Démon Docker injoignable : service arrêté, ou utilisateur absent du groupe 'docker' (reconnexion nécessaire)."
  if [ "${CTR_NETWORK_MODE}" = host ] && [ "${N}" -gt 1 ]; then die "CTR_NETWORK_MODE=host n'autorise qu'une instance."; fi
  log "Prérequis OK."
}

build_image() {
  if [ "${FAST}" -eq 1 ] && docker image inspect "${CTR_IMAGE}" >/dev/null 2>&1; then return 0; fi
  log "Construction de l'image ${CTR_IMAGE}"
  docker build -q -t "${CTR_IMAGE}" -f "${ROOT_DIR}/docker/Dockerfile" "${ROOT_DIR}" >/dev/null
}

create_instance() { # indice
  local i="$1" n cpus="" start c v ncpu
  n="$(ctr_name "${i}")"
  local opts=(-d --name "${n}" --cpus "${VCPUS}" --memory "${RAM_MB}m" --memory-swap "${RAM_MB}m")
  if [ "${CTR_NETWORK_MODE}" = host ]; then
    opts+=(--network host)
  else
    opts+=(-p "$((CTR_HTTP_PORT_BASE + i)):80" -p "$((CTR_IPERF_PORT_BASE + i)):5201" -p "$((CTR_IPERF_PORT_BASE + i)):5201/udp")
  fi
  if [ "${CPU_PIN}" = spread ]; then
    ncpu="$(nproc)"; start=$(( (i - 1) * VCPUS ))
    for ((v = 0; v < VCPUS; v++)); do
      c=$(( (start + v) % ncpu )); cpus="${cpus:+${cpus},}${c}"
    done
    opts+=(--cpuset-cpus "${cpus}")
  fi
  if [ "${CTR_DATA_MODE}" = volume ]; then opts+=(-v "${n}-data:/data"); fi
  log "Création de ${n} (${VCPUS} CPU, ${RAM_MB} Mo)"
  docker run "${opts[@]}" "${CTR_IMAGE}" >/dev/null
}

remove_instance() { # indice
  local n; n="$(ctr_name "$1")"
  docker rm -f "${n}" >/dev/null 2>&1 || true
  docker volume rm "${n}-data" >/dev/null 2>&1 || true
}

http_port() { if [ "${CTR_NETWORK_MODE}" = host ]; then echo 80; else echo $((CTR_HTTP_PORT_BASE + $1)); fi; }
iperf_port() { if [ "${CTR_NETWORK_MODE}" = host ]; then echo 5201; else echo $((CTR_IPERF_PORT_BASE + $1)); fi; }

write_csv() {
  local i n ip dd
  if [ "${CTR_DATA_MODE}" = volume ]; then dd=/data/fio; else dd=/var/tmp/fio; fi
  echo "env,index,name,profile,vcpus,ram_mb,inner_ip,access_host,http_port,iperf_port,data_dir" > "${CSV}.tmp"
  for i in $(existing_indices); do
    n="$(ctr_name "${i}")"
    ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${n}" 2>/dev/null || true)"
    echo "docker,${i},${n},${PROFILE_NAME},${VCPUS},${RAM_MB},${ip},,$(http_port "${i}"),$(iperf_port "${i}"),${dd}" >> "${CSV}.tmp"
  done
  mv "${CSV}.tmp" "${CSV}"
}

do_down() {
  local i
  for i in $(existing_indices); do remove_instance "${i}"; done
  rm -f "${CSV}"
  log "Tous les conteneurs '${CTR_PREFIX}-*' ont été supprimés."
}

do_up() {
  if [ "${FAST}" -ne 1 ]; then check_host; fi
  build_image
  local i n cur_v cur_r
  if [ -f "${CSV}" ]; then
    cur_v="$(awk -F, 'NR==2{print $5}' "${CSV}")"; cur_r="$(awk -F, 'NR==2{print $6}' "${CSV}")"
    if [ -n "${cur_v}" ] && { [ "${cur_v}" != "${VCPUS}" ] || [ "${cur_r}" != "${RAM_MB}" ]; }; then
      log "Profil différent de celui des conteneurs existants : recréation."
      do_down
    fi
  fi
  for i in $(existing_indices); do
    if [ "${i}" -gt "${N}" ]; then remove_instance "${i}"; fi
  done
  for ((i = 1; i <= N; i++)); do
    n="$(ctr_name "${i}")"
    if ! docker container inspect "${n}" >/dev/null 2>&1; then
      create_instance "${i}"
    elif [ "$(docker inspect -f '{{.State.Running}}' "${n}")" != true ]; then
      docker start "${n}" >/dev/null
    fi
  done
  for ((i = 1; i <= N; i++)); do
    wait_http "http://127.0.0.1:$(http_port "${i}")/" "${READY_TIMEOUT_S}" \
      || die "$(ctr_name "${i}") : l'application ne répond pas (diagnostic : docker logs $(ctr_name "${i}"))"
  done
  write_csv
  log "${N} conteneur(s) prêt(s), profil ${PROFILE_NAME} : voir ${CSV}"
}

do_status() {
  docker ps -a --filter "name=${CTR_PREFIX}-" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  if [ -f "${CSV}" ]; then cat "${CSV}"; else echo "(aucun conteneur enregistré)"; fi
}

case "${ACTION}" in
  up)       do_up ;;
  down)     check_host; do_down ;;
  redeploy) check_host; do_down; do_up ;;
  status)   do_status ;;
  check)    check_host ;;
  *)        usage; exit 2 ;;
esac
