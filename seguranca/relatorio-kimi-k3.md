# Relatório de Análise de Segurança — TaskHive

**Analista:** Kimi K3 (Moonshot AI)
**Data:** 2026-08-20
**Escopo:** Backend (NestJS 11 + TypeORM + PostgreSQL), Frontend (Next.js 16 BFF), Containers/Infra (Docker Compose, Nginx, Prometheus, Grafana)
**Método:** Revisão estática manual de código e configuração (white-box). Os demais relatórios desta pasta foram propositalmente ignorados, a pedido do autor, para garantir uma opinião independente.

---

## 1. Sumário executivo

O TaskHive é uma aplicação self-hosted (LAN doméstica) com arquitetura BFF (Next.js) → API (NestJS) → Postgres, fronteada por Nginx e observada por Prometheus/Grafana. O projeto demonstra **boas decisões de engenharia incomuns em códigobases desse porte**: token JWT em cookie `httpOnly` (nunca acessível ao JS do navegador), proxy BFF com allowlist de path, validação com `whitelist: true`, queries parametrizadas, helpers de permissão por recurso em `projects`/`tasks`/`project-stages`/`timetrack`, containers com usuário não-root e segredos fora do Git.

Porém, o mesmo projeto contém **falhas críticas de autorização (IDOR/BOLA) em módulos inteiros** (`users`, `to-do`, `companies`, `subtasks`), um **gateway WebSocket totalmente desautenticado**, **ausência completa de rate limiting**, e uma **cadeia de comprometimento via banco de dados exposto na LAN com senha reutilizada** que rende sessões e tokens de reset em texto claro. O modelo de autorização é inconsistente: módulos novos têm verificação rigorosa; módulos antigos não têm nenhuma.

**Contagem de achados:** 6 críticos · 7 altos · 12 médios · 9 baixos/informativos.

| Severidade | IDs |
|---|---|
| Crítica | C1–C6 |
| Alta | A1–A7 |
| Média | M1–M12 |
| Baixa / Info | B1–B9 |

---

## 2. Achados críticos

### C1 — IDOR generalizado no módulo `users` (qualquer autenticado altera/apaga qualquer conta)

**Arquivo:** `backend/src/users/users.controller.ts`, `backend/src/users/users.service.ts`

Todos os endpoints de escrita/leitura individual recebem o `:id` alvo mas **nunca comparam com o usuário autenticado** nem exigem papel administrativo:

- `PUT /users/:id` — altera `name`, `email` e `avatar` de **qualquer** usuário. Trocar o e-mail da vítima é preparação para sequestro de conta via fluxo de reset.
- `PATCH /users/:id` (soft delete) e `DELETE /users/:id` — removem **qualquer** usuário. O único bloqueio existente é contra auto-remoção (`users.service.ts:68`), ou seja: posso apagar todos, menos a mim mesmo.
- `GET /users` — lista id, nome e **e-mail de todos os usuários** para qualquer conta autenticada (enumeração em massa / vazamento de PII).
- `GET /users/:id` — idem individual.

O `RolesGuard` existe (`backend/src/guards/roles.guard.ts`) mas **não é aplicado em nenhum controller** — não há um único `@Roles()` no código. O RBAC é efetivamente inexistente.

**Exploração:** registrar conta gratuita (registro é público, `POST /users` sem auth) → `PUT /users/<id-do-admin>` trocando o e-mail → combinar com A2/C5 para reset de senha → takeover de conta `ADMIN_GOD`.

**Correção:** verificar `id === user.id` (ou papel admin) no serviço antes de update/remove; restringir `GET /users` a admins; aplicar `RolesGuard` de fato.

---

### C2 — IDOR no módulo `to-do` (tarefas pessoais de qualquer usuário)

**Arquivo:** `backend/src/to-do/to-do.service.ts`

Os métodos `update`, `remove`, `endTask`, `changeTaskStatus`, `nextDateRecurringTask` e `findOne` recebem o objeto `user` **mas jamais verificam `todo.user.id === user.id`**. O parâmetro `user` é aceito e silenciosamente ignorado — o que sugere que a verificação foi planejada e esquecida.

