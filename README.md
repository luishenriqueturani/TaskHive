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

## Docker em casa (stack completa)

Postgres + API Nest + Next.js + Nginx numa única entrada HTTP na LAN — **sem DNS**.

```
http://IP:8080  →  Nginx
                 ├─ /              → Next (UI + /api/bff + auth)
                 ├─ /socket.io/    → Nest (timetrack)
                 └─ /swagger       → Nest Swagger (Basic Auth do .env)
```

As rotas de página do Next (`/projects`, `/to-do`, etc.) **não** devem ir para a API Nest — o browser usa o BFF (`/api/bff/...`), que fala com `http://api:3001` na rede Docker.

Ficheiros: [`docker-compose.yml`](docker-compose.yml), [`docker/nginx.conf`](docker/nginx.conf), [`backend/Dockerfile`](backend/Dockerfile), [`FrontEnd/Dockerfile`](FrontEnd/Dockerfile).

Não corras em paralelo com `backend/docker-compose.yml` (mesmos contentores / volume `task_hive_pg`).

### 1. Configurar o backend

```bash
cd backend
cp .env.example .env
# Preenche: POSTGRES_PASSWORD, DB_PASSWORD, DB_REMOTE_PASSWORD,
# JWT_SECRET, CRYPT_SALT, SWAGGER_USER, SWAGGER_PASSWORD
# Alinha DB_NAME com POSTGRES_DB
```

### 2. Subir a stack (na raiz do monorepo)

```bash
docker compose up -d --build
```

Portas no host (opcional no `.env` da raiz ou no ambiente):

| Variável | Default | Uso |
|----------|---------|-----|
| `HTTP_PORT` | `8080` | Entrada Nginx |
| `POSTGRES_PUBLISH_PORT` | `5432` | Postgres na LAN (pgAdmin, etc.) |

O serviço `web` já define `BACKEND_API_BASE_URL=http://api:3001`, `SESSION_COOKIE_SECURE=false` e `ENABLE_HSTS=false` (HTTP doméstico). O Socket.IO usa o mesmo host da página (derivado do `Host`); podes forçar com `PUBLIC_WS_URL` no serviço `web` se precisares.

### 3. Seed do admin

As migrations correm ao arrancar a API. Criar o primeiro utilizador:

```bash
docker compose exec -e SEED_ADMIN_PASSWORD='palavra-passe-forte' api npm run seed:admin:dist
```

### 4. Usar

No browser da LAN: **`http://IP_DO_SERVIDOR:8080`** (substitui pelo IP real).

- App: `http://IP:8080`
- Swagger: `http://IP:8080/swagger` (credenciais `SWAGGER_*` do `.env`)

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
