#!/usr/bin/env bash
# =============================================================================
# target/measure-startup.sh : mesure UN essai de démarrage/arrêt (scénario 1).
# S'EXÉCUTE SUR : la machine cible (la mesure se fait en local, sans réseau intermédiaire).
# Usage : ./target/measure-startup.sh <vm|docker> <start|redeploy> [cold|warm]
#   start     : instance 1, arrêtée au départ ; temps jusqu'à ce que l'application réponde
#               (HTTP), puis temps d'un arrêt propre.
#   redeploy  : suppression puis recréation complète de l'instance 1 (création, démarrage,
#               première requête réussie). Nécessite l'image dorée / l'image Docker déjà prêtes.
#   cold      : caches de l'hôte vidés avant le démarrage ; warm : caches conservés.
# Sortie (stdout, une ligne) : durée_démarrage_s,durée_arrêt_s   (arrêt vide pour redeploy)
# Variable : BENCH_PROFILE (profil A ou B ; défaut : PROFILE de config.env).
# =============================================================================
set -Eeuo pipefail
TAG=startup
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

ENVN="${1:?vm|docker}"; WHAT="${2:-start}"; MODE="${3:-warm}"
PROF="${BENCH_PROFILE:-${PROFILE}}"
VIRSH=(virsh --connect "${LIBVIRT_URI}")

drop_caches() {
  if [ "${MODE}" = cold ]; then sync; echo 3 | ${SUDO} tee /proc/sys/vm/drop_caches >/dev/null; fi
}
vm_state() { "${VIRSH[@]}" domstate "$1" 2>/dev/null | head -n1 || true; }
wait_off() { # nom
  local end=$((SECONDS + 180))
  until [ "$(vm_state "$1")" = "shut off" ]; do
    [ "${SECONDS}" -lt "${end}" ] || die "$1 ne s'arrête pas."
    sleep 0.1
  done
}

case "${ENVN}:${WHAT}" in
  vm:start)
    name="${VM_PREFIX}-1"
    ip="$(csv_get "${WORKDIR}/instances-vm.csv" 1 inner_ip)"
    [ -n "${ip}" ] || die "Instance ${name} inconnue : lancez d'abord ./target/setup-vm.sh up -n 1"
    if [ "$(vm_state "${name}")" != "shut off" ]; then "${VIRSH[@]}" shutdown "${name}" >/dev/null; wait_off "${name}"; fi
    drop_caches
    t0="$(now)"; "${VIRSH[@]}" start "${name}" >/dev/null
    wait_http "http://${ip}/" 300 || die "${name} : pas de réponse HTTP."
    t1="$(now)"
    t2="$(now)"; "${VIRSH[@]}" shutdown "${name}" >/dev/null; wait_off "${name}"; t3="$(now)"
    echo "$(elapsed "${t0}" "${t1}"),$(elapsed "${t2}" "${t3}")"
    ;;
  docker:start)
    name="${CTR_PREFIX}-1"
    port="$(csv_get "${WORKDIR}/instances-docker.csv" 1 http_port)"
    [ -n "${port}" ] || die "Instance ${name} inconnue : lancez d'abord ./target/deploy-container.sh up -n 1"
    docker stop "${name}" >/dev/null 2>&1 || true
    drop_caches
    t0="$(now)"; docker start "${name}" >/dev/null
    wait_http "http://127.0.0.1:${port}/" 300 || die "${name} : pas de réponse HTTP."
    t1="$(now)"
    t2="$(now)"; docker stop "${name}" >/dev/null; t3="$(now)"
    echo "$(elapsed "${t0}" "${t1}"),$(elapsed "${t2}" "${t3}")"
    ;;
  vm:redeploy)
    drop_caches
    t0="$(now)"; "${ROOT_DIR}/target/setup-vm.sh" redeploy -n 1 -p "${PROF}" --fast >&2; t1="$(now)"
    echo "$(elapsed "${t0}" "${t1}"),"
    ;;
  docker:redeploy)
    drop_caches
    t0="$(now)"; "${ROOT_DIR}/target/deploy-container.sh" redeploy -n 1 -p "${PROF}" --fast >&2; t1="$(now)"
    echo "$(elapsed "${t0}" "${t1}"),"
    ;;
  *) die "Usage : $0 <vm|docker> <start|redeploy> [cold|warm]" ;;
esac