Qualquer usuário autenticado pode ler (`GET /to-do/:id`), editar, concluir, mudar status e apagar as tarefas pessoais de terceiros. IDs são snowflakes previsíveis por ordem temporal (ver M12), facilitando enumeração.

**Correção:** carregar a entidade, comparar `todo.user.id` com o autenticado (ou `isAdmin`) e lançar `ForbiddenException`, como já se faz em `tasks.service.ts`.

---

### C3 — Módulo `companies` sem nenhuma autorização

**Arquivo:** `backend/src/companies/companies.service.ts`

CRUD completo de empresas aberto a **qualquer usuário autenticado**: criar, listar todas, renomear e remover empresas alheias. Não existe conceito de dono no serviço. Combinado com `POST /projects` (que aceita `companyOwnerId`), um atacante vincula projetos a empresas que não controla.

**Correção:** modelar ownership de `Company` e verificar no serviço, ou restringir o módulo a admins via `RolesGuard`.

---

### C4 — Gateway WebSocket sem autenticação e com rooms arbitrárias

**Arquivo:** `backend/src/tasks/timetrack.gateway.ts`

- `handleConnection()` **não valida token algum** — qualquer cliente anônimo conecta.
- `joinTask` faz `client.join('task:' + payload.taskId)` com `taskId` livre → um anônimo entra na room de **qualquer tarefa** e passa a receber em tempo real os eventos `timetrack:started/stopped/updated/deleted`, que carregam dados do registro (quem está trabalhando em quê, quando).
- `@WebSocketGateway({ cors: true })` — qualquer origem pode abrir o socket (cross-site WebSocket hijacking facilitado, pois não há cookie nem token a exigir).

**Correção:** validar JWT no handshake (`handleConnection(client)` lendo `client.handshake.auth.token`, com `client.disconnect()` em falha) e, no `joinTask`, verificar `canAccessProject` da tarefa antes do `join`. Restringir `cors` às origens conhecidas.

---

### C5 — Cadeia de takeover via Postgres exposto na LAN + senha única reutilizada

**Arquivos:** `backend/.env`, `docker-compose.yml`, `backend/docker/postgres/init/01-users.sh`

A mesma senha (`2]#Pe4?M1+50`) é usada para **três papéis distintos**: superuser do container (`POSTGRES_USER`), usuário da aplicação (`DB_USER`) e usuário remoto (`DB_REMOTE_USER`). O init script cria os três, mas a separação de privilégios é cosmética quando a credencial é idêntica.

O Postgres é publicado no host em `0.0.0.0:${POSTGRES_PUBLISH_PORT}` (5468) para "pgAdmin/DBeaver a partir da LAN". Resultado: **qualquer dispositivo na rede local tem acesso total de leitura/escrita ao banco**, incluindo:

- tabela `session` → **JWTs completos e válidos em texto claro** (ver A1) → sequestro imediato de qualquer sessão, sem precisar quebrar bcrypt;
- tabela `forget_password` → tokens de reset válidos por 24h (ver A2) → redefinir a senha de qualquer conta;
- escrita direta → trocar `role` para `ADMIN_GOD`, zerar hashes, etc.

O comentário no `.env` ("Protege com firewall se expuseres à Internet") indica ciência do risco, mas a exposição **na LAN já é suficiente** para o cenário acima.

**Correção:** senhas distintas por papel (geradas aleatoriamente); idealmente **não publicar a porta do Postgres no host** (remover `ports:` e usar apenas a rede interna do Compose); se acesso remoto for indispensável, restringir `DB_REMOTE_USER` a read-only e bind em interface específica + TLS no Postgres.

---

### C6 — Ausência total de rate limiting (brute force irrestrito)

**Evidência:** nenhuma dependência `@nestjs/throttler` em `backend/package.json`; nenhum `ThrottlerGuard` em `app.module.ts`; nenhum `limit_req_zone` no `docker/nginx.conf`.

