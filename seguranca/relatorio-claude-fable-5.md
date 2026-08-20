# Relatório de Segurança — TaskHive

**Autor:** Claude Fable 5 (Cursor)
**Data:** 20/08/2026
**Escopo:** Backend (NestJS), Frontend (Next.js) e infraestrutura de containers (Docker Compose, Nginx, Postgres, Grafana/Prometheus).
**Método:** Revisão estática de código (somente leitura), `npm audit` das dependências de produção e inspeção da configuração de infraestrutura. Nenhum arquivo do projeto foi modificado.

> Este relatório é independente. Outros relatórios existentes na pasta `seguranca/` foram ignorados propositalmente, conforme solicitado.

---

## 1. Resumo executivo

O TaskHive tem uma base arquitetural razoável em vários pontos: autenticação com JWT validada contra sessão em banco (permite logout real), `ValidationPipe` global com `whitelist`, senhas com bcrypt, padrão BFF no frontend com o JWT guardado em cookie `httpOnly` (o token nunca chega ao JavaScript do navegador) e SQL parametrizado. Não há upload de arquivos, o que elimina toda uma classe de vulnerabilidades.

Apesar disso, existem **falhas graves de controle de acesso** que comprometem a confidencialidade e integridade dos dados de todos os usuários. As mais sérias:

- **IDOR/BOLA generalizado**: qualquer usuário autenticado consegue ler, alterar e apagar recursos de outros usuários (contas de usuário, to-dos, projetos, stages, tasks, subtasks, empresas).
- **Vazamento do hash de senha (bcrypt)** de outros usuários em respostas da API, através de `relations`/joins do TypeORM, porque a coluna `password` não é marcada como `select: false`.
- **Segredos reais commitados/expostos** em `backend/.env` (senhas de banco, `JWT_SECRET`, senha do admin seed, senha do Grafana) — o arquivo está fora do Git, mas contém segredos de produção em texto puro e precisa de rotação.
- **WebSocket (Socket.IO) sem autenticação** e com CORS aberto.
- **Swagger e `/api-json` expostos publicamente sem autenticação** porque `SWAGGER_PASSWORD` está vazio.
- **Ausência total de rate limiting** (força bruta em login/reset), **CORS aberto** (`enableCors()` sem restrição) e **sem Helmet**.
- **Dependências com muitas vulnerabilidades conhecidas**: backend com 26 (2 críticas, 16 altas); frontend com Next.js afetado por advisories de severidade alta, incluindo bypass de middleware/proxy.

### Contagem de achados por severidade

| Severidade | Quantidade |
|------------|:----------:|
| Crítica    | 6 |
| Alta       | 11 |
| Média      | 12 |
| Baixa      | 7 |
| Informativo | vários |

### Top 5 correções prioritárias

1. Parar o vazamento do hash de senha (`@Column({ select: false })` em `password` + sanitizar todas as respostas que retornam entidades `User`).
2. Corrigir os IDOR: toda leitura/escrita de recurso deve filtrar por dono/participante ou validar permissão no serviço.
3. Rotacionar todos os segredos expostos no `.env` e garantir que nunca sejam versionados.
4. Fechar o Swagger/`api-json` (definir `SWAGGER_PASSWORD` forte ou desabilitar em produção) e autenticar o WebSocket.
5. Adicionar rate limiting, restringir CORS e atualizar dependências vulneráveis.

---

## 2. Infraestrutura e containers

### [CRÍTICA] Segredos de produção em texto puro no `.env`

**Arquivo:** `backend/.env`

O arquivo contém credenciais reais em texto puro:

```
DB_PASSWORD="2]#Pe4?M1+50"
JWT_SECRET="dF#9xL7p@Yz8K!3rM*q$4NtWvJ%5G2hC"
POSTGRES_PASSWORD="2]#Pe4?M1+50"
DB_REMOTE_PASSWORD="2]#Pe4?M1+50"
SEED_ADMIN_PASSWORD=Aaaa@1234
GRAFANA_ADMIN_PASSWORD="sdg465sdfg6sdfg4s6df"
```

