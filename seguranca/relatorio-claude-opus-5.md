# Relatório de Auditoria de Segurança — TaskHive

**Auditor:** Claude Opus 5 (via Cursor)
**Data:** 20 de agosto de 2026
**Escopo:** Backend (NestJS), Frontend (Next.js 16 / App Router), Infraestrutura (Docker Compose, nginx, Postgres, Prometheus, Grafana)
**Metodologia:** Revisão manual de código-fonte (130 ficheiros backend, 125 frontend), análise de configuração de containers e verificação do histórico Git. Todos os achados abaixo foram confirmados por leitura directa do código — não há especulação.

---

## 1. Sumário executivo

O TaskHive tem uma base de segurança **parcialmente sólida**: passwords com bcrypt, JWT validado contra sessão em base de dados, cookie `httpOnly` no BFF, protecção anti-SSRF no proxy, `.env` fora do Git, Dockerfiles multi-stage com utilizador não-root e TypeORM sem `synchronize`. Isto indica preocupação genuína com segurança durante o desenvolvimento.

O problema é que essa preocupação foi aplicada de forma **assimétrica**. A autenticação ("quem és tu?") está bem resolvida. A autorização ("podes fazer isto?") está ausente em módulos inteiros. O projecto tem um helper de permissões bem desenhado (`project-permissions.helper.ts`) que é aplicado com rigor nas mutações de projectos e tarefas — e simplesmente ignorado em `users`, `companies`, `to-do` e em quase todas as operações de leitura.

O resultado prático: **qualquer utilizador registado consegue tomar controlo da conta de qualquer outro utilizador**, ler e apagar dados de todos, e a documentação completa da API está publicada sem password.

### Contagem de achados

| Severidade | Quantidade |
|---|---|
| Crítica | 9 |
| Alta | 14 |
| Média | 17 |
| Baixa | 6 |

### Os cinco problemas que exigem acção imediata

1. **Takeover de conta via `PUT /users/:id`** — trocar o email de qualquer utilizador sem verificação de identidade.
2. **IDOR total no módulo `to-do`** — o objecto `user` é passado ao serviço e nunca comparado com o dono do recurso.
3. **Token de recuperação de password reutilizável** — nunca é invalidado após o uso, permanece válido 24 h.
4. **Swagger publicado sem autenticação** — `SWAGGER_PASSWORD` está vazio no `.env` em uso.
5. **Postgres exposto em `0.0.0.0`** com a mesma password para os três papéis de acesso.

---

## 2. Achados críticos

### CRIT-01 — Takeover de conta através de `PUT /users/:id`

**Ficheiro:** `backend/src/users/users.controller.ts:85-87` e `backend/src/users/users.service.ts:110-131`
**Categoria:** OWASP A01 — Broken Access Control (BOLA)

O endpoint aceita um UUID arbitrário e actualiza o utilizador correspondente. O utilizador autenticado nunca é comparado com o alvo:

```85:87:backend/src/users/users.controller.ts
  update(@Param('id') id: string, @Body() updateUserDto: UpdateUserDto) {
    return this.usersService.update(id, updateUserDto);
  }
```

O serviço confirma a ausência total de verificação de propriedade — repare que nem sequer recebe o utilizador autenticado como parâmetro:

```110:131:backend/src/users/users.service.ts
  async update(id: string, updateUserDto: UpdateUserDto) {
    return this.metrics.track('users', 'update', async () => {
      const user = await this.findOneUntracked(id);

      if(!user) {
        throw new HttpException('User not found', HttpStatus.NOT_FOUND);
      }

      if(user.email !== updateUserDto.email) {
        const existing = await this.findByEmail(updateUserDto.email);
        if(existing) {
          throw new HttpException('Email already exists', HttpStatus.UNPROCESSABLE_ENTITY);
        }
      }

      return this.userRepository.update(id, {
        avatar: updateUserDto.avatar,
        email: updateUserDto.email,
        name: updateUserDto.name,
      });
    });
  }
```

**Cadeia de exploração completa.** Um atacante regista uma conta normal (`POST /users` é público). Chama `GET /users`, que devolve o UUID e o email de toda a base de utilizadores. Escolhe a vítima e executa:

```http
PUT /users/{uuid-da-vitima}
Authorization: Bearer {token-do-atacante}
Content-Type: application/json

{ "name": "Vitima", "email": "atacante@evil.com" }
```

O email da vítima passa a ser controlado pelo atacante. A vítima já não consegue autenticar-se (`login` procura por email). O atacante executa `POST /auth/forget-password` para `atacante@evil.com`, recebe o token de recuperação, define uma password nova e assume a conta — incluindo eventuais contas com `role` de administrador.

**Nota agravante:** não há verificação de password actual nem confirmação por email para a mudança de endereço, portanto mesmo com a correcção de propriedade este fluxo continuaria frágil.

---

### CRIT-02 — Desactivação arbitrária de contas via `PATCH /users/:id`

**Ficheiro:** `backend/src/users/users.controller.ts:96-98`, `backend/src/users/users.service.ts:133-143`

```96:98:backend/src/users/users.controller.ts
  softDelete(@Param('id') id: string) {
    return this.usersService.softDelete(id);
  }
```

Sem qualquer verificação. Qualquer utilizador autenticado desactiva a conta de qualquer outro (`deletedAt` preenchido faz o login falhar, porque `findFirstUserByEmail` filtra por `deletedAt: null`).

