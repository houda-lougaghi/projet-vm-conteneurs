#!/usr/bin/env bash
# =============================================================================
# Scénario 2 : consommation CPU et mémoire, du repos à la charge, pour 1, 2, 4, 8… instances.
# (Fichier « sourcé » par run-experiment.sh.)
# Pour chaque palier : mesure « au repos » (le « loyer » de la VM ou du conteneur), puis charge
# stress-ng lancée DANS chaque instance en parallèle.
# Métriques : idle_cpu_pct, idle_mem_used_mb, inst_mem_*_mb, load_cpu_pct, load_mem_*_mb,
#             bogo_cpu_ops_s, bogo_vm_ops_s (par instance et moyenne).
# =============================================================================
s2_once() {
  local f="${RAW_DIR}/s2_${CUR_ENV}_n${CUR_LEVEL}_r${CUR_REP}_w${CUR_WARM}"
  local c m x i pids=() dur sum_c=0 sum_v=0 n_ok=0 b
  # 1) Au repos
  sample_start "${IDLE_SAMPLE_S}" "${f}.idle.csv"; sample_wait
  read -r c m x < <(sample_stats "${f}.idle.csv")
  record idle_cpu_pct "${c}" "%"; record idle_mem_used_mb "${m}" MB
  collect_inst_stats idle "${f}.stats_idle.csv" || true
  # 2) Sous charge : stress-ng dans toutes les instances, en parallèle
  dur=$((STRESS_TIMEOUT + 5))
  sample_start "${dur}" "${f}.load.csv"
  for ((i = 1; i <= CUR_LEVEL; i++)); do
    inst_sh "${CUR_ENV}" "${i}" "stress-ng --cpu ${VCPUS} --vm 1 --vm-bytes ${STRESS_VM_BYTES} --timeout ${STRESS_TIMEOUT}s --metrics-brief 2>&1" > "${f}.stress${i}.txt" &
    pids+=($!)
  done
  sleep $((STRESS_TIMEOUT / 2))
  collect_inst_stats load "${f}.stats_load.csv" || true
  wait "${pids[@]}" 2>/dev/null || true
  sample_wait
  read -r c m x < <(sample_stats "${f}.load.csv")
  record load_cpu_pct "${c}" "%"; record load_mem_used_mb "${m}" MB; record load_mem_max_mb "${x}" MB
  for ((i = 1; i <= CUR_LEVEL; i++)); do
    b="$(stress_bogo "${f}.stress${i}.txt" cpu)"
    if [ -n "${b}" ]; then record bogo_cpu_ops_s "${b}" ops/s "${i}"; sum_c="$(awk -v a="${sum_c}" -v b="${b}" 'BEGIN{print a+b}')"; n_ok=$((n_ok + 1)); fi
    b="$(stress_bogo "${f}.stress${i}.txt" vm)"
    if [ -n "${b}" ]; then record bogo_vm_ops_s "${b}" ops/s "${i}"; sum_v="$(awk -v a="${sum_v}" -v b="${b}" 'BEGIN{print a+b}')"; fi
  done
  if [ "${n_ok}" -gt 0 ]; then
    record bogo_cpu_ops_s_mean "$(awk -v s="${sum_c}" -v n="${n_ok}" 'BEGIN{print s/n}')" ops/s
    record bogo_vm_ops_s_mean "$(awk -v s="${sum_v}" -v n="${n_ok}" 'BEGIN{print s/n}')" ops/s
  else
    warn "S2 : aucune valeur stress-ng exploitable (voir ${f}.stress1.txt)"; return 1
  fi
}

scenario_s2() {
  local env level
  CUR_PROFILE="${S2_PROFILE}"; resolve_profile "${CUR_PROFILE}"
  for env in ${ENVS}; do
    for level in ${INSTANCE_LEVELS}; do
      log "S2 | ${env} | ${level} instance(s) | profil ${CUR_PROFILE}"
      CUR_ENV="${env}"; CUR_LEVEL="${level}"
      ensure_only "${env}" "${level}" "${CUR_PROFILE}" || { warn "S2 : déploiement impossible (${env}, ${level})"; continue; }
      run_reps s2 "${env}" "${level}" s2_once
    done
  done
}
