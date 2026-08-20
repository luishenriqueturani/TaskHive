# Auditoria de segurança — Task Hive

| Campo | Valor |
| --- | --- |
| Autor | Cursor Composer 2.5 |
| Data | 2026-08-20 |
| Âmbito | Frontend (Next.js 16), backend (NestJS 11), containers (Compose raiz + `backend/docker-compose.yml`) |
| Método | Revisão estática de código-fonte, configuração Docker/Nginx/Prometheus/Grafana, `npm audit --omit=dev`, análise de fluxos auth/authz |
| Contexto | Stack pensada para LAN doméstica (HTTP, cookies sem `Secure`), com caminho de evolução para TLS |

Este documento é uma opinião **independente** desta sessão. Outros relatórios na pasta `seguranca/` não foram utilizados como base.

---

## Resumo executivo

O Task Hive combina uma **camada de sessão no frontend acima da média** (BFF Next.js, JWT em cookie `httpOnly`, token nunca exposto ao JavaScript) com um **backend que autentica bem mas autoriza mal**. A pergunta dominante nas rotas Nest é “existe um JWT válido?”, não “este utilizador pode aceder a **este** recurso?”. Helpers de permissão (`canAccessProject`, `canManageProject`) existem e são usados em mutações de projetos/tarefas, mas **falham em leituras**, em módulos inteiros (`users`, `companies`, `to-do`) e no canal WebSocket.

Achados adicionais relevantes:

- **Vazamento de hashes bcrypt** quando relações TypeORM carregam a entidade `User` completa (sem `select` explícito).
- **`/metrics` Prometheus** sem autenticação no Nest, alcançável via BFF (`/api/bff/metrics`) na stack completa.
- **Socket.IO aberto**: qualquer cliente entra em salas `task:{id}` e recebe eventos de timetrack.
- **Superfície Docker**: Postgres e Grafana em `0.0.0.0`, HTTP sem TLS, stack só-API expõe **toda** a API incluindo métricas e Swagger.
- **Dependências**: 26 vulnerabilidades no backend (2 críticas) e 4 high no frontend (Next.js/sharp/postcss).

**Veredicto:** adequado apenas numa LAN de confiança extrema, e mesmo assim com risco elevado de abuso interno (visitante Wi‑Fi, colega com conta `CLIENT`). Não expor à Internet sem corrigir IDORs, WebSocket, métricas e endurecer containers.

**Contagem desta análise:** 4 críticos · 12 altos · 13 médios · 8 baixos/informativos.

---

## Metodologia

1. Leitura de controllers, services, guards, gateways, Route Handlers BFF e ficheiros Compose/Nginx.
2. Verificação cruzada de padrões IDOR (parâmetro `user` recebido mas não usado; `findOne` sem `canAccessProject`).
3. `npm audit --omit=dev` em `backend/` e `FrontEnd/` (2026-08-20).
4. Análise de exposição de portas, utilizadores de contentor e segredos em `.env.example` / Compose.

Não foram executados testes dinâmicos nem scans de imagem (Trivy/Snyk).

---

## Arquitetura relevante para segurança

```
Browser ──HTTP──► Nginx:8080 ──┬──► Next.js (UI + BFF /api/bff, /api/auth)
                               ├──► Nest /socket.io (WebSocket)
                               └──► Nest /swagger, /api-json

Next BFF ──HTTP Docker──► api:3001 (Nest)
Nest ──► postgres:5432
Prometheus (interno) ◄── scrape ── Nest /metrics
Grafana:3002 (host) ◄── Prometheus
Postgres:5432 (host, exposto)
```

O BFF reescreve o cookie `th_session` em `Authorization: Bearer` — boa separação. Porém, o proxy genérico encaminha **qualquer** path válido ao backend, incluindo endpoints administrativos e observabilidade.

---

## Achados críticos

### C1 — Vazamento de hash bcrypt via relações TypeORM

