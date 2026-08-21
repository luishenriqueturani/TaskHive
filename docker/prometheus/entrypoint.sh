#!/bin/sh
set -eu

# v2.55 não suporta --config.expand-env; substituímos METRICS_TOKEN aqui.
# O token tem de vir de backend/.env (env_file no Compose) — igual ao serviço api.
if [ -z "${METRICS_TOKEN:-}" ]; then
  echo "METRICS_TOKEN vazio — defina em backend/.env e recrie o Prometheus." >&2
  echo "Sem token a API devolve 404 em /metrics (produção) e o Grafana fica sem dados." >&2
  exit 1
fi

awk -v token="$METRICS_TOKEN" '{gsub("\\$\\{METRICS_TOKEN\\}", token); print}' \
  /etc/prometheus/prometheus.yml.template \
  > /tmp/prometheus.yml

exec /bin/prometheus \
  --config.file=/tmp/prometheus.yml \
  --storage.tsdb.path=/prometheus
