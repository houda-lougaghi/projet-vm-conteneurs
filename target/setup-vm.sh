#!/usr/bin/env bash
# =============================================================================
# target/setup-vm.sh : gère un lot de N machines virtuelles identiques
# (KVM/QEMU + libvirt), sans interface graphique et sans ISO à choisir.
# S'EXÉCUTE SUR : la machine cible (Linux).
#
# Principe : on télécharge l'image cloud officielle d'Ubuntu (un disque déjà installé),
# on construit UNE FOIS une « image dorée » (paquets installés : nginx, fio, stress-ng,
# iperf3), puis chaque VM n'est qu'un disque dérivé de cette image : création rapide
# et identique, comme pour l'image Docker.
#
# Usage : ./target/setup-vm.sh <action> [-n N] [-p A|B] [--fast]
#   up        s'assure que N VM tournent (crée les manquantes, supprime les surnuméraires)
#   down      supprime toutes les VM (et leurs redirections de ports)
#   redeploy  down puis up
#   status    état des VM
#   check     vérifie seulement les prérequis de l'hôte
#   golden    reconstruit l'image dorée (après changement de l'application ou des paquets)
# Options : -n N (nombre de VM, défaut 1) ; -p A|B (profil de ressources, voir config.env) ;
#           --fast (ne refait pas la vérification des prérequis).
# Écrit work/instances-vm.csv, lu par l'orchestrateur.
# =============================================================================
set -Eeuo pipefail
TAG=vm
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}"; }

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

VIRSH=(virsh --connect "${LIBVIRT_URI}")
CSV="${WORKDIR}/instances-vm.csv"
KEY="${WORKDIR}/${VM_SSH_KEY_FILE}"
GOLDEN="${IMAGES_DIR}/${VM_PREFIX}-golden.qcow2"
BASE_COPY="${IMAGES_DIR}/base-${IMAGE_FILE}"
mkdir -p "${WORKDIR}"

vm_name()   { echo "${VM_PREFIX}-$1"; }
dom_state() { "${VIRSH[@]}" domstate "$1" 2>/dev/null | head -n1 || true; }
existing_indices() {
  "${VIRSH[@]}" list --all --name 2>/dev/null | sed -n "s/^${VM_PREFIX}-\([0-9][0-9]*\)$/\1/p" | sort -n || true
}
vm_ip() {
  local ip=""
  ip="$("${VIRSH[@]}" domifaddr "$1" --source lease 2>/dev/null | awk '/ipv4/{split($4,a,"/");print a[1];exit}')" || true
  if [ -z "${ip}" ]; then
    ip="$("${VIRSH[@]}" domifaddr "$1" --source arp 2>/dev/null | awk '/ipv4/{split($4,a,"/");print a[1];exit}')" || true
  fi
  printf '%s' "${ip}"
}
wait_ip() {
  local n="$1" end=$((SECONDS + ${2:-${READY_TIMEOUT_S}})) ip
  while [ "${SECONDS}" -lt "${end}" ]; do
    ip="$(vm_ip "${n}")"
    if [ -n "${ip}" ]; then echo "${ip}"; return 0; fi
    sleep 2
  done
  return 1
}
wait_state() { # nom état délai
  local end=$((SECONDS + ${3:-120}))
  until [ "$(dom_state "$1")" = "$2" ]; do
    [ "${SECONDS}" -lt "${end}" ] || return 1
    sleep 1
  done
}
vm_ssh() { # ip commande...
  local ip="$1"; shift
  ssh -i "${KEY}" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=5 "${VM_USER}@${ip}" "$@"
}