| | |
|---|---|
| **Severidade** | Crítico |
| **Ficheiros** | `backend/src/projects/projects.service.ts` (L57–63, L75–80), `backend/src/subtasks/subtasks.service.ts` (L72–79) |
| **Problema** | `leftJoinAndSelect('project.userOwner', 'owner')` e `relations: ['responsible']` carregam `User` **completo**, incluindo coluna `password` (bcrypt). O Nest serializa a resposta JSON tal como está. |
| **Contraste** | `tasks.service.ts` (L145–149) faz join correto com `addSelect(['user.id', 'user.name', 'user.email'])`. `users.service.ts` usa `select: { password: false }`. |
| **Impacto** | Offline cracking de passwords de donos de projeto e responsáveis por subtarefas. |
| **Correção** | Nunca join/select de `User` sem campos explícitos; `@Exclude()` na entidade + `ClassSerializerInterceptor`; testes de regressão que falham se `"password"` aparecer na resposta. |

---

### C2 — IDOR total no módulo `users`

| | |
|---|---|
| **Severidade** | Crítico |
| **Ficheiros** | `backend/src/users/users.controller.ts`, `backend/src/users/users.service.ts` |
| **Problema** | `POST /users` é **público** (L26–37). Com JWT válido: `GET /users` lista todos; `PUT/PATCH/DELETE /users/:id` altera/apaga **qualquer** UUID sem verificar `id === request.user.id`. O comentário em `users.service.ts` menciona restrição a `ADMIN_GOD`, mas **não está implementada**. |
| **Impacto** | Takeover de contas (alterar email/senha de admin), enumeração, lockout. |
| **Correção** | Self-service só no próprio ID; operações globais com `@Roles(UserRole.ADMIN_GOD)` + `RolesGuard`; desactivar registo público em produção. |

---

### C3 — IDOR no módulo `to-do` (ownership ignorado)

| | |
|---|---|
| **Severidade** | Crítico |
| **Ficheiros** | `backend/src/to-do/to-do.service.ts` (L104–137, L139–224, L203+) |
| **Problema** | `findOne`, `update`, `remove`, `endTask`, `changeTaskStatus`, `nextDateRecurringTask` recebem `user` mas **nunca comparam** `todo.user.id === user.id`. `findAll` filtra correctamente; as outras operações não. |
| **Impacto** | Leitura, alteração e soft-delete de to-dos de terceiros. |
| **Correção** | Verificar ownership em todas as mutações e leituras unitárias; retornar 404 (não 403) para evitar enumeração. |

---

### C4 — IDOR em leituras de tasks, project-stages e projects

| | |
|---|---|
| **Severidade** | Crítico |
| **Ficheiros** | `backend/src/tasks/tasks.controller.ts` (L68–78, `GET :id`), `backend/src/tasks/tasks.service.ts` (L140–158, L161–163), `backend/src/project-stages/project-stages.controller.ts` (`GET` global e por project), `backend/src/projects/projects.controller.ts` (L164–189) |
| **Problema** | Mutações de tasks usam `canAccessProject` / `canMoveOrRemoveTask`, mas **`findByStage`**, **`findOne`**, **`GET /project-stages`**, **`GET /projects/:id`** não verificam permissão no projeto. |
| **Impacto** | Qualquer autenticado lê kanban, tarefas e metadados de projetos alheios conhecendo IDs (enumeráveis via listagens globais). |
| **Correção** | Aplicar `canAccessProject()` em todos os reads; filtrar listagens globais por participação/ownership. |

---

## Achados altos

### H1 — `RolesGuard` implementado mas nunca aplicado

| | |
|---|---|
| **Ficheiros** | `backend/src/guards/roles.guard.ts`, `backend/src/decorators/roles.decorator.ts` |
| **Problema** | Nenhum controller usa `@Roles(...)`. Papéis `ADMIN_GOD`, `ADMIN_COLLABORATOR`, `CLIENT` existem no JWT mas não governam rotas. |
| **Correção** | `@UseGuards(AuthGuard, RolesGuard)` + `@Roles(...)` em users, companies, endpoints administrativos. |

