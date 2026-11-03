#!/usr/bin/env python3
# =============================================================================
# analysis/analyze.py : statistiques et graphiques à partir de results.csv
# S'EXÉCUTE SUR : n'importe quelle machine disposant de Python 3 (pandas, matplotlib ; scipy facultatif).
#
# Usage : python3 analysis/analyze.py <dossier_de_résultats ...> [--out DOSSIER]   (plusieurs dossiers : campagnes sur plusieurs jours)
#         python3 analysis/analyze.py --demo DOSSIER   (génère de FAUSSES données pour tester l'outil)
#
# Entrée : results.csv, colonnes date,scenario,env,profile,level,rep,warmup,instance,metric,value,unit
# Sorties (dans <dossier>/analysis/) :
#   summary.csv     par métrique : n, moyenne, écart-type, médiane, min, max, IC à 95 %, valeurs aberrantes
#   comparison.csv  Docker contre VM : valeurs absolues, écart absolu et relatif, recouvrement des IC
#   figures/*.png   barres avec barres d'erreur (IC 95 %), courbes selon le niveau, boîtes à moustaches
# Règles (CDC) : les essais d'échauffement sont exclus des statistiques mais conservés dans les
# données brutes ; les valeurs aberrantes sont SIGNALÉES (règle de l'écart interquartile), jamais supprimées.
# =============================================================================
import argparse
import math
import os
import re
import sys

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# Quantiles de Student à 97,5 % (IC à 95 %) pour 1 à 30 degrés de liberté
T975 = [12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
        2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086,
        2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042]
COLORS = {"vm": "#1f4e79", "docker": "#d98e04"}
LABELS = {"vm": "Machine virtuelle (KVM)", "docker": "Conteneur (Docker)"}


def t_crit(df_free):
    if df_free < 1:
        return float("nan")
    return T975[df_free - 1] if df_free <= 30 else 1.96


def load(paths):
    """Lit un ou plusieurs results.csv (campagnes menées sur plusieurs jours) et les concatène."""
    frames, base = [], None
    for path in paths:
        if os.path.isdir(path):
            path = os.path.join(path, "results.csv")
        d = pd.read_csv(path)
        d["source"] = os.path.dirname(os.path.abspath(path))
        frames.append(d)
        base = base or os.path.dirname(os.path.abspath(path))
    df = pd.concat(frames, ignore_index=True)
    df["value"] = pd.to_numeric(df["value"], errors="coerce")
    df = df.dropna(subset=["value"])
    # Essais de campagnes différentes : numéros de répétition rendus uniques (jamais fusionnés)
    df["rep"] = pd.factorize(df["source"].astype(str) + ":" + df["rep"].astype(str))[0]
    return df, base


def per_rep(df):
    """Une valeur par essai : moyenne sur les instances de l'essai (échauffement exclu)."""
    d = df[df["warmup"] == 0]
    keys = ["scenario", "env", "profile", "level", "metric", "unit", "rep"]
    return d.groupby(keys, as_index=False)["value"].mean()


def summarize(rep_df):
    rows = []
    keys = ["scenario", "env", "profile", "level", "metric", "unit"]
    for k, g in rep_df.groupby(keys):
        v = g["value"].to_numpy(dtype=float)
        n = len(v)
        mean = v.mean()
        std = v.std(ddof=1) if n > 1 else float("nan")
        ci = t_crit(n - 1) * std / math.sqrt(n) if n > 1 else float("nan")
        q1, q3 = np.percentile(v, [25, 75])
        iqr = q3 - q1
        out = int(((v < q1 - 1.5 * iqr) | (v > q3 + 1.5 * iqr)).sum()) if n >= 4 else 0
        rows.append(dict(zip(keys, k), n=n, mean=mean, std=std, median=float(np.median(v)),
                         min=v.min(), max=v.max(), ci95=ci, outliers_iqr=out))
    return pd.DataFrame(rows)


