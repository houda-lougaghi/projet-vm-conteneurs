#!/usr/bin/env bash
# =============================================================================
# target/prepare-host.sh : prépare la machine cible pour des mesures stables.
# S'EXÉCUTE SUR : la machine cible (Linux).
#
# Usage : ./target/prepare-host.sh <action>
#   install [--passwordless-sudo]   installe KVM/libvirt, Docker, SSH et les outils (Debian/Ubuntu)
#   apply                           fixe le gouverneur CPU et le mode turbo (valeurs ci-dessous)
#   restore                         remet les réglages d'origine
#   status                          affiche l'état de la machine (fréquence, température, batterie...)
#   info                            écrit et affiche work/host-info.txt (matériel et versions)
# Réglages de « apply » (variables d'environnement) :
#   HOST_GOVERNOR=performance   gouverneur de fréquence
#   HOST_NO_TURBO=keep          keep (ne pas toucher) | 1 (désactiver le turbo) | 0 (activer)
# =============================================================================
set -Eeuo pipefail
TAG=host
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
usage() { sed -n '2,16p' "${BASH_SOURCE[0]}"; }

ACTION="${1:-status}"
if [ $# -gt 0 ]; then shift; fi
HOST_GOVERNOR="${HOST_GOVERNOR:-performance}"
HOST_NO_TURBO="${HOST_NO_TURBO:-keep}"
STATE="${WORKDIR}/host-state.env"
TURBO=/sys/devices/system/cpu/intel_pstate/no_turbo
mkdir -p "${WORKDIR}"

do_install() {
  local passwordless=0
  [ "${1:-}" = "--passwordless-sudo" ] && passwordless=1
  command -v apt-get >/dev/null || die "apt-get introuvable : installez à la main les équivalents Debian/Ubuntu (voir README)."
  local pkgs=(qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst cloud-image-utils
              docker.io iptables curl jq sysstat lm-sensors openssh-server)
  log "Installation des paquets : ${pkgs[*]}"
  ${SUDO} apt-get update -qq
  ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  local s
  for s in libvirtd docker ssh; do ${SUDO} systemctl enable --now "${s}" 2>/dev/null || warn "service ${s} non démarré"; done
  local u="${SUDO_USER:-${USER:-$(id -un)}}"
  ${SUDO} usermod -aG libvirt,kvm,docker "${u}"
  if [ "${passwordless}" -eq 1 ]; then
    local f="/etc/sudoers.d/90-bench-${u}"
    echo "${u} ALL=(ALL) NOPASSWD:ALL" | ${SUDO} tee "${f}" >/dev/null
    ${SUDO} chmod 0440 "${f}"
    ${SUDO} visudo -cf "${f}" >/dev/null || { ${SUDO} rm -f "${f}"; die "Règle sudoers invalide : supprimée."; }
    log "sudo sans mot de passe activé pour ${u} (nécessaire à l'automatisation ; acceptable sur une machine de laboratoire)."
  else
    warn "Sans --passwordless-sudo, l'orchestrateur (SSH, sans terminal) ne pourra pas utiliser sudo."
  fi
  log "Terminé. Déconnectez-vous puis reconnectez-vous pour que les groupes libvirt/kvm/docker soient pris en compte."
  log "Rappel : la virtualisation (VT-x/AMD-V) doit être activée dans le BIOS/UEFI."
}

do_apply() {
  local gov_old="" turbo_old="" f
  f=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
  [ -r "${f}" ] && gov_old="$(cat "${f}")"
  [ -r "${TURBO}" ] && turbo_old="$(cat "${TURBO}")"
  { echo "GOV_OLD=${gov_old}"; echo "TURBO_OLD=${turbo_old}"; } > "${STATE}"
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -e "${f}" ] || continue
    echo "${HOST_GOVERNOR}" | ${SUDO} tee "${f}" >/dev/null || warn "gouverneur non modifiable : ${f}"
  done
  if [ "${HOST_NO_TURBO}" != keep ]; then
    if [ -e "${TURBO}" ]; then echo "${HOST_NO_TURBO}" | ${SUDO} tee "${TURBO}" >/dev/null
    else warn "Pas de contrôle du turbo (intel_pstate absent) : réglage ignoré."; fi
  fi
  log "Gouverneur : ${HOST_GOVERNOR} (avant : ${gov_old:-inconnu}) ; no_turbo : ${HOST_NO_TURBO} (avant : ${turbo_old:-inconnu})"
  do_status
  do_info >/dev/null
}