**Problemas:**
- A mesma senha (`2]#Pe4?M1+50`) é reutilizada para o usuário da aplicação, o superusuário `postgres` e o usuário remoto — comprometer um compromete todos.
- `SEED_ADMIN_PASSWORD=Aaaa@1234` é uma senha fraca e previsível para a conta `ADMIN_GOD` (privilégio máximo).
- `SEED_ADMIN_EMAIL` é um e-mail pessoal real, combinado a uma senha fraca de administrador.
- O `.gitignore` da raiz e dos subprojetos ignora `.env` (confirmei via `git ls-files` — não está versionado), o que é bom, **mas** os segredos ainda existem em texto puro no disco e provavelmente foram compartilhados. Devem ser tratados como comprometidos.

**Risco:** Comprometimento total do banco de dados, forja de qualquer JWT (com o `JWT_SECRET` conhecido, um atacante assina tokens válidos para qualquer usuário/role, incluindo `ADMIN_GOD`) e acesso ao Grafana.

**Recomendação:**
- Rotacionar **todas** as senhas e o `JWT_SECRET` imediatamente.
- Usar senhas distintas por papel (app, superuser, remoto).
- Definir uma senha forte para o admin seed e trocá-la após o primeiro login.
- Gerir segredos via cofre (Docker secrets, Vault, ou variáveis de ambiente do orquestrador), não em arquivo `.env` em disco compartilhado.

---

### [ALTA] Porta do Postgres publicada no host

**Arquivo:** `docker-compose.yml:19-20`, `backend/.env:45`

```yaml
ports:
  - '${POSTGRES_PUBLISH_PORT:-5432}:5432'
```

O Postgres é publicado na LAN (`POSTGRES_PUBLISH_PORT=5468`). Com senhas fracas/reutilizadas, isso amplia bastante a superfície de ataque. O próprio comentário no `.env` reconhece o risco ("Protege com firewall se expuseres à Internet").

**Recomendação:** Não publicar a porta do banco a menos que estritamente necessário; se preciso, restringir por firewall a IPs confiáveis e usar credenciais fortes exclusivas. Considerar `127.0.0.1:5468:5432` para limitar ao host.

---

### [ALTA] Usuário remoto do Postgres com privilégios excessivos

**Arquivo:** `backend/docker/postgres/init/01-users.sh:38-49`

O `DB_REMOTE_USER` recebe `ALL PRIVILEGES` no schema `public` e em todas as tabelas/sequências. Combinado com a porta publicada e senha reutilizada, um acesso remoto tem controle praticamente total sobre os dados.

**Recomendação:** Conceder apenas os privilégios mínimos necessários (ex.: `SELECT` para consultas ad-hoc), com usuário e senha exclusivos.

---

### [MÉDIA] Nginx sem cabeçalhos de segurança nem rate limiting

**Arquivo:** `docker/nginx.conf`

O Nginx é o ponto de entrada único, mas não aplica cabeçalhos de segurança (CSP, HSTS, etc.) nem `limit_req` para mitigar força bruta/DoS. O `client_max_body_size 20m` é generoso para uma app sem upload.

**Recomendação:** Adicionar `limit_req_zone`/`limit_req` para `/api/auth/*` e login; considerar cabeçalhos de segurança na borda; reduzir o body size.

---

### [MÉDIA] Swagger e `/api-json` roteados publicamente pelo Nginx

**Arquivo:** `docker/nginx.conf:45-82`

O Nginx expõe `/swagger`, `/swagger/` e `/api-json` publicamente. Como o Basic Auth do backend está desativado (ver seção Backend — `SWAGGER_PASSWORD` vazio), a documentação completa da API e o schema OpenAPI ficam acessíveis a qualquer um na LAN. Isso facilita muito o reconhecimento de endpoints para explorar os IDORs.

**Recomendação:** Não rotear o Swagger publicamente em produção, ou exigir autenticação forte.

---

### [BAIXA] Grafana com credenciais derivadas do `.env` compartilhado

**Arquivo:** `docker-compose.yml:107-133`, `backend/.env:54-56`

O Grafana usa `GRAFANA_ADMIN_PASSWORD` do `.env`. A porta 3002 é publicada no host. A senha atual (`sdg465sdfg6sdfg4s6df`) deve ser rotacionada junto com os demais segredos.

---

### Pontos positivos (infraestrutura)

- Containers `api` e `web` rodam como usuário não-root (`USER node` / `USER nextjs`) — bom.
- API e web usam `expose` (rede interna) em vez de `ports`, ficando atrás do Nginx.
- Dockerfiles multi-stage com `npm prune --omit=dev` no backend.
- `.env` não está versionado no Git.

