#!/bin/sh
set -eu

# v2.55 não suporta --config.expand-env; substituímos METRICS_TOKEN aqui.
sed "s|\${METRICS_TOKEN}|${METRICS_TOKEN}|g" \
  /etc/prometheus/prometheus.yml.template \
  > /tmp/prometheus.yml

exec /bin/prometheus \
  --config.file=/tmp/prometheus.yml \
  --storage.tsdb.path=/prometheus