# -----------------------------------------------------------------------------
# Prérequis de l'hôte (la sélection des paquets se fait par target/prepare-host.sh install)
# -----------------------------------------------------------------------------
check_host() {
  [ "$(uname -s)" = "Linux" ] || die "Un hôte Linux est nécessaire (KVM est une fonction du noyau Linux)."
  grep -Eq '(vmx|svm)' /proc/cpuinfo \
    || die "Virtualisation matérielle absente ou désactivée (VT-x / AMD-V) : activez-la dans le BIOS/UEFI. (Dans une VM, la virtualisation imbriquée fausserait les mesures.)"
  local c missing=()
  for c in virsh virt-install qemu-img cloud-localds curl ssh-keygen iptables; do
    command -v "${c}" >/dev/null || missing+=("${c}")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "Commandes manquantes : ${missing[*]}. Lancez d'abord : ./target/prepare-host.sh install"
  fi
  [ -e /dev/kvm ] || die "/dev/kvm absent : modules KVM non chargés (virtualisation désactivée dans le BIOS ?)."
  "${VIRSH[@]}" list >/dev/null 2>&1 \
    || die "libvirt injoignable (${LIBVIRT_URI}) : service arrêté, ou utilisateur absent du groupe 'libvirt' (reconnexion nécessaire)."
  [ "${DISK_GB}" -ge 10 ] || die "DISK_GB doit être au moins 10 (taille de l'image dorée)."
  local net info
  net="$(sed -n 's/.*network=\([^,]*\).*/\1/p' <<<"${VM_NET_SPEC}")"
  if [ -n "${net}" ]; then
    info="$("${VIRSH[@]}" net-info "${net}" 2>&1)" || die "Réseau libvirt '${net}' introuvable : ${info}"
    if ! grep -Eq 'Active:[[:space:]]+yes' <<<"${info}"; then
      log "Démarrage du réseau libvirt '${net}'"
      "${VIRSH[@]}" net-start "${net}" >/dev/null
      "${VIRSH[@]}" net-autostart "${net}" >/dev/null || true
    fi
  fi
  if command -v osinfo-query >/dev/null; then
    local k
    k="$(osinfo-query -f short-id os short-id="${OS_VARIANT}" 2>/dev/null | grep -cw -- "${OS_VARIANT}" || true)"
    if [ "${k}" -lt 1 ]; then
      warn "Variante OS '${OS_VARIANT}' inconnue de libosinfo : utilisation de 'generic'."
      OS_VARIANT="generic"
    fi
  fi
  log "Prérequis OK."
}

# -----------------------------------------------------------------------------
# Image cloud : téléchargement et vérification d'intégrité (SHA-256)
# -----------------------------------------------------------------------------
prepare_image() {
  mkdir -p "${WORKDIR}/images"
  IMG="${WORKDIR}/images/${IMAGE_FILE}"
  if [ ! -f "${IMG}" ]; then
    log "Téléchargement de ${IMAGE_URL_BASE}/${IMAGE_FILE} (environ 600 Mo)"
    curl -fL --retry 3 -C - -o "${IMG}.part" "${IMAGE_URL_BASE}/${IMAGE_FILE}"
    mv "${IMG}.part" "${IMG}"
  fi
  local expected="${IMAGE_SHA256}" actual
  if [ -z "${expected}" ]; then
    expected="$(curl -fsSL "${IMAGE_URL_BASE}/SHA256SUMS" | awk -v f="${IMAGE_FILE}" '$2==f || $2=="*"f {print $1; exit}')" || true
  fi
  [ -n "${expected}" ] || die "Empreinte SHA-256 introuvable (ni dans config.env, ni dans ${IMAGE_URL_BASE}/SHA256SUMS)."
  actual="$(sha256sum "${IMG}" | awk '{print $1}')"
  [ "${actual}" = "${expected}" ] || die "Empreinte invalide (attendue ${expected}, obtenue ${actual}). Supprimez ${IMG} et relancez."
  log "Image vérifiée (sha256 ${actual}). Pour la figer : IMAGE_SHA256=${actual} dans config.env"
}

ensure_key() {
  [ -f "${KEY}" ] || ssh-keygen -q -t ed25519 -N "" -C "bench" -f "${KEY}"
}