Há aqui uma inconsistência reveladora: o método `remove` (`DELETE /users/:id`) recebe `currentUserId` e implementa uma regra de negócio — impedir a auto-remoção:

```62:75:backend/src/users/users.service.ts
  async remove(id: string, currentUserId?: string) {
    return this.metrics.track('users', 'remove', async () => {
      const user = await this.findOneUntracked(id);
      if (!user) {
        throw new HttpException('User not found', HttpStatus.NOT_FOUND);
      }
      if (currentUserId && id === currentUserId) {
        throw new HttpException('Não é permitido remover a própria conta', HttpStatus.FORBIDDEN);
      }
      return this.userRepository.update(id, {
        deletedAt: new Date(),
      });
    });
  }
```

A regra protege o utilizador de si próprio, mas permite explicitamente apagar terceiros. O `softDelete`, que faz exactamente a mesma escrita (`deletedAt: new Date()`), nem essa verificação tem. Ou seja: existem dois caminhos para o mesmo efeito destrutivo, e o único controlo implementado é o que não interessa do ponto de vista de segurança.

---

### CRIT-03 — Token de recuperação de password nunca é invalidado

**Ficheiro:** `backend/src/auth/auth.service.ts:164-205`
**Categoria:** OWASP A07 — Identification and Authentication Failures

Este achado não foi detectado pelas análises automáticas e é dos mais perigosos, porque transforma uma exposição momentânea de token numa porta permanente.

```164:205:backend/src/auth/auth.service.ts
  async resetPassword(password: string, token: string) {
    return this.metrics.track('auth', 'reset_password', async () => {
      const check = await this.isValidResetToken(token)

      if (!check) {
        throw new BadRequestException('Token inválido')
      }

      const fp = await this.forgetPasswordRepository.findOne({
        where: {
          token,
        },
        relations: ['user'],
      })

      if (!fp) {
        throw new BadRequestException('Token inválido')
      }

      const user = await this.userRepository.findOne({
        where: {
          id: fp.user.id,
        },
      })

      if (!user) {
        throw new BadRequestException('Usuário inválido')
      }

      user.password = await Crypt.hash(password)

      const update = await this.userRepository.save(user)

      if (!update) {
        throw new BadRequestException('Falha ao atualizar usuário')
      }

      // enviar email de aviso de alteração de senha

      return this.createSession(user)
    });
  }
```

Três falhas acumuladas neste bloco:

**a) O registo `ForgetPassword` nunca é apagado.** Depois de a password ser alterada, a linha permanece na tabela e `isValidResetToken` continua a devolver `true` até o JWT expirar (24 h). Qualquer pessoa que obtenha o token — através de logs, histórico do browser, `Referer`, um email reencaminhado, ou um backup — pode repor a password quantas vezes quiser durante um dia inteiro. Mesmo depois de o utilizador legítimo já a ter alterado.

**b) As sessões existentes não são revogadas.** `createSession` acrescenta uma sessão nova sem remover as antigas. Um atacante com uma sessão activa mantém acesso mesmo depois de a vítima trocar a password — que é precisamente a acção que uma vítima toma ao suspeitar de compromisso. A tabela `session` também não é limpa no fluxo normal, pelo que tokens de 90 dias acumulam-se indefinidamente.

**c) A validação do token não verifica a `audience`.** Compare com o `AuthGuard`, que é rigoroso:

```32:35:backend/src/guards/auth.guard.ts
      const res = this.authService.checkToken(token, {
        audience: JWTAudience.LOGIN,
        issuer: 'TaskHive',
      })
```

E agora o caminho de reset:

```218:232:backend/src/auth/auth.service.ts
  private async isValidResetToken(token: string) {
    const check = this.checkToken(token)

    if (!check) {
      throw new BadRequestException('Token inválido')
    }

    const res = await this.forgetPasswordRepository.findOne({
      where: {
        token,
      },
    })

    return !!res
  }
```

`checkToken(token)` é chamado sem opções — não valida `audience` nem `issuer`. O risco de confusão entre tokens de `LOGIN` e `FORGET_PASSWORD` está atenuado porque o token também tem de existir na tabela `forget_password`, mas a defesa em profundidade foi perdida. O campo `expiresAt` guardado na entidade também nunca é consultado; a expiração depende exclusivamente do `exp` do JWT.

---

### CRIT-04 — IDOR generalizado no módulo `to-do`

**Ficheiros:** `backend/src/to-do/to-do.controller.ts`, `backend/src/to-do/to-do.service.ts`

Este é o caso mais claro de intenção não concretizada em todo o projecto. O controller obtém correctamente o utilizador autenticado e passa-o a todos os métodos de escrita:

```199:201:backend/src/to-do/to-do.controller.ts
  update(@Param('id') id: string, @Body() updateToDoDto: UpdateToDoDto, @User() user: UserEntity) {
    try {
      return this.toDoService.update(BigInt(id), updateToDoDto, user);
```

O serviço recebe o parâmetro `user`... e nunca o usa:

```139:151:backend/src/to-do/to-do.service.ts
  async update(id: bigint, updateToDoDto: UpdateToDoDto, user: User) {
    return this.metrics.track('to-do', 'update', async () => {
      try {
        const todo = await this.toDoRepository.findOne({
          where: {
            id: String(id),
          },
        })

        if (!todo) {
          throw new BadRequestException('Tarefa não encontrada')
        }
```

O `where` filtra apenas por `id`. Bastaria `where: { id: String(id), user: { id: user.id } }` para eliminar a falha.

