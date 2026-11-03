#!/usr/bin/env bash
# =============================================================================
# Scénario 1 : temps de démarrage, d'arrêt et de redéploiement.
# (Fichier « sourcé » par run-experiment.sh : ne pas le lancer directement.)
# La mesure se fait sur la cible (target/measure-startup.sh), en local : le point d'arrivée
# est la première réponse HTTP correcte de l'application, identique pour VM et conteneur.
# Métriques : start_cold_s, stop_cold_s, start_warm_s, stop_warm_s, redeploy_s.
# =============================================================================
s1_once() {
  local out mode
  for mode in cold warm; do
    out="$(tproj "BENCH_PROFILE=${CUR_PROFILE} ./target/measure-startup.sh ${CUR_ENV} start ${mode}")" || { warn "démarrage ${mode} en échec"; return 1; }
    record "start_${mode}_s" "${out%%,*}" s
    record "stop_${mode}_s" "${out##*,}" s
  done
  out="$(tproj "BENCH_PROFILE=${CUR_PROFILE} ./target/measure-startup.sh ${CUR_ENV} redeploy warm")" || { warn "redéploiement en échec"; return 1; }
  record redeploy_s "${out%%,*}" s
  fetch_instances
}

scenario_s1() {
  local env
  CUR_PROFILE="${S1_PROFILE}"; resolve_profile "${CUR_PROFILE}"
  for env in ${ENVS}; do
    log "S1 | ${env} | profil ${CUR_PROFILE}"
    CUR_ENV="${env}"
    ensure_only "${env}" 1 "${CUR_PROFILE}" || { warn "S1 : déploiement impossible pour ${env}"; continue; }
    run_reps s1 "${env}" 1 s1_once
  done
}
