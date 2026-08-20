# Auditoria de segurança — Task Hive

| Campo | Valor |
| --- | --- |
| Autor | Cursor Grok 4.6 |
| Data | 2026-08-20 |
| Âmbito | Frontend (Next.js 16), backend (NestJS 11), containers (Compose raiz + `backend/docker-compose.yml`) |
| Método | Revisão estática de código, configuração Docker/Nginx e fluxos de autenticação/autorização |
| Classificação | CVSS qualitativo (Crítico / Alto / Médio / Baixo), impacto × explorabilidade no contexto LAN/doméstico e eventual exposição à Internet |

Este ficheiro é a opinião **desta** análise. Outros relatórios na mesma pasta (ou noutros sítios do repo) foram ignorados de propósito.

---

## Resumo executivo

O projeto tem uma base de sessão **bem pensada no BFF**: JWT em cookie `httpOnly`, proxy que não devolve o token ao browser, `SameSite=Lax`, bloqueio de `auth/login|logout|reset-password` no proxy genérico, validação `whitelist` no Nest e bcrypt nas senhas. Isso reduz XSS clássico que roubaria `localStorage`.

Essa camada **não cobre autorização**. Quase todos os CRUDs autenticam (“há um Bearer válido?”) e vários **não autorizam** (“este utilizador pode ver/alterar *este* recurso?”). O `RolesGuard` existe e **não é usado** nas rotas. O cadastro é público. Na prática, **qualquer conta na LAN é um atacante interno** com leitura/escrita cruzada e, em alguns endpoints, com **hashes bcrypt** de outros utilizadores.

A superfície Docker agrava: HTTP sem TLS, Postgres e Grafana publicados em `0.0.0.0`, Swagger na entrada Nginx, e o BFF encaminha `/metrics` (sem auth no Nest) para a Internet/LAN embora o Prometheus não esteja no host.

**Veredicto:** não está pronto para exposição fora de uma LAN de confiança. Mesmo em casa, um visitante na Wi‑Fi (ou um colega com conta `CLIENT`) consegue dados e contas de terceiros. Corrigir IDORs, fugas de `User` no TypeORM e o proxy de métricas antes de qualquer endurecimento cosmética (Helmet, HSTS, etc.).

Contagem (esta análise): **4 críticos, 11 altos, 14 médios, 9 baixos**. Vários positivos no final.

---

## Cadeia de ataque principal (realista)

Pré-condição: acesso HTTP à app (`http://IP:8080`) ou à API (`backend/docker-compose` na `:8080`).

1. `POST /api/bff/users` — cadastro aberto, role `CLIENT` por omissão.
2. `POST /api/auth/login` — cookie `th_session`.
3. `GET /api/bff/users` — diretório de e-mails/nomes de **todos** os utilizadores.
4. `GET /api/bff/project-stages` — IDs Snowflake de **todas** as colunas.
5. `GET /api/bff/tasks/stage/{id}` — tarefas de projetos alheios (sem `canAccessProject`).
6. `GET /api/bff/subtasks/task/{id}` — `relations: ['responsible']` **sem `select`**, JSON com **`password` (bcrypt)**.
7. `GET /api/bff/projects` (se o atacante for participante) — `leftJoinAndSelect` de `userOwner`/`participants` também serializa o hash.
8. `PUT /api/bff/users/{uuid}` / `PATCH /api/bff/users/{uuid}` — alterar ou soft-delete de **qualquer** conta.
9. Sem sessão: `GET /api/bff/metrics` — métricas Prometheus da API (Node, HTTP, operações por módulo).

Passos 3–8 exigem apenas um JWT válido. Não exigem `ADMIN_GOD`.

---

## Achados críticos

### C1 — Hashes bcrypt no JSON da API (TypeORM `relations` sem `select`)

**Onde:** `backend/src/projects/projects.service.ts` (`findAll`, `findOneWithOwnerAndParticipants`); `backend/src/subtasks/subtasks.service.ts` (`findByTaskId`); resposta de `DELETE /projects/:id`.

**O quê:** `leftJoinAndSelect('project.userOwner', 'owner')` e `relations: ['responsible']` carregam a entidade `User` **inteira**, incluindo a coluna `password`. O Nest serializa isso para JSON.