---

### H2 — Cadastro público sem controlo

| | |
|---|---|
| **Ficheiro** | `backend/src/users/users.controller.ts` L26 |
| **Problema** | Qualquer actor cria conta com role default `CLIENT`. |
| **Correção** | Convite-only, CAPTCHA, rate limit, ou desactivar em produção. |

---

### H3 — JWT com validade de 90 dias

| | |
|---|---|
| **Ficheiros** | `backend/src/auth/auth.service.ts` L44–57, `FrontEnd/src/lib/session.ts` L10–11 |
| **Problema** | Token roubado permanece válido até logout manual ou expiração. |
| **Correção** | Access token curto (15–60 min) + refresh token; rotação de sessões no login. |

---

### H4 — Reset de senha: token reutilizável e validação incompleta

| | |
|---|---|
| **Ficheiros** | `backend/src/auth/auth.service.ts` L164–231 |
| **Problema** | `isValidResetToken()` chama `checkToken(token)` **sem** `audience: FORGET_PASSWORD`. Não valida `expiresAt` da entidade. Após `resetPassword()`, o registo em `forget_password` **não é apagado** — o token pode ser reutilizado. |
| **Correção** | Validar audience + expiry; invalidar token após uso único; limpar tokens expirados. |

---

### H5 — CORS totalmente aberto no backend

| | |
|---|---|
| **Ficheiro** | `backend/src/main.ts` L45 |
| **Problema** | `app.enableCors()` sem opções aceita **qualquer origem**. |
| **Correção** | `origin: process.env.CORS_ORIGINS?.split(',')` ou lista fixa. |

---

### H6 — Ausência de rate limiting

| | |
|---|---|
| **Ficheiros** | `backend/package.json`, `backend/src/main.ts` |
| **Problema** | Login, registo, forget-password, reset-password sem throttling — brute force viável. |
| **Correção** | `@nestjs/throttler` global + limites agressivos em `/auth/*`. |

---

### H7 — WebSocket sem autenticação nem autorização

| | |
|---|---|
| **Ficheiros** | `backend/src/tasks/timetrack.gateway.ts` (L22, L31–50), `FrontEnd/src/lib/use-task-timetrack-socket.ts` (L44–49) |
| **Problema** | `@WebSocketGateway({ cors: true })`. `handleConnection()` não valida JWT. `joinTask` entra em `task:{taskId}` sem verificar permissão. Cliente liga sem credenciais. |
| **Impacto** | Espionagem em tempo real de timetrack de qualquer tarefa. |
| **Correção** | Middleware Socket.IO com JWT; `canAccessProject` antes de `client.join()`. |

---

### H8 — `/metrics` Prometheus sem autenticação

| | |
|---|---|
| **Ficheiros** | `backend/src/metrics/metrics.module.ts` L17–18, `FrontEnd/src/app/api/bff/[...path]/route.ts` |
| **Problema** | Endpoint expõe métricas Node.js, HTTP por rota, conexões WebSocket. Na stack completa, o BFF encaminha `/api/bff/metrics` → backend `/metrics` com cookie de sessão (ou sem). |
| **Correção** | Bloquear no BFF; auth básica; ou não registar rota em produção. |

---

### H9 — IDOR em `companies`

| | |
|---|---|
| **Ficheiros** | `backend/src/companies/companies.controller.ts`, `companies.service.ts` |
| **Problema** | Qualquer autenticado faz CRUD em **qualquer** empresa, sem vínculo a owner ou role. |
| **Correção** | Restringir a admins ou associar empresa a utilizador/projeto. |

---

### H10 — IDOR em `subtasks` (listagem global e leitura por task)

| | |
|---|---|
| **Ficheiros** | `backend/src/subtasks/subtasks.service.ts` (L40–47, L64–80) |
| **Problema** | `findAll()` lista todas. `findByTaskId()` não chama `canAccessProject`. `relations: ['responsible']` vaza hash bcrypt (ver C1). |
| **Correção** | Filtrar por permissão; select explícito de User. |