# -----------------------------------------------------------------------------
# cloud-init : configuration du premier démarrage (utilisateur, clé SSH, paquets)
#   full  : image dorée (installe nginx, fio, stress-ng, iperf3 et la page de test)
#   light : VM dérivée (nom d'hôte et clé SSH seulement)
# -----------------------------------------------------------------------------
render_ci() { # genre nom dossier
  local kind="$1" host="$2" dir="$3" pub
  pub="$(cat "${KEY}.pub")"
  mkdir -p "${dir}"
  {
    printf '#cloud-config\nhostname: %s\nmanage_etc_hosts: true\nssh_pwauth: false\n' "${host}"
    cat <<UD
users:
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${pub}
UD
    if [ "${kind}" = full ]; then
      cat <<UD
package_update: true
packages: [nginx, curl, fio, stress-ng, iperf3, sysstat]
write_files:
  - path: /var/www/html/index.html
    owner: root:root
    permissions: '0644'
    encoding: b64
    content: $(base64 -w0 "${ROOT_DIR}/app/index.html")
  - path: /etc/systemd/system/iperf3-server.service
    permissions: '0644'
    content: |
      [Unit]
      Description=iperf3 server
      After=network.target
      [Service]
      ExecStart=/usr/bin/iperf3 -s
      Restart=always
      [Install]
      WantedBy=multi-user.target
runcmd:
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, --now, nginx ]
  - [ systemctl, enable, --now, iperf3-server ]
  - [ systemctl, disable, --now, apt-daily.timer, apt-daily-upgrade.timer, unattended-upgrades.service ]
UD
    fi
  } > "${dir}/user-data"
  printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "${host}" "$(date +%s%N)" "${host}" > "${dir}/meta-data"
}

make_seed() { # dossier fichier_iso
  if command -v cloud-localds >/dev/null; then
    ${SUDO} cloud-localds "$2" "$1/user-data" "$1/meta-data"
  else
    ${SUDO} genisoimage -quiet -output "$2" -volid cidata -joliet -rock "$1/user-data" "$1/meta-data"
  fi
  ${SUDO} chmod 0644 "$2"
}

make_disk() { # source_qcow2 destination
  case "${DISK_FORMAT}" in
    qcow2) ${SUDO} qemu-img create -q -f qcow2 -F qcow2 -b "$1" "$2" "${DISK_GB}G" ;;
    raw)   ${SUDO} qemu-img convert -O raw "$1" "$2"
           ${SUDO} qemu-img resize -q -f raw "$2" "${DISK_GB}G" ;;
    *)     die "DISK_FORMAT doit valoir qcow2 ou raw." ;;
  esac
}

define_vm() { # nom disque seed vcpus ram_mb
  virt-install --connect "${LIBVIRT_URI}" --name "$1" --memory "$5" --vcpus "$4" \
    --cpu "${CPU_MODE}" --os-variant "${OS_VARIANT}" --import --boot hd \
    --disk "path=$2,format=${DISK_FORMAT},bus=${DISK_BUS},cache=${DISK_CACHE}" \
    --disk "path=$3,device=cdrom" \
    --network "${VM_NET_SPEC}" \
    --graphics none --console pty,target_type=serial --noautoconsole >/dev/null
}

pin_vm() { # indice nom
  [ "${CPU_PIN}" = spread ] || return 0
  local ncpu start v c
  ncpu="$(nproc)"; start=$(( ($1 - 1) * VCPUS ))
  for ((v = 0; v < VCPUS; v++)); do
    c=$(( (start + v) % ncpu ))
    "${VIRSH[@]}" vcpupin "$2" "${v}" "${c}" --live --config >/dev/null || warn "vcpupin échoué pour $2"
  done
}

# -----------------------------------------------------------------------------
# Redirection de ports (réseau NAT) : la machine de charge joint une VM via
# <IP de la cible>:<port>, redirigé par iptables vers <IP de la VM>:<port interne>.
# Équivalent, côté VM, de la publication de ports de Docker.
# -----------------------------------------------------------------------------
pf_add() { # port_externe ip port_interne
  [ "${VM_FORWARD_PORTS}" = 1 ] || return 0
  ${SUDO} iptables -t nat -C PREROUTING -p tcp --dport "$1" -j DNAT --to-destination "$2:$3" 2>/dev/null \
    || ${SUDO} iptables -t nat -A PREROUTING -p tcp --dport "$1" -j DNAT --to-destination "$2:$3"
  ${SUDO} iptables -C FORWARD -p tcp -d "$2" --dport "$3" -j ACCEPT 2>/dev/null \
    || ${SUDO} iptables -I FORWARD 1 -p tcp -d "$2" --dport "$3" -j ACCEPT
}
pf_del() {
  [ "${VM_FORWARD_PORTS}" = 1 ] || return 0
  ${SUDO} iptables -t nat -D PREROUTING -p tcp --dport "$1" -j DNAT --to-destination "$2:$3" 2>/dev/null || true
  ${SUDO} iptables -D FORWARD -p tcp -d "$2" --dport "$3" -j ACCEPT 2>/dev/null || true
}
pf_add_all() { pf_add $((VM_HTTP_PORT_BASE + $1)) "$2" 80; pf_add $((VM_IPERF_PORT_BASE + $1)) "$2" 5201; }
pf_del_all() { pf_del $((VM_HTTP_PORT_BASE + $1)) "$2" 80; pf_del $((VM_IPERF_PORT_BASE + $1)) "$2" 5201; }

