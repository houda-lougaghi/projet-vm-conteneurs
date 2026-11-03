#!/usr/bin/env bash
# =============================================================================
# target/sampler.sh : échantillonne l'utilisation de la machine cible.
# S'EXÉCUTE SUR : la machine cible. Lancé par l'orchestrateur (SSH) pendant un essai.
# Usage : ./target/sampler.sh <durée_s> [intervalle_s]
# Sortie (stdout, une ligne par échantillon) : horodatage,cpu_pct,mem_utilisee_mo,mem_utilisee_pct
#   cpu_pct : part du temps CPU non inactif (hors attente d'E/S), toutes instances comprises.
# =============================================================================
set -u
DURATION="${1:?durée en secondes}"; INTERVAL="${2:-1}"

read_cpu() { awk '/^cpu /{idle=$5; total=0; for(i=2;i<=NF;i++) total+=$i; print idle, total}' /proc/stat; }

end=$((SECONDS + DURATION))
read -r pi pt < <(read_cpu)
while [ "${SECONDS}" -lt "${end}" ]; do
  sleep "${INTERVAL}"
  read -r ci ct < <(read_cpu)
  cpu="$(awk -v pi="${pi}" -v pt="${pt}" -v ci="${ci}" -v ct="${ct}" \
    'BEGIN{d=ct-pt; if(d<=0) print "0.00"; else printf "%.2f", 100*(1-(ci-pi)/d)}')"
  mem="$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%.0f,%.2f", (t-a)/1024, 100*(t-a)/t}' /proc/meminfo)"
  echo "$(date +%s.%N),${cpu},${mem}"
  pi="${ci}"; pt="${ct}"
done
