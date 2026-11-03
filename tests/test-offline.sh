#!/usr/bin/env bash
# =============================================================================
# tests/test-offline.sh : vérifie, SANS cible ni réseau, que l'orchestrateur et les six scénarios
# enregistrent correctement les résultats. Les commandes (SSH, iperf3, wrk, ab, fio, stress-ng...)
# sont remplacées par des sorties simulées au format réel des outils. Ce test valide la LOGIQUE
# des scripts (analyse des sorties, boucle de répétitions, CSV), pas les performances.
# S'EXÉCUTE SUR : n'importe quelle machine Linux avec bash, awk et jq. Usage : ./tests/test-offline.sh
# =============================================================================
set -u
TAG=test
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
command -v jq >/dev/null || { echo "jq est requis pour ce test (sudo apt install jq)"; exit 1; }
source "${ROOT_DIR}/loadgen/lib/orch.sh"
for _f in "${ROOT_DIR}"/loadgen/scenarios/s*.sh; do source "${_f}"; done

PASS=0; FAIL=0
check() { # description attendu obtenu
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  ECHEC %s (attendu "%s", obtenu "%s")\n' "$1" "$2" "$3"; fi
}

# ---- Sorties simulées au format réel des outils ---------------------------------
WRK_OUT='Running 5s test @ http://x/
  2 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     1.20ms  500.00us   9.00ms   90.00%
  Latency Distribution
     50%    1.10ms
     75%    1.40ms
     90%    1.90ms
     99%  P99VALUE
  200000 requests in 5.00s, 160.00MB read
  Socket errors: connect 0, read 2, write 1, timeout 0
Requests/sec:  40000.00'
WRK2_OUT='  Latency Distribution (HdrHistogram - Recorded Latency)
 50.000%  850.00us
 75.000%    1.40ms
 90.000%    1.90ms
 99.000%  P99VALUE
 99.900%    5.00ms
Requests/sec:    500.10'
AB_OUT='Requests per second:    12345.67 [#/sec] (mean)
Failed requests:        0
Percentage of the requests served within a certain time (ms)
  50%      3
  75%      4
  90%      6
  95%      8
  99%     12
 100%     30 (longest request)'
STRESS_OUT='stress-ng: info:  [1] dispatching hogs: 2 cpu, 1 vm
stress-ng: metrc: [1] stressor       bogo ops real time  usr time  sys time   bogo ops/s     bogo ops/s CPU used per       RSS Max
stress-ng: metrc: [1]                           (secs)    (secs)    (secs)   (real time) (usr+sys time) instance (%)          (KB)
stress-ng: metrc: [1] cpu               12000     10.00     19.80      0.01      1200.00         605.00        99.00      4000
stress-ng: metrc: [1] vm                 5000     10.00      4.00      6.00       500.00         500.00        100.0     260000'
FIO_OUT='{"jobs":[{"read":{"bw_bytes":120000000,"iops":29000.5,"clat_ns":{"mean":34000.0,"percentile":{"95.000000":60000,"99.000000":90000}}},"write":{"bw_bytes":80000000,"iops":19000,"clat_ns":{"mean":50000.0,"percentile":{"95.000000":70000,"99.000000":99000}}}}]}'
IPERF_OUT='{"end":{"sum_received":{"bits_per_second":9.41e8},"sum_sent":{"retransmits":3}}}'