---

## 3. Backend (NestJS)

### [CRÍTICA] IDOR em contas de usuário (alterar/apagar qualquer conta)

**Arquivos:** `backend/src/users/users.controller.ts:64-98`, `backend/src/users/users.service.ts:110-143`

`PUT /users/:id` (update), `PATCH /users/:id` (soft delete) e `DELETE /users/:id` usam apenas `AuthGuard`, sem checar se o `:id` pertence ao usuário autenticado nem exigir role de admin. Só `DELETE` compara `currentUserId` — e ainda assim apenas para impedir auto-remoção, não para impedir remover **outros**.

```85:98:backend/src/users/users.controller.ts
  update(@Param('id') id: string, @Body() updateUserDto: UpdateUserDto) {
    return this.usersService.update(id, updateUserDto);
  }
  // ...
  softDelete(@Param('id') id: string) {
    return this.usersService.softDelete(id);
  }
```

**Risco:** Qualquer usuário autenticado altera o e-mail/nome/avatar ou desativa a conta de qualquer outro usuário (inclusive administradores).

**Recomendação:** Exigir `id === user.id` para self-service, e `@Roles(ADMIN)` + `RolesGuard` para operações administrativas.

---

### [CRÍTICA] Vazamento do hash de senha via relations/joins do TypeORM

**Arquivos:** `backend/src/users/entities/User.entity.ts:24-25`, `backend/src/projects/projects.service.ts:54-68`, além de subtasks/tasks/timetrack

A coluna `password` **não** tem `select: false`:

```24:25:backend/src/users/entities/User.entity.ts
  @Column({ type: 'varchar', length: 255 })
  password: string;
```

Quando uma consulta carrega o usuário via `leftJoinAndSelect`/`relations` sem `select` explícito, a coluna `password` é incluída. Exemplo confirmado em `projects.findAll`:

```54:63:backend/src/projects/projects.service.ts
  async findAll(user: User) {
    return this.metrics.track('projects', 'find_all', async () => {
      try {
        return this.projectsRepository
          .createQueryBuilder('project')
          .leftJoinAndSelect('project.userOwner', 'owner')
          .leftJoinAndSelect('project.participants', 'participants')
          .where('owner.id = :userId', { userId: user.id })
          .orWhere('participants.id = :userId', { userId: user.id })
          .getMany();
```

Aqui o `owner` e cada `participant` retornam com o hash bcrypt. O mesmo padrão aparece em `projects.remove`, `subtasks.findByTaskId` (`relations: ['responsible']`), e nos retornos de `timetrack` (`relations: ['user']`) e `tasks.remove`.

**Risco:** Qualquer usuário autenticado coleta hashes bcrypt de outros usuários e faz ataque offline (cracking). Com `CRYPT_SALT=10` (custo baixo), o cracking é mais viável.

**Recomendação:** Marcar `password` como `@Column({ select: false })`; usar `ClassSerializerInterceptor` + `@Exclude()` na entidade; nunca retornar entidades `User` cruas — usar DTOs de resposta com campos explícitos.

---

### [CRÍTICA] IDOR nos to-dos (ler/editar/apagar to-dos de outros)

**Arquivo:** `backend/src/to-do/to-do.service.ts:104-137, 139-201, 203-223`

`findOne`, `update`, `remove`, `endTask` e `changeTaskStatus` recebem o `user` autenticado, mas **nunca** filtram por `user.id`. A busca é apenas por `id` do to-do:

```139:150:backend/src/to-do/to-do.service.ts
  async update(id: bigint, updateToDoDto: UpdateToDoDto, user: User) {
    return this.metrics.track('to-do', 'update', async () => {
      try {
        const todo = await this.toDoRepository.findOne({
          where: {
            id: String(id),
          },
        })
```

**Risco:** Qualquer autenticado lê, edita ou apaga os to-dos de qualquer outro usuário apenas iterando IDs.

**Recomendação:** Filtrar por `where: { id, user: { id: user.id } }` e retornar 404/403 se não for o dono.

---

### [CRÍTICA] IDOR de leitura em projetos, stages, tasks e subtasks

**Arquivos:** `backend/src/projects/projects.controller.ts:182-189` (+ `projects.service.ts:70-72`), `project-stages`, `tasks`, `subtasks`