def compare(summary):
    rows = []
    keys = ["scenario", "profile", "level", "metric", "unit"]
    for k, g in summary.groupby(keys):
        s = g.set_index("env")
        if "vm" not in s.index or "docker" not in s.index:
            continue
        vm, dk = s.loc["vm"], s.loc["docker"]
        diff = dk["mean"] - vm["mean"]
        pct = 100 * diff / vm["mean"] if vm["mean"] not in (0, 0.0) else float("nan")
        if math.isnan(vm["ci95"]) or math.isnan(dk["ci95"]):
            verdict = "IC indisponible (moins de 2 essais)"
        elif (vm["mean"] + vm["ci95"] < dk["mean"] - dk["ci95"]) or (dk["mean"] + dk["ci95"] < vm["mean"] - vm["ci95"]):
            verdict = "IC disjoints : différence statistiquement significative"
        else:
            verdict = "IC qui se recouvrent : pas de conclusion sans test complémentaire"
        rows.append(dict(zip(keys, k), vm_mean=vm["mean"], vm_ci95=vm["ci95"], docker_mean=dk["mean"],
                         docker_ci95=dk["ci95"], diff_abs_docker_minus_vm=diff, diff_pct_vs_vm=pct,
                         n_vm=int(vm["n"]), n_docker=int(dk["n"]), verdict=verdict))
    return pd.DataFrame(rows)


def safe(s):
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", str(s))


def plot_metric(rep_df, summary, scenario, metric, unit, outdir):
    s = summary[(summary.scenario == scenario) & (summary.metric == metric)]
    levels = sorted(s["level"].unique())
    envs = [e for e in ("vm", "docker") if e in set(s["env"])]
    if not envs:
        return None
    fig, ax = plt.subplots(figsize=(6.4, 4.2))
    if len(levels) == 1:
        lv = levels[0]
        for i, e in enumerate(envs):
            r = s[(s.env == e) & (s.level == lv)].iloc[0]
            ax.bar(i, r["mean"], yerr=0 if math.isnan(r["ci95"]) else r["ci95"], capsize=6,
                   color=COLORS[e], label=LABELS[e], alpha=0.85)
            pts = rep_df[(rep_df.scenario == scenario) & (rep_df.metric == metric) & (rep_df.env == e) & (rep_df.level == lv)]["value"]
            ax.scatter(np.full(len(pts), i) + np.linspace(-0.12, 0.12, max(len(pts), 1))[:len(pts)], pts,
                       color="black", s=10, zorder=3)
        ax.set_xticks(range(len(envs)))
        ax.set_xticklabels([LABELS[e] for e in envs], fontsize=8)
    else:
        for e in envs:
            se = s[s.env == e].sort_values("level")
            ax.errorbar(se["level"], se["mean"], yerr=se["ci95"].fillna(0), marker="o", capsize=4,
                        color=COLORS[e], label=LABELS[e])
        ax.set_xlabel("Niveau (nombre d'instances)")
        ax.set_xticks(levels)
    ax.set_ylabel(f"{metric} ({unit})")
    ax.set_title(f"{scenario.upper()} : {metric}\nmoyenne et intervalle de confiance à 95 %", fontsize=10)
    ax.grid(alpha=0.3)
    ax.legend(fontsize=8)
    fig.tight_layout()
    path = os.path.join(outdir, f"{safe(scenario)}_{safe(metric)}.png")
    fig.savefig(path, dpi=130)
    plt.close(fig)
    # boîtes à moustaches (dispersion), pour les métriques à un seul niveau
    if len(levels) == 1:
        data, names = [], []
        for e in envs:
            v = rep_df[(rep_df.scenario == scenario) & (rep_df.metric == metric) & (rep_df.env == e)]["value"]
            if len(v):
                data.append(v.to_numpy()); names.append(LABELS[e])
        if data:
            fig, ax = plt.subplots(figsize=(5.6, 4.0))
            try:
                ax.boxplot(data, tick_labels=names)      # matplotlib >= 3.9
            except TypeError:
                ax.boxplot(data, labels=names)           # versions plus anciennes
            ax.set_ylabel(f"{metric} ({unit})")
            ax.set_title(f"{scenario.upper()} : {metric}\ndispersion des essais", fontsize=10)
            ax.grid(alpha=0.3)
            fig.tight_layout()
            fig.savefig(os.path.join(outdir, f"box_{safe(scenario)}_{safe(metric)}.png"), dpi=130)
            plt.close(fig)
    return path