# -----------------------------------------------------------------------------
# Image dorée : une VM installée une fois, puis figée
# -----------------------------------------------------------------------------
build_golden() {
  check_host
  prepare_image
  ensure_key
  local n="${VM_PREFIX}-golden" disk seed ip
  disk="${IMAGES_DIR}/${n}-build.qcow2"; seed="${IMAGES_DIR}/${n}-seed.iso"
  log "Construction de l'image dorée (téléchargement des paquets : quelques minutes)"
  ${SUDO} mkdir -p "${IMAGES_DIR}"
  [ -f "${BASE_COPY}" ] || ${SUDO} install -m 0644 "${IMG}" "${BASE_COPY}"
  "${VIRSH[@]}" destroy "${n}" >/dev/null 2>&1 || true
  "${VIRSH[@]}" undefine "${n}" >/dev/null 2>&1 || true
  ${SUDO} rm -f "${disk}" "${seed}"
  ${SUDO} qemu-img create -q -f qcow2 -F qcow2 -b "${BASE_COPY}" "${disk}" 10G
  render_ci full "${n}" "${WORKDIR}/ci/${n}"
  make_seed "${WORKDIR}/ci/${n}" "${seed}"
  DISK_FORMAT_SAVE="${DISK_FORMAT}"; DISK_FORMAT=qcow2
  define_vm "${n}" "${disk}" "${seed}" 2 2048
  DISK_FORMAT="${DISK_FORMAT_SAVE}"
  ip="$(wait_ip "${n}" 300)" || die "La VM de construction n'obtient pas d'adresse IP."
  log "VM de construction joignable (${ip}) : attente de la fin de cloud-init"
  local end=$((SECONDS + 600))
  until vm_ssh "${ip}" true 2>/dev/null; do
    [ "${SECONDS}" -lt "${end}" ] || die "SSH ne répond pas sur la VM de construction."
    sleep 3
  done
  vm_ssh "${ip}" "cloud-init status --wait" >/dev/null 2>&1 || warn "cloud-init a signalé une erreur : vérifiez work/ci et la VM."
  vm_ssh "${ip}" "systemctl is-active nginx iperf3-server" >&2 || warn "nginx ou iperf3 inactif dans l'image dorée."
  # Remise à zéro de l'identité de la machine : chaque clone aura son propre identifiant
  vm_ssh "${ip}" "sudo cloud-init clean --logs; sudo truncate -s 0 /etc/machine-id; sudo rm -f /var/lib/dbus/machine-id; sync" >/dev/null 2>&1 || true
  "${VIRSH[@]}" shutdown "${n}" >/dev/null 2>&1 || true
  wait_state "${n}" "shut off" 120 || "${VIRSH[@]}" destroy "${n}" >/dev/null 2>&1 || true
  ${SUDO} qemu-img convert -O qcow2 "${disk}" "${GOLDEN}"
  "${VIRSH[@]}" undefine "${n}" >/dev/null 2>&1 || true
  ${SUDO} rm -f "${disk}" "${seed}"
  log "Image dorée prête : ${GOLDEN}"
}
ensure_golden() { [ -f "${GOLDEN}" ] || build_golden; }

# -----------------------------------------------------------------------------
# Instances
# -----------------------------------------------------------------------------
create_instance() { # indice
  local i="$1" n disk seed
  n="$(vm_name "${i}")"; disk="${IMAGES_DIR}/${n}.${DISK_FORMAT}"; seed="${IMAGES_DIR}/${n}-seed.iso"
  log "Création de ${n} (${VCPUS} vCPU, ${RAM_MB} Mo)"
  make_disk "${GOLDEN}" "${disk}"
  render_ci light "${n}" "${WORKDIR}/ci/${n}"
  make_seed "${WORKDIR}/ci/${n}" "${seed}"
  define_vm "${n}" "${disk}" "${seed}" "${VCPUS}" "${RAM_MB}"
  pin_vm "${i}" "${n}"
}

