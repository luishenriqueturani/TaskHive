# Task Hive API — guia de integração

Documentação prática para agentes de IA, scripts e integrações na LAN (ex.: `http://192.168.1.34:8080` ou `http://orangepi.local:8080`).

Use este arquivo como referência para criar/atualizar projectos, colunas Kanban e tarefas no Task Hive a partir de outros repositórios.

---

## Arquitetura (importante)

Há **duas superfícies** relevantes para integração externa:

| Superfície | URL | Uso |
|---|---|---|
| **Nginx + BFF (Next.js)** | `http://<host>:8080` | **Usar esta** — login, CRUD e PAT |
| Swagger / OpenAPI | `http://<host>:8080/swagger` e `/api-json` | Contratos Nest (HTTP Basic: `SWAGGER_*` no `.env`) |

A API Nest (`http://api:3001`) **não é publicada no host** na stack Compose por defeito — só existe na rede Docker. O BFF fala com ela internamente.

```text
Cliente (curl / agente) → :8080/api/bff/* → Next BFF → api:3001
```

Mapeamento de paths:

```text
/api/bff/<path-do-swagger>
```

Ex.: Swagger `POST /projects` → cliente `POST /api/bff/projects`.

### Allowlist do BFF

Só estes prefixos passam pelo proxy (outros devolvem **403**):

`projects`, `project-stages`, `tasks`, `subtasks`, `to-do`, `users`, `companies`, `personal-access-tokens`

Rotas de auth têm handlers dedicados em `/api/auth/*` (não use `/api/bff/auth/login`).

`/metrics`, `/swagger` directo no BFF → **403** ou **404**.

---

## Autenticação

Dois modos suportados via `:8080`:

| Modo | Quando usar | Header / cookie |
|---|---|---|
| **PAT (recomendado para LLMs)** | Scripts longos, agentes, CI | `Authorization: Bearer th_pat_…` |
| **Sessão (browser / legado)** | Login interactivo, testes rápidos | Cookie `th_session` (+ opcional `Bearer` JWT) |

### PAT — Personal Access Token (recomendado)

1. No browser, autentique-se na UI e abra **`/settings/api-tokens`**.
2. Crie um token (nome + expiração; default **90 dias**).
3. Copie o valor **`th_pat_…`** — **só é mostrado uma vez**.
4. Guarde no `.env` do repositório cliente (nunca commitar):

```bash
TASK_HIVE_BASE_URL=http://192.168.1.34:8080
TASKHIVE_API_TOKEN=th_pat_xxxxxxxxxxxxxxxxxxxxxxxx
TASK_HIVE_PROJECT_ID=740267155987238912   # opcional, projecto alvo
```

Chamadas:

```bash
set -a && source .env && set +a
curl -sS \
  -H "Authorization: Bearer $TASKHIVE_API_TOKEN" \
  -H "Accept: application/json" \
  "$TASK_HIVE_BASE_URL/api/bff/projects"
```

**Segurança:** nunca cole o PAT em chats de LLM; use variável de ambiente. Revogue em `/settings/api-tokens` se exposto.

Criar PAT via API (requer sessão browser uma vez):

```http
POST /api/bff/personal-access-tokens
Cookie: th_session=<JWT>
Content-Type: application/json

{ "name": "cursor-trackr", "expiresInDays": 90 }
```

Resposta inclui `token` (plain-text, uma vez) + metadados (`id`, `tokenPrefix`, `expiresAt`).

### Sessão — login com cookie

```http
POST /api/auth/login
Content-Type: application/json

{ "email": "seu@email.com", "password": "sua-senha" }
```

Resposta JSON traz só `user`. Tokens vêm em cookies httpOnly:

```http
Set-Cookie: th_session=<JWT>; Path=/; HttpOnly; SameSite=lax
Set-Cookie: th_refresh=<opaco>; Path=/; HttpOnly; SameSite=lax
```

O **access JWT** expira em ~**1 hora** (`exp` no payload). Renovar:

```http
POST /api/auth/refresh
Cookie: th_refresh=<refresh>
```

Persistir para scripts:

```bash
TASK_HIVE_BASE_URL=http://192.168.1.34:8080
TASK_HIVE_SESSION=<valor th_session após login>
```

Obter o token:

```bash
curl -sS -c /tmp/th.txt -X POST "$TASK_HIVE_BASE_URL/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"email":"...","password":"..."}' -o /dev/null
grep th_session /tmp/th.txt | awk '{print $7}'
```

Uso nas chamadas BFF:

```bash
curl -H "Cookie: th_session=$TASK_HIVE_SESSION" \
  -H "Accept: application/json" \
  "$TASK_HIVE_BASE_URL/api/bff/projects"
```

Se receber **401**, faça login de novo ou use `POST /api/auth/refresh` com `th_refresh`.

### CSRF (login / registo)

O backend valida `Origin`/`Referer` quando presentes (`CSRF_ALLOWED_ORIGINS` no Compose). Pedidos **sem** esses headers (curl, agentes) continuam permitidos. Scripts curl normalmente não precisam de headers extra.

### Outros endpoints de auth (BFF)

| Método | Path | Notas |
|---|---|---|
| `POST` | `/api/auth/login` | Cria sessão |
| `GET` | `/api/auth/me` | Utilizador actual (401 sem cookie) |
| `POST` | `/api/auth/refresh` | Renova `th_session` + `th_refresh` |
| `POST` | `/api/auth/logout` | Invalida sessão |
| `POST` | `/api/auth/reset-password` | Reset com token no body |

---

## Fluxo de trabalho com o Trackr

1. Implementar o item no código / docs.
2. Marcar o checkbox em `docs/TODO.md`.
3. **Sempre** actualizar a tarefa correspondente no Task Hive (mover / concluir). Não deixar o quadro e o TODO divergirem.

Fluxo técnico:

1. Autenticar (PAT no `.env` **ou** login → `th_session`)
2. `POST /api/bff/projects` → criar projecto
3. `POST /api/bff/project-stages` (×N) → colunas Kanban
4. `PATCH /api/bff/project-stages/:id` → encadear `prevStageId` / `nextStageId`
5. `POST /api/bff/tasks` → criar tarefas na coluna desejada
6. `PATCH /api/bff/tasks/:id` → descrição / ordem
7. `POST /api/bff/tasks/:id/completions` → marcar como concluída

---

## Endpoints usados

Base: `http://<host>:8080` — prefixo `/api/bff/` em todos os paths abaixo.

Autenticação em **todas** as chamadas: `Authorization: Bearer th_pat_…` **ou** `Cookie: th_session=…`.

### Projectos

| Método | Path | Body |
|---|---|---|
| `GET` | `/api/bff/projects` | — |
| `POST` | `/api/bff/projects` | `{ "name": "...", "description": "..." }` |
| `PATCH` | `/api/bff/projects/:id` | parcial |
| `DELETE` | `/api/bff/projects/:id` | — |
| `GET` | `/api/bff/projects/:id/participants` | — |
| `POST` | `/api/bff/projects/:id/participants` | `{ "userId": "<uuid>" }` |
| `DELETE` | `/api/bff/projects/:id/participants/:userId` | — |

`name` é obrigatório. Só vê/edita projectos em que participa (IDOR corrigido).

### Utilizadores

| Método | Path | Notas |
|---|---|---|
| `GET` | `/api/bff/users/search?q=<texto>` | Busca participantes (mín. 2 caracteres) |
| `GET` | `/api/bff/users` | **Apenas admins** |
| `GET` | `/api/bff/users/:id` | Próprio perfil ou admin |

### Colunas (stages)

| Método | Path | Body |
|---|---|---|
| `GET` | `/api/bff/project-stages` | — |
| `GET` | `/api/bff/project-stages/project/:projectId` | — |
| `POST` | `/api/bff/project-stages` | `{ "name", "projectId", "order" }` |
| `PATCH` | `/api/bff/project-stages/:id` | `{ "name"?, "order"?, "nextStageId"?, "prevStageId"? }` |
| `DELETE` | `/api/bff/project-stages/:id` | — |

Kanban básico sugerido:

| name | order |
|---|---|
| A Fazer | 0 |
| Em Progresso | 1 |
| Concluído | 2 |

Depois encadear:

- A Fazer → `nextStageId = Em Progresso`
- Em Progresso → `prevStageId = A Fazer`, `nextStageId = Concluído`
- Concluído → `prevStageId = Em Progresso`

IDs de projecto/coluna/tarefa são **bigint em string** (ex.: `"739896941068029952"`).

### Tarefas

| Método | Path | Body |
|---|---|---|
| `GET` | `/api/bff/tasks` | — |
| `GET` | `/api/bff/tasks/stage/:stageId` | — |
| `POST` | `/api/bff/tasks` | `{ "name", "stageId" }` |
| `PATCH` | `/api/bff/tasks/:id` | `{ "name"?, "description"?, "order"?, "stageId"?, "finishDate"? }` |
| `POST` | `/api/bff/tasks/:id/completions` | — (marca concluída) |
| `DELETE` | `/api/bff/tasks/:id` | — |
| `PATCH` | `/api/bff/tasks/nextStage/:id` | move para próxima coluna |
| `PATCH` | `/api/bff/tasks/previousStage/:id` | move para coluna anterior |

`CreateTaskDto` só aceita `name` + `stageId`. Descrição e ordem vão no `PATCH` em seguida.

### Subtarefas e to-do

| Path | Uso |
|---|---|
| `/api/bff/subtasks/...` | subtarefas de uma task |
| `/api/bff/to-do/...` | tarefas avulsas (fora do quadro do projecto) |
| `/api/bff/tasks/:id/timetrack` | timer da tarefa (WebSocket separado) |

### Tokens de API

| Método | Path | Auth |
|---|---|---|
| `GET` | `/api/bff/personal-access-tokens` | sessão ou PAT |
| `POST` | `/api/bff/personal-access-tokens` | **só sessão** (criar PAT) |
| `DELETE` | `/api/bff/personal-access-tokens/:id` | sessão ou PAT (revogar o próprio) |

---

## Exemplo mínimo (Python) — com PAT

```python
import json, os, urllib.request

BASE = os.environ["TASK_HIVE_BASE_URL"]
TOKEN = os.environ["TASKHIVE_API_TOKEN"]

def api(method: str, path: str, body=None):
    data = None if body is None else json.dumps(body).encode()
    headers = {
        "Authorization": f"Bearer {TOKEN}",
        "Accept": "application/json",
        "Content-Type": "application/json",
    }
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req) as resp:
        raw = resp.read().decode()
        return json.loads(raw) if raw else None

project = api("POST", "/api/bff/projects", {
    "name": "meu-repo",
    "description": "Descrição do projecto",
})
project_id = str(project["id"])

stages = []
for name, order in [("A Fazer", 0), ("Em Progresso", 1), ("Concluído", 2)]:
    stages.append(api("POST", "/api/bff/project-stages", {
        "name": name,
        "projectId": project_id,
        "order": order,
    }))

for i, stage in enumerate(stages):
    body = {}
    if i > 0:
        body["prevStageId"] = str(stages[i - 1]["id"])
    if i < len(stages) - 1:
        body["nextStageId"] = str(stages[i + 1]["id"])
    if body:
        api("PATCH", f"/api/bff/project-stages/{stage['id']}", body)

done_id = str(stages[2]["id"])
task = api("POST", "/api/bff/tasks", {
    "name": "Primeira tarefa",
    "stageId": done_id,
})
api("PATCH", f"/api/bff/tasks/{task['id']}", {
    "description": "Detalhes / commit / fase",
    "order": 0,
})
api("POST", f"/api/bff/tasks/{task['id']}/completions")
```

## Exemplo mínimo (curl) — com PAT

```bash
export TASK_HIVE_BASE_URL=http://192.168.1.34:8080
export TASKHIVE_API_TOKEN=th_pat_...

curl -sS -H "Authorization: Bearer $TASKHIVE_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -X POST "$TASK_HIVE_BASE_URL/api/bff/projects" \
  -d '{"name":"meu-repo","description":"Descrição"}'
```