Os endpoints `POST /auth/login`, `POST /users` (registro público), `POST /auth/forget-password` e `POST /auth/reset-password` aceitam tentativas ilimitadas. A senha do admin seed (`Aaaa@1234`, ver M8) é trivialmente atacável por força bruta online. O login ainda confirma se o e-mail existe (ver A3), alimentando credential stuffing direcionado.

**Correção:** `@nestjs/throttler` global + limites agressivos em `/auth/*`; bloqueio progressivo/captcha após N falhas; `limit_req_zone` no Nginx como segunda camada.

---

## 3. Achados altos

### A1 — Tokens de sessão (JWT completos) em texto claro no banco

**Arquivo:** `backend/src/auth/entities/Session.entity.ts` (`token: string`), `auth.service.ts:288`

A tabela `session` guarda o JWT íntegro. Como o token **é** a credencial (stateless, audience `login`), quem lê o banco (ver C5) assume qualquer sessão ativa — o hash bcrypt da senha torna-se irrelevante. Padrão correto: armazenar apenas `sha256(token)` e comparar o hash no `AuthGuard`, de modo que vazamento do banco não revele credenciais utilizáveis.

### A2 — Fluxo de reset de senha frágil em três pontos

**Arquivo:** `backend/src/auth/auth.service.ts`

1. **Token não é invalidado após o uso** — `resetPassword` (linhas 164–205) nunca remove o registro de `forget_password`; o mesmo token redefine a senha repetidas vezes durante 24h.
2. **`expiresAt` do banco nunca é verificado** — `isValidResetToken` só valida assinatura/exp do JWT e existência do registro. A coluna `expiresAt` é decorativa.
3. **Sessões antigas não são revogadas** ao trocar a senha — um atacante com sessão ativa permanece logado mesmo após a vítima redefinir a senha.

Agravante arquitetural: o "envio de e-mail" não está implementado (`// enviar email`, linha 152). Os tokens de reset **só existem no banco** — qualquer leitura de banco (C5) vira reset de qualquer conta. E como o e-mail da vítima pode ser trocado por IDOR (C1), o fluxo inteiro de recuperação é subvertível.

**Correção:** deletar o registro ao usar; checar `expiresAt`; revogar todas as sessões do usuário no reset; token de reset deve ser valor aleatório opaco (não JWT reutilizável), armazenado com hash.

### A3 — Enumeração de usuários por mensagens de erro e por timing

**Arquivo:** `backend/src/auth/auth.service.ts:87-109, 135-141`

- Login: `'Usuário não cadastrado'` vs `'Senha incorreta'` — respostas distintas confirmam a existência da conta.
- `forget-password`: `'Usuário não cadastrado'` idem.
- Timing: `bcrypt.compare` só executa quando o usuário existe → diferença mensurável de latência mesmo se as mensagens forem unificadas.

**Correção:** mensagem única ("credenciais inválidas" / "se o e-mail existir, enviaremos instruções") e `compare` contra hash dummy quando o usuário não existe.

### A4 — CORS irrestrito na API

**Arquivo:** `backend/src/main.ts:45` — `app.enableCors()` sem opções → reflete **qualquer origem**.

Como a autenticação usa header `Authorization` (não cookie na API), o impacto direto via navegador é limitado — mas qualquer token obtido (XSS futuro, extensão maliciosa, C5) pode ser usado de qualquer site. Em dev, a API escuta diretamente no host (`APP_PORT=3069`) sem Nginx, ficando acessível à LAN com CORS aberto. O gateway WS repete o erro com `cors: true` (C4).

**Correção:** `enableCors({ origin: [lista explícita] })` — na prática, via Nginx/BFF a API nem precisa de CORS.

### A5 — Swagger e especificação OpenAPI potencialmente públicos

**Arquivos:** `backend/src/main.ts:18-35`, `backend/.env` (`SWAGGER_PASSWORD=` vazio), `docker/nginx.conf:45-82`

