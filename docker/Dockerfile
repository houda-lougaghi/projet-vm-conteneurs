# Image du conteneur : même base (Ubuntu 24.04), même application (nginx + même page)
# et mêmes outils (fio, stress-ng, iperf3) que la VM.
FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends nginx curl ca-certificates fio stress-ng iperf3 sysstat \
 && rm -rf /var/lib/apt/lists/*
COPY app/index.html /var/www/html/index.html
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 80 5201
ENTRYPOINT ["/entrypoint.sh"]