O kanban já faz o contrário e de forma correcta em `tasks.service.ts` (`addSelect(['user.id', 'user.name', 'user.email'])`). Projetos e subtarefas não.

**Impacto:** hash bcrypt offline (wordlist + GPU). Quem está no mesmo projeto, ou quem enumerar `taskId` via C3, parte da senha de colegas/admin. Com a senha, a sessão é de 90 dias.

**Correção:** nunca fazer `JoinAndSelect` de `User` sem `addSelect` explícito; DTO de resposta (`class-transformer` `@Exclude()` na password); testes que falham se o JSON contiver `"password"`.

---

### C2 — IDOR de contas (qualquer autenticado gere qualquer utilizador)

**Onde:** `backend/src/users/users.controller.ts` + `users.service.ts`.

| Método | Rota | Controlo |
| --- | --- | --- |
| `GET` | `/users` | Auth apenas. Lista todos. |
| `GET` | `/users/:id` | Auth apenas. |
| `PUT` | `/users/:id` | **Não** compara `id` com o utilizador da sessão. |
| `PATCH` | `/users/:id` | Soft-delete de **qualquer** id, inclusive o próprio. |
| `DELETE` | `/users/:id` | Impede auto-delete; **permite apagar os outros**. |

`UpdateUserDto` não tem `password`/`role` (whitelist ajuda contra auto-promoção), mas permite trocar **e-mail e nome** de qualquer UUID. Isso é sequestro parcial (lockout do admin ao alterar o e-mail) e vandalismo.

`@Roles()` / `RolesGuard` **não estão aplicados** neste controller.

**Correção:** `id === request.user.id` para self-service; mutações de terceiros só `ADMIN_GOD`; `PATCH` self-delete alinhado com `DELETE`; não listar o diretório completo a `CLIENT` (busca paginada/filtrada, já usada na UI de participantes).

---

### C3 — Autorização ausente ou incompleta na maior parte do domínio

O helper `canAccessProject` / `canManageProject` existe e **é usado** em create/update/delete de projetos, colunas (mutações) e parte de tasks/timetrack. Os **GET** e vários módulos ignoram-no.

| Recurso | Problema |
| --- | --- |
| `GET /projects/:id` | `findOne` sem `canAccessProject`. Metadados de qualquer projeto se o Snowflake for conhecido/enumerado. |
| `GET /tasks/stage/:stage` | Sem ACL. Kanban de qualquer coluna. |
| `GET /tasks/:id` | Sem ACL. |
| `GET /project-stages` | Todas as colunas. |
| `GET /project-stages/project/:id` | Sem verificar pertença ao projeto. |
| `GET /project-stages/:id` | `loadStage` com `relations: ['project', 'tasks', ...]`. **Dump das tarefas da coluna.** |
| `GET /subtasks` | Todas as subtarefas. |
| `GET /subtasks/task/:taskId` | Sem ACL (+ C1). |
| `POST /subtasks` | Cria subtarefa em **qualquer** `taskId` (só verifica se a task existe). |
| To-do `findOne` / `update` / `remove` / `endTask` / `changeTaskStatus` / `nextDateRecurringTask` | Recebem `user` e **não o usam** para ownership. |
| Companies (CRUD inteiro) | Qualquer autenticado cria/lista/edita/apaga qualquer empresa. |

IDs Snowflake são ordenados no tempo: enumeração é mais barata do que UUID v4.

**Correção:** um único ponto (guard ou policy) em **todas** as leituras e escritas; testes negativos (utilizador A não lê recurso de B); to-do: `where: { id, user: { id: user.id } }`.

---

### C4 — Cadastro público transforma C1–C3 em exploit sem convite

**Onde:** `POST /users` sem auth (`users.controller.ts`); UI `/register`.

Não há convite, aprovação, CAPTCHA nem rate limit. Na LAN (e pior na Internet) o atacante cria a própria identidade privilegiada de “qualquer autenticado”.

**Correção (escolher uma):** convites, `REGISTRATION_OPEN=false` por omissão no Compose, ou só `ADMIN_*` cria contas. Rate limit agressivo se o cadastro ficar aberto.

---

## Achados altos