A proteção por Basic Auth **só é ativada se usuário E senha estiverem definidos**; com senha vazia (estado atual do `.env`), cai no ramo do `Logger.warn` e o Swagger sobe aberto. O Nginx encaminha `/swagger` e `/api-json` publicamente. A especificação completa (rotas, DTOs, exemplos com formatos de ID) é um mapa para os IDORs deste relatório. Adicional: `express-basic-auth` não faz comparação em tempo constante por padrão.

**Correção:** falhar o bootstrap (`throw`) se Swagger estiver habilitado sem senha em qualquer ambiente acessível à rede; idealmente desabilitar Swagger quando `NODE_ENV=production`.

### A6 — Stack inteira sem TLS (credenciais e sessões em claro na rede)

**Arquivos:** `docker/nginx.conf` (só `listen 80`), `docker-compose.yml` (`SESSION_COOKIE_SECURE: 'false'`, `ENABLE_HSTS: 'false'`)

Login, cookie de sessão, JWTs e o Basic Auth do Swagger trafegam em HTTP puro na LAN. Qualquer dispositivo na rede (ou ARP spoofing) captura credenciais. Reconheço a decisão documentada ("HTTP doméstico"), mas ela deve constar como risco aceito formalmente — e o sistema deveria ao menos facilitar a ativação de TLS (ex.: Caddy/Traefik com cert interno) sem exigir edição de código.

### A7 — Endpoint `/metrics` do Prometheus sem autenticação, alcançável de fora via BFF

**Arquivos:** `backend/src/metrics/metrics.module.ts` (`path: '/metrics'`, sem guard), `FrontEnd/src/app/api/bff/[...path]/route.ts`

Dois vetores:
1. Na rede Docker, qualquer container lê `/metrics` da API (baixo, porém sem autenticação).
2. **Incomum e mais interessante:** o proxy BFF valida o path com `^[a-zA-Z0-9/_-]+$` — `metrics` passa. O proxy só anexa `Authorization` *se houver* cookie, mas como `/metrics` no backend não exige auth, **`GET /api/bff/metrics` é público via Nginx**, expondo nomes de rotas, contadores por módulo, durações e metadata do Node (versão, GC, memória) a qualquer um na LAN — reconhecimento gratuito para os ataques deste relatório.

**Correção:** guard no endpoint de métricas (ou bind interno); adicionar `metrics` a `BLOCKED_PATHS` no BFF.

---

## 4. Achados médios

### M1 — Leitura IDOR em `tasks` e `projects`

- `GET /tasks/:id` → `tasks.service.ts:161` (`findOne`) **não verifica acesso ao projeto**.
- `GET /tasks/stage/:stage` → `findByStage` (linha 140) ignora o usuário — lista tarefas de qualquer coluna.
- `GET /projects/:id` → `projects.controller.ts:182` recebe `@User() user` e **não o usa**; o serviço retorna o projeto sem checagem.

Ironicamente, as *escritas* desses módulos têm verificação cuidadosa (`canAccessProject`, `canManageProject`, `canMoveOrRemoveTask`) — a inconsistência sugere cobertura parcial de revisão. Padrão: toda leitura individual deve passar pelo mesmo helper das escritas.

### M2 — `subtasks`: listagem global e criação sem verificar acesso

**Arquivo:** `backend/src/subtasks/subtasks.service.ts`

- `findAll()` retorna **todas as subtarefas do sistema** a qualquer autenticado.
- `create` verifica apenas se a task existe — qualquer um cria subtarefas em tarefas de projetos alheios.
- `findByTaskId` não checa acesso ao projeto.
- (update/remove checam `responsible.id` — correto, porém fora do padrão dos demais módulos.)

### M3 — JWT com validade de 90 dias e sem rotação

**Arquivos:** `backend/src/auth/auth.module.ts:18` (`expiresIn: '90d'`), `auth.service.ts:44`