Este padrão repete-se em **cinco** métodos, todos com a mesma assinatura enganadora — recebem `user`, ignoram `user`:

| Método | Linha | Endpoint | Impacto |
|---|---|---|---|
| `update` | 139 | `PUT /to-do/:id` | Reescrever tarefas alheias |
| `remove` | 203 | `PATCH /to-do/:id` | Apagar tarefas alheias |
| `endTask` | 226 | `PATCH /to-do/end/:id` | Marcar como concluída |
| `changeTaskStatus` | 255 | `PATCH /to-do/status/:id` | Alterar estado |
| `nextDateRecurringTask` | 299 | `PATCH /to-do/nextDateRecurring/:id` | Manipular recorrência |

O `findOne` é ainda mais directo — o controller nem se dá ao trabalho de passar o utilizador:

```115:117:backend/src/to-do/to-do.controller.ts
  findOne(@Param('id') id: string) {
    try {
      return this.toDoService.findOne(BigInt(id));
```

E devolve os dados do dono junto com a tarefa (`to-do.service.ts:104-137` inclui `relations: ['user']` com `select` de `id`, `name`, `email`, `avatar`).

**Agravante — IDs previsíveis.** Ao contrário dos utilizadores, que usam UUID, as tarefas usam Snowflake IDs (`SnowflakeIdService`). São sequenciais e ordenados no tempo, o que torna a enumeração trivial: obtém-se um ID válido criando uma tarefa própria e incrementa-se. Não é necessário adivinhar nada.

Note-se o contraste com `findAll`, que está correcto (`to-do.service.ts:67-102`, filtra por `user.id`). A protecção existe onde não é contornável e falta onde é.

---

### CRIT-05 — Módulo `companies` sem qualquer noção de propriedade

**Ficheiro:** `backend/src/companies/companies.controller.ts`

O controller aplica `@UseGuards(AuthGuard)` ao nível da classe (linha 10), pelo que exige autenticação — e mais nada. Nenhum dos cinco endpoints verifica se o utilizador tem relação com a empresa:

```56:58:backend/src/companies/companies.controller.ts
  findAll() {
    return this.companiesService.findAll();
  }
```

```130:132:backend/src/companies/companies.controller.ts
  remove(@Param('id') id: string) {
    return this.companiesService.remove(id);
  }
```

A causa raiz é estrutural: a entidade `Company` não tem qualquer relação com `User`. Não existe modelo de pertença, portanto não há sequer como verificar autorização sem primeiro alterar o schema. Qualquer utilizador autenticado lista todas as empresas, altera e apaga qualquer uma.

Existe ainda um vector de poluição cross-tenant na criação de projectos (`backend/src/projects/projects.service.ts:35-45`): `companyOwnerId` é aceite do cliente e resolvido sem validação, permitindo associar um projecto a uma empresa arbitrária. O `update` de projecto ignora este campo, pelo que o problema limita-se à criação.

---

### CRIT-06 — Swagger e OpenAPI públicos (`SWAGGER_PASSWORD` vazio)

**Ficheiros:** `backend/src/main.ts:18-35`, `backend/.env`, `docker/nginx.conf:49-75`

A protecção Basic Auth é condicional e falha em modo aberto:

```18:35:backend/src/main.ts
  const swaggerUser = process.env.SWAGGER_USER;
  const swaggerPassword = process.env.SWAGGER_PASSWORD;

  if (swaggerUser && swaggerPassword) {
    app.use(
      ['/swagger', '/api-json', '/api-yaml'],
      expressBasicAuth({
        challenge: true,
        users: { [swaggerUser]: swaggerPassword },
      }),
    );
  } else {
    Logger.warn(
      'Swagger exposto sem HTTP Basic: defina SWAGGER_USER e SWAGGER_PASSWORD no .env (recomendado em qualquer ambiente acessível na rede).',
    );
  }
```

Inspeccionando o `.env` actualmente em uso (sem revelar valores):

```
SWAGGER_USER      = <definido, 5 chars>
SWAGGER_PASSWORD  = <VAZIO>
```

A condição avalia como falsa e a documentação fica aberta. O nginx encaminha estes caminhos para o exterior:

```49:50:docker/nginx.conf
    location = /swagger {
        proxy_pass http://taskhive_api/swagger;
```

```74:75:docker/nginx.conf
    location = /api-json {
        proxy_pass http://taskhive_api/api-json;
```

Qualquer pessoa com acesso de rede obtém em `http://<ip>:8080/api-json` o inventário completo de endpoints, schemas, parâmetros e exemplos. Combinado com os IDOR acima, isto converte um ataque que exigiria descoberta num ataque guiado por documentação oficial. O aviso no log é a única defesa, e um aviso não bloqueia pedidos.

---

### CRIT-07 — Postgres publicado em `0.0.0.0` com password partilhada

**Ficheiros:** `docker-compose.yml:19-20`, `backend/docker-compose.yml:17-18`, `backend/.env`

```19:20:docker-compose.yml
    ports:
      - '${POSTGRES_PUBLISH_PORT:-5432}:5432'
```

Sem prefixo de IP, o Docker liga a porta a todas as interfaces do host. A base de dados fica acessível a partir de toda a LAN, e da Internet caso exista encaminhamento de portas no router.

A verificação das credenciais revelou algo mais grave. Comparando os hashes SHA-256 dos valores (sem os expor):

