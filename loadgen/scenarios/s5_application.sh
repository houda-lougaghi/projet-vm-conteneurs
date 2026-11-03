#!/usr/bin/env bash
# =============================================================================
# Scénario 5 : charge applicative réaliste (une instance), depuis la machine de charge.
# (Fichier « sourcé » par run-experiment.sh.)
# - wrk2 à plusieurs débits constants (S5_RATES : faible, moyenne, élevée) : latences p50/p90/p99.
# - wrk saturant (sans débit imposé) : débit maximal.
# - ApacheBench en recoupement : percentiles p50/p95/p99 (wrk2 ne fournit pas le p95).
# Métriques : r<débit>_rps / _p50_ms / _p90_ms / _p99_ms / _http_errors, sat_*, ab_*.
# Application de test : à remplacer (API REST + base de données) en adaptant le Dockerfile
# et le cloud-init ; ce scénario n'a pas à changer tant qu'une URL HTTP répond.
# =============================================================================
s5_once() {
  local f="${RAW_DIR}/s5_${CUR_ENV}_r${CUR_REP}_w${CUR_WARM}"
  local host port url r
  host="$(inst_host "${CUR_ENV}" 1)"; port="$(inst_http "${CUR_ENV}" 1)"
  [ -n "${port}" ] || { warn "S5 : instance 1 inconnue"; return 1; }
  url="http://${host}:${port}/"
  for r in ${S5_RATES}; do
    run_wrk2 "${url}" "${S5_CONNS}" "${r}" "${S5_DURATION}" "${f}.wrk2_r${r}.txt" || true
    parse_wrk "${f}.wrk2_r${r}.txt" > "${f}.wrk2_r${r}.parsed"
    record_parsed "${f}.wrk2_r${r}.parsed" "r${r}_"
  done
  wrk -t"${WRK_THREADS}" -c"${S5_SAT_CONNS}" -d"${S5_DURATION}"s --latency "${url}" > "${f}.wrk_sat.txt" 2>&1 || true
  parse_wrk "${f}.wrk_sat.txt" > "${f}.wrk_sat.parsed"
  record_parsed "${f}.wrk_sat.parsed" "sat_"
  ab -q -n "${S5_AB_REQUESTS}" -c "${S5_AB_CONC}" "${url}" > "${f}.ab.txt" 2>&1 || true
  parse_ab "${f}.ab.txt" > "${f}.ab.parsed"
  record_parsed "${f}.ab.parsed" "ab_"
  # ressources de la cible pendant une charge de référence : mesurées dans S2 et S6
}

scenario_s5() {
  local env
  CUR_PROFILE="${S5_PROFILE}"; resolve_profile "${CUR_PROFILE}"
  lat_tool_warn
  for env in ${ENVS}; do
    log "S5 | ${env}"
    CUR_ENV="${env}"
    ensure_only "${env}" 1 "${CUR_PROFILE}" || { warn "S5 : déploiement impossible (${env})"; continue; }
    run_reps s5 "${env}" 1 s5_once
  done
}