---

### H11 — Utilizador remoto Postgres com privilégios excessivos

| | |
|---|---|
| **Ficheiro** | `backend/docker/postgres/init/01-users.sh` (L39–48) |
| **Problema** | `DB_REMOTE_USER` recebe `ALL PRIVILEGES ON TABLES` e sequences. Com Postgres publicado em `0.0.0.0:5432`, acesso total de leitura/escrita/destruição. |
| **Correção** | Privilégios mínimos (SELECT only para pgAdmin read-only); bind `127.0.0.1`. |

---

### H12 — Vulnerabilidades em dependências de produção

| | |
|---|---|
| **Fonte** | `npm audit --omit=dev` (2026-08-20) |
| **Backend** | 26 vulnerabilidades (2 critical, 16 high, 6 moderate, 2 low). Destaque: `ws` via `socket.io-adapter` (memory disclosure, DoS). |
| **Frontend** | 4 high: `next@16.2.1` (postcss path traversal), `sharp`/libvips CVEs. Fix sugerido: `next@16.3.1`. |
| **Correção** | `npm audit fix`; CI com gate para high/critical; pin de versões. |

---

## Achados médios

### M1 — Enumeração de utilizadores no login e forget-password

`auth.service.ts` L91–92, L139–140: mensagens distintas (“Usuário não cadastrado” vs “Senha incorreta”). Usar resposta genérica e timing constante.

### M2 — `AuthGuard` devolve 403 em vez de 401

`auth.guard.ts` L26–28, L43–44: token ausente/inválido resulta em Forbidden. Lançar `UnauthorizedException`.

### M3 — `JWT_SECRET` não validado na inicialização

`configuration.ts`, `auth.module.ts`: app pode arrancar com secret vazio/fraco. Fail-fast em produção (mín. 32 chars), como já faz `DB_PASSWORD`.

### M4 — `ValidationPipe` sem `forbidNonWhitelisted`

`main.ts` L47–52: propriedades extra são descartadas silenciosamente. Adicionar `forbidNonWhitelisted: true`.

### M5 — Swagger exposto sem Basic Auth se credenciais ausentes

`main.ts` L31–35: warning no log mas Swagger fica público. Em produção, abortar startup ou desactivar.

### M6 — Postgres e Grafana publicados em `0.0.0.0`

`docker-compose.yml` (raiz) L19–20, L114–115; `backend/docker-compose.yml` L17–18, L77–78. Exposição na LAN inteira.

### M7 — Stack só-API expõe API completa

`backend/docker/nginx.conf`: `location /` → toda a API, incluindo `/metrics`, `/swagger`, WebSocket. Documentar que **não** deve ser usada na LAN sem hardening.

### M8 — Erros internos expostos ao cliente (to-do)

`to-do.service.ts`: `BadRequestException('... Error: ' + error)` concatena objeto Error — pode vazar SQL/stack.

### M9 — HTTP sem TLS na stack doméstica

JWT, cookies e credenciais em texto claro. `SESSION_COOKIE_SECURE=false` no Compose é coerente com HTTP, mas inseguro se a LAN não for confiável.

### M10 — Proxy BFF genérico sem allowlist

`FrontEnd/src/app/api/bff/[...path]/route.ts`: encaminha paths como `users`, `auth/forget-password`, `metrics`. Bloqueia apenas login/logout/reset dedicados.

### M11 — Token de reset na query string

`FrontEnd/src/app/reset-password/page.tsx`: JWT pode vazar via histórico, logs Nginx, header `Referer`. Preferir path segment ou fragmento.

### M12 — JWT decodificado no BFF sem verificar assinatura

`FrontEnd/src/lib/session.ts` L43–47: usado para UI/proxy. Backend valida nas chamadas autenticadas, mas cookie forjado (se secret vazar) passa no middleware Next até falhar no backend.