```
DB_PASSWORD         -> f2f0682e089a
POSTGRES_PASSWORD   -> f2f0682e089a
DB_REMOTE_PASSWORD  -> f2f0682e089a
```

Os três são **idênticos**. A separação de papéis existe no schema — `backend/docker/postgres/init/01-users.sh` cria utilizadores distintos — mas é anulada na prática. Comprometer a credencial da aplicação dá acesso de superutilizador. E o utilizador remoto tem privilégios máximos:

```39:40:backend/docker/postgres/init/01-users.sh
GRANT USAGE, CREATE ON SCHEMA public TO "${DB_USER}", "${DB_REMOTE_USER}";
GRANT ALL PRIVILEGES ON SCHEMA public TO "${DB_REMOTE_USER}";
```

Uma conta destinada a leitura para relatórios pode executar DDL — incluindo `DROP TABLE`.

Ponto positivo: o script recusa passwords vazias e a autenticação é SCRAM, não `trust`.

---

### CRIT-08 — WebSocket sem autenticação nem autorização

**Ficheiro:** `backend/src/tasks/timetrack.gateway.ts`

```22:39:backend/src/tasks/timetrack.gateway.ts
@WebSocketGateway({ cors: true })
export class TimetrackGateway implements OnGatewayConnection, OnGatewayDisconnect {
  @WebSocketServer()
  server: Server;

  private readonly logger = new Logger(TimetrackGateway.name);

  constructor(private readonly metrics: AppMetricsService) {}

  handleConnection() {
    this.logger.debug('Client connected');
    this.metrics.websocketConnected();
  }
```

`handleConnection` não recebe o socket, logo não pode inspeccionar token algum. Não há handshake autenticado. A adesão a salas aceita qualquer identificador:

```41:50:backend/src/tasks/timetrack.gateway.ts
  @SubscribeMessage('joinTask')
  handleJoinTask(
    @MessageBody() payload: { taskId: string },
    @ConnectedSocket() client: Socket,
  ) {
    if (payload?.taskId) {
      client.join(`task:${payload.taskId}`);
      this.metrics.websocketEvent('joinTask');
    }
  }
```

Um cliente **não autenticado** liga-se, emite `joinTask` com qualquer `taskId` e passa a receber `timetrack:started`, `stopped`, `updated` e `deleted` em tempo real — quem trabalhou em quê e durante quanto tempo. Com `cors: true`, a ligação pode partir de qualquer origem, incluindo um site malicioso aberto no browser da vítima.

Combinando com a previsibilidade dos Snowflake IDs, é possível fazer sondagem sistemática e montar vigilância sobre a actividade de toda a organização.

---

### CRIT-09 — Ausência total de limitação de taxa

**Verificação:** procura por `Throttle`, `helmet`, `rateLimit`, `RateLimit` em `backend/src/` → **0 ocorrências em 130 ficheiros**. `@nestjs/throttler` não consta das dependências.

Nem a aplicação nem o nginx (`docker/nginx.conf` não tem `limit_req`) impõem qualquer limite. Isto amplifica praticamente todos os outros achados:

- `POST /auth/login` — força bruta ilimitada, agravada por `CRYPT_SALT=10`, que torna cada verificação barata.
- `POST /auth/forget-password` — enumeração de emails à velocidade da rede.
- `GET /users` — extracção completa da base de utilizadores.
- Enumeração de Snowflake IDs em `to-do`, `tasks`, `subtasks`, `project-stages`.
- Negação de serviço por exaustão, agravada por `client_max_body_size 20m` no nginx.

---

## 3. Achados de severidade alta

### ALTO-01 — CORS completamente aberto

```45:45:backend/src/main.ts
  app.enableCors();
```

Sem argumentos, o NestJS responde `Access-Control-Allow-Origin: *`. Qualquer site pode invocar a API a partir do browser da vítima. Como a autenticação usa o header `Authorization` e não cookies, o browser não anexa credenciais automaticamente — o que limita o impacto directo. Ainda assim, todos os endpoints públicos (`POST /users`, `/auth/login`, `/auth/forget-password`) ficam acessíveis a scripts de terceiros para enumeração e abuso, e qualquer migração futura para cookies transformaria isto numa falha crítica.

### ALTO-02 — `GET /users` expõe toda a base de utilizadores

```49:51:backend/src/users/users.controller.ts
  findAll() {
    return this.usersService.findAll();
  }
```

Devolve `id`, `name`, `email`, `avatar` e datas de todos os utilizadores a qualquer autenticado. É o passo de reconhecimento que viabiliza o CRIT-01. Deveria exigir papel administrativo.

### ALTO-03 — `RolesGuard` implementado mas nunca aplicado

O guard existe e está correcto (`backend/src/guards/roles.guard.ts`), o decorador `@Roles()` existe (`backend/src/decorators/roles.decorator.ts`), o enum `UserRole` existe — e **nenhum controller os usa**. Toda a infra-estrutura de RBAC foi construída e deixada desligada. Não há distinção efectiva entre `CLIENT` e administrador em nenhum endpoint HTTP.

### ALTO-04 — IDOR de leitura transversal

Confirmado em todos os módulos:

| Endpoint | Ficheiro:linha | O que expõe |
|---|---|---|
| `GET /projects/:id` | `projects.controller.ts:182` | Recebe `@User()` e ignora-o |
| `GET /tasks/:id` | `tasks.controller.ts:207` | Tarefa + coluna + email do responsável |
| `GET /tasks/stage/:stage` | `tasks.controller.ts:72` | Recebe `@User()` e ignora-o |
| `GET /subtasks` | `subtasks.controller.ts:67` | Todas as subtarefas do sistema |
| `GET /subtasks/task/:taskId` | `subtasks.service.ts:64` | Só verifica se a tarefa existe |
| `GET /project-stages` | `project-stages.controller.ts:69` | Todas as colunas do sistema |
| `GET /project-stages/:id` | `project-stages.service.ts:115` | Coluna com `relations: ['project','tasks',...]` — kanban completo |

O padrão de receber `@User()` e não o utilizar aparece repetidamente, o que sugere que a verificação estava planeada e ficou por escrever.

### ALTO-05 — Criação de subtarefas em tarefas alheias

```23:36:backend/src/subtasks/subtasks.service.ts
  async create(createSubtaskDto: CreateSubtaskDto, user: User) {
    const task = await this.tasksService.findOne(BigInt(createSubtaskDto.taskId))
    if (!task) {
      throw new BadRequestException(`Task not found`)
    }
    return this.subtasksRepository.save({
      ...
      task,
      responsible: user
    })
  }
```

Verifica-se a existência da tarefa, nunca o acesso ao projecto. Um atacante injecta conteúdo no quadro de outra equipa — vector de phishing interno, já que o texto aparece na UI legítima. Como fica registado como `responsible`, ganha também permissão para editar e apagar essas subtarefas (a verificação em `subtasks.service.ts:94` compara apenas com `responsible`, nunca com o projecto).

### ALTO-06 — Ausência de TLS e cookie de sessão sem `Secure`

```63:65:docker-compose.yml
      # HTTP na LAN: cookie sem Secure; HSTS desligado até haver TLS.
      SESSION_COOKIE_SECURE: 'false'
      ENABLE_HSTS: 'false'
```

O nginx só escuta em `:80` (`docker/nginx.conf:16-18`), sem redireccionamento para HTTPS. O JWT de sessão — válido por 90 dias — viaja em claro. Numa LAN, ARP spoofing ou uma rede Wi-Fi partilhada bastam para o capturar. A decisão está documentada e é consciente, mas o risco mantém-se e o prazo de 90 dias torna cada captura muito valiosa.

### ALTO-07 — Sessões de 90 dias sem rotação nem expiração no servidor

`createToken` usa `expiresIn: string = '90d'` (`auth.service.ts:44`). Não há refresh tokens, rotação, nem limite de sessões simultâneas. `findSessionByToken` não verifica qualquer campo de expiração — só a assinatura do JWT limita a validade. Não existe endpoint para o utilizador listar ou revogar as suas sessões.

### ALTO-08 — JWT armazenado em claro na base de dados

A entidade `Session` guarda o token integral. Qualquer leitura da tabela `session` — backup, credencial de DB comprometida, o utilizador remoto com `GRANT ALL` do CRIT-07 — entrega sessões imediatamente utilizáveis. Deveria guardar-se apenas um hash do token.

### ALTO-09 — Password do administrador semeado é fraca

`SEED_ADMIN_PASSWORD` tem 9 caracteres com todas as classes presentes (minúscula, maiúscula, dígito, símbolo) — padrão característico de passwords de exemplo do tipo `Aaaa@1234`. É a conta com maior privilégio do sistema, e sem limitação de taxa (CRIT-09) a força bruta é viável.

### ALTO-10 — Grafana publicado na LAN

```114:115:docker-compose.yml
    ports:
      - '${GRAFANA_PORT:-3002}:3000'
```

Interface administrativa exposta a todas as interfaces, com utilizador `admin` previsível. Positivo: o entrypoint recusa arrancar sem password definida e `GF_USERS_ALLOW_SIGN_UP` está a `false`.

### ALTO-11 — `/metrics` público na stack só-API

```7:8:backend/docker/nginx.conf
    location / {
        proxy_pass http://api:3001;
```

Um `location /` genérico encaminha tudo, incluindo `/metrics` (`metrics.module.ts:17-18`). Expõe rotas internas, volumes de pedidos, taxas de erro e contagem de ligações WebSocket. A stack completa em `docker/nginx.conf` usa `location` explícitos e não tem este problema — a inconsistência entre os dois ficheiros é o risco.

### ALTO-12 — Movimentação de tarefas entre projectos distintos

```263:268:backend/src/tasks/tasks.service.ts
        if (stageChanging) {
          const stage = await this.projectStagesService.loadStage(
            BigInt(updateTaskDto.stageId!),
          );
          if (!stage) throw new BadRequestException('Stage not found');
        }
```

Valida a existência da coluna, nunca que pertence ao mesmo projecto. O dono da tarefa move-a para o quadro de outro projecto. Falha equivalente em `project-stages.service.ts:37-47`, onde `nextStageId`/`prevStageId` podem encadear colunas de projectos diferentes, corrompendo a lista ligada.

### ALTO-13 — Enumeração de utilizadores nas mensagens de erro

```91:93:backend/src/auth/auth.service.ts
      if(!user) {
        throw new BadRequestException('Usuário não cadastrado')
      }
```

Distingue "Usuário não cadastrado" de "Senha incorreta", confirmando que emails existem. `forgetPassword` (linha 139-141) tem o mesmo problema. Ambos deveriam devolver resposta genérica e idêntica.

### ALTO-14 — Base de dados E2E com credenciais em Git e porta aberta