# ---- Faux outils et fausse cible --------------------------------------------------
FAKE_P99JUMP=0
p99_now() { if [ "${FAKE_P99JUMP}" = 1 ] && [ "${CUR_LEVEL:-1}" -ge 2 ]; then echo "30.00ms"; else echo "3.20ms"; fi; }
wrk()    { echo "${WRK_OUT/P99VALUE/$(p99_now)}"; }
wrk2()   { echo "${WRK2_OUT/P99VALUE/$(p99_now)}"; }
ab()     { echo "${AB_OUT}"; }
iperf3() { echo "${IPERF_OUT}"; }
WRK2_BIN=wrk2
tssh()   { return 0; }
tdown()  { return 0; }
fetch_instances() { return 0; }
ensure_only() { # env n profil : écrit un faux inventaire
  local env="$1" n="$2" i
  echo "env,index,name,profile,vcpus,ram_mb,inner_ip,access_host,http_port,iperf_port,data_dir" > "${RUN_DIR}/instances-${env}.csv"
  for ((i = 1; i <= n; i++)); do echo "${env},${i},bench-${env}-${i},$3,1,1024,10.0.0.${i},,900${i},940${i},/var/tmp/fio" >> "${RUN_DIR}/instances-${env}.csv"; done
}
tproj() {
  local c="$*" n i
  case "${c}" in
    *measure-startup.sh*redeploy*) echo "9.5," ;;
    *measure-startup.sh*) echo "12.3,4.5" ;;
    *sampler.sh*) n="$(echo "${c}" | sed -n 's/.*sampler.sh \([0-9]*\).*/\1/p')"
                  for ((i = 0; i < ${n:-3}; i++)); do echo "170000000$i.0,25.5,2048,13.5"; done ;;
    *instance-stats.sh*) printf 'docker,bench-docker-1,10.5,120,80\ndocker,bench-docker-2,9.5,130,85\n' ;;
    *host-metric.sh*mem_total_mb*) echo 15000 ;;
    *host-metric.sh*mem_used_pct*) echo 42.5 ;;
    *) return 0 ;;
  esac
}
inst_sh() {
  case "$3" in
    *stress-ng*) echo "${STRESS_OUT}" ;;
    *fio*)       echo "${FIO_OUT}" ;;
  esac
}

# ---- Contexte d'exécution rapide ---------------------------------------------------
TMP="$(mktemp -d)"; RUN_DIR="${TMP}/run"; RAW_DIR="${RUN_DIR}/raw"; mkdir -p "${RAW_DIR}"
RESULTS="${RUN_DIR}/results.csv"
echo "date,scenario,env,profile,level,rep,warmup,instance,metric,value,unit" > "${RESULTS}"
ENVS="vm docker"; WARMUP=1; REPEATS=2; PAUSE_S=0; DROP_CACHES=0
IDLE_SAMPLE_S=2; STRESS_TIMEOUT=4; INSTANCE_LEVELS="1 2"; S4_LEVELS="1 2"; S5_RATES="500 2000"
S6_LEVELS="1 2 16"; S6_REPEATS=1; FIO_JOBS="randread:randread:4k:32:1:read seqwrite:write:1M:16:1:write"
S3_WRK_CONNS="16 64"
log() { :; }; warn() { echo "  [avertissement] $*"; }

echo "== Analyse des sorties d'outils =="
printf '%s\n' "${WRK_OUT/P99VALUE/3.20ms}" > "${TMP}/wrk.txt"
check "wrk : requêtes/s"            "40000.00" "$(parse_wrk "${TMP}/wrk.txt" | awk '$1=="rps"{print $2}')"
check "wrk : p99 en ms"             "3.2"      "$(parse_wrk "${TMP}/wrk.txt" | awk '$1=="p99_ms"{print $2+0}')"
check "wrk : p50 en ms"             "1.1"      "$(parse_wrk "${TMP}/wrk.txt" | awk '$1=="p50_ms"{print $2+0}')"
check "wrk : erreurs de socket"     "3"        "$(parse_wrk "${TMP}/wrk.txt" | awk '$1=="socket_errors"{print $2}')"
printf '%s\n' "${WRK2_OUT/P99VALUE/3.20ms}" > "${TMP}/wrk2.txt"
check "wrk2 : p50 (850us) en ms"    "0.85"     "$(parse_wrk "${TMP}/wrk2.txt" | awk '$1=="p50_ms"{print $2}')"
check "wrk2 : p99 en ms"            "3.2"      "$(parse_wrk "${TMP}/wrk2.txt" | awk '$1=="p99_ms"{print $2+0}')"
printf '%s\n' "${AB_OUT}" > "${TMP}/ab.txt"
check "ab : requêtes/s"             "12345.67" "$(parse_ab "${TMP}/ab.txt" | awk '$1=="rps"{print $2}')"
check "ab : p95"                    "8"        "$(parse_ab "${TMP}/ab.txt" | awk '$1=="p95_ms"{print $2}')"
check "ab : requêtes échouées"      "0"        "$(parse_ab "${TMP}/ab.txt" | awk '$1=="failed_requests"{print $2}')"
printf '%s\n' "${STRESS_OUT}" > "${TMP}/stress.txt"
check "stress-ng : bogo ops/s (cpu)" "1200.00" "$(stress_bogo "${TMP}/stress.txt" cpu)"
check "stress-ng : bogo ops/s (vm)"  "500.00"  "$(stress_bogo "${TMP}/stress.txt" vm)"
printf '%s\n' "${FIO_OUT}" > "${TMP}/fio.json"
check "fio : lecture, débit (Mo/s)" "120"      "$(parse_fio "${TMP}/fio.json" read | awk '$1=="bw_mbps"{print $2}')"
check "fio : écriture, p99 (µs)"    "99"       "$(parse_fio "${TMP}/fio.json" write | awk '$1=="lat_p99_us"{print $2}')"

