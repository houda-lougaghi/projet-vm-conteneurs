#!/bin/sh
# Démarre le serveur iperf3 (en arrière-plan) puis nginx (au premier plan).
iperf3 -s -D
exec nginx -g 'daemon off;'