Sessão de 3 meses sem refresh token, sem idle timeout e sem revogação em cascata (A2). O cookie do frontend espelha isso (`SESSION_MAX_AGE_SECONDS` = 90 dias em `FrontEnd/src/lib/session.ts:11`). Uma cópia do token vale por um trimestre. Recomendado: access token curto (15min–1h) + refresh rotativo, ou ao menos expiração de dias (não meses) com revalidação.

### M4 — bcrypt com custo 10

**Arquivos:** `backend/.env` (`CRYPT_SALT=10`), `backend/src/utils/crypt.ts`

10 rounds era o padrão de 2015; em 2026 o recomendado é 12+ (OWASP) para hardware moderno. O código ainda aceita o alias `CRYPT_SAULT` (sic) sem validar que o valor parseado é um número sadio (`Number(raw)` pode virar `NaN` → `bcrypt` lançaria erro em runtime).

### M5 — Vazamento de erros internos ao cliente

**Arquivo:** `backend/src/to-do/to-do.service.ts` (ex.: linha 62: `'Falha ao criar a tarefa, Error: ' + error`)

Concatenar o erro original na resposta 400 devolve mensagens internas (constraints do Postgres, paths, SQL) ao cliente. O `AllExceptionsFilter` loga 5xx corretamente, mas esses 400 artesanais vazam detalhes sem deixar log útil. Corrigir para mensagem fixa + log interno.

### M6 — `RolesGuard` implementado e nunca utilizado

RBAC existe só no papel: nenhum `@Roles()` em controller algum. Toda a diferenciação admin/cliente ocorre via helpers nos services de `projects`/`tasks`/`project-stages`/`timetrack`. Qualquer endpoint futuro que depender de papel corre o risco de nascer desprotegido. Aplicar `RolesGuard` como guard global com `@Roles()` explícito, ou removê-lo para não dar falsa sensação de cobertura.

### M7 — Segredos concentrados e distribuídos a todos os containers

**Arquivos:** `backend/.env`, `docker-compose.yml` (`env_file: ./backend/.env` em postgres, api **e grafana**)

- O mesmo `env_file` injeta `JWT_SECRET`, senhas de banco, senha do admin seed e senha do Grafana **em todos os containers** — o Grafana não precisa do `JWT_SECRET` da API; o Postgres não precisa da senha do Grafana. Comprometimento de qualquer container (ou um simples `docker inspect`) expõe tudo.
- Senha do admin seed: `Aaaa@1234` — padrão de teclado fraco para a conta `ADMIN_GOD`, com e-mail real do autor em texto claro.
- `FrontEnd/.env` linha 8 contém um comentário solto com o que aparenta ser uma credencial real (`p-7#7Jb=?94AB7RZ`) — remover/rotacionar se for.
- Positivo: os `.env` **não estão versionados** (verificado via `git ls-files` nos três repositórios) e `.env.example`/`.env.e2e.example` estão limpos.

**Correção:** segregar variáveis por serviço (`environment:` explícito em vez de `env_file` compartilhado), rotacionar a senha do admin e investigar o comentário no `.env` do frontend.

### M8 — Imagens por tag mutável e builds não reproduzíveis

**Arquivos:** `backend/Dockerfile`, `FrontEnd/Dockerfile`, `docker-compose.yml`

- `node:22-alpine`, `nginx:alpine`, `postgres:16-alpine` — tags flutuantes, sem pin por digest (`@sha256:…`). Um retag malicioso/comprometido upstream entra no próximo build.
- `RUN npm install` (ambos os Dockerfiles) **ignora o lockfile** — resolve versões novas de dependências transitórias a cada build (supply chain). Trocar por `npm ci`.
- Sem escaneamento de imagens (trivy/grype) no fluxo.

### M9 — Frontend sem Content-Security-Policy

**Arquivo:** `FrontEnd/next.config.ts`

Há `X-Frame-Options`, `nosniff`, `Referrer-Policy` e `Permissions-Policy` (bom), mas **nenhum CSP** — a defesa mais importante contra XSS. Como o token vive em cookie httpOnly, um XSS não rouba o token diretamente, mas executa ações autenticadas via BFF à vontade. Começar com CSP em `Report-Only` e endurecer.