### A1 — BFF como *confused deputy* para `/metrics`

**Onde:** `FrontEnd/src/app/api/bff/[...path]/route.ts`; `backend/src/metrics/metrics.module.ts` (`path: '/metrics'`, sem auth).

O Nginx **não** publica `/metrics` no host (vai para o Next). O BFF faz `http://api:3001/${path}`. `PATH_SAFE` aceita `metrics`. `BLOCKED_PATHS` só cobre login/logout/reset.

`GET /api/bff/metrics` (sem cookie) devolve default metrics Node + contadores da app. Reconhecimento, volume de tráfego, nomes de módulos, eventualmente labels.

O mesmo vale para `swagger` / `api-json` se o Basic Auth do Swagger estiver desligado.

**Correção:** allowlist de prefixes (`users`, `projects`, `tasks`, …); nunca proxy de `metrics`, `swagger`, `api-json`; no Nest, `/metrics` só na rede Docker (token, mTLS, ou bind interno). Não chegar ao Next.

---

### A2 — Socket.IO sem autenticação nem autorização

**Onde:** `backend/src/tasks/timetrack.gateway.ts` (`@WebSocketGateway({ cors: true })`); Nginx `location /socket.io/`; cliente `use-task-timetrack-socket.ts` liga **sem** JWT.

Qualquer cliente que fale o handshake entra. `joinTask` aceita qualquer `taskId` e passa a receber `timetrack:*` (userId, userName, start/end).

Não há forge de eventos HTTP por este canal (o gateway só emite a partir do service), mas a leitura em tempo real é pública no L3/L4 da LAN.

**Correção:** `IoAdapter` com JWT (cookie ou auth handshake); recusar `joinTask` sem `canAccessProject`; CORS allowlist; rate limit de joins.

---

### A3 — Reset de senha não fecha sessões; token não é gasto

**Onde:** `backend/src/auth/auth.service.ts` (`resetPassword`, `isValidResetToken`).

- Após reset, as sessões antigas (90 dias, tabela `Session`) **continuam válidas**.
- O registo em `ForgetPassword` **não é apagado** nem marcado usado.
- `isValidResetToken` chama `checkToken(token)` **sem** `audience: FORGET_PASSWORD` e **sem** ler `expiresAt` da linha.

Roubo de um token de reset (histórico, log, query string `?token=`) permite redefinir de novo dentro da validade do JWT (24 h) e as sessões do atacante anteriores sobrevivem.

O e-mail ainda não é enviado (token só na BD): o risco sobe no dia em que o envio existir.

**Correção:** apagar/consumir o token; invalidar **todas** as sessões do utilizador; verificar audience + `expiresAt`; não criar sessão automática sem invalidar as outras.

---

### A4 — Sem rate limit; enumeração de contas

**Onde:** `auth.service.ts` `login` / `forgetPassword`; ausência de `@nestjs/throttler` / equivalente no BFF.

Mensagens distintas: “Usuário não cadastrado” vs “Senha incorreta”. `forget-password` idem. Timing: bcrypt só corre se o e-mail existe.

Login no DTO exige `IsStrongPassword` (reduz um pouco a força bruta fraca, não substitui lockout).

**Correção:** mensagem genérica; throttling por IP+e-mail; backoff; eventualmente CAPTCHA; no BFF, limite em `/api/auth/login` e `/api/bff/users`.

---

### A5 — Superfície de rede do Compose (raiz)

```yaml
postgres:  '${POSTGRES_PUBLISH_PORT:-5432}:5432'   # 0.0.0.0
nginx:     '${HTTP_PORT:-8080}:80'                 # HTTP claro
grafana:   '${GRAFANA_PORT:-3002}:3000'
web:       SESSION_COOKIE_SECURE: 'false'
```

- Postgres com `DB_REMOTE_*` (`GRANT ALL` em `public`, ver `backend/docker/postgres/init/01-users.sh`) à escuta na LAN.
- Grafana com admin do `.env`, signup desligado (bom), mas UI na LAN.
- Cookie de sessão **sem** `Secure` em HTTP: qualquer MITM Wi‑Fi lê `th_session`.
- Swagger em `/swagger` na mesma porta da app.