echo "== Scénarios (cible simulée) =="
CUR_ENV=""; CUR_PROFILE=A
scenario_s1; scenario_s2; scenario_s3; scenario_s4; scenario_s5
FAKE_P99JUMP=1; scenario_s6; FAKE_P99JUMP=0
n() { awk -F, -v s="$1" -v m="$2" -v e="${3:-}" -v w="${4:-0}" 'NR>1 && $2==s && $9==m && (e=="" || $3==e) && $7==w {c++} END{print c+0}' "${RESULTS}"; }
check "S1 : 2 mesures start_cold_s par environnement" "4" "$(n s1 start_cold_s)"
check "S1 : l'échauffement est enregistré mais marqué" "2" "$(n s1 start_cold_s '' 1)"
check "S1 : redeploy_s présent"                         "4" "$(n s1 redeploy_s)"
check "S2 : bogo_cpu_ops_s_mean (2 env x 2 paliers x 2 essais)" "8" "$(n s2 bogo_cpu_ops_s_mean)"
check "S2 : mémoire des instances enregistrée"          "yes" "$([ "$(n s2 inst_mem_idle_total_mb)" -gt 0 ] && echo yes || echo no)"
check "S3 : débit iperf3 montant"                       "4" "$(n s3 tcp_up_gbps)"
check "S3 : valeur du débit"                            "0.941" "$(awk -F, '$2=="s3" && $9=="tcp_up_gbps"{print $10+0; exit}' "${RESULTS}")"
check "S3 : requêtes/s à 64 connexions"                 "4" "$(n s3 c64_rps)"
check "S3 : latence à faible débit"                     "4" "$(n s3 lat_p99_ms)"
check "S4 : débit fio randread"                         "yes" "$([ "$(n s4 randread_bw_mbps)" -gt 0 ] && echo yes || echo no)"
check "S4 : 2 instances en concurrence => lignes par instance" "yes" "$(awk -F, '$2=="s4" && $5==2 && $8==2 && $9=="seqwrite_iops"{f=1} END{print f?"yes":"no"}' "${RESULTS}")"
check "S5 : p99 wrk2 à 2000 req/s"                      "4" "$(n s5 r2000_p99_ms)"
check "S5 : p95 ApacheBench"                            "4" "$(n s5 ab_p95_ms)"
check "S5 : saturation wrk"                             "4" "$(n s5 sat_rps)"
check "S6 : point de rupture détecté au palier 2"       "2" "$(awk -F, '$2=="s6" && $9=="break_point_level"{print $10; exit}' "${RESULTS}")"
FAKE_P99JUMP=0; rm -f "${RESULTS}"; echo "date,scenario,env,profile,level,rep,warmup,instance,metric,value,unit" > "${RESULTS}"
S6_LEVELS="1 16"; scenario_s6
check "S6 : arrêt sur limite de mémoire au palier 16"   "16" "$(awk -F, '$2=="s6" && $9=="capacity_stop_level"{print $10; exit}' "${RESULTS}")"
check "Aucune ligne vide ni colonne manquante"          "0" "$(awk -F, 'NR>1 && NF!=11{c++} END{print c+0}' "${RESULTS}")"

echo
echo "Résultat : ${PASS} réussi(s), ${FAIL} échec(s)."
rm -rf "${TMP}"
[ "${FAIL}" -eq 0 ]
