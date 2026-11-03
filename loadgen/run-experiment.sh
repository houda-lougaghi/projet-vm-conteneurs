#!/usr/bin/env bash
# =============================================================================
# loadgen/run-experiment.sh : ORCHESTRATEUR des expériences (« chef d'orchestre »).
# S'EXÉCUTE SUR : la machine de charge. Il pilote la machine cible par SSH, enchaîne les essais,
# répète chaque mesure (échauffement + répétitions), vide les caches, lance la charge depuis
# cette machine et enregistre tout en CSV : results/<run>/results.csv + sorties brutes (raw/).
#
# Usage : ./loadgen/run-experiment.sh [options] <scénario...>
#   scénarios : s1 (démarrage) s2 (CPU/mémoire) s3 (réseau) s4 (disque) s5 (application)
#               s6 (densité) all
# Options :
#   --env vm|docker|both   environnement testé (défaut : both)
#   --run-id NOM           nom du dossier de résultats (défaut : date et heure)
#   --quick                version courte pour tester les scripts (2 essais, durées réduites) ;
#                          les résultats ne sont PAS exploitables pour l'étude
#   --keep                 laisse les instances en place à la fin (défaut : tout supprimer)
#   --dry-run              affiche le plan sans rien exécuter
# Exemple : ./loadgen/run-experiment.sh --quick s1 s3
# =============================================================================
set -Euo pipefail
TAG=orch
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
LD="${ROOT_DIR}/loadgen"
# shellcheck disable=SC1091
source "${LD}/lib/orch.sh"
for _f in "${LD}"/scenarios/s*.sh; do
  # shellcheck disable=SC1090
  source "${_f}"
done

usage() { sed -n '2,23p' "${BASH_SOURCE[0]}"; }

ENVS="vm docker"; QUICK=0; KEEP=0; DRY=0; RUN_ID="$(date +%Y%m%d-%H%M%S)"; SCENARIOS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --env) case "$2" in vm) ENVS="vm" ;; docker) ENVS="docker" ;; both) ENVS="vm docker" ;; *) die "--env : vm, docker ou both" ;; esac; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --quick) QUICK=1; shift ;;
    --keep) KEEP=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    s1|s2|s3|s4|s5|s6) SCENARIOS+=("$1"); shift ;;
    all) SCENARIOS=(s1 s2 s3 s4 s5 s6); shift ;;
    *) die "Argument inconnu : $1 (voir --help)" ;;
  esac
done
[ "${#SCENARIOS[@]}" -gt 0 ] || { usage; exit 2; }

# Mode court : pour vérifier que tout fonctionne, pas pour mesurer
if [ "${QUICK}" -eq 1 ]; then
  REPEATS=2; WARMUP=1; PAUSE_S=2; IDLE_SAMPLE_S=5; STRESS_TIMEOUT=10; IPERF_TIME=5; WRK_DURATION=5
  FIO_RUNTIME=8; FIO_RAMP=2; FIO_SIZE=256M; S5_DURATION=8; S5_AB_REQUESTS=5000; S5_RATES="500 2000"
  S6_LEVELS="1 2"; S6_DURATION=8; S6_REPEATS=1; S4_LEVELS="1"; INSTANCE_LEVELS="1 2"
  warn "MODE COURT : résultats non exploitables pour l'étude."
fi

RUN_DIR="${RESULTS_DIR}/${RUN_ID}"; RAW_DIR="${RUN_DIR}/raw"