Enquanto `update`/`remove` de projeto verificam permissão (`canManageProject`), os endpoints de **leitura** não. `GET /projects/:id` chama `findOne(id)` sem passar o `user` nem checar acesso:

```182:189:backend/src/projects/projects.controller.ts
  findOne(@Param('id') id: string, @User() user: UserEntity) {
    try {
      return this.projectsService.findOne(BigInt(id));
```

O mesmo padrão de leitura sem `canAccessProject` ocorre em stages (`GET /project-stages`, `.../project/:id`, `.../:id`), tasks (`GET /tasks/:id`, `GET /tasks/stage/:stage`) e subtasks (listagens e `POST` de subtask em task alheia).

**Risco:** Enumeração e leitura de dados de projetos/tarefas de outros usuários; criação de subtasks em tasks sem acesso.

**Recomendação:** Aplicar `canAccessProject`/`canManageProject` também nos GETs e no create de subtasks.

---

### [CRÍTICA] Swagger/`api-json` público (Basic Auth desativado)

**Arquivos:** `backend/src/main.ts:18-43`, `backend/.env:19-20`

O Basic Auth só é aplicado se `SWAGGER_USER` **e** `SWAGGER_PASSWORD` estiverem definidos:

```21:35:backend/src/main.ts
  if (swaggerUser && swaggerPassword) {
    app.use(
      ['/swagger', '/api-json', '/api-yaml'],
      expressBasicAuth({ challenge: true, users: { [swaggerUser]: swaggerPassword } }),
    );
  } else {
    Logger.warn('Swagger exposto sem HTTP Basic: ...');
  }
```

Como `SWAGGER_PASSWORD=` está **vazio** no `.env`, a condição é falsa e o Swagger fica aberto — e o Nginx o roteia publicamente. Além disso, o Swagger é sempre montado, inclusive em produção.

**Recomendação:** Definir `SWAGGER_PASSWORD` forte, ou (melhor) desabilitar o Swagger quando `NODE_ENV=production`.

---

### [ALTA] `JWT_SECRET` conhecido permite forja total de tokens

**Arquivos:** `backend/.env:14`, `backend/src/auth/auth.module.ts:16-18`, `backend/src/auth/auth.service.ts:44-58`

Com o `JWT_SECRET` exposto no `.env` (HS256, chave simétrica), qualquer pessoa que conheça o segredo pode assinar um JWT válido com `role: ADMIN_GOD` para qualquer usuário. O `AuthGuard` valida o token e depois procura a sessão no banco — o que **mitiga parcialmente** (é preciso uma sessão correspondente no banco). Ainda assim, a exposição do segredo é um risco sistêmico e o algoritmo não é fixado explicitamente.

**Recomendação:** Rotacionar o segredo; fixar `algorithms: ['HS256']` no `verify`; falhar o boot se `JWT_SECRET` estiver ausente/fraco; considerar chaves assimétricas (RS256).

---

### [ALTA] Sem rate limiting / proteção contra força bruta

**Arquivos:** `backend/src/app.module.ts`, `backend/src/auth/*`

Não há `@nestjs/throttler` nem `limit_req` no Nginx. `POST /auth/login`, `/auth/forget-password`, `/auth/check-token` e `/auth/reset-password`, além de `POST /users` (registro), são alvos de força bruta e enumeração sem qualquer limitação.

**Recomendação:** Adicionar `ThrottlerModule` (limites por IP/e-mail), backoff/lockout e, em produção, CAPTCHA.

---

### [ALTA] CORS totalmente aberto

**Arquivo:** `backend/src/main.ts:45`

```45:45:backend/src/main.ts
  app.enableCors();
```

Sem restrição de origem. Qualquer site pode fazer requisições à API (o impacto real depende de o token estar em header Bearer, não em cookie — mas ainda é uma má prática).

**Recomendação:** Restringir `origin` a uma allowlist; habilitar `credentials` apenas se necessário.

---

### [ALTA] `RolesGuard`/`@Roles` existem mas nunca são usados

**Arquivos:** `backend/src/guards/roles.guard.ts`, `backend/src/decorators/roles.decorator.ts`, `backend/src/auth/auth.module.ts:26`

O `RolesGuard` está implementado e exportado, mas **nenhum** controller o aplica. Endpoints sensíveis (listar todos os usuários, apagar usuários) ficam acessíveis a qualquer `CLIENT`.