**Correção:** Postgres `127.0.0.1:5432:5432` (ou não publicar); Grafana só na rede Docker ou SSH tunnel; TLS (Caddy/Traefik) e aí `SESSION_COOKIE_SECURE=true` + `ENABLE_HSTS=true`; Swagger off em produção (`SWAGGER_*` + não encaminhar no Nginx).

---

### A6 — `JWT_SECRET` (e Swagger) sem validação no arranque

`DB_PASSWORD` vazio aborta a DataSource. `JWT_SECRET` vazio **não**. HMAC com segredo vazio/fraco = tokens forjáveis. A sessão na BD ainda exige uma linha, mas o atacante que forja + injeta sessão (ou que apanha C1) ganha terreno.

Swagger sem `SWAGGER_USER`/`PASSWORD` só faz `Logger.warn` e fica aberto (`main.ts`).

**Correção:** fail-fast se `JWT_SECRET` tiver menos de ~32 bytes aleatórios; em `production`, exigir Basic no Swagger ou desligar a UI.

---

### A7 — CORS aberto e stack só-API sem fronteira

`app.enableCors()` sem origin. No compose da **raiz** a API REST não está no Nginx (só `/socket.io`, `/swagger`, `/api-json`) — o dano é menor.

`backend/docker/nginx.conf` faz `location / { proxy_pass http://api:3001; }`: **API inteira**, incluindo `/metrics` e todos os IDORs, na porta HTTP. CORS reflecte qualquer `Origin`.

**Correção:** allowlist (`http://IP:8080`); na stack só-API, as mesmas restrições de A1 e auth em `/metrics`.

---

### A8 — Sessão de 90 dias e JWT em claro na tabela `Session`

`createToken(..., '90d')`; `Session.token` guarda o JWT completo. Dump da BD = todas as sessões (não há hash do token). Logout apaga uma linha; não há teto de sessões concorrentes nem rotação.

**Correção:** guardar `sha256(token)` (ou jti); TTL menor + refresh; limite de sessões; revogação global em reset/mudança de senha (A3).

---

### A9 — Modelo de papéis morto na prática

`RolesGuard` + `@Roles()` existem. Nenhum controller de users/companies os usa. `isAdmin()` trata `ADMIN_COLLABORATOR` como acesso a **todos** os projetos (não só aos da empresa). Um UPDATE manual na BD (ou seed extra) é superutilizador horizontal.

**Correção:** aplicar Roles nas rotas administrativas; admins de empresa ≠ god-mode global, salvo `ADMIN_GOD`.

---

### A10 — Nginx da raiz: headers e TLS

`X-Forwarded-Proto $scheme` será sempre `http`. `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for` **acrescenta** ao valor do cliente: spoof de IP em logs (e em rate limits futuros). `client_max_body_size 20m` sem limite equivalente no BFF → DoS de body.

Não há `limit_req`, `server_tokens off`, nem CSP no Nginx (o Next envia alguns headers, não CSP).

---

### A11 — Timetrack: fraude de tempo e dados no WS

`CreateTimetrackDto.start` aceita data arbitrária (`timetrack.service.ts`). Quem tem acesso ao projeto inventa intervalos. Combinado com A2, terceiros vêem esses eventos.

---

## Achados médios

### M1 — Sem Helmet, sem CSP

Backend: zero `helmet`. Frontend (`next.config.ts`): `X-Frame-Options SAMEORIGIN`, `nosniff`, `Referrer-Policy`, `Permissions-Policy`. **Não há** `Content-Security-Policy`. XSS em dependência ou `dangerouslySetInnerHTML` futuro fica sem rede. React 19 escapa por omissão (hoje não há `dangerouslySetInnerHTML` nas páginas revistas).

### M2 — `/api/auth/me` decodifica JWT sem assinatura

`decodeSessionUser` documenta isso. A API real valida. A UI (botões admin, nome) pode ser mentida se o cookie for escrito por outro processo. Em HTTP (A5) o MITM escreve o cookie. Preferir verificar a assinatura no BFF ou chamar `/users/:id` no Nest.

### M3 — `proxy.ts` só testa **presença** do cookie

Cookie lixo redirecciona para o layout; o layout usa o mesmo decode. Não é bypass da API; é UX/cache de rotas “protegidas”.

