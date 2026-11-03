#!/usr/bin/env bash
# =============================================================================
# target/instance-stats.sh : ressources consommées par chaque instance (VM et conteneurs),
# vues DEPUIS L'HÔTE, donc avec le même point de vue pour les deux environnements.
# S'EXÉCUTE SUR : la machine cible.
# Sortie (stdout) : env,nom,cpu_secondes,mem_mo,mem_anonyme_mo
#   VM         : temps CPU et mémoire résidente (RSS) du processus QEMU de la VM.
#   conteneur  : compteurs du cgroup du conteneur (cgroup v2 ; sinon colonnes vides).
# Remarque : la mémoire d'un conteneur (memory.current) inclut le cache de fichiers ;
# la colonne « anonyme » l'exclut. Le choix de la mesure de référence est à fixer en phase 2.
# =============================================================================
set -u
TAG=stats
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
CLK="$(getconf CLK_TCK)"

vm_csv="${WORKDIR}/instances-vm.csv"
if [ -f "${vm_csv}" ]; then
  tail -n +2 "${vm_csv}" | while IFS=, read -r _env _idx name _rest; do
    pidf=""
    for f in "/run/libvirt/qemu/${name}.pid" "/var/run/libvirt/qemu/${name}.pid"; do
      if [ -f "${f}" ]; then pidf="${f}"; break; fi
    done
    [ -n "${pidf}" ] || continue
    pid="$(cat "${pidf}")"
    [ -r "/proc/${pid}/stat" ] || continue
    cpu="$(awk -v c="${CLK}" '{printf "%.2f", ($14+$15)/c}' "/proc/${pid}/stat")"
    rss="$(awk '/^VmRSS:/{printf "%.0f", $2/1024}' "/proc/${pid}/status")"
    anon="$(awk '/^RssAnon:/{printf "%.0f", $2/1024}' "/proc/${pid}/status")"
    echo "vm,${name},${cpu},${rss},${anon}"
  done
fi

ctr_csv="${WORKDIR}/instances-docker.csv"
if [ -f "${ctr_csv}" ]; then
  tail -n +2 "${ctr_csv}" | while IFS=, read -r _env _idx name _rest; do
    id="$(docker inspect -f '{{.Id}}' "${name}" 2>/dev/null || true)"
    [ -n "${id}" ] || continue
    cg=""
    for d in "/sys/fs/cgroup/system.slice/docker-${id}.scope" "/sys/fs/cgroup/docker/${id}"; do
      if [ -d "${d}" ]; then cg="${d}"; break; fi
    done
    if [ -n "${cg}" ] && [ -f "${cg}/memory.current" ]; then
      mem="$(awk '{printf "%.0f", $1/1048576}' "${cg}/memory.current")"
      anon="$(awk '/^anon /{printf "%.0f", $2/1048576}' "${cg}/memory.stat")"
      cpu="$(awk '/^usage_usec/{printf "%.2f", $2/1000000}' "${cg}/cpu.stat")"
    else
      mem=""; anon=""; cpu=""
    fi
    echo "docker,${name},${cpu},${mem},${anon}"
  done
fi