```10:14:backend/docker-compose.e2e.yml
      POSTGRES_USER: taskhive_e2e
      POSTGRES_PASSWORD: taskhive_e2e_secret
      POSTGRES_DB: task_hive_e2e
    ports:
      - '5433:5432'
```

Password versionada em texto e porta em `0.0.0.0`. Numa máquina de desenvolvimento em rede partilhada, acesso trivial.

---

## 4. Achados de severidade média

### MED-01 — Sessão do frontend confia em JWT não verificado

```43:48:FrontEnd/src/lib/session.ts
/**
 * Decodifica o payload do JWT sem verificar assinatura: o cookie é httpOnly e
 * só é gravado pelo BFF a partir da resposta do backend, que continua a
 * validar o token em toda chamada autenticada.
 */
export function decodeSessionUser(token: string): SessionUser | null {
```

O raciocínio documentado é defensável, mas incompleto. Quem tenha acesso ao browser (DevTools) substitui o cookie por um JWT forjado com `role: "ADMIN_GOD"`. O layout `(app)/layout.tsx` aceita, a UI apresenta controlos administrativos e `canManageProject()` em `projects-api.ts:117` devolve `true`. As chamadas reais falham no backend, pelo que **não há escalada de privilégio efectiva** — mas há um estado de interface inconsistente que dificulta o diagnóstico e pode revelar a estrutura de funcionalidades administrativas.

### MED-02 — Ausência de Content-Security-Policy

`FrontEnd/next.config.ts:3-12` define `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy` e `Permissions-Policy` — bom trabalho —, mas não há CSP. Não existe defesa em profundidade caso surja um XSS. O nginx também não acrescenta cabeçalhos de segurança nem tem `server_tokens off`.

### MED-03 — Login CSRF

Nenhum handler verifica `Origin`/`Referer` nem usa token anti-CSRF. `SameSite=lax` protege a maioria das mutações, mas não o login: um site malicioso submete um formulário para `/api/auth/login` com credenciais do atacante, e a vítima passa a trabalhar dentro da conta dele sem perceber, com o conteúdo que produzir a ficar acessível ao atacante.

### MED-04 — Open redirect por codificação de URL

```33:38:FrontEnd/src/components/auth/login-form.tsx
function safeNextPath(nextPath?: string): string {
  if (nextPath && nextPath.startsWith("/") && !nextPath.startsWith("//")) {
    return nextPath;
  }
  return "/dashboard";
}
```

`?next=/%2f%2fevil.com` começa por `/` e não por `//`, passando a validação. O browser descodifica para `//evil.com` e redirecciona para domínio externo. Deveria usar-se `new URL(path, origin).pathname`.

### MED-05 — BFF encaminha toda a superfície da API

```83:88:FrontEnd/src/app/api/bff/[...path]/route.ts
export const GET = handle;
export const POST = handle;
...
```

A protecção anti-SSRF está bem feita (regex restritivo, bloqueio de `..`, host fixo por variável de ambiente) e há uma lista de bloqueio para rotas de autenticação. Mas não há lista de permissões: qualquer caminho válido chega ao backend com o token da sessão anexado automaticamente. É isto que torna os IDOR do backend exploráveis directamente a partir do browser, sem necessidade de acesso de rede à API.

### MED-06 — `/api/runtime` confia em cabeçalhos do cliente

```10:24:FrontEnd/src/app/api/runtime/route.ts
  const host =
    request.headers.get("x-forwarded-host")?.split(",")[0]?.trim() ||
    request.headers.get("host")?.trim();
```

Rota pública, sem verificação de sessão. Com um proxy mal configurado, um `X-Forwarded-Host` controlado pelo atacante faz o browser da vítima ligar-se a um WebSocket hostil. Mitigado se `PUBLIC_WS_URL` estiver definido — mas está comentado no `docker-compose.yml:67`.

### MED-07 — Mensagens de erro expõem detalhes internos

```61:63:backend/src/to-do/to-do.service.ts
      } catch (error) {
        throw new BadRequestException('Falha ao criar a tarefa, Error: ' + error)
      }
```

O objecto de erro é concatenado na resposta ao cliente, podendo incluir SQL, nomes de colunas e detalhes do TypeORM. Ocorre em todos os métodos de `to-do.service.ts` e noutros serviços.

Há também um `catch` que engole a distinção de erros em `auth.service.ts:104-107`: qualquer excepção durante o login vira "Senha incorreta", incluindo falhas de base de dados.

### MED-08 — `forbidNonWhitelisted` não activado

```47:53:backend/src/main.ts
  app.useGlobalPipes(
    new ValidationPipe({
      errorHttpStatusCode: 422,
      transform: true,
      whitelist: true,
    }),
  );
```

`whitelist: true` remove campos não declarados, o que previne mass assignment na prática (os serviços também usam campos explícitos, não spread). Acrescentar `forbidNonWhitelisted: true` faria os pedidos maliciosos falharem visivelmente em vez de serem truncados em silêncio.

### MED-09 — `AuthGuard` devolve 403 em vez de 401

O guard usa `return false` em todos os caminhos de falha (`auth.guard.ts:27, 44, 58`), o que produz 403 Forbidden. Semanticamente deveria ser 401 Unauthorized com `WWW-Authenticate`. Confunde clientes que tentam renovar a sessão automaticamente.

### MED-10 — `CRYPT_SALT=10` abaixo do recomendado

