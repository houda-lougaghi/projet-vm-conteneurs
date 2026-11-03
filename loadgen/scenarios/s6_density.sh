#!/usr/bin/env bash
# =============================================================================
# Scénario 6 : densité de déploiement.
# (Fichier « sourcé » par run-experiment.sh.)
# On ajoute des instances par paliers (S6_LEVELS) jusqu'à une limite FIXÉE À L'AVANCE :
#   mémoire allouée > S6_MEM_LIMIT_PCT % de la RAM de l'hôte, moins S6_HOST_RESERVE_MB.
# À chaque palier, une charge sonde (wrk2, débit S6_RATE) vise l'instance 1 pendant que les
# autres sont au repos ; on relève mémoire de l'hôte, latence p99 et erreurs.
# Point de rupture : erreurs, ou p99 > S6_P99_FACTOR x p99 du premier palier (et pas seulement
# l'épuisement de la mémoire). Les limites sont vérifiées AVANT chaque ajout : la machine
# cible ne doit pas être poussée jusqu'au blocage.
# Métriques : p99_ms, rps, errors, host_mem_used_pct, host_cpu_pct, break_point_level, capacity_stop_level.
# =============================================================================
s6_once() {
  local f="${RAW_DIR}/s6_${CUR_ENV}_r${CUR_REP}_w${CUR_WARM}"
  local level base_p99="" p99 rps errs c m x pct host port url
  for level in ${S6_LEVELS}; do
    if [ $((level * RAM_MB)) -gt "${S6_LIMIT_MB}" ]; then
      CUR_LEVEL="${level}"; record capacity_stop_level "${level}" instances
      log "S6 : limite de mémoire atteinte avant le palier ${level}"; break
    fi
    CUR_LEVEL="${level}"
    ensure_only "${CUR_ENV}" "${level}" "${CUR_PROFILE}" || { record deploy_failed 1 flag; break; }
    sleep 10
    host="$(inst_host "${CUR_ENV}" 1)"; port="$(inst_http "${CUR_ENV}" 1)"; url="http://${host}:${port}/"
    sample_start "${S6_DURATION}" "${f}.l${level}.csv"
    run_wrk2 "${url}" 16 "${S6_RATE}" "${S6_DURATION}" "${f}.l${level}.wrk.txt" || true
    sample_wait
    parse_wrk "${f}.l${level}.wrk.txt" > "${f}.l${level}.parsed"
    read -r c m x < <(sample_stats "${f}.l${level}.csv")
    pct="$(tproj "./target/host-metric.sh mem_used_pct" 2>/dev/null || true)"
    p99="$(awk '$1=="p99_ms"{print $2}' "${f}.l${level}.parsed")"
    rps="$(awk '$1=="rps"{print $2}' "${f}.l${level}.parsed")"
    errs="$(awk '$1=="http_errors"||$1=="socket_errors"{s+=$2} END{print s+0}' "${f}.l${level}.parsed")"
    [ -n "${p99}" ] && record p99_ms "${p99}" ms
    [ -n "${rps}" ] && record rps "${rps}" req/s
    record errors "${errs}" count
    record host_cpu_pct "${c}" "%"
    [ -n "${pct}" ] && record host_mem_used_pct "${pct}" "%"
    if [ -z "${base_p99}" ] && [ -n "${p99}" ]; then base_p99="${p99}"; fi
    if [ "${errs}" -gt 0 ] || { [ -n "${p99}" ] && [ -n "${base_p99}" ] \
         && awk -v p="${p99}" -v b="${base_p99}" -v k="${S6_P99_FACTOR}" 'BEGIN{exit !(p > k*b)}'; }; then
      record break_point_level "${level}" instances
      log "S6 : point de rupture au palier ${level}"; break
    fi
  done
  tdown "${CUR_ENV}" || true
}

scenario_s6() {
  local env total
  CUR_PROFILE="${S6_PROFILE}"; resolve_profile "${CUR_PROFILE}"
  lat_tool_warn
  total="$(tproj "./target/host-metric.sh mem_total_mb" 2>/dev/null || true)"
  [ -n "${total}" ] || { warn "S6 : mémoire de la cible inconnue"; return 1; }
  S6_LIMIT_MB=$(( total * S6_MEM_LIMIT_PCT / 100 - S6_HOST_RESERVE_MB ))
  log "S6 : mémoire totale ${total} Mo, limite d'allocation ${S6_LIMIT_MB} Mo (${S6_MEM_LIMIT_PCT} % moins ${S6_HOST_RESERVE_MB} Mo)"
  for env in ${ENVS}; do
    CUR_ENV="${env}"
    run_reps s6 "${env}" 0 s6_once "${S6_REPEATS:-${REPEATS}}"
  done
}