plan() {
  local s
  log "Plan : scénarios [${SCENARIOS[*]}], environnements [${ENVS}], ${WARMUP} essai(s) d'échauffement + ${REPEATS} répétition(s)"
  log "Cible : ${TARGET_USER}@${TARGET_HOST} (projet : ~/${TARGET_PROJECT_DIR}) ; résultats : ${RUN_DIR}"
  for s in "${SCENARIOS[@]}"; do
    case "${s}" in
      s1) log "  s1 : démarrage/arrêt/redéploiement, profil ${S1_PROFILE}" ;;
      s2) log "  s2 : CPU/mémoire, paliers [${INSTANCE_LEVELS}], profil ${S2_PROFILE}" ;;
      s3) log "  s3 : réseau, profil ${S3_PROFILE}" ;;
      s4) log "  s4 : disque, instances en concurrence [${S4_LEVELS}], profil ${S4_PROFILE}" ;;
      s5) log "  s5 : application, débits [${S5_RATES}], profil ${S5_PROFILE}" ;;
      s6) log "  s6 : densité, paliers [${S6_LEVELS}], profil ${S6_PROFILE}, limite ${S6_MEM_LIMIT_PCT} %" ;;
    esac
  done
}

preflight() {
  local c e
  log "Vérifications préalables"
  for c in wrk ab iperf3 jq ssh awk curl; do
    command -v "${c}" >/dev/null || die "Outil manquant sur la machine de charge : ${c} (lancez ./loadgen/install-load-tools.sh)"
  done
  tssh true 2>/dev/null || die "SSH impossible vers ${TARGET_USER}@${TARGET_HOST} : vérifiez TARGET_HOST, TARGET_USER, la clé (ssh-copy-id) et le réseau."
  tssh "sudo -n true" 2>/dev/null || die "sudo sans mot de passe indisponible sur la cible : lancez sur la cible ./target/prepare-host.sh install --passwordless-sudo"
  tssh "test -x ${TARGET_PROJECT_DIR}/target/setup-vm.sh" 2>/dev/null \
    || die "Projet absent ou scripts non exécutables sur la cible (~/${TARGET_PROJECT_DIR}) : git clone puis chmod +x (voir README)."
  for e in ${ENVS}; do
    if [ "${e}" = vm ]; then tproj "./target/setup-vm.sh check" >&2 || die "Prérequis VM non satisfaits sur la cible."
    else tproj "./target/deploy-container.sh check" >&2 || die "Prérequis Docker non satisfaits sur la cible."; fi
  done
}

write_meta() {
  mkdir -p "${RUN_DIR}/meta" "${RAW_DIR}"
  cp "${CONFIG_FILE}" "${RUN_DIR}/meta/config.env"
  tproj "./target/prepare-host.sh info" > "${RUN_DIR}/meta/host-info.txt" 2>/dev/null || warn "host-info indisponible"
  {
    echo "date : $(date -Is)"
    echo "commit : $(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null || echo inconnu)"
    echo "scénarios : ${SCENARIOS[*]} ; environnements : ${ENVS} ; mode court : ${QUICK}"
    echo "machine de charge : $(uname -srvm)"
    wrk -v 2>&1 | head -n1 || true
    ab -V 2>&1 | head -n1 || true
    iperf3 --version 2>&1 | head -n1 || true
    jq --version || true
    echo "wrk2 : ${WRK2_BIN:-absent}"
  } > "${RUN_DIR}/meta/loadgen-info.txt" 2>&1
  echo "date,scenario,env,profile,level,rep,warmup,instance,metric,value,unit" > "${RUN_DIR}/results.csv"
}

plan
if [ "${DRY}" -eq 1 ]; then log "(--dry-run : rien n'est exécuté)"; exit 0; fi
trap 'warn "Interrompu."; exit 130' INT TERM
preflight
write_meta
T0="${SECONDS}"
for s in "${SCENARIOS[@]}"; do
  log "=== Scénario ${s} ==="
  "scenario_${s}" || warn "Le scénario ${s} s'est terminé avec une erreur."
done
if [ "${KEEP}" -eq 0 ]; then tdown vm || true; tdown docker || true; fi
log "Terminé en $(( (SECONDS - T0) / 60 )) min. Résultats : ${RUN_DIR}/results.csv"
log "Analyse : python3 analysis/analyze.py ${RUN_DIR}"