### M10 — `/api/runtime` confia em headers `Host`/`X-Forwarded-Host`

**Arquivo:** `FrontEnd/src/app/api/runtime/route.ts:14-22`

A `wsUrl` devolvida ao browser deriva de headers controláveis pelo cliente, e o Nginx repassa `$http_host` sem validação (`server_name _`). Um request com `Host: evil.com` recebe `{"wsUrl":"http://evil.com"}`. Hoje o impacto é limitado (resposta `force-dynamic`, sem cache; cada cliente recebe a sua), mas é um padrão frágil: qualquer cache futuro ou consumidor diferente transforma isso em envenenamento. Preferir `PUBLIC_WS_URL` fixo em produção e validar o host contra allowlist.

### M11 — Prometheus com `--web.enable-lifecycle`

**Arquivo:** `docker-compose.yml:96`

Habilita `POST /-/reload` e `POST /-/quit` sem autenticação na rede interna — qualquer container (ou qualquer um que alcance a rede `taskhive`) derruba o Prometheus ou força reloads. Remover a flag ou proteger.

### M12 — IDs snowflake vazam informação e são ordenáveis

**Arquivo:** `backend/src/snowflakeid/SnowflakeId.ts`

IDs de tasks/projetos/subtasks codificam timestamp de criação, worker e sequência — previsíveis por vizinhança temporal (basta criar um recurso e chutar ±N ms). Não é vulnerabilidade por si só, mas **remove a segurança obscura que mascararia os IDORs** (C1–C3, M1, M2): enumerar todos os recursos do sistema é trivial. Se a autorização for corrigida, o risco desaparece; até lá, agrava tudo.

---

## 5. Achados baixos / informativos

| ID | Achado | Local |
|---|---|---|
| B1 | `safeNextPath` aceita `/\evil.com` (barras invertidas não são filtradas) — bypass clássico de validação de redirect interno. Hoje `router.push` do Next limita o impacto (pushState não navega cross-origin), mas é frágil se o padrão for reutilizado com `location.href`. | `FrontEnd/src/components/auth/login-form.tsx:33-38` |
| B2 | Guard de rotas do Next verifica só a **presença** do cookie, não a validade — decisão documentada e aceitável, desde que nenhum dado sensível seja renderizado server-side sem revalidação (hoje ok). | `FrontEnd/src/proxy.ts` |
| B3 | `AuthGuard` retorna `false` (→ 403) em vez de lançar `UnauthorizedException` (401), e engole qualquer erro (inclusive falha de banco) como "não autorizado", dificultando diagnóstico. | `backend/src/guards/auth.guard.ts` |
| B4 | `checkToken` lança `BadRequestException` (400) para token inválido — códigos inconsistentes (400/401/403 para o mesmo fenômeno). | `backend/src/auth/auth.service.ts:76` |
| B5 | `console.log(error)` em vários controllers/services em vez de `Logger` estruturado — logs sem nível/contexto e possível vazamento de payload para stdout do container. | vários (`auth.service.ts`, `projects.controller.ts`, etc.) |
| B6 | `ValidationPipe` sem `forbidNonWhitelisted: true` — propriedades extras são silenciosamente descartadas; dificulta detecção de tentativas de mass assignment. | `backend/src/main.ts:47-53` |
| B7 | Sem verificação de e-mail no registro e sem confirmação de senha atual para trocar e-mail/senha da própria conta. | `users.controller.ts` |
| B8 | `trust proxy` fixo em 1 hop: correto atrás do Nginx, mas se a API for exposta diretamente (porta 3069 em dev), `X-Forwarded-For` fica falsificável (relevante quando houver rate limiting por IP). | `backend/src/main.ts:13` |
| B9 | Compose secundário (`backend/docker-compose.yml`) referencia `./docker/nginx.conf` que não existe em `backend/docker/` — falha de disponibilidade ao subir a stack por ali (não é vetor de ataque, mas indica configuração sem teste). | `backend/docker-compose.yml:51` |

---

