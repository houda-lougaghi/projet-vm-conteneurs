#!/usr/bin/env bash
# =============================================================================
# loadgen/lib/orch.sh : fonctions de l'orchestrateur (à « sourcer »).
# S'EXÉCUTE SUR : la machine de charge (Ubuntu dans VirtualBox ou sur clé live).
# =============================================================================

# ---- Accès SSH à la cible ------------------------------------------------------
SSH_OPTS=(-n -i "${TARGET_SSH_KEY}" -o BatchMode=yes -o StrictHostKeyChecking=accept-new
          -o ConnectTimeout=10 -o ServerAliveInterval=15)
tssh()  { ssh "${SSH_OPTS[@]}" "${TARGET_USER}@${TARGET_HOST}" "$@"; }
tproj() { tssh "cd ${TARGET_PROJECT_DIR} && $*"; }
q()     { printf '%q' "$1"; }   # protège une chaîne pour qu'elle traverse un niveau de shell

# ---- Instances (inventaire écrit par la cible, copié ici) ---------------------
fetch_instances() {
  local e
  for e in vm docker; do
    tssh "cat ${TARGET_PROJECT_DIR}/work/instances-${e}.csv" > "${RUN_DIR}/instances-${e}.csv" 2>/dev/null \
      || : > "${RUN_DIR}/instances-${e}.csv"
  done
}
inst_field() { csv_get "${RUN_DIR}/instances-$1.csv" "$2" "$3"; }
inst_host()  { local h; h="$(inst_field "$1" "$2" access_host)"; echo "${h:-${TARGET_HOST}}"; }
inst_http()  { inst_field "$1" "$2" http_port; }
inst_iperf() { inst_field "$1" "$2" iperf_port; }

# inst_sh <vm|docker> <indice> "<commande>" : exécute une commande DANS l'instance
# (VM : SSH de la cible vers la VM ; conteneur : docker exec sur la cible).
inst_sh() {
  local env="$1" idx="$2" cmd="$3" name ip
  name="$(inst_field "${env}" "${idx}" name)"
  if [ "${env}" = vm ]; then
    ip="$(inst_field vm "${idx}" inner_ip)"
    tssh "ssh -i ${TARGET_PROJECT_DIR}/work/${VM_SSH_KEY_FILE} -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR ${VM_USER}@${ip} $(q "${cmd}")"
  else
    tssh "docker exec ${name} sh -c $(q "${cmd}")"
  fi
}

# ---- Déploiement ---------------------------------------------------------------
tup()   { if [ "$1" = vm ]; then tproj "./target/setup-vm.sh up -n $2 -p $3 --fast" >&2
          else tproj "./target/deploy-container.sh up -n $2 -p $3 --fast" >&2; fi; }
tdown() { if [ "$1" = vm ]; then tproj "./target/setup-vm.sh down --fast" >&2
          else tproj "./target/deploy-container.sh down --fast" >&2; fi; }
# ensure_only <env> <n> <profil> : l'autre environnement est arrêté (machine au repos), N instances de <env> tournent
ensure_only() {
  local env="$1" n="$2" prof="$3" other
  if [ "${env}" = vm ]; then other=docker; else other=vm; fi
  tdown "${other}" || return 1
  tup "${env}" "${n}" "${prof}" || return 1
  fetch_instances
  [ -s "${RUN_DIR}/instances-${env}.csv" ] || return 1
}

# ---- Enregistrement des résultats ---------------------------------------------
# Variables de contexte : CUR_SC, CUR_ENV, CUR_PROFILE, CUR_LEVEL, CUR_REP, CUR_WARM
record() { # métrique valeur unité [instance]
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date -Is)" "${CUR_SC}" "${CUR_ENV}" "${CUR_PROFILE}" \
    "${CUR_LEVEL}" "${CUR_REP}" "${CUR_WARM}" "${4:-all}" "$1" "$2" "$3" >> "${RUN_DIR}/results.csv"
}
# record_parsed <fichier "métrique valeur unité"> [préfixe] [instance]
record_parsed() {
  local m v u
  while read -r m v u; do
    [ -n "${m}" ] && record "${2:-}${m}" "${v}" "${u}" "${3:-all}"
  done < "$1"
}

# ---- Boucle de répétitions : échauffement, vidage des caches, pause ------------
prep_state() {
  [ "${DROP_CACHES}" = 1 ] || return 0
  tproj "sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null" \
    || warn "Vidage des caches impossible (sudo sans mot de passe sur la cible ?)."
}
# run_reps <scénario> <env> <niveau> <fonction> [nb_repetitions]
run_reps() {
  local sc="$1" env="$2" level="$3" fn="$4" reps="${5:-${REPEATS}}" total i
  total=$((WARMUP + reps))
  CUR_SC="${sc}"; CUR_ENV="${env}"; CUR_LEVEL="${level}"
  for ((i = 1; i <= total; i++)); do
    if [ "${i}" -le "${WARMUP}" ]; then CUR_WARM=1; CUR_REP="${i}"; else CUR_WARM=0; CUR_REP=$((i - WARMUP)); fi
    log "${sc} | ${env} | niveau ${level} | essai ${CUR_REP}/${reps}$([ "${CUR_WARM}" = 1 ] && echo ' (échauffement)')"
    prep_state
    "${fn}" || warn "Essai en échec (${sc}, ${env}, niveau ${level}, essai ${CUR_REP})."
    sleep "${PAUSE_S}"
  done
}