### M4 — Token de reset na query string

`/reset-password?token=...` — Referer, histórico, logs de access. Preferir `POST` + fragmento ou código de uso único curto.

### M5 — `ValidationPipe` sem `forbidNonWhitelisted`

Campos extra são silenciosamente dropados. Melhor 422 para detectar tentativas de mass assignment (`role`, `password` em update).

### M6 — Fuga de internals em erros

`to-do.service.ts`: `'Falha ao criar a tarefa, Error: ' + error`. Auth `console.log(error)` em senha errada. Pode ir stack/SQL ao cliente ou ao stdout do contentor.

### M7 — Prometheus `--web.enable-lifecycle`

Na rede Docker, `POST /-/reload` sem auth. Compromisso da API (RCE) ou de outro contentor recarrega config. Desligar o flag se não for preciso.

### M8 — Imagens e supply chain

- `nginx:alpine` **sem pin** de digest.
- Grafana `11.3.0` e Prometheus `v2.55.1` (2024) em 2026: CVEs acumuladas.
- Dockerfile: `npm install` em vez de `npm ci`.
- Contentores postgres/nginx/prometheus/grafana como root por omissão; sem `cap_drop: ALL`, `no-new-privileges`, `read_only`.
- API e web: `USER node` / `nextjs` — **bom**.

### M9 — `/api/runtime` e Host

`wsUrl` deriva de `X-Forwarded-Host` ou `Host`. O Nginx sobrescreve com `$http_host`, o que mitiga na stack completa. Se o Next for alcançado em directo, Host header injection aponta o Socket.IO para um servidor do atacante. Allowlist / `PUBLIC_WS_URL` fixo.

### M10 — Init SQL: identificadores não escapados

`01-users.sh` escapa passwords para SQL; nomes `DB_USER` / `DB_REMOTE_USER` interpolados em `"${DB_USER}"`. Um `.env` malicioso com aspas no nome parte o SQL. Validar `^[a-zA-Z_][a-zA-Z0-9_]*$`.

`DB_REMOTE_USER` tem `CREATE` + `ALL` em tabelas — excessivo para pgAdmin (basta `SELECT` ou um schema).

### M11 — `trust proxy: 1`

Correcto atrás de um Nginx. Se a API for publicada sem proxy, o cliente escolhe `X-Forwarded-*`.

### M12 — AuthGuard: `replace('Bearer ', '')` e `return false`

Não é case-insensitive; `return false` tende a **403** em vez de 401. Menor; padronizar `UnauthorizedException`.

### M13 — Open redirect residual em `?next=`