## 6. Pontos fortes (vale manter)

1. **BFF com cookie `httpOnly`** — o JWT nunca toca o JS do navegador (`FrontEnd/src/app/api/auth/login/route.ts`, `lib/session.ts`); login/logout/reset têm route handlers dedicados e o proxy genérico **bloqueia** esses paths para não vazar token.
2. **Proxy BFF higienizado**: regex de path, bloqueio de `..`, forward apenas de headers necessários, `cache: no-store`.
3. **Queries parametrizadas em tudo** — TypeORM e o único SQL manual (`tasks.service.ts:71-73`) usam bindings `$1/$2/$3`. Nenhuma injeção de SQL encontrada.
4. **Helpers de autorização por recurso** (`project-permissions.helper.ts`) aplicados com consistência nos módulos `projects` (escritas), `tasks` (escritas), `project-stages` e `timetrack` — prova de que o padrão correto já existe na base; falta estendê-lo.
5. **Validação de DTOs** com `class-validator` + `whitelist: true` (senha forte no registro/reset, `IsEqualsTo` para confirmação).
6. **Containers não-root** (`USER node` / `USER nextjs`), volumes de config `:ro`, healthcheck do Postgres, `GF_USERS_ALLOW_SIGN_UP=false`, falha explícita do Grafana sem senha.
7. **Segredos fora do Git** (verificado nos 3 repositórios) e `.env.example` sem valores reais.
8. **Headers de segurança parciais** no Next e `sameSite: lax` no cookie de sessão.
9. Migrations em vez de `synchronize` (com warning explícito no código).
10. Soft delete generalizado (auditoria/recuperação).

---

## 7. Recomendações priorizadas

**Imediato (esta semana):**
1. Corrigir IDORs: `users` (C1), `to-do` (C2), `companies` (C3), leituras de `tasks`/`projects` (M1), `subtasks` (M2). O padrão já existe — replicar `canAccessProject`/ownership check.
2. Autenticar o WebSocket e autorizar `joinTask` (C4).
3. Rate limiting em `/auth/*` e registro (C6).
4. Senhas distintas por papel de banco e, idealmente, **não publicar** a porta do Postgres no host (C5). Rotacionar tudo que está no `.env` atual — incluindo a senha do admin seed (M7).

**Curto prazo:**
5. Hash dos tokens em `session` e invalidação de reset token após uso + revogação de sessões no reset (A1, A2).
6. Mensagens de erro unificadas no login/forget-password (A3).
7. CORS restrito (A4) e Swagger bloqueado ou protegido à força (A5) — falhar o boot sem `SWAGGER_PASSWORD`.
8. Bloquear `metrics` no BFF e proteger `/metrics` (A7).

**Médio prazo:**
9. Reduzir validade do JWT e implementar refresh/rotatividade (M3); bcrypt 12+ (M4).
10. `npm ci` + pin de digest das imagens + scan de vulnerabilidades no build (M8).
11. CSP no frontend (M9), `PUBLIC_WS_URL` fixo (M10), remover `--web.enable-lifecycle` (M11).
12. Aplicar `RolesGuard` de verdade ou removê-lo (M6); uniformizar códigos 401/403 (B3/B4).
13. Plano de TLS para a LAN (A6) — mesmo que decidido não aplicar, documentar o risco aceito.

---

## 8. Nota sobre o modelo de ameaça

Esta análise assume o cenário declarado pelo próprio projeto (self-hosted em LAN doméstica). Mesmo nesse cenário, "rede interna" inclui visitantes no Wi-Fi, IoT comprometido e extensões de navegador — por isso C4, C5, C6 e A6 figuram como severidades altas/críticas. Se um dia esta stack for exposta à Internet (port-forward, tunnel, VPS), **todos os itens críticos tornam-se exploráveis remotamente por qualquer pessoa**, e a ausência de TLS (A6) garante a interceptação das credenciais. A recomendação estrutural única mais valiosa é: **fechar os IDORs e autenticar o WebSocket antes de qualquer exposição adicional**.