def make_demo(folder):
    """Fausses données (aucune valeur réelle) pour tester la chaîne d'analyse."""
    rng = np.random.default_rng(1)
    rows = []
    def add(sc, env, level, rep, warm, metric, val, unit, inst="all"):
        rows.append(["2026-01-01T00:00:00", sc, env, "A", level, rep, warm, inst, metric, val, unit])
    for env, k in (("vm", 1.0), ("docker", 0.9)):
        for rep in range(1, 13):
            warm = 1 if rep <= 2 else 0
            r = rep if warm else rep - 2
            add("s1", env, 1, r, warm, "start_warm_s", rng.normal(14 if env == "vm" else 0.8, 0.6 if env == "vm" else 0.05), "s")
            add("s3", env, 1, r, warm, "tcp_up_gbps", rng.normal(0.93, 0.005), "Gbit/s")
            add("s5", env, 1, r, warm, "r2000_p99_ms", rng.normal(3.1 * k, 0.2), "ms")
            for lv in (1, 2, 4):
                for inst in range(1, lv + 1):
                    add("s2", env, lv, r, warm, "load_mem_used_mb", rng.normal(900 * lv * (1.4 if env == "vm" else 1.0), 30), "MB")
                    add("s4", env, lv, r, warm, "randread_iops", rng.normal(40000 / lv * (0.8 if env == "vm" else 0.95), 800), "iops", inst)
    os.makedirs(folder, exist_ok=True)
    pd.DataFrame(rows, columns=["date", "scenario", "env", "profile", "level", "rep", "warmup", "instance", "metric", "value", "unit"]
                 ).to_csv(os.path.join(folder, "results.csv"), index=False)
    print(f"Données de démonstration écrites dans {folder}/results.csv (valeurs fictives)")


def main():
    ap = argparse.ArgumentParser(description="Statistiques et graphiques des résultats.")
    ap.add_argument("path", nargs="*", help="un ou plusieurs dossiers de résultats (ou results.csv)")
    ap.add_argument("--out", help="dossier de sortie (défaut : <premier dossier>/analysis)")
    ap.add_argument("--demo", metavar="DOSSIER", help="génère de fausses données de test dans DOSSIER")
    a = ap.parse_args()
    if a.demo:
        make_demo(a.demo)
        if not a.path:
            a.path = [a.demo]
    if not a.path:
        ap.print_help(); return 2
    df, base = load(a.path)
    n_sources = df["source"].nunique()
    out = a.out or os.path.join(base, "analysis")
    figs = os.path.join(out, "figures")
    os.makedirs(figs, exist_ok=True)
    n_warm = int((df["warmup"] == 1).sum())
    rep_df = per_rep(df)
    summary = summarize(rep_df)
    summary.to_csv(os.path.join(out, "summary.csv"), index=False)
    comp = compare(summary)
    comp.to_csv(os.path.join(out, "comparison.csv"), index=False)
    n_fig = 0
    for (sc, m, u), _ in summary.groupby(["scenario", "metric", "unit"]):
        if plot_metric(rep_df, summary, sc, m, u, figs):
            n_fig += 1
    print(f"{len(df)} lignes lues dans {n_sources} campagne(s) ({n_warm} d'échauffement exclues des statistiques).")
    if n_sources > 1:
        print("RAPPEL : ne regrouper que des campagnes faites avec la MÊME configuration (config.env) et des conditions comparables.")
    print(f"{len(summary)} séries résumées -> {out}/summary.csv")
    print(f"{len(comp)} comparaisons VM/Docker -> {out}/comparison.csv")
    print(f"{n_fig} graphiques -> {figs}/")
    low = summary[summary["n"] < 10]
    if len(low):
        print(f"ATTENTION : {len(low)} série(s) avec moins de 10 répétitions (le CDC en demande au moins 10).")
    flagged = summary[summary["outliers_iqr"] > 0]
    if len(flagged):
        print(f"{len(flagged)} série(s) contiennent des valeurs aberrantes (signalées, non supprimées) : voir summary.csv.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
