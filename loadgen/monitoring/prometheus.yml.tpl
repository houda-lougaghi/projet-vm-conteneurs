# Modèle de configuration Prometheus : __TARGET__ est remplacé par TARGET_HOST (config.env).
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: cadvisor
    static_configs:
      - targets: ["__TARGET__:18080"]
  - job_name: node
    static_configs:
      - targets: ["__TARGET__:9100"]
