# Projet d'expertise : machines virtuelles et conteneurs — plateforme et scripts

Ce dépôt contient tout ce qu'il faut pour **déployer** (VM KVM/QEMU et conteneurs Docker, avec les
mêmes ressources), **charger**, **mesurer**, **répéter** et **analyser** les six scénarios du cahier
des charges. Tous les paramètres sont dans **`config.env`** : les décisions de la phase 2 s'y traduisent
en changeant des valeurs, sans toucher aux scripts.

## 1. Les trois « lieux » et qui lance quoi

```
   MACHINE DE CHARGE (Ubuntu : VirtualBox en pont, ou clé « live »)        MACHINE CIBLE (Linux, dual boot)
  ┌───────────────────────────────────────────┐   câble Ethernet   ┌───────────────────────────────────────┐
  │ loadgen/run-experiment.sh  (orchestrateur)│───── SSH ─────────▶│ target/*.sh : création et mesures     │
  │ wrk, wrk2, ab, iperf3 (client), jq        │                    │ ┌────────────┐   ┌─────────────────┐  │
  │ Prometheus + Grafana (optionnel)          │──── HTTP / iperf ─▶│ │ VM (KVM)   │   │ Conteneurs      │  │
  │ analysis/analyze.py (ou ailleurs)         │                    │ │ nginx, fio,│   │ nginx, fio,     │  │
  │ results/<essai>/results.csv               │◀── résultats ──────│ │ stress-ng, │   │ stress-ng,      │  │
  └───────────────────────────────────────────┘                    │ │ iperf3     │   │ iperf3          │  │
                                                                   │ └────────────┘   └─────────────────┘  │
                                                                   │ cAdvisor, node_exporter (optionnel)   │
                                                                   └───────────────────────────────────────┘
```

Règle de base : **on ne lance à la main que les scripts de préparation** ; pendant une campagne,
c'est l'orchestrateur (machine de charge) qui pilote la cible par SSH.