**Recomendação:** Aplicar `@Roles(...)` + `RolesGuard` (ou `APP_GUARD` global) nas rotas administrativas.

---

### [ALTA] Companies sem verificação de propriedade

**Arquivo:** `backend/src/companies/companies.service.ts`

Operações CRUD de empresas não filtram por dono/membro — qualquer autenticado gerencia qualquer empresa.

**Recomendação:** Vincular owner/membros e filtrar por associação.

---

### [ALTA] JWT com validade de 90 dias e sem refresh token

**Arquivos:** `backend/src/auth/auth.module.ts:18`, `backend/src/auth/auth.service.ts:44`

O access token dura 90 dias e não há mecanismo de refresh/rotação. Um token comprometido vale ~3 meses. Cada login cria uma nova sessão sem limite.

**Recomendação:** Access token curto (ex.: 15 min) + refresh token rotativo; limitar número de sessões; invalidar sessões no reset de senha.

---

### [ALTA] Fluxo de reset de senha frágil

**Arquivo:** `backend/src/auth/auth.service.ts:135-232`

- O `expiresAt` gravado em `forgetPassword` **nunca é comparado** — o token de reset segue válido enquanto o JWT (24h) for válido.
- O token de reset não é apagado após o uso (reutilizável).
- `isValidResetToken` valida o JWT sem exigir `audience: FORGET_PASSWORD`.
- Após o reset, as sessões antigas do usuário **não são invalidadas**.

**Recomendação:** Verificar `expiresAt`; exigir audience correta; tornar o token one-time (apagar após uso); invalidar todas as sessões do usuário no reset.

---

### [ALTA] Enumeração de usuários no login e no forget-password

**Arquivo:** `backend/src/auth/auth.service.ts:91-99, 139-140`

Login distingue `"Usuário não cadastrado"` de `"Senha incorreta"`; forget-password retorna erro se o usuário não existe. Isso permite descobrir e-mails cadastrados.

**Recomendação:** Mensagens genéricas idênticas; sempre responder 200 no forget-password.

---

### [MÉDIA] WebSocket (Socket.IO) sem autenticação e CORS aberto

**Arquivo:** `backend/src/tasks/timetrack.gateway.ts:22-50`

```22:49:backend/src/tasks/timetrack.gateway.ts
@WebSocketGateway({ cors: true })
export class TimetrackGateway ... {
  @SubscribeMessage('joinTask')
  handleJoinTask(@MessageBody() payload: { taskId: string }, @ConnectedSocket() client: Socket) {
    if (payload?.taskId) {
      client.join(`task:${payload.taskId}`);
```

Não há verificação de token no handshake nem autorização no `joinTask`. Qualquer cliente conecta (CORS `true` = qualquer origem) e entra em `task:<id>` para receber eventos de timetrack de qualquer tarefa. O Nginx expõe `/socket.io/` publicamente.

**Recomendação:** Autenticar no handshake (JWT + sessão), autorizar o `join` com `canAccessProject`, e restringir o CORS do gateway.

---

### [MÉDIA] `/metrics` do Prometheus sem autenticação

**Arquivo:** `backend/src/metrics/metrics.module.ts`

O endpoint `/metrics` expõe métricas (inclui versão do Node e padrões de uso). Na stack Compose a porta 3001 não é publicada no host, mas o endpoint fica acessível na rede Docker e em `start:dev`.

**Recomendação:** Proteger `/metrics` (basic auth/mTLS) ou restringir à rede de monitoração.

---

### [MÉDIA] `ValidationPipe` sem `forbidNonWhitelisted`

**Arquivo:** `backend/src/main.ts:47-53`

`whitelist: true` remove campos extras silenciosamente, mas sem `forbidNonWhitelisted` a API não rejeita payloads com campos inesperados.

**Recomendação:** Adicionar `forbidNonWhitelisted: true` para respostas 422 explícitas.

---

### [MÉDIA] Vazamento de detalhes de erro e `console.log` de exceções

**Arquivos:** `backend/src/to-do/to-do.service.ts` (`'Falha..., Error: ' + error`), `backend/src/auth/auth.service.ts:75,105`, e `console.log(error)` em vários controllers

Mensagens ao cliente concatenam o objeto de erro; `console.log` de stacks polui o stdout e pode vazar dados internos nos logs.

