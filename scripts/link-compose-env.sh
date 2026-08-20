#!/usr/bin/env sh
# Garante que o Docker Compose na raiz do monorepo interpola portas/secrets
# a partir de backend/.env (o Compose só lê automaticamente o ficheiro `.env` na raiz).
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$root"

if [ ! -f backend/.env ]; then
  echo "Falta backend/.env — corre: cp backend/.env.example backend/.env" >&2
  exit 1
fi

ln -sfn backend/.env .env
echo "OK: .env → backend/.env"
echo "Portas no host (edita em backend/.env):"
grep -E '^(POSTGRES_PUBLISH_PORT|HTTP_PORT|GRAFANA_PORT)=' backend/.env || true