`safeNextPath` bloqueia `//`. Vale endurecer contra `/\`, `/\t/`, backslash e esquemas (`/\\`, `/\u0000`). Permitir só prefixes conhecidos (`/dashboard`, `/projects`, …).

### M14 — Cookie sem prefixo `__Host-` / `__Secure-`

Com TLS futuro, `__Host-th_session` (Secure, Path=/, sem Domain) reduz subdomain cookie tossing.

---

## Achados baixos / defesa em profundidade

1. **HSTS desligado** — coerente com HTTP doméstico; ligar só com TLS (preload com HTTP é perigoso).
2. **Gerar senha + clipboard em HTTP** — `copyToClipboard` usa `execCommand` na LAN; o clipboard fica exposto a outras apps no OS. Aceitável em casa; em partilha de PC, menos.
3. **Seed admin** lê `git config user.email` — surpresa se o Git no contentor existir; o Compose documenta `SEED_ADMIN_*`.
4. **Exemplos JWT no Swagger** — ruído, não segredo real.
5. **`X-DNS-Prefetch-Control: on`**.
6. **`X-Frame-Options: SAMEORIGIN`** em vez de `DENY` (não há necessidade de iframe).
7. **Lookups `BigInt(id)`** em params malformados → 500, mini-DoS.
8. **Tabela `Session` sem índice único documentado em `token`** — enumeração lenta / CPU em login lookup (verificar migration).
9. **bcrypt cost 10** — aceitável hoje; 12+ se o hardware aguentar.

---

## Frontend — o que está bem (e o que não)

**Bem**

- BFF não devolve `token` no JSON de login/reset; cookie `httpOnly`.
- `credentials: 'include'` só contra `/api/bff` e `/api/auth/*`.
- Sem `NEXT_PUBLIC` de segredos (`.env.example` correcto).
- `.dockerignore` exclui `.env`.
- `PATH_SAFE` no proxy (sem `.` nem `..`).
- Password gerada com `crypto.getRandomValues` + Fisher–Yates sem viés de módulo.
- Headers básicos no `next.config.ts`.
- `output: 'standalone'` + user `nextjs`.

**Mal / em falta**

- Proxy genérico demasiado genérico (A1).
- Autorização só “espelhada” na UI (`canManageProject` em `projects-api.ts`): a API tem de ser a fonte da verdade (hoje não é, C3).
- WS sem auth (A2).
- Sem CSP.
- Guard de rotas baseado em cookie opaco.

---

## Backend — o que está bem

- `ValidationPipe` `whitelist` + 422.
- bcrypt; `IsStrongPassword` no registo.
- JWT com `issuer` + `audience` no **login** (o reset é que falha nisto).
- Sessão conferida na BD (`findSessionByToken`), não só a assinatura.
- `synchronize: false`; migrations.
- Queries parametrizadas (`$1,$2,$3` no `placeTask`).
- Soft-delete TypeORM.
- Swagger *pode* ter Basic Auth.
- Password do Postgres obrigatória na DataSource.
- Separação `POSTGRES_USER` / `DB_USER` / `DB_REMOTE_USER` no init.

---

## Containers — matriz rápida

| Serviço | User não-root | Porta no host | Auth | Notas |
| --- | --- | --- | --- | --- |
| `api` | Sim (`node`) | Não (só `expose`) | JWT nas rotas; `/metrics` não | Imagem própria |
| `web` | Sim (`nextjs`) | Não | Cookie | BFF |
| `nginx` | Root (imagem) | HTTP 8080 | Não | Sem TLS, sem `limit_req` |
| `postgres` | Root (imagem) | **5432** | Password | Bind em todas as interfaces |
| `prometheus` | — | Não | Lifecycle ligado | Scrapes API |
| `grafana` | — | **3002** | Admin `.env` | Signup off |

---

## Prioridade de remediação

1. **Já:** DTO/`select` para nunca serializar `password` (C1); testes de regressão no JSON.
2. **Já:** ownership em to-do, GET de projects/tasks/stages/subtasks; self-only em `PUT /users/:id` (C2, C3).
3. **Já:** allowlist no BFF; bloquear `metrics` (A1).
4. **Já:** auth no Socket.IO (A2).
5. **Curto prazo:** rate limit + mensagens de login genéricas (A4); consumir reset e matar sessões (A3); validar `JWT_SECRET` (A6).
6. **Curto prazo:** não publicar Postgres/Grafana; TLS; Swagger só em dev (A5).
7. **Médio:** Helmet+CSP; pin de imagens; `npm ci`; `cap_drop`; Roles de verdade (A9, M1, M8).
8. **Produto:** fechar cadastro ou convites (C4).

---

## Fora de âmbito / limitações

- Sem pentest dinâmico nem scan de dependências (`npm audit`) nesta passagem.
- `.env` real não foi usado como fonte de achados (só `.env.example` e o código que o lê).
- Relatórios anteriores de outras LLMs não foram lidos.

---

## Referência rápida de ficheiros

| Área | Caminhos |
| --- | --- |
| BFF / sessão | `FrontEnd/src/app/api/bff/[...path]/route.ts`, `FrontEnd/src/lib/session.ts`, `FrontEnd/src/proxy.ts` |
| Auth API | `backend/src/auth/auth.service.ts`, `backend/src/guards/auth.guard.ts`, `backend/src/main.ts` |
| ACL | `backend/src/projects/project-permissions.helper.ts` (subutilizado) |
| Fuga User | `backend/src/projects/projects.service.ts`, `backend/src/subtasks/subtasks.service.ts` |
| WS | `backend/src/tasks/timetrack.gateway.ts` |
| Compose | `docker-compose.yml`, `docker/nginx.conf`, `backend/docker/nginx.conf` |