**Recomendação:** Mensagens genéricas ao cliente; logging estruturado e sanitizado no servidor.

---

### [BAIXA] Custo do bcrypt em 10

**Arquivo:** `backend/src/utils/crypt.ts:4-7`, `backend/.env:16`

`CRYPT_SALT=10` — em 2026, recomenda-se ≥ 12. Combinado ao vazamento de hashes, aumenta o risco de cracking offline.

**Recomendação:** Aumentar para ≥ 12 e considerar argon2id.

---

### [BAIXA] Token de reset é um JWT, não um token opaco aleatório

Preferível gerar um token opaco (`crypto.randomBytes`) e armazenar apenas o hash no banco, evitando reutilização e reduzindo a superfície ligada ao `JWT_SECRET`.

---

### Pontos positivos (backend)

- Dupla verificação: JWT válido **e** sessão existente no banco (`AuthGuard`), permitindo logout efetivo.
- `audience`/`issuer` verificados no guard.
- SQL parametrizado (ex.: `tasks.service.ts` usa `$1, $2, $3`); sem `exec`/`spawn` em runtime.
- `whitelist: true` no `ValidationPipe`; DTOs com `class-validator` (`IsEmail`, `IsStrongPassword`).
- `role` não é exposto nos DTOs de criação/atualização de usuário (sem mass assignment de privilégio via API).
- `synchronize: false` (só migrations).
- Login/registro limpam `user.password` antes de responder (nesses fluxos específicos).

---

## 4. Frontend (Next.js)

### [ALTA] Next.js com vulnerabilidades conhecidas (incl. bypass de middleware/proxy)

**Evidência:** `npm audit --omit=dev` no `FrontEnd/`

O `next` instalado está sujeito a advisories de severidade **alta**, incluindo bypass de Middleware/Proxy (relevante porque `src/proxy.ts` implementa o guard de autenticação de rotas), DoS em Server Components/Image Optimization e cache confusion. Também aparecem `postcss` (XSS no stringify), `nanoid` e `sharp` (libvips).

**Recomendação:** Atualizar o `next` para a versão corrigida mais recente, revalidar o guard de rotas e o build.

---

### [ALTA] Token de redefinição de senha na query string (`?token=`)

**Arquivos:** `FrontEnd/src/app/reset-password/page.tsx:10-21`, `FrontEnd/src/components/auth/reset-password-form.tsx`

O token de reset trafega na URL, ficando sujeito a vazamento por histórico do navegador, cabeçalho `Referer`, logs de proxy/CDN, screenshots e extensões.

**Recomendação:** Passar o token via fragment (`#`) ou trocá-lo por um cookie httpOnly de curta duração após o landing; `Referrer-Policy` mais restritiva nessa rota.

---

### [ALTA] Socket.IO no cliente sem autenticação

**Arquivo:** `FrontEnd/src/lib/use-task-timetrack-socket.ts:44-49`

```44:49:FrontEnd/src/lib/use-task-timetrack-socket.ts
    const s = io(body.wsUrl, {
      transports: ["websocket"],
      autoConnect: true,
    });
    socket = s;
    s.emit("joinTask", { taskId });
```

O cliente não envia JWT no handshake (`auth`/`extraHeaders`). Combinado com o gateway sem auth no backend, é uma falha ponta a ponta.

**Recomendação:** Enviar token de curta duração no handshake e autorizar o room no servidor.

---

### [ALTA] Sessão (cookie) de 90 dias sem rotação

**Arquivo:** `FrontEnd/src/lib/session.ts:10-11`

O cookie `th_session` tem `maxAge` de 90 dias, alinhado ao JWT longo do backend. Cookie roubado permanece válido por meses.

**Recomendação:** Reduzir para 1–7 dias; alinhar com refresh token rotativo no backend.

---

### [MÉDIA] Ausência de Content-Security-Policy

**Arquivo:** `FrontEnd/next.config.ts:3-42`

Há `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy` e `Permissions-Policy`, mas **não** há CSP. HSTS está desligado por padrão (`ENABLE_HSTS=false`, apropriado só enquanto for HTTP na LAN).

**Recomendação:** Adicionar CSP restritiva (`default-src 'self'`, `connect-src` para BFF/WS); habilitar HSTS quando houver HTTPS.

---

### [MÉDIA] Proxy BFF genérico encaminha ampla superfície da API