# ---- Échantillonnage de la cible pendant un essai ------------------------------
sample_start() { # durée fichier
  tproj "./target/sampler.sh $1 1" > "$2" 2>/dev/null &
  SAMPLE_PID=$!
}
sample_wait()  { wait "${SAMPLE_PID}" 2>/dev/null || true; }
sample_stats() { # fichier -> "cpu_moyen mem_moyenne_mo mem_max_mo"
  awk -F, '$2 != "" {c+=$2; m+=$3; if($3>mx) mx=$3; n++}
           END{ if(n>0) printf "%.2f %.0f %.0f\n", c/n, m/n, mx; else print "0 0 0" }' "$1"
}
# collect_inst_stats <étiquette> <fichier> : ressources par instance, vues de l'hôte
collect_inst_stats() {
  tproj "./target/instance-stats.sh" > "$2" 2>/dev/null || { warn "instance-stats indisponible"; return 1; }
  awk -F, -v l="$1" '$4 != "" {print "inst_mem_" l "_mb", $4, "MB", $2; s+=$4}
                     $3 != "" {print "inst_cpu_" l "_s", $3, "s", $2}
                     END{ if(s != "") print "inst_mem_" l "_total_mb", s, "MB", "all" }' "$2" \
    | while read -r m v u inst; do record "${m}" "${v}" "${u}" "${inst}"; done
}

# ---- Analyse des sorties des outils (sortie : « métrique valeur unité ») -------
# wrk / wrk2
parse_wrk() {
  awk '
  function ms(v, u) { if (u == "us") return v/1000; if (u == "ms") return v; if (u == "s") return v*1000; if (u == "m") return v*60000; return v }
  /^Requests\/sec:/ { print "rps", $2, "req/s" }
  /^[ \t]+[0-9.]+%[ \t]+[0-9.]+(us|ms|s|m)[ \t]*$/ {
    p = $1; sub("%", "", p); v = $2; u = v; gsub(/[0-9.]+/, "", u); n = v; sub(/(us|ms|s|m)$/, "", n); pp = p + 0
    if (pp == 50) print "p50_ms", ms(n, u), "ms"
    else if (pp == 90) print "p90_ms", ms(n, u), "ms"
    else if (pp == 99) print "p99_ms", ms(n, u), "ms"
  }
  /Non-2xx or 3xx responses:/ { print "http_errors", $NF, "count" }
  /Socket errors:/ { e = 0; for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+,?$/) { x = $i; sub(",", "", x); e += x } print "socket_errors", e, "count" }
  ' "$1"
}
# ApacheBench
parse_ab() {
  awk '
  /^Requests per second:/ { print "rps", $4, "req/s" }
  /^Failed requests:/ { print "failed_requests", $3, "count" }
  /^Non-2xx responses:/ { print "http_errors", $3, "count" }
  /^[ \t]+(50|90|95|99)%/ { p = $1; sub("%", "", p); print "p" p "_ms", $2, "ms" }
  ' "$1"
}
# stress-ng : opérations « bogo » par seconde (temps réel) d'un stresseur donné
stress_bogo() { # fichier stresseur
  awk -v n="$2" '$0 ~ /stress-ng: (metrc|info):/ && $4 == n && NF >= 9 && $9 ~ /^[0-9.]+$/ {v = $9} END{ if (v != "") print v }' "$1"
}
# fio (JSON) : débit (Mo/s), IOPS, latence moyenne et p95/p99 (µs) pour un sens (read|write)
parse_fio() { # fichier sens
  jq -r --arg d "$2" '.jobs[0][$d] |
    "bw_mbps \((.bw_bytes // 0)/1e6) MB/s\niops \(.iops // 0) iops\nlat_mean_us \((.clat_ns.mean // 0)/1000) us\nlat_p95_us \((.clat_ns.percentile["95.000000"] // 0)/1000) us\nlat_p99_us \((.clat_ns.percentile["99.000000"] // 0)/1000) us"' "$1" 2>/dev/null
}

# Outil de latence à débit constant : wrk2 si disponible, sinon wrk (avec avertissement)
WRK2_BIN="$(command -v wrk2 || true)"
lat_tool_warn() {
  [ -n "${WRK2_BIN}" ] || warn "wrk2 absent : repli sur wrk (les latences élevées peuvent être sous-estimées : coordinated omission)."
}
# run_wrk2 <url> <connexions> <débit> <durée_s> <fichier>
run_wrk2() {
  if [ -n "${WRK2_BIN}" ]; then
    "${WRK2_BIN}" -t"${WRK_THREADS}" -c"$2" -d"$4"s -R"$3" --latency "$1" > "$5" 2>&1
  else
    wrk -t1 -c"$2" -d"$4"s --latency "$1" > "$5" 2>&1
  fi
}
