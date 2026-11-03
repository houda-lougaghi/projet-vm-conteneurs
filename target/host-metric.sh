#!/usr/bin/env bash
# =============================================================================
# target/host-metric.sh : une valeur sur la mémoire ou le CPU de la machine cible.
# Usage : ./target/host-metric.sh mem_total_mb | mem_used_mb | mem_used_pct | ncpu
# =============================================================================
set -u
case "${1:-}" in
  mem_total_mb) awk '/^MemTotal:/{printf "%d\n", $2/1024}' /proc/meminfo ;;
  mem_used_mb)  awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%d\n", (t-a)/1024}' /proc/meminfo ;;
  mem_used_pct) awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%.2f\n", 100*(t-a)/t}' /proc/meminfo ;;
  ncpu)         nproc ;;
  *) echo "Usage : $0 mem_total_mb|mem_used_mb|mem_used_pct|ncpu" >&2; exit 2 ;;
esac