**Arquivo:** `FrontEnd/src/app/api/bff/[...path]/route.ts:14-73`

O proxy valida o path (`PATH_SAFE`, bloqueia `..`) e bloqueia login/logout/reset — bom. Porém encaminha qualquer outro caminho ao backend anexando o Bearer do cookie, sem allowlist de recursos nem rate limiting. Isso amplifica os IDORs do backend, pois expõe toda a API via `/api/bff/*`.

**Recomendação:** Restringir a uma allowlist de prefixos (`projects`, `tasks`, `to-do`, ...); aplicar rate limiting.

---

### [MÉDIA] `/api/auth/me` confia no payload do JWT sem verificar assinatura

**Arquivos:** `FrontEnd/src/lib/session.ts:43-81`, `FrontEnd/src/app/api/auth/me/route.ts`

O `decodeSessionUser` decodifica o payload do JWT sem validar a assinatura para montar a UI (role, nome). Como o cookie é httpOnly e só gravado pelo BFF, o risco prático é limitado — mas um cookie forjado poderia induzir a UI a exibir controles de admin (o backend ainda rejeitaria as chamadas se a validação server-side estiver correta).

**Recomendação:** Validar a assinatura no BFF ou obter o usuário via endpoint autenticado do backend.

---

### [MÉDIA] `/api/runtime` deriva a URL do WebSocket de headers do cliente

**Arquivo:** `FrontEnd/src/app/api/runtime/route.ts:10-24`

A `wsUrl` é derivada de `X-Forwarded-Host`/`Host`. Se um proxy confiar em headers controláveis pelo cliente, a URL do WebSocket pode ser apontada para um host malicioso.

**Recomendação:** Preferir `PUBLIC_WS_URL` fixo; não confiar em `X-Forwarded-Host` sem allowlist.

---

### [MÉDIA] Autorização apenas na UI (`canManage*`)

**Arquivos:** `FrontEnd/src/lib/projects-api.ts`, `tasks-api.ts`, `subtasks-api.ts`, `timetrack-api.ts`

As funções `canManageProject`/`canMoveOrRemoveTask`/etc. apenas escondem controles na interface. Como o backend tem IDORs, um usuário pode chamar `/api/bff/...` diretamente e contornar essas verificações.

**Recomendação:** Backend como fonte da verdade (corrigir os IDORs); tratar a UI como cosmética.

---

### [BAIXA] Comentário parecido com credencial no `.env` do frontend

**Arquivo:** `FrontEnd/.env` (última linha, `# p-7#7Jb=?94AB7RZ`)

O arquivo não está no Git, mas a string parece uma senha. Se for real, remover e rotacionar.

---

### [BAIXA] Cookie `Secure` desligável em HTTP

**Arquivo:** `FrontEnd/src/lib/session.ts:14-19`

Em HTTP doméstico (`SESSION_COOKIE_SECURE=false`), o cookie de sessão pode trafegar em claro (MITM na LAN).

**Recomendação:** HTTPS + `Secure=true` em qualquer ambiente exposto além da LAN de confiança.

---

### [BAIXA] `console.error` em error boundaries e senha de teste no repositório

`FrontEnd/src/app/error.tsx` e afins logam o erro no console (possível vazamento em DevTools). `tests/e2e/smoke.spec.ts` contém uma senha de teste — aceitável por ser apenas de teste, mas vale destacar.

---

### Pontos positivos (frontend)

- **Padrão BFF sólido**: JWT em cookie `httpOnly`, `sameSite=lax`; o token nunca é exposto ao JavaScript (não há `localStorage`/`sessionStorage` de token).
- Login/logout/reset têm route handlers dedicados e são bloqueados no proxy genérico, evitando vazamento do token.
- Path do BFF sanitizado (`PATH_SAFE`, bloqueio de `..`).
- Mitigação de open redirect em `?next=` (`safeNextPath`), com testes.
- Sem `dangerouslySetInnerHTML`/`innerHTML`/markdown renderer — XSS de DOM tradicional ausente (escape padrão do React).
- Sem segredos em variáveis `NEXT_PUBLIC_*`; `BACKEND_API_BASE_URL` é server-only.
- Cabeçalhos básicos de segurança em `next.config.ts`.

---

## 5. Dependências vulneráveis