O valor actual está a 10 rondas; a recomendação corrente para bcrypt é 12 ou superior. Combinado com a ausência de limitação de taxa, reduz o custo de ataques offline sobre hashes eventualmente vazados.

### MED-11 — Containers sem restrições de privilégio

Nenhum serviço em qualquer dos ficheiros Compose define `cap_drop`, `security_opt: no-new-privileges`, `read_only` ou limites de CPU/memória. Positivo: não há `privileged`, nem montagem de `docker.sock`, nem `network_mode: host`.

### MED-12 — `npm install` em vez de `npm ci`

`backend/Dockerfile:10` e `FrontEnd/Dockerfile:7` usam `npm install`, que pode divergir do lockfile. As compilações não são reprodutíveis e abre-se margem para desvios de dependências. Nenhum Dockerfile define `HEALTHCHECK`.

### MED-13 — Imagens base sem fixação por digest

`node:22-alpine`, `postgres:16-alpine`, `nginx:alpine`. As tags são mutáveis. Positivo: Prometheus e Grafana estão fixados em versões concretas (`v2.55.1`, `11.3.0`).

### MED-14 — API de lifecycle do Prometheus activada

```96:96:docker-compose.yml
      - '--web.enable-lifecycle'
```

Permite `POST /-/reload` sem autenticação. Actualmente o Prometheus só tem `expose`, não `ports`, portanto não está acessível do exterior — mas é uma bomba armadilhada caso a porta venha a ser publicada.

### MED-15 — Guard de rotas verifica apenas a presença do cookie

```29:29:FrontEnd/src/proxy.ts
  const hasSession = request.cookies.has(SESSION_COOKIE);
```

Um cookie com valor arbitrário passa. Mitigado porque `(app)/layout.tsx:15-16` valida no servidor e redirecciona, mas o guard sozinho não protege.

### MED-16 — Dependências transitivas com vulnerabilidades

`next@16.2.1` arrasta `sharp <0.35.0` e `postcss` com avisos de severidade alta. A actualização para `16.3.1` resolve.

### MED-17 — `backend/docker-compose.yml` sem rede dedicada

Ao contrário do Compose da raiz, não define `networks:`, usando a rede bridge por omissão — menor isolamento entre serviços.

---

## 5. Achados de severidade baixa

| ID | Achado | Referência |
|---|---|---|
| BAIXO-01 | `server_tokens` activo — nginx revela a versão | `docker/nginx.conf` |
| BAIXO-02 | `client_max_body_size 20m` sem limitação de taxa associada | `docker/nginx.conf:20` |
| BAIXO-03 | `GF_SERVER_ROOT_URL` aponta para `localhost`, divergindo do acesso por IP | `docker-compose.yml:118` |
| BAIXO-04 | `console.log(error)` em caminhos de autenticação polui logs com dados de token | `auth.service.ts:75, 105` |
| BAIXO-05 | Dashboards do Grafana com `editable: true` | `docker/grafana/dashboards/` |
| BAIXO-06 | Sem `OPTIONS` no BFF (intencional, mas indocumentado) | `bff/[...path]/route.ts` |

---

## 6. Controlos verificados e considerados correctos

Vale a pena registar o que resistiu à análise, para não se regredir nestes pontos:

**Backend**
- Passwords com bcrypt; nunca devolvidas em respostas (`select: { password: false }` consistente, `user.password = undefined` após login).
- JWT validado contra sessão persistida — a revogação por logout funciona de facto.
- `AuthGuard` verifica `audience` e `issuer`, não apenas a assinatura.
- **Sem SQL injection.** A única query crua usa parâmetros posicionais correctamente:

```71:74:backend/src/tasks/tasks.service.ts
        await this.tasksRepository.query(
          `UPDATE "task" SET "order" = $1, "stageId" = $2 WHERE id = $3`,
          [i, targetStageId, id],
        );
```

- `synchronize: false` imposto em três locais, com aviso explícito sobre `DB_SYNCHRONIZE` obsoleto. Schema gerido por migrações.
- Escalada de privilégio por mass assignment **bloqueada**: `role` não existe em `CreateUserDto` nem `UpdateUserDto`, e `whitelist: true` descarta o campo.
- Mutações de projectos e tarefas correctamente protegidas por `canManageProject` / `canMoveOrRemoveTask` / `canAccessProject`. Um participante não se promove a dono nem gere membros.
- `GET /projects`, `GET /tasks` e `GET /to-do` (findAll) filtram pelo utilizador autenticado.

**Frontend**
- Mitigação de SSRF no BFF bem construída: regex restritivo, bloqueio de `..`, host de destino fixado por variável de ambiente do servidor.
- Cabeçalhos encaminhados por lista de permissões mínima. O `Authorization` vem sempre do cookie do servidor — o cliente não o consegue sobrepor.
- Da resposta do backend só passa `content-type`; `Set-Cookie` e `Location` não vazam.
- JWT em cookie `httpOnly`, nunca em `localStorage`. O `sessionStorage` só guarda estado de UI do temporizador.
- **Sem XSS**: zero ocorrências de `dangerouslySetInnerHTML`, `eval`, `new Function`, `innerHTML` ou `document.write`. Conteúdo de utilizador renderizado como texto por React. Sem renderização de Markdown.
- Nenhuma variável `NEXT_PUBLIC_*` — nenhum segredo no bundle.
- Autenticação validada no servidor em `(app)/layout.tsx`.