do_restore() {
  [ -f "${STATE}" ] || die "Aucun état sauvegardé (${STATE}) : rien à restaurer."
  # shellcheck disable=SC1090
  source "${STATE}"
  local f
  if [ -n "${GOV_OLD:-}" ]; then
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      [ -e "${f}" ] && echo "${GOV_OLD}" | ${SUDO} tee "${f}" >/dev/null
    done
  fi
  if [ -n "${TURBO_OLD:-}" ] && [ -e "${TURBO}" ]; then echo "${TURBO_OLD}" | ${SUDO} tee "${TURBO}" >/dev/null; fi
  log "Réglages d'origine restaurés (gouverneur ${GOV_OLD:-?}, no_turbo ${TURBO_OLD:-?})."
}

do_status() {
  echo "== alimentation ==" >&2
  local ac found=0
  for ac in /sys/class/power_supply/A*/online /sys/class/power_supply/AC*/online; do
    if [ -r "${ac}" ]; then found=1; echo "secteur branché : $(cat "${ac}") (1 = oui)" >&2; break; fi
  done
  [ "${found}" -eq 1 ] || echo "état du secteur : inconnu" >&2
  echo "== processeur ==" >&2
  echo "gouverneur : $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo inconnu)" >&2
  echo "no_turbo   : $(cat "${TURBO}" 2>/dev/null || echo inconnu)" >&2
  echo "fréquences (MHz) : $(awk '/MHz/{printf "%d ", $4}' /proc/cpuinfo)" >&2
  if command -v sensors >/dev/null; then echo "== températures ==" >&2; sensors 2>/dev/null | grep -Ei 'package|core|temp1' >&2 || true; fi
  echo "== mémoire ==" >&2; free -m >&2
  echo "== instances ==" >&2
  echo "VM : $(virsh --connect "${LIBVIRT_URI}" list --name 2>/dev/null | grep -c . || true) en cours ; conteneurs : $(docker ps -q 2>/dev/null | wc -l)" >&2
}

do_info() {
  local f="${WORKDIR}/host-info.txt"
  {
    echo "== date =="; date -Is
    echo "== noyau =="; uname -a
    echo "== processeur =="; lscpu
    echo "== mémoire =="; free -m
    echo "== disques =="; lsblk -d -o NAME,ROTA,SIZE,MODEL; df -h /
    echo "== gouverneur / turbo =="
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo inconnu
    cat "${TURBO}" 2>/dev/null || echo "no_turbo inconnu"
    echo "== versions =="
    qemu-system-x86_64 --version 2>/dev/null | head -n1 || true
    echo "libvirt $(virsh --version 2>/dev/null || echo ?)"
    echo "virt-install $(virt-install --version 2>/dev/null || echo ?)"
    echo "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo ?)"
    echo "pilote de stockage docker : $(docker info --format '{{.Driver}}' 2>/dev/null || echo ?)"
    echo "cgroups docker : v$(docker info --format '{{.CgroupVersion}}' 2>/dev/null || echo ?)"
    echo "== réseau =="; ip -br addr 2>/dev/null || true
  } > "${f}" 2>&1 || true
  cat "${f}"
}

case "${ACTION}" in
  install) do_install "${1:-}" ;;
  apply)   do_apply ;;
  restore) do_restore ;;
  status)  do_status ;;
  info)    do_info ;;
  *)       usage; exit 2 ;;
esac