## Exemplo mínimo (curl) — com sessão

```bash
# 1) Login e extrair cookie
curl -sS -c cookies.txt -X POST "$TASK_HIVE_BASE_URL/api/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"email":"seu@email.com","password":"sua-senha"}'

# 2) Criar projecto
curl -sS -b cookies.txt -X POST "$TASK_HIVE_BASE_URL/api/bff/projects" \
  -H 'Content-Type: application/json' \
  -d '{"name":"meu-repo","description":"Descrição"}'
```

---

## Armadilhas

1. **Não usar `:3001` no host** — na stack Compose actual a API Nest **não está exposta**; use sempre `:8080` + `/api/bff/`.
2. **Não usar `/api/projects`** — 404 no Next; o path certo é `/api/bff/projects`.
3. **Login BFF não devolve `token` no JSON** — ler cookies `th_session` / `th_refresh`.
4. **Access JWT expira ~1 h** — renove com `/api/auth/refresh` ou prefira **PAT** (`th_pat_`, default 90 d).
5. **Swagger `servers.url` aponta para `localhost:3001`** — ignore; use BFF em `:8080`.
6. **IDs são bigint string** — sempre enviar como string JSON.
7. **Descrição da tarefa não entra no create** — criar e depois `PATCH`.
8. **Concluir ≠ mover de coluna** — `POST .../completions` marca `completedAt`; coluna é `stageId` / nextStage.
9. **Evitar duplicar** — listar antes de recriar (`GET /api/bff/projects`, `GET /api/bff/tasks/stage/:id`).
10. **403 no BFF** — path fora da allowlist ou sem autenticação.
11. **429** — rate limit em login/registo/forget-password; aguarde e repita.
12. **Respostas nunca incluem `password`** — se aparecer, reporte como bug de segurança.
13. **Compose na LAN** — defina no `.env` da raiz: `PUBLIC_WS_URL=http://<IP>:8080` e, se usar login browser com CSRF, `CSRF_ALLOWED_ORIGINS=http://<IP>:8080`.

---

## Referência OpenAPI

- UI: `http://<host>:8080/swagger` (HTTP Basic: variáveis `SWAGGER_USER` / `SWAGGER_PASSWORD`)
- JSON: `http://<host>:8080/api-json`

Contratos úteis: `CreateProjectDto`, `CreateProjectStageDto`, `CreateTaskDto`, `UpdateTaskDto`, `CreatePersonalAccessTokenDto`.

No cliente externo, prefixar paths com `/api/bff/`.

---

## Caso fipe-api (já criado)

| Campo | Valor |
|---|---|
| Projecto | `fipe-api` |
| ID | `739896941068029952` |
| UI | http://orangepi.local:8080/projects |
| Colunas | A Fazer → Em Progresso → Concluído |
| Tarefas | 34 (histórico Git), todas em Concluído e marcadas concluídas |

Fonte das tarefas locais: `TASKS.md` (no repositório fipe-api).

---

## Caso Proposify (já criado)

| Campo | Valor |
|---|---|
| Projecto | `Proposify` |
| ID | `739909504547819520` |
| UI | http://orangepi.local:8080/projects |
| Colunas | A Fazer (`739909505025970176`) → Em Progresso (`739909505336348672`) → Concluído (`739909505617367040`) |
| Tarefas | 34 (MVP do PLANEJAMENTO.md), todas em **A Fazer** |

Fonte das tarefas locais: [`TASKS.md`](./TASKS.md).

---

## Caso trackr (já criado)

| Campo | Valor |
|---|---|
| Projecto | `trackr` |
| ID | `740267155987238912` |
| UI | http://orangepi.local:8080/projects |
| Colunas | A Fazer (`740267156285034496`) → Futuro (`740267924119490560`) → Em Progresso (`740267156570247168`) → Concluído (`740267156838682624`) |
| Tarefas | MVP em **A Fazer** / **Concluído**; pós-MVP na coluna **Futuro** (~24: Fase 17 tenant + backlog de `docs/TODO.md` § Futuro) |

Fonte das tarefas locais: [`docs/TODO.md`](./docs/TODO.md).