remove_instance() { # indice
  local i="$1" n ip=""
  n="$(vm_name "${i}")"
  if [ -f "${CSV}" ]; then ip="$(csv_get "${CSV}" "${i}" inner_ip || true)"; fi
  if [ -n "${ip}" ]; then pf_del_all "${i}" "${ip}"; fi
  "${VIRSH[@]}" destroy "${n}" >/dev/null 2>&1 || true
  "${VIRSH[@]}" undefine "${n}" --nvram >/dev/null 2>&1 || "${VIRSH[@]}" undefine "${n}" >/dev/null 2>&1 || true
  ${SUDO} rm -f "${IMAGES_DIR}/${n}.${DISK_FORMAT}" "${IMAGES_DIR}/${n}-seed.iso"
}

write_csv() {
  local i n ip ah hp xp
  echo "env,index,name,profile,vcpus,ram_mb,inner_ip,access_host,http_port,iperf_port,data_dir" > "${CSV}.tmp"
  for i in $(existing_indices); do
    n="$(vm_name "${i}")"; ip="$(vm_ip "${n}")"
    if [ "${VM_FORWARD_PORTS}" = 1 ]; then ah=""; hp=$((VM_HTTP_PORT_BASE + i)); xp=$((VM_IPERF_PORT_BASE + i))
    else ah="${ip}"; hp=80; xp=5201; fi
    echo "vm,${i},${n},${PROFILE_NAME},${VCPUS},${RAM_MB},${ip},${ah},${hp},${xp},${VM_DATA_DIR}" >> "${CSV}.tmp"
  done
  mv "${CSV}.tmp" "${CSV}"
}

do_down() {
  local i
  for i in $(existing_indices); do remove_instance "${i}"; done
  rm -f "${CSV}"
  log "Toutes les VM '${VM_PREFIX}-*' ont été supprimées."
}

do_up() {
  if [ "${FAST}" -ne 1 ]; then check_host; fi
  ensure_golden
  local i n ip cur_v cur_r
  # Profil différent de celui des VM existantes : on repart de zéro
  if [ -f "${CSV}" ]; then
    cur_v="$(awk -F, 'NR==2{print $5}' "${CSV}")"; cur_r="$(awk -F, 'NR==2{print $6}' "${CSV}")"
    if [ -n "${cur_v}" ] && { [ "${cur_v}" != "${VCPUS}" ] || [ "${cur_r}" != "${RAM_MB}" ]; }; then
      log "Profil différent de celui des VM existantes : recréation."
      do_down
    fi
  fi
  for i in $(existing_indices); do
    if [ "${i}" -gt "${N}" ]; then remove_instance "${i}"; fi
  done
  for ((i = 1; i <= N; i++)); do
    n="$(vm_name "${i}")"
    case "$(dom_state "${n}")" in
      absent|"") create_instance "${i}" ;;
      running) ;;
      *) log "Démarrage de ${n}"; "${VIRSH[@]}" start "${n}" >/dev/null ;;
    esac
  done
  for ((i = 1; i <= N; i++)); do
    n="$(vm_name "${i}")"
    ip="$(wait_ip "${n}")" || die "${n} : aucune adresse IP obtenue."
    wait_http "http://${ip}/" "${READY_TIMEOUT_S}" || die "${n} : l'application ne répond pas (diagnostic : ssh -i ${KEY} ${VM_USER}@${ip} 'sudo cat /var/log/cloud-init-output.log')"
    pf_add_all "${i}" "${ip}"
  done
  write_csv
  log "${N} VM prête(s), profil ${PROFILE_NAME} : voir ${CSV}"
}

do_status() {
  local i
  for i in $(existing_indices); do
    printf '%s  état=%s  ip=%s\n' "$(vm_name "${i}")" "$(dom_state "$(vm_name "${i}")")" "$(vm_ip "$(vm_name "${i}")")"
  done
  if [ -f "${CSV}" ]; then cat "${CSV}"; else echo "(aucune VM enregistrée)"; fi
}

case "${ACTION}" in
  up)       do_up ;;
  down)     do_down ;;
  redeploy) do_down; do_up ;;
  status)   do_status ;;
  check)    check_host ;;
  golden)   check_host; ${SUDO} rm -f "${GOLDEN}"; build_golden ;;
  *)        usage; exit 2 ;;
esac