### M13 — Grafana recebe `.env` completo do backend

`docker-compose.yml` L113: contentor Grafana herda `JWT_SECRET`, passwords DB, etc. via `env_file: ./backend/.env`. Segmentar ficheiros de ambiente.

---

## Achados baixos / informativos

| ID | Severidade | Achado |
|----|------------|--------|
| B1 | Baixo | SQL injection: queries raw usam parâmetros bind — risco baixo. Manter padrão. |
| B2 | Baixo | Sem endpoints de upload de ficheiros — path traversal não aplicável. |
| B3 | Baixo | `console.log(error)` espalhado — logs não estruturados; risco de vazar dados em produção. |
| B4 | Baixo | Dockerfiles usam `npm install` em vez de `npm ci` — builds menos reproduzíveis. |
| B5 | Info | `.env` no `.gitignore`; `.env.example` sem valores reais; API corre como user `node`, Next como `nextjs`. |
| B6 | Info | Filtro global `AllExceptionsFilter` loga 5xx com stack no servidor — correcto. |
| B7 | Info | Frontend: sem `dangerouslySetInnerHTML`, sem `NEXT_PUBLIC_*` secrets, open redirect mitigado no login. |
| B8 | Info | Nginx raiz não encaminha rotas de página Next para API — boa separação documentada. |

---

## Frontend — avaliação separada

### Pontos fortes

- Padrão BFF maduro: cookie `httpOnly`, Route Handlers dedicados para auth, proxy bloqueia paths sensíveis de login.
- Headers de segurança em `next.config.ts`: `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`, HSTS condicional.
- Validação de path no BFF (`PATH_SAFE`, anti `..`).
- Testes unitários do proxy BFF existem.
- Dockerfile multi-stage, utilizador não-root, `standalone`.

### Lacunas principais

1. **Socket.IO** — canal paralelo sem auth (H7).
2. **CSP ausente** — defesa em profundidade contra XSS futuro.
3. **Dependências** — Next.js 16.2.1 com CVEs high (H12).
4. **`/api/runtime` público** — deriva `wsUrl` de `Host`/`X-Forwarded-*`; risco de host header poisoning se proxy mal configurado.
5. **CSRF** — mitigação parcial via `SameSite=Lax`; sem validação `Origin`/`Referer` nos POST do BFF.

---

## Containers e infraestrutura

| Componente | Estado | Risco |
|------------|--------|-------|
| **Postgres** | Porta host `5432` (default), `0.0.0.0` | Alto — brute force, acesso directo se password fraca |
| **Grafana** | Porta host `3002`, password obrigatória | Médio — superfície extra; `.env` completo injectado |
| **Prometheus** | Só `expose:9090` (rede Docker) | Baixo no host; métricas vazam via API/BFF |
| **Nginx raiz** | `:8080`, sem TLS, sem rate limit, sem security headers | Médio |
| **Nginx só-API** | Proxy total para Nest | Alto se usado na LAN |
| **API/Web** | Não publicados no host (só `expose`) | Bom |
| **Rede Docker** | `taskhive` isolada | Bom |
| **Contentores** | API `USER node`, Web `USER nextjs` | Bom |
| **Prometheus lifecycle** | `--web.enable-lifecycle` activo | Baixo — permite reload/admin remoto se exposto |

### Recomendações infra (prioridade)

```yaml
# Bind localhost para serviços administrativos
ports:
  - '127.0.0.1:${POSTGRES_PUBLISH_PORT:-5432}:5432'
  - '127.0.0.1:${GRAFANA_PORT:-3002}:3000'
```

