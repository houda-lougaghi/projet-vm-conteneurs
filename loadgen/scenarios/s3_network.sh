#!/usr/bin/env bash
# =============================================================================
# Scénario 3 : performances réseau (une instance), mesurées DEPUIS la machine de charge.
# (Fichier « sourcé » par run-experiment.sh.)
# - iperf3 TCP, dans les deux sens : débit (Gbit/s) et retransmissions.
# - wrk pour plusieurs nombres de connexions : requêtes par seconde et latences.
# - wrk2 à faible débit constant : latence applicative en charge légère.
# Rappel : sur un lien gigabit, le débit TCP plafonne vers 0,94 Gbit/s ; l'écart VM/conteneur se lit
# alors surtout dans les latences et dans le CPU de la cible (voir S2/S5).
# =============================================================================
s3_once() {
  local f="${RAW_DIR}/s3_${CUR_ENV}_r${CUR_REP}_w${CUR_WARM}"
  local host port iport c bps retr dir
  host="$(inst_host "${CUR_ENV}" 1)"; port="$(inst_http "${CUR_ENV}" 1)"; iport="$(inst_iperf "${CUR_ENV}" 1)"
  [ -n "${port}" ] && [ -n "${iport}" ] || { warn "S3 : instance 1 inconnue"; return 1; }
  # iperf3 : client sur la machine de charge, serveur dans l'instance
  for dir in up down; do
    if [ "${dir}" = up ]; then
      iperf3 -c "${host}" -p "${iport}" -t "${IPERF_TIME}" -O 2 -J > "${f}.iperf_${dir}.json" 2>/dev/null || true
    else
      iperf3 -c "${host}" -p "${iport}" -t "${IPERF_TIME}" -O 2 -R -J > "${f}.iperf_${dir}.json" 2>/dev/null || true
    fi
    bps="$(jq -r '.end.sum_received.bits_per_second // empty' "${f}.iperf_${dir}.json" 2>/dev/null || true)"
    if [ -n "${bps}" ]; then
      record "tcp_${dir}_gbps" "$(awk -v b="${bps}" 'BEGIN{printf "%.4f", b/1e9}')" Gbit/s
      retr="$(jq -r '.end.sum_sent.retransmits // empty' "${f}.iperf_${dir}.json" 2>/dev/null || true)"
      [ -n "${retr}" ] && record "tcp_${dir}_retransmits" "${retr}" count
    else
      warn "S3 : iperf3 ${dir} sans résultat (serveur iperf3 joignable ? ${host}:${iport})"
    fi
  done
  # wrk : requêtes par seconde selon le nombre de connexions simultanées
  for c in ${S3_WRK_CONNS}; do
    wrk -t"${WRK_THREADS}" -c"${c}" -d"${WRK_DURATION}"s --latency "http://${host}:${port}/" > "${f}.wrk_c${c}.txt" 2>&1 || true
    parse_wrk "${f}.wrk_c${c}.txt" > "${f}.wrk_c${c}.parsed"
    record_parsed "${f}.wrk_c${c}.parsed" "c${c}_"
  done
  # latence à faible débit constant
  run_wrk2 "http://${host}:${port}/" 8 "${S3_LAT_RATE}" "${WRK_DURATION}" "${f}.lat.txt" || true
  parse_wrk "${f}.lat.txt" > "${f}.lat.parsed"
  record_parsed "${f}.lat.parsed" "lat_"
}

scenario_s3() {
  local env
  CUR_PROFILE="${S3_PROFILE}"; resolve_profile "${CUR_PROFILE}"
  lat_tool_warn
  for env in ${ENVS}; do
    log "S3 | ${env}"
    CUR_ENV="${env}"
    ensure_only "${env}" 1 "${CUR_PROFILE}" || { warn "S3 : déploiement impossible (${env})"; continue; }
    run_reps s3 "${env}" 1 s3_once
  done
}
