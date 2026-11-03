#!/usr/bin/env bash
# =============================================================================
# Scénario 4 : performances disque avec fio, lancé DANS les instances.
# (Fichier « sourcé » par run-experiment.sh.)
# Accès direct (direct=1) pour contourner le cache de pages. Les tâches de FIO_JOBS
# (config.env) couvrent séquentiel/aléatoire, plusieurs tailles de blocs et nombres de tâches.
# S4_LEVELS : nombre d'instances qui sollicitent le disque EN MÊME TEMPS (contention).
# Métriques par tâche : <nom>_bw_mbps, _iops, _lat_mean_us, _lat_p95_us, _lat_p99_us.
# =============================================================================
s4_once() {
  local f="${RAW_DIR}/s4_${CUR_ENV}_n${CUR_LEVEL}_r${CUR_REP}_w${CUR_WARM}"
  local job jname rw bs iod nj dir i dd cmd pids=()
  for job in ${FIO_JOBS}; do
    IFS=: read -r jname rw bs iod nj dir <<<"${job}"
    pids=()
    for ((i = 1; i <= CUR_LEVEL; i++)); do
      dd="$(inst_field "${CUR_ENV}" "${i}" data_dir)"
      cmd="mkdir -p ${dd} && fio --name=${jname} --directory=${dd} --rw=${rw} --bs=${bs} --iodepth=${iod} --numjobs=${nj} --size=${FIO_SIZE} --runtime=${FIO_RUNTIME} --time_based --ramp_time=${FIO_RAMP} --direct=1 --ioengine=libaio --group_reporting --output-format=json --output=/tmp/fio_${jname}.json >/dev/null 2>&1; cat /tmp/fio_${jname}.json; rm -rf ${dd} /tmp/fio_${jname}.json"
      inst_sh "${CUR_ENV}" "${i}" "${cmd}" > "${f}.${jname}.i${i}.json" 2>/dev/null &
      pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null || true
    for ((i = 1; i <= CUR_LEVEL; i++)); do
      parse_fio "${f}.${jname}.i${i}.json" "${dir}" > "${f}.${jname}.i${i}.parsed" || true
      if [ -s "${f}.${jname}.i${i}.parsed" ]; then record_parsed "${f}.${jname}.i${i}.parsed" "${jname}_" "${i}"
      else warn "S4 : résultat fio illisible (${jname}, instance ${i}) : voir ${f}.${jname}.i${i}.json"; fi
    done
  done
}

scenario_s4() {
  local env level
  CUR_PROFILE="${S4_PROFILE}"; resolve_profile "${CUR_PROFILE}"
  for env in ${ENVS}; do
    for level in ${S4_LEVELS}; do
      log "S4 | ${env} | ${level} instance(s) en concurrence"
      CUR_ENV="${env}"; CUR_LEVEL="${level}"
      ensure_only "${env}" "${level}" "${CUR_PROFILE}" || { warn "S4 : déploiement impossible (${env}, ${level})"; continue; }
      run_reps s4 "${env}" "${level}" s4_once
    done
  done
}