### Backend — `npm audit --omit=dev`: 26 vulnerabilidades (2 críticas, 16 altas, 6 moderadas, 2 baixas)

Destaques:

| Severidade | Pacote | Problema |
|------------|--------|----------|
| Crítica | `tar` (via `@mapbox/node-pre-gyp`) | Arbitrary file creation/overwrite via hardlink path traversal |
| Crítica | `sha.js` | Falta de checagem de tipo (hash rewind) |
| Alta | `typeorm` | SQL injection via `repository.save`/`update` com request forjada |
| Alta | `@nestjs/core` | Neutralização imprópria de elementos especiais (injection) |
| Alta | `ws` / `socket.io-parser` / `engine.io` | Divulgação de memória, DoS, attachments ilimitados |
| Alta | `jws` | Verificação imprópria de assinatura HMAC |
| Alta | `lodash` | Code injection via `_.template` |
| Alta | `js-yaml` (via `@nestjs/swagger`) | Prototype pollution no merge |
| Alta | `validator` | Bypass de validação de URL |
| Alta | `path-to-regexp`, `minimatch`, `brace-expansion` | ReDoS |
| Moderada | `@nestjs/common` | RCE via header Content-Type |

### Frontend — `npm audit --omit=dev`: 4 vulnerabilidades altas

| Severidade | Pacote | Problema |
|------------|--------|----------|
| Alta | `next` | DoS com Server Components / (advisories de middleware/proxy) |
| Alta | `postcss` | XSS via `</style>` não escapado no stringify |
| Alta | `nanoid` | Loop infinito com tamanho zero |
| Alta | `sharp` | Vulnerabilidades herdadas do libvips |

**Recomendação:** Rodar `npm audit fix` em ambos, priorizando `typeorm`, `@nestjs/*`, `ws`/`socket.io*` e `next`. Fixar versões (evitar `"*"` em `@nestjs/mapped-types`), remover dependências não usadas (`zod` no backend) e adotar Dependabot/renovate.

---

## 6. Plano de ação priorizado

### Imediato (crítico)
1. Rotacionar todos os segredos do `.env` (DB, `JWT_SECRET`, admin seed, Grafana), com valores fortes e distintos por papel.
2. Marcar `password` como `select: false` e sanitizar todas as respostas que retornam entidades `User`.
3. Corrigir os IDORs: filtrar por dono/participante em users, to-dos, projetos (GET), stages, tasks (GET), subtasks e companies.
4. Fechar o Swagger/`api-json` (senha forte ou desabilitar em produção).

### Curto prazo (alto)
5. Adicionar rate limiting (`@nestjs/throttler` + `limit_req` no Nginx) em login/reset/registro.
6. Restringir CORS (backend e gateway WebSocket) a origens conhecidas.
7. Autenticar o WebSocket no handshake e autorizar os rooms.
8. Reduzir o TTL do JWT/cookie e introduzir refresh token rotativo; invalidar sessões no reset de senha.
9. Corrigir o fluxo de reset (expiração, one-time, audience).
10. Atualizar dependências (`npm audit fix`), com foco em `next`, `typeorm`, `@nestjs/*`, `ws`.
11. Tirar o token de reset da query string.

### Médio prazo
12. Adicionar Helmet no backend e CSP/HSTS no frontend/Nginx.
13. Aplicar `RolesGuard`/`@Roles` nas rotas administrativas.
14. `forbidNonWhitelisted: true`; aumentar bcrypt para ≥ 12.
15. Restringir a superfície do proxy BFF (allowlist); validar `Origin` nas rotas mutantes.
16. Proteger `/metrics`; remover `console.log`/`console.error` de dados sensíveis.
17. Não publicar a porta do Postgres na LAN; reduzir privilégios do usuário remoto.

---

## 7. Observações finais

A base do projeto demonstra boas intenções de segurança (BFF com cookie httpOnly, sessão em banco, validação de DTOs, SQL parametrizado). O problema dominante é **controle de acesso**: a autenticação está resolvida, mas a **autorização por recurso** foi implementada de forma inconsistente — presente em algumas mutações de projetos/tasks, ausente em leituras e em módulos inteiros (users, to-dos, companies). Corrigir os IDORs e parar o vazamento de hashes de senha deve ser a prioridade absoluta, seguido da rotação dos segredos expostos.

Nenhum arquivo do projeto foi modificado durante esta auditoria.