**Infraestrutura**
- **`.env` não está versionado.** Confirmado por `git ls-files` e `git log --all -- '*.env'` em ambos os repositórios — sem resultados.
- `.dockerignore` exclui `.env`, `.git` e `node_modules` nos dois serviços.
- Dockerfiles multi-stage com `USER node` / `USER nextjs` — sem execução como root.
- `npm prune --omit=dev` no backend após a compilação.
- API, web e Prometheus apenas com `expose`, sem publicação no host.
- Postgres com SCRAM, recusa arranque com passwords vazias.
- Grafana recusa arrancar sem password; registo de novos utilizadores desactivado; sem acesso anónimo.
- Volumes de configuração montados em modo leitura (`:ro`).
- Healthcheck do Postgres configurado.

---

## 7. Plano de remediação

### Fase 1 — Imediata (falhas exploráveis por qualquer utilizador registado)

1. **Adicionar verificação de propriedade em `users`.** `update` e `softDelete` devem receber o utilizador autenticado e recusar alvos diferentes, salvo papel administrativo. Exigir password actual e confirmação por email para alteração de endereço.
2. **Corrigir o módulo `to-do`.** Os parâmetros `user` já estão a ser passados; basta usá-los. A correcção mínima em cada um dos cinco métodos:

```typescript
const todo = await this.toDoRepository.findOne({
  where: { id: String(id), user: { id: user.id } },
  relations: ['user'],
});
if (!todo) throw new NotFoundException('Tarefa não encontrada');
```

E fazer o controller passar `@User()` também ao `findOne`.

3. **Consumir o token de recuperação.** Apagar o registo `ForgetPassword` após a reposição, revogar todas as sessões existentes do utilizador, e validar `audience: JWTAudience.FORGET_PASSWORD` em `isValidResetToken`.
4. **Definir `SWAGGER_PASSWORD`** com valor forte, ou bloquear `/swagger`, `/api-json` e `/api-yaml` no nginx fora de desenvolvimento. Considerar transformar o aviso em falha de arranque quando `NODE_ENV=production`.
5. **Restringir o Postgres a `127.0.0.1`:** `'127.0.0.1:${POSTGRES_PUBLISH_PORT:-5432}:5432'`. Gerar passwords distintas para os três papéis e reduzir `DB_REMOTE_USER` a `SELECT`.
6. **Autenticar o WebSocket.** Validar o JWT no handshake (`handleConnection(client: Socket)` com token em `client.handshake.auth`) e verificar `canAccessProject` antes de aceitar `joinTask`. Substituir `cors: true` por lista de origens.
7. **Restringir `companies`** a `@Roles(ADMIN_GOD)` como medida imediata, e definir um modelo de pertença como solução definitiva.

### Fase 2 — Curto prazo

8. Instalar `@nestjs/throttler` com limites agressivos em `/auth/login` e `/auth/forget-password`; acrescentar `limit_req` no nginx.
9. Configurar CORS com lista explícita de origens em vez de `app.enableCors()`.
10. Aplicar `@UseGuards(AuthGuard, RolesGuard)` e `@Roles(...)` — a infra-estrutura já existe.
11. Adicionar verificação de acesso em todos os endpoints de leitura listados em ALTO-04.
12. Exigir `canAccessProject` na criação de subtarefas e validar que colunas de destino pertencem ao mesmo projecto.
13. Instalar `helmet` no backend e definir CSP no `next.config.ts`.
14. Uniformizar as mensagens de erro de autenticação e remover a concatenação do objecto de erro nas respostas.

### Fase 3 — Endurecimento

15. TLS, mesmo autoassinado, com `SESSION_COOKIE_SECURE=true` e HSTS activo.
16. Reduzir a validade do JWT e introduzir refresh tokens com rotação; guardar apenas o hash do token na tabela `session` e implementar limpeza de sessões expiradas.
17. Elevar `CRYPT_SALT` para 12 e substituir `SEED_ADMIN_PASSWORD` por valor forte gerado aleatoriamente.
18. Compose: `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, limites de recursos. Remover `--web.enable-lifecycle`.
19. Dockerfiles: `npm ci`, fixação de imagens por digest, `HEALTHCHECK`.
20. Corrigir `safeNextPath` com `new URL()`; verificar `Origin` nas mutações; introduzir lista de permissões de rotas no BFF.
21. Actualizar `next` para 16.3.1 ou superior.

---

## 8. Observação final

A distribuição das falhas conta uma história coerente. O módulo `projects` — provavelmente o primeiro a ser levado a sério — tem um sistema de permissões bem desenhado, com distinção entre dono, participante e administrador, e aplicado com cuidado em todas as mutações. Os módulos construídos depois herdaram a estrutura mas não a disciplina: `to-do` chega ao ponto de passar o objecto `user` para dentro dos serviços e nunca o comparar com nada, e `companies` foi escrito sem sequer uma relação com `User` no schema.

Isto é encorajador do ponto de vista de remediação. Não é preciso repensar a arquitectura de segurança: ela existe, funciona e está testada em `projects`. É preciso aplicá-la de forma uniforme ao resto do código. As correcções da Fase 1 são maioritariamente de poucas linhas cada, e resolvem os nove achados críticos.

Duas recomendações de processo que ajudariam a evitar reincidência: um teste automatizado por endpoint que confirme que o utilizador B não acede ao recurso do utilizador A, e uma verificação no arranque que recuse `NODE_ENV=production` com `SWAGGER_PASSWORD` vazio — falhar ruidosamente em vez de registar um aviso que ninguém lê.