- TLS no Nginx (Caddy/Traefik/Let's Encrypt) antes de `SESSION_COOKIE_SECURE=true`.
- Segmentar `.env.grafana` / `.env.postgres`.
- Adicionar `server_tokens off`, rate limiting e security headers no Nginx.
- Remover `--web.enable-lifecycle` se não necessário.

---

## Cadeia de ataque realista (LAN)

```
1. POST /api/bff/users          → criar conta (público via BFF)
2. POST /api/auth/login         → cookie th_session
3. GET  /api/bff/users          → emails de todos
4. GET  /api/bff/project-stages → IDs de colunas
5. GET  /api/bff/tasks/stage/:id → tarefas de projetos alheios
6. GET  /api/bff/subtasks/task/:id → subtarefas + hash bcrypt do responsible
7. PATCH /api/bff/users/:adminId → alterar email do admin
8. GET  /api/bff/metrics        → reconhecimento (sem auth no Nest)
9. WebSocket joinTask           → espionar timetrack em tempo real
```

Todos os passos 3–9 exigem apenas sessão válida de conta `CLIENT`.

---

## Matriz consolidada

| ID | Sev. | Área | Resumo |
|----|------|------|--------|
| C1 | Crítico | Backend | Hash bcrypt vazado via relations TypeORM |
| C2 | Crítico | Backend | IDOR total em `/users` |
| C3 | Crítico | Backend | IDOR em to-do |
| C4 | Crítico | Backend | IDOR leituras tasks/stages/projects |
| H1 | Alto | Backend | RolesGuard nunca aplicado |
| H2 | Alto | Backend | Cadastro público |
| H3 | Alto | Auth | JWT 90 dias |
| H4 | Alto | Auth | Reset password inseguro |
| H5 | Alto | Backend | CORS aberto |
| H6 | Alto | Backend | Sem rate limiting |
| H7 | Alto | Full-stack | WebSocket sem auth |
| H8 | Alto | Full-stack | `/metrics` sem auth |
| H9 | Alto | Backend | IDOR companies |
| H10 | Alto | Backend | IDOR subtasks |
| H11 | Alto | Docker | DB_REMOTE ALL PRIVILEGES + Postgres exposto |
| H12 | Alto | Deps | npm audit backend/frontend |
| M1–M13 | Médio | Vários | Ver secção média |
| B1–B8 | Baixo/Info | Vários | Ver secção baixa |

---

## Plano de remediação sugerido

### Fase 1 — Imediato (1–3 dias)

1. Corrigir serialização de `User` em projects/subtasks (C1).
2. Ownership checks em to-do, users (self-only), reads de tasks/stages/projects (C2–C4).
3. Autenticar WebSocket + autorizar `joinTask` (H7).
4. Bloquear `/metrics` no BFF e no Nest em produção (H8).

### Fase 2 — Curto prazo (1–2 semanas)

5. Aplicar `RolesGuard` em rotas administrativas (H1).
6. Rate limiting + CORS restrito (H5, H6).
7. Reset password seguro (H4).
8. Bind `127.0.0.1` Postgres/Grafana (M6).
9. `npm audit fix` + actualizar Next.js (H12).

### Fase 3 — Médio prazo

10. TLS + cookies seguros (M9).
11. CSP no Next.js; allowlist no BFF (M10).
12. Reduzir privilégios `DB_REMOTE_*` (H11).
13. Access/refresh tokens (H3).
14. CI: `npm audit`, scan de imagens, testes que falham se `password` aparece em JSON.

---

## Conclusão

O Task Hive demonstra **maturidade na camada de sessão do frontend** — raro em projetos deste tamanho — mas o **modelo de autorização do backend está incompleto** relativamente ao que a documentação interna (`to-do.md`, helpers de permissão) sugere que deveria existir. A discrepância entre mutações protegidas e leituras abertas, somada ao WebSocket e métricas expostas, cria um cenário em que a autenticação dá falsa sensação de segurança.

Para uso doméstico na LAN, o mínimo aceitável é corrigir os quatro críticos e H7/H8 antes de convidar outros utilizadores. Para qualquer exposição além da rede local, tratar a Fase 1–2 como bloqueante.

---

*Relatório gerado por análise estática. Recomenda-se validação dinâmica (pentest, OWASP ZAP, testes de integração de autorização) após remediação.*
