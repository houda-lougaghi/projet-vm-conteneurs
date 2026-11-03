#!/usr/bin/env bash
# =============================================================================
# lib/common.sh : configuration et fonctions communes (à « sourcer », pas à lancer)
# Les messages (log, warn, die) vont sur la SORTIE D'ERREUR : la sortie standard
# est réservée aux données (CSV) que l'orchestrateur récupère par SSH.
# =============================================================================
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${ROOT_DIR}/config.env}"
[ -f "${CONFIG_FILE}" ] || { echo "config.env introuvable : ${CONFIG_FILE}" >&2; exit 1; }
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

TAG="${TAG:-bench}"
log()  { printf '\033[1;34m[%s]\033[0m %s\n' "${TAG}" "$*" >&2; }
warn() { printf '\033[1;33m[%s][ATTENTION]\033[0m %s\n' "${TAG}" "$*" >&2; }
die()  { printf '\033[1;31m[%s][ERREUR]\033[0m %s\n' "${TAG}" "$*" >&2; exit 1; }

# Chemins relatifs -> absolus (relatifs à la racine du projet)
case "${WORKDIR}" in /*) ;; *) WORKDIR="${ROOT_DIR}/${WORKDIR}" ;; esac
case "${RESULTS_DIR}" in /*) ;; *) RESULTS_DIR="${ROOT_DIR}/${RESULTS_DIR}" ;; esac
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# resolve_profile A|B : positionne VCPUS, RAM_MB et PROFILE_NAME
resolve_profile() {
  local p="${1:-${PROFILE}}" v r
  v="PROFILE_${p}_VCPUS"; r="PROFILE_${p}_RAM_MB"
  VCPUS="${!v:-}"; RAM_MB="${!r:-}"
  if [ -z "${VCPUS}" ] || [ -z "${RAM_MB}" ]; then
    die "Profil inconnu : ${p} (définir PROFILE_${p}_VCPUS et PROFILE_${p}_RAM_MB dans config.env)"
  fi
  PROFILE_NAME="${p}"
}

now()     { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", b-a}'; }

# wait_http URL [délai_s] : attend qu'une URL réponde (code 2xx). Retour 1 si délai dépassé.
wait_http() {
  local url="$1" end=$((SECONDS + ${2:-300}))
  until curl -fs --max-time 1 -o /dev/null "${url}"; do
    [ "${SECONDS}" -lt "${end}" ] || return 1
    sleep 0.1
  done
}

# csv_get fichier indice colonne : valeur d'une colonne pour l'instance numéro <indice>
csv_get() {
  awk -F, -v idx="$2" -v col="$3" \
    'NR==1{for(i=1;i<=NF;i++) if($i==col) c=i; next} $2==idx && c {print $c}' "$1"
}
