# Task Hive

Gestão de projetos e tarefas estilo **Trello**: quadros kanban, to-do avulsas, timetrack em tempo real e autenticação por roles.

O repositório é um **monorepo informal** com dois projetos Git independentes:

| Pasta | Stack | Estado |
|-------|-------|--------|
| [`backend/`](backend/) | NestJS 11, PostgreSQL, JWT, Socket.IO | MVP |
| [`FrontEnd/`](FrontEnd/) | Next.js 16, React 19, Tailwind 4, Orval | Em evolução (ver `to-do.md`) |

---

## Documentação

### Backend

- [`backend/README.md`](backend/README.md) — setup, Docker só-API, migrations, seed admin, OpenAPI
- [`backend/to-do.md`](backend/to-do.md) — roadmap e checklist (fases 1–5)
- [`backend/docs/e2e-coverage.md`](backend/docs/e2e-coverage.md) — cobertura de testes E2E

### Frontend

- [`FrontEnd/to-do.md`](FrontEnd/to-do.md) — roadmap do frontend
- [`FrontEnd/.cursor/rules/task-hive-conventions.mdc`](FrontEnd/.cursor/rules/task-hive-conventions.mdc) — convenções (tema, pt-BR, BFF, cookies httpOnly)

---

## Docker em casa (Orange Pi)

A app (API + Next) sobe com o compose desta raiz. Postgres, Nginx, Prometheus e Grafana são serviços partilhados em `/root/infra` no Pi, para outros projetos usarem o mesmo cluster, o mesmo proxy e o mesmo Grafana. Neste ambiente de testes não há DNS: o TaskHive entra pela porta **8080**.

```
http://IP:8080  →  Nginx partilhado
                 ├─ /              → Next (UI + /api/bff + auth)
                 ├─ /socket.io/    → Nest (timetrack)
                 └─ /swagger       → Nest Swagger (Basic Auth do .env)

http://IP:3002  →  Grafana partilhado
IP:5433         →  Postgres (clientes na LAN). A API usa shared-postgres:5432 na rede Docker.
```

As rotas de página do Next (`/projects`, `/to-do`, etc.) **não** devem ir para a API Nest — o browser usa o BFF (`/api/bff/...`), que fala com `http://task-hive-api:3001` na rede Docker.

Ficheiros da app: [`docker-compose.yml`](docker-compose.yml), [`docker/nginx.conf`](docker/nginx.conf) (vhost copiado para o Nginx partilhado), [`backend/Dockerfile`](backend/Dockerfile), [`FrontEnd/Dockerfile`](FrontEnd/Dockerfile).

O volume `task_hive_pg` pertence ao Postgres em `/root/infra/postgres` e está marcado `external`. Não uses `docker compose down -v` nessa pasta.

### 1. Configurar o backend

```bash
cd backend
cp .env.example .env
# Preenche secrets. DB_NAME alinhado com a base task_hive.
# No contentor, o compose força DB_HOST=shared-postgres e DB_PORT=5432.
# A partir do portátil: DB_HOST=<IP-do-Pi> e DB_PORT=5433.
cd ..
./scripts/link-compose-env.sh   # cria .env → backend/.env (PUBLIC_* e CSRF_*)
```

### 2. Subir a app (na raiz do monorepo, com a infra já a correr)

```bash
docker compose up -d --build
```

O Nginx partilhado resolve `task-hive-api` e `task-hive-web` em cada pedido (DNS do Docker). Um rebuild deixa de exigir restart do Nginx por causa de IP novo.

| Onde | Porta | Uso |
|------|-------|-----|
| Nginx partilhado | `8080` | Entrada HTTP do TaskHive |
| Postgres partilhado | `5433` | Clientes na LAN (psql, DBeaver) |
| Grafana partilhado | `3002` | UI de métricas |

**`METRICS_TOKEN` tem de estar definido em `backend/.env`.** O fragmento `docker/prometheus/taskhive.scrape.yml.template` é gravado no servidor em `/root/infra/observability/scrape.d/taskhive.yml` (token já substituído, fora do git). Sem token a API responde 404 em `/metrics` e o Grafana fica sem dados. `/metrics` não é exposto pelo Nginx.

O serviço `web` define `BACKEND_API_BASE_URL=http://task-hive-api:3001`, `SESSION_COOKIE_SECURE=false` e `ENABLE_HSTS=false`. Na LAN, define no `.env` (via `backend/.env` + link):

- `PUBLIC_APP_URL=http://<IP-ou-host>:8080` — redirects de sessão (evita `0.0.0.0:3000/login`)
- `PUBLIC_WS_URL=http://<IP-ou-host>:8080` — Socket.IO
- `CSRF_ALLOWED_ORIGINS=http://<IP-ou-host>:8080` — fallback se faltar `PUBLIC_APP_URL`

Depois de mudar o vhost, copia `docker/nginx.conf` para `/root/infra/nginx/conf.d/taskhive.conf` e recarrega o Nginx. Depois de mudar só o `web`: `docker compose up -d web`.

### 3. Seed do admin

As migrations correm ao arrancar a API. Criar o primeiro utilizador:

```bash
docker compose exec -e SEED_ADMIN_PASSWORD='palavra-passe-forte' api npm run seed:admin:dist
```

### 4. Usar

No browser da LAN: **`http://IP_DO_SERVIDOR:8080`** (substitui pelo IP real).

- App: `http://IP:8080`
- Swagger: `http://IP:8080/swagger` (credenciais `SWAGGER_*` do `.env`)
- Grafana: `http://IP:3002` (credenciais `GRAFANA_*`; dashboard **TaskHive API** com filtro por módulo)

Quando tiveres DNS/TLS, liga `SESSION_COOKIE_SECURE=true` e `ENABLE_HSTS=true` no serviço `web` e acrescenta HTTPS no Nginx.

### Stack só-API

Se quiseres apenas a API (sem UI): [`backend/README.md`](backend/README.md#docker-em-casa).

---

## Início rápido (desenvolvimento local)

### 1. Backend

```bash
cd backend
cp .env.example .env   # configurar DB_*, JWT_SECRET, etc.
npm install
npm run typeorm -- migration:run
SEED_ADMIN_PASSWORD='sua-senha' npm run seed:admin
npm run start:dev      # http://localhost:3001
```

### 2. Frontend

```bash
cd FrontEnd
cp .env.example .env   # BACKEND_API_BASE_URL=http://localhost:3001
npm install
npm run dev            # http://localhost:3000
```

Opcional — regenerar cliente API a partir do OpenAPI do backend:

```bash
cd FrontEnd
npm run api:fetch-spec   # ou api:generate se o backend estiver offline
npm run api:generate
```