| Script | Machine | Quand | Commande |
|---|---|---|---|
| `target/prepare-host.sh` | cible | une fois, puis avant les mesures | `install --passwordless-sudo`, `apply`, `status`, `info`, `restore` |
| `target/setup-vm.sh` | cible | tests manuels (l'orchestrateur le lance sinon) | `up -n 3 -p B`, `down`, `status`, `golden` |
| `target/deploy-container.sh` | cible | idem | `up -n 3 -p B`, `down`, `status` |
| `target/monitoring.sh` | cible | si supervision voulue | `up`, `down` |
| `target/sampler.sh`, `instance-stats.sh`, `host-metric.sh`, `measure-startup.sh` | cible | **jamais à la main** : appelés par l'orchestrateur | — |
| `loadgen/install-load-tools.sh` | charge | une fois | `./loadgen/install-load-tools.sh` |
| `loadgen/monitoring.sh` | charge | si supervision voulue | `up`, `down` |
| `loadgen/run-experiment.sh` | charge | **à chaque campagne** | `[--quick] [--env vm|docker|both] s1 … s6 | all` |
| `loadgen/scenarios/s1…s6` | charge | jamais seuls : chargés par l'orchestrateur | — |
| `analysis/analyze.py` | n'importe où | après une campagne | `python3 analysis/analyze.py results/<essai>` |
| `tests/test-offline.sh` | n'importe où | après toute modification des scripts | `./tests/test-offline.sh` |

## 2. Ce qui reste manuel (aucun script ne peut le faire)

1. Activer **VT-x** dans le BIOS/UEFI de la cible. 2. Installer Ubuntu (dual boot) sur la cible et créer la VM
Ubuntu de la machine de charge (VirtualBox, réseau en **« Accès par pont »**, 4 vCPU, 4 à 6 Go).
3. Relier les deux machines **en câble** (adaptateur USB-Ethernet si besoin) et leur donner des adresses fixes
du même sous-réseau (par exemple 192.168.50.10 et 192.168.50.20).
4. Se reconnecter après l'ajout aux groupes `libvirt`, `kvm`, `docker`. 5. Échanger les clés SSH (`ssh-copy-id`).
6. Choisir les valeurs de la phase 2 et les écrire dans `config.env`.

## 3. Installation pas à pas

### A. Sur la machine cible (Linux)
```bash
git clone <URL_DU_DEPOT> projet-vm-conteneurs && cd projet-vm-conteneurs
chmod +x target/*.sh loadgen/*.sh tests/*.sh analysis/*.py docker/entrypoint.sh    # nécessaire si le dépôt vient de Windows
./target/prepare-host.sh install --passwordless-sudo      # KVM, libvirt, Docker, SSH, outils
# → se déconnecter / se reconnecter, puis :
./target/setup-vm.sh check && ./target/deploy-container.sh check
./target/prepare-host.sh apply                            # gouverneur « performance » (turbo : voir HOST_NO_TURBO)
```
Le dossier du projet doit s'appeler comme `TARGET_PROJECT_DIR` (config.env) et se trouver dans le dossier personnel
du compte SSH (`TARGET_USER`).

### B. Sur la machine de charge (Ubuntu)
```bash
git clone <URL_DU_DEPOT> projet-vm-conteneurs && cd projet-vm-conteneurs
chmod +x target/*.sh loadgen/*.sh tests/*.sh analysis/*.py
./loadgen/install-load-tools.sh                           # wrk, ab, iperf3, jq, Docker, Python, wrk2 (compilé)
# renseigner TARGET_HOST et TARGET_USER dans config.env, puis :
ssh-copy-id -i ~/.ssh/id_ed25519.pub <TARGET_USER>@<TARGET_HOST>
ssh <TARGET_USER>@<TARGET_HOST> 'echo ok'
```
**Étalonnage** : avant toute mesure, vérifiez le plafond de votre dispositif : `iperf3 -s` sur la cible (hôte),
`iperf3 -c <cible>` depuis la charge. Sur du gigabit, attendez-vous à environ 0,94 Gbit/s : un écart VM/conteneur n'a de
sens que sous ce plafond.

### C. Supervision (facultatif, pour les tableaux de bord)
Cible : `./target/monitoring.sh up`. Charge : `./loadgen/monitoring.sh up`, puis http://localhost:3000.
**Les essais « sans supervision » et « avec supervision » doivent être faits séparément** (`--run-id sans-sup`,
`--run-id avec-sup`) pour mesurer l'effet de l'observation, comme l'exige le CDC.

## 4. Première utilisation (progressive)

```bash
# Sur la cible : une première VM et un premier conteneur, à la main
./target/setup-vm.sh up -n 1            # 1re fois : télécharge l'image (~600 Mo) et construit l'image dorée (quelques min)
./target/deploy-container.sh up -n 1
./target/setup-vm.sh status             # tableau des instances (IP, ports)
./target/setup-vm.sh down && ./target/deploy-container.sh down

# Sur la charge : vérifier la chaîne complète, en mode court (résultats NON exploitables)
./loadgen/run-experiment.sh --quick s1
./loadgen/run-experiment.sh --quick s3
python3 analysis/analyze.py results/<dossier_affiché>

# Campagne réelle, scénario par scénario (recommandé), après décision de la phase 2
./loadgen/run-experiment.sh --run-id essai1 s1
```

## 5. Les scénarios

| Scénario | Mesuré par | Métriques principales (colonne `metric`) | Profil |
|---|---|---|---|
| s1 démarrage | `measure-startup.sh` en local sur la cible : durée jusqu'à la 1re réponse HTTP | `start_cold_s`, `stop_cold_s`, `start_warm_s`, `stop_warm_s`, `redeploy_s` | A |
| s2 CPU / mémoire | repos 15 s, puis `stress-ng` dans chaque instance (1, 2, 4, 8 instances) | `idle_cpu_pct`, `idle_mem_used_mb`, `load_cpu_pct`, `load_mem_used_mb`, `inst_mem_*`, `bogo_cpu_ops_s`, `bogo_vm_ops_s` | B |
| s3 réseau | iperf3 (2 sens), wrk (16/64/256 connexions), wrk2 à faible débit | `tcp_up_gbps`, `tcp_down_gbps`, `c64_rps`, `c64_p99_ms`, `lat_p99_ms` | A |
| s4 disque | `fio` dans l'instance, accès direct ; 1 puis 4 instances en concurrence | `<tâche>_bw_mbps`, `_iops`, `_lat_mean_us`, `_lat_p95_us`, `_lat_p99_us` | A |
| s5 application | wrk2 à 500/2000/5000 req/s, wrk saturant, ApacheBench | `r2000_p99_ms`, `sat_rps`, `ab_p95_ms`, `*_http_errors` | A |
| s6 densité | ajout d'instances par paliers jusqu'à la limite de mémoire fixée | `p99_ms`, `rps`, `errors`, `host_mem_used_pct`, `break_point_level`, `capacity_stop_level` | B |

Chaque essai d'**échauffement** est enregistré (`warmup=1`) mais exclu des statistiques ; les valeurs aberrantes sont
signalées par `analyze.py`, jamais supprimées. Les sorties brutes de chaque outil sont conservées dans
`results/<essai>/raw/`, la configuration et les versions dans `results/<essai>/meta/`.

**Durées** (ordres de grandeur *calculés* à partir des valeurs par défaut, non mesurés) : avec 2 + 10 essais et les deux
environnements, comptez environ 0,5 à 1 h pour s1, 1 à 2 h pour s2, 40 à 60 min pour s3, 2 à 3 h pour s4,
1 h pour s5 et plusieurs heures pour s6. Lancez un scénario à la fois et commencez par `--quick`.

## 6. Adapter les scripts aux décisions de la phase 2

| Décision | Variable (config.env) |
|---|---|
| Ressources des instances | `PROFILE_A_*`, `PROFILE_B_*`, `S*_PROFILE` |
| Niveaux d'instances | `INSTANCE_LEVELS`, `S4_LEVELS`, `S6_LEVELS` |
| Répétitions, échauffement, pauses | `REPEATS`, `WARMUP`, `PAUSE_S`, `DROP_CACHES` |
| Format de disque, bus, cache, CPU, réseau VM | `DISK_FORMAT`, `DISK_BUS`, `DISK_CACHE`, `CPU_MODE`, `VM_NET_SPEC`, `VM_FORWARD_PORTS` |
| Réseau et stockage Docker | `CTR_NETWORK_MODE`, `CTR_DATA_MODE` |
| Épinglage des cœurs | `CPU_PIN` |
| Turbo et gouverneur | `HOST_NO_TURBO`, `HOST_GOVERNOR` (variables de `prepare-host.sh apply`) |
| Charges, durées, débits | `STRESS_*`, `IPERF_TIME`, `WRK_*`, `FIO_*`, `S3_*`, `S5_*`, `S6_*` |
| Limite de densité | `S6_MEM_LIMIT_PCT`, `S6_HOST_RESERVE_MB`, `S6_P99_FACTOR` |

**Changer l'application de test** (API REST, base de données) : modifier `docker/Dockerfile` et la section
`write_files`/`packages` de `render_ci` dans `target/setup-vm.sh` (image dorée), puis reconstruire :
`./target/setup-vm.sh golden` et `docker build`. Les scénarios n'ont à changer que si l'URL testée n'est plus `/`.
Pour une application à plusieurs composants, il faudra aussi adapter `stress`/`fio` si leur cible change.

## 7. Choix techniques à connaître (et à valider en phase 2)

- **Équité réseau** : la VM est sur le réseau NAT de libvirt et rendue joignable par redirection de ports
  (`iptables`), comme Docker publie ses ports. Pour comparer aussi un mode « pont » : `VM_NET_SPEC="bridge=br0,…"`
  et `VM_FORWARD_PORTS=0` (le pont `br0` est à créer à la main).
- **Image dorée** : la VM n'est pas installée à chaque fois ; chaque VM est un disque dérivé d'une image préparée une fois
  (comme l'image Docker). Les temps de s1 se mesurent donc sur des systèmes déjà installés.
- **Quota CPU Docker** : `--cpus N` est un quota de temps, pas un épinglage ; `CPU_PIN=spread` épingle VM et conteneurs.
- **Stockage Docker** : `CTR_DATA_MODE=layer` écrit dans la couche overlay2, `volume` dans un volume Docker.
- **Mémoire consommée** : vue de l'hôte pour les deux (RSS du processus QEMU, cgroup du conteneur). Le cgroup d'un
  conteneur inclut le cache de fichiers ; la colonne « anonyme » l'exclut.
- **Pas de swap** pour les conteneurs (`--memory-swap` = `--memory`) ; l'image cloud n'en a pas non plus.
- **sudo sans mot de passe** sur la cible : nécessaire à l'automatisation. Acceptable sur une machine de laboratoire dédiée.
- **Ports ouverts** sur la cible : 9301+ (HTTP VM), 9401+ (iperf3 VM), 8301+ et 8401+ (conteneurs), 18080 et 9100
  (supervision). À fermer (`down`) après les mesures.

## 8. Ce qui est validé, et ce qui ne l'est pas

**Vérifié** (hors matériel) : syntaxe de tous les scripts ; `tests/test-offline.sh` (30 contrôles : analyse des sorties
de wrk, wrk2, ab, stress-ng, fio et iperf3 au format des outils, boucle de répétitions, enregistrement CSV, six scénarios
contre une cible simulée) ; flux de `setup-vm.sh` et `deploy-container.sh` contre de faux `virsh`, `virt-install`,
`qemu-img`, `iptables` et `docker` (création, réduction, changement de profil, suppression, règles de redirection) ;
`analyze.py` sur des données fictives.

**Non vérifié, à valider chez vous** : tout ce qui exige un vrai KVM, Docker, un réseau et deux machines : construction
réelle de l'image dorée, démarrage des VM, règles `iptables`/`libvirt` sur votre version, compilation de wrk2, format exact
des sorties de **votre** version de stress-ng, images de supervision, mesures par cgroup (cgroup v2 attendu), accès
SSH et `sudo -n`. Les premières exécutions réelles révéleront probablement des ajustements : conservez les messages
d'erreur exacts.

## 9. Dépannage

| Message ou symptôme | Cause probable et remède |
|---|---|
| `Permission denied` en lançant un script | `chmod +x` (dépôt venu de Windows) |
| `/bin/bash^M: bad interpreter` | fins de ligne Windows : vérifier `.gitattributes`, ou `dos2unix` |
| `Virtualisation matérielle absente ou désactivée` | activer VT-x dans le BIOS ; ne pas lancer dans une VM |
| `libvirt injoignable` | service arrêté, ou reconnexion oubliée après l'ajout au groupe `libvirt` |
| `Variante OS … inconnue` | `OS_VARIANT=ubuntu22.04` ou `generic` |
| SSH : `sudo -n true` échoue | `./target/prepare-host.sh install --passwordless-sudo` sur la cible |
| VM sans adresse IP | réseau libvirt `default` inactif : `virsh net-start default` |
| Aucune réponse de la VM depuis la machine de charge | règles `iptables` (`sudo iptables -t nat -L PREROUTING -n`), pare-feu de la cible (`ufw`) |
| `iperf3` sans résultat | serveur non démarré dans l'instance (`systemctl status iperf3-server` dans la VM) |
| S4 : « résultat fio illisible » | `O_DIRECT` refusé sur la couche overlay2 : essayer `CTR_DATA_MODE=volume` |
| wrk2 absent | compilation échouée : l'orchestrateur utilise wrk (latences de queue possiblement sous-estimées) |
| `stress-ng` : aucune valeur | ouvrir `raw/s2_*.stress1.txt` et envoyer le format des lignes de résultats |

## 10. Campagnes sur plusieurs jours

Les scénarios sont **indépendants** : chacun repart d'un état propre (l'autre environnement est supprimé, les instances
sont recréées). On peut donc les répartir sur plusieurs jours, avec ces règles :

1. **Un scénario = les deux environnements dans la même séance** (VM et Docker le même jour), sinon l'écart mesuré
   mélange la technologie et les conditions du jour (température, charge de fond).
2. **Un dossier par séance** : `--run-id j1-s1`, `--run-id j2-s4`... Ne jamais relancer dans un dossier existant ;
   si un essai est interrompu, on le refait dans un nouveau `--run-id`.
3. **Même configuration** (`config.env`, versions, réglages `prepare-host.sh apply`) pour tous les essais d'un même
   scénario ; chaque dossier garde une copie de sa configuration dans `meta/`.
4. Lancer dans `tmux` (`tmux new -s mesure`) pour qu'une fenêtre fermée n'arrête pas la campagne ; se détacher
   avec Ctrl+B puis D, se rattacher avec `tmux attach -t mesure`.
5. Regrouper l'analyse : `python3 analysis/analyze.py results/j1-s1 results/j1-s3 results/j2-s4 --out results/analyse`.
