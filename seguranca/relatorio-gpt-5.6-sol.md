# Auditoria de Segurança — TaskHive

**Autor da análise:** GPT-5.6 Sol  
**Data:** 20 de agosto de 2026  
**Escopo:** frontend Next.js, BFF, backend NestJS, PostgreSQL, WebSocket, Nginx, Docker Compose, imagens e configurações operacionais.  
**Método:** revisão estática independente do código e das configurações atuais. Os relatórios já existentes em `seguranca/` não foram usados como fonte.

## Resumo executivo

O nível de risco agregado é **crítico**, embora nenhum achado isolado tenha sido classificado como crítico. A razão é a combinação de controles de autorização ausentes, transporte HTTP, sessões de 90 dias e serviços administrativos publicados na rede.

Foram consolidados **22 achados**:

- 11 de severidade alta;
- 10 de severidade média;
- 1 de severidade baixa.

Os riscos mais urgentes são:

1. usuários autenticados podem alterar ou remover contas de terceiros;
2. tarefas avulsas, projetos, colunas, tarefas e subtarefas possuem falhas de autorização por objeto;
3. o WebSocket aceita conexões e inscrições em tarefas sem autenticação;
4. tokens de redefinição de senha são reutilizáveis e não revogam sessões;
5. o deployment padrão transmite credenciais e sessões de longa duração por HTTP;
6. Next.js 16.2.1 está abaixo da versão de segurança 16.2.11;
7. PostgreSQL e Grafana são publicados em todas as interfaces, com credenciais e privilégios excessivamente compartilhados.

Uma conta comum comprometida é suficiente para acessar ou adulterar dados de outros usuários. Em uma rede hostil, o cookie de sessão pode ser capturado e reutilizado por até 90 dias. O encadeamento desses problemas torna uma invasão persistente plausível.

## Modelo de ameaça considerado

- usuário comum autenticado tentando elevar privilégios ou acessar dados de terceiros;
- atacante anônimo com acesso HTTP ao host na LAN ou por encaminhamento de porta;
- máquina ou Wi-Fi da LAN comprometidos;
- processo comprometido dentro de um container;
- usuário local sem privilégios administrativos;
- requisições concorrentes e payloads destinados a causar indisponibilidade;
- dependência ou imagem upstream comprometida.

## Achados de severidade alta

### SEC-01 — Alteração e remoção de qualquer conta autenticada

**CWE:** CWE-639, CWE-862  
**Confiança:** alta

`backend/src/users/users.controller.ts:39-109` protege as rotas apenas com `AuthGuard`. As operações `PUT`, `PATCH` e `DELETE /users/:id` não verificam se o ID pertence ao usuário autenticado nem exigem papel administrativo. `GET /users` fornece os UUIDs, nomes e e-mails necessários à exploração.

**Impacto:** alteração de identidade, troca de e-mail, desativação de contas e sabotagem de administradores.

**Correção:** aplicar política de recurso no backend. Usuários comuns só podem editar a própria conta; operações sobre terceiros devem exigir um `RolesGuard` administrativo. Retornar 404 para recursos fora do escopo e adicionar testes negativos.

### SEC-02 — IDOR completo em tarefas avulsas

**CWE:** CWE-639  
**Confiança:** alta

`backend/src/to-do/to-do.controller.ts:91-220` recebe o usuário em várias rotas, mas `backend/src/to-do/to-do.service.ts:104-137,139-224,226-359` consulta e atualiza somente por `id`. O parâmetro `user` não restringe leitura, edição, remoção, conclusão, status ou recorrência.

**Impacto:** qualquer usuário autenticado que descubra um Snowflake ID pode ler, editar, concluir ou apagar a tarefa de outra pessoa.

**Correção:** incluir sempre `user.id` no predicado da consulta e da mutação. Centralizar a carga do recurso em um método `loadOwnedTodo(id, userId)` e cobrir todas as rotas com testes de isolamento entre contas.

### SEC-03 — Leitura transversal de projetos, colunas, tarefas e subtarefas

**CWE:** CWE-639, CWE-862  
**Confiança:** alta

Há consultas por ID ou listagens globais sem `canAccessProject`:

- `backend/src/projects/projects.service.ts:70-82,200-204`;
- `backend/src/project-stages/project-stages.service.ts:85-123`;
- `backend/src/tasks/tasks.service.ts:140-177`;
- `backend/src/subtasks/subtasks.service.ts:23-80`.

A criação de subtarefa confirma apenas que a tarefa existe; não verifica acesso ao projeto pai.

**Impacto:** vazamento de nomes, descrições, participantes e estrutura de projetos, além da criação de subtarefas em tarefas privadas.

**Correção:** resolver o projeto pai em toda operação e aplicar `canAccessProject` ou `canManageProject`. Remover endpoints globais desnecessários. Uma rota nunca deve confiar apenas na existência do ID.

### SEC-04 — Relações e tarefas podem atravessar projetos

**CWE:** CWE-863, CWE-840  
**Confiança:** alta

Em `backend/src/project-stages/project-stages.service.ts:24-69,126-167`, `nextStageId` e `prevStageId` são carregados sem confirmar que pertencem ao mesmo projeto. O serviço chega a atualizar diretamente a coluna externa. Em `backend/src/tasks/tasks.service.ts:242-295`, a coluna de destino é validada apenas por existência, sem comparar seu projeto com o projeto de origem.

**Impacto:** corrupção do Kanban de terceiros, ligações entre projetos privados e movimentação de tarefas para colunas não autorizadas.

**Correção:** exigir igualdade entre o projeto do recurso de origem e o de destino, autorizar os dois lados e executar a mutação relacional em transação.

### SEC-05 — WebSocket sem autenticação ou autorização

**CWE:** CWE-306, CWE-284, CWE-400  
**Confiança:** alta

`backend/src/tasks/timetrack.gateway.ts:22-73` usa `cors: true`, aceita qualquer conexão e executa `client.join("task:<id>")` após receber `joinTask`. Não existe validação de JWT, origem, formato do ID ou acesso ao projeto. `docker/nginx.conf:27-39` publica o endpoint e mantém conexões por até 24 horas.

Os eventos emitidos por `backend/src/tasks/timetrack.service.ts:88-95,122-129,157-164` incluem IDs, nomes de usuários e horários.

**Impacto:** monitoramento anônimo de atividade e identidade, enumeração de salas e esgotamento de conexões/memória.

**Correção:** autenticar o handshake, associar o socket ao usuário, verificar `canAccessProject` antes de entrar na sala, restringir origens e limitar conexões, eventos, salas e tamanho de frames.

### SEC-06 — Redefinição de senha reutilizável e sem revogação

**CWE:** CWE-640, CWE-613  
**Confiança:** alta

`backend/src/auth/auth.service.ts:164-203,218-231` atualiza a senha, mas não apaga nem marca o registro de `ForgetPassword` como consumido. O token permanece reutilizável durante 24 horas. As sessões existentes também não são revogadas.

**Impacto:** quem obtiver um token pode redefinir a senha repetidamente; uma sessão roubada continua válida depois da troca de senha.

**Correção:** armazenar apenas o hash do token, manter `usedAt`, consumir o token atomicamente em transação, invalidar tokens anteriores e revogar todas as sessões do usuário.

### SEC-07 — Administração global de empresas por qualquer usuário

**CWE:** CWE-862  
**Confiança:** média-alta

`backend/src/companies/companies.controller.ts:8-131` exige apenas autenticação. Qualquer papel pode listar, criar, renomear e remover qualquer empresa. Não há proprietário, associação nem `RolesGuard`.

**Impacto:** adulteração do cadastro empresarial e dos vínculos usados pelos projetos.

**Correção:** definir pertencimento explícito ou restringir as mutações a administradores. Se empresas forem globais por requisito, documentar e testar essa política.

### SEC-08 — Sessões de 90 dias trafegam por HTTP

**CWE:** CWE-319, CWE-614  
**Confiança:** alta

`backend/src/auth/auth.service.ts:44-57` cria JWTs de login com validade padrão de 90 dias. `FrontEnd/src/lib/session.ts:10-29` mantém o cookie pelo mesmo período. O Compose define `SESSION_COOKIE_SECURE=false` e o Nginx escuta apenas HTTP em `docker-compose.yml:61-80` e `docker/nginx.conf:16-20`.

**Impacto:** um atacante na mesma LAN, Wi-Fi ou caminho de rede pode capturar login/cookie e reutilizar a sessão por longo período.

**Correção:** TLS obrigatório, redirecionamento HTTP→HTTPS, cookie `Secure`, HSTS depois da migração, sessão curta e refresh token rotativo.

### SEC-09 — Next.js 16.2.1 contém vulnerabilidades conhecidas

**CWE:** CWE-1104 e CWEs específicos dos advisories  
**Confiança:** alta para a versão; a explorabilidade varia por advisory

`FrontEnd/package.json:22` fixa `next` em 16.2.1. A versão de segurança publicada em julho de 2026 é 16.2.11. A faixa `>=16.0.0 <16.2.11` é afetada por falhas de alta severidade, incluindo DoS em Server Actions, bypass de Middleware/Proxy e SSRF em configurações específicas.

**Referências oficiais:**

- Next.js July 2026 Security Release: https://nextjs.org/blog/july-2026-security-release
- Release 16.2.11: https://github.com/vercel/next.js/releases/tag/v16.2.11
- GHSA-6gpp-xcg3-4w24: https://github.com/vercel/next.js/security/advisories/GHSA-6gpp-xcg3-4w24

**Correção:** atualizar no mínimo para `next@16.2.11`, atualizar o lockfile, reconstruir a imagem e testar App Router, BFF, Proxy e WebSocket.

### SEC-10 — PostgreSQL e Grafana publicados com privilégio excessivo

**CWE:** CWE-668, CWE-250, CWE-319  
**Confiança:** alta para o bind; o alcance externo depende de firewall/NAT

`docker-compose.yml:19-20,114-118` publica PostgreSQL e Grafana sem IP de bind, normalmente em `0.0.0.0`. Não há TLS entre clientes e PostgreSQL. `backend/docker/postgres/init/01-users.sh:31-48` concede ao usuário remoto `CREATE`, `ALL PRIVILEGES ON SCHEMA` e privilégios integrais padrão em tabelas e sequências.

**Impacto:** brute force, interceptação e, com a credencial remota, leitura, alteração, exclusão e persistência no banco.

**Correção:** não publicar PostgreSQL; se necessário, vincular a `127.0.0.1` ou rede administrativa/VPN. Restringir Grafana da mesma forma. Separar papéis de leitura, aplicação e migração; remover `CREATE` e `ALL` do usuário cotidiano.

### SEC-11 — Segredos compartilhados entre containers e permissões locais fracas

**CWE:** CWE-200, CWE-522, CWE-732  
**Confiança:** alta

`docker-compose.yml:15,35,111-129` injeta o mesmo `backend/.env` integralmente em PostgreSQL, API e Grafana. Assim, containers recebem segredos que não precisam conhecer. As permissões observadas são `0664` em `backend/.env` e `0644` em `FrontEnd/.env`, permitindo leitura por outros usuários locais.

Nenhum valor de segredo foi incluído neste relatório.

**Impacto:** uma RCE ou leitura de ambiente em um único container facilita movimento lateral para banco, JWT e Grafana.

**Correção:** rotacionar credenciais, usar valores únicos, separar segredos por serviço, preferir Docker Secrets/arquivos montados e aplicar modo `0600`.

## Achados de severidade média

### SEC-12 — Login e recuperação sem rate limiting e com enumeração

**CWE:** CWE-307, CWE-204  
**Confiança:** alta

`backend/src/auth/auth.service.ts:87-106,135-140` diferencia usuário inexistente de senha incorreta. Não foi encontrado throttling global, por IP ou por conta.

**Correção:** resposta uniforme, limite por IP e identidade, atraso progressivo e proteção adicional no Nginx.

### SEC-13 — Tokens longos armazenados integralmente no banco

**CWE:** CWE-613, CWE-922  
**Confiança:** alta

`backend/src/auth/auth.service.ts:253-302` pesquisa e grava o JWT completo na tabela de sessões. Um vazamento do banco fornece tokens imediatamente utilizáveis.

**Correção:** persistir hash de token opaco, usar access token curto, refresh rotativo, expiração no banco e revogação por dispositivo.

### SEC-14 — BFF genérico expõe rotas operacionais

**CWE:** CWE-200, CWE-284  
**Confiança:** alta

`FrontEnd/src/app/api/bff/[...path]/route.ts:7-88` bloqueia somente três rotas de autenticação e encaminha qualquer path sintaticamente válido. Assim, `/api/bff/metrics` alcança `backend/src/metrics/metrics.module.ts:14-22`, que não exige autenticação.

**Impacto:** exposição de memória, CPU, volume de operações, conexões WebSocket e outros dados úteis para reconhecimento.

**Correção:** allowlist explícita de rotas de negócio no BFF e autenticação/restrição de rede na própria rota `/metrics`.

### SEC-15 — Cache do React Query sobrevive à troca de usuário

**CWE:** CWE-525  
**Confiança:** alta

`FrontEnd/src/components/theme/app-providers.tsx:10-34` mantém um único `QueryClient` no layout. `FrontEnd/src/components/auth/logout-button.tsx:16-23` encerra a sessão e navega, mas não chama `queryClient.clear()`.

**Impacto:** em um dispositivo compartilhado, a conta B pode ver temporariamente dados ainda frescos da conta A.

**Correção:** limpar React Query e qualquer armazenamento de sessão no logout e no login, ou recriar o provider por ID de sessão.

### SEC-16 — DoS por buffering e ausência de limites

**CWE:** CWE-400, CWE-770  
**Confiança:** alta

`FrontEnd/src/app/api/bff/[...path]/route.ts:50-64` materializa todo o corpo com `request.arrayBuffer()`. O Nginx permite 20 MB em `docker/nginx.conf:20`; não há `limit_req`, `limit_conn`, limites de CPU/memória/PIDs ou limites de eventos WebSocket.

**Correção:** rejeitar antecipadamente por `Content-Length`, usar limites por rota e streaming, aplicar rate/connection limiting e limites de recursos no Compose.

### SEC-17 — Condições de corrida em timers e ordenação

**CWE:** CWE-362  
**Confiança:** alta

`backend/src/tasks/timetrack.service.ts:67-87` faz “listar abertos → fechar → inserir” sem transação ou índice único. `backend/src/tasks/tasks.service.ts:30-97` reordena com múltiplos updates sem lock/transação.

**Impacto:** múltiplos timers ativos e ordens duplicadas ou inconsistentes sob requisições concorrentes.

**Correção:** transações, locks adequados, índice parcial único para timer ativo por usuário e restrição/estratégia atômica de ordenação.

### SEC-18 — Erros internos devolvidos ao cliente

**CWE:** CWE-209  
**Confiança:** alta

`backend/src/to-do/to-do.service.ts:98-100,133-135,197-199,220-222,249-251,272-274,343-345` concatena exceções internas nas mensagens HTTP.

**Correção:** resposta pública genérica, logging estruturado apenas no servidor e remoção/redação de dados sensíveis.

### SEC-19 — CORS, Swagger e métricas permissivos

**CWE:** CWE-942, CWE-200  
**Confiança:** média-alta

`backend/src/main.ts:18-45` habilita CORS sem allowlist e deixa Swagger público quando usuário ou senha não estão configurados. O Nginx publica `/swagger` e `/api-json`. `/metrics` não possui autenticação própria.

**Correção:** allowlist de origens, falha de inicialização em produção quando credenciais obrigatórias faltarem e restrição de Swagger/métricas por autenticação e rede.

### SEC-20 — Containers sem hardening e builds não reprodutíveis

**CWE:** CWE-829, CWE-1104, CWE-250  
**Confiança:** alta

Os Dockerfiles executam como usuários não-root, o que é positivo. Porém, `backend/Dockerfile:1-13` e `FrontEnd/Dockerfile:1-21` usam tags mutáveis e `npm install`; o Compose não define `read_only`, `cap_drop`, `no-new-privileges`, `pids_limit`, CPU ou memória.

**Correção:** usar `npm ci`, fixar imagens por digest, gerar SBOM, verificar proveniência e aplicar filesystem somente leitura, capabilities mínimas e limites de recursos.

### SEC-21 — Ambiente E2E publicado com credencial fixa

**CWE:** CWE-798, CWE-668  
**Confiança:** alta

`backend/docker-compose.e2e.yml:5-19` publica PostgreSQL em `0.0.0.0:5433` com credenciais versionadas e previsíveis.

**Correção:** bind em `127.0.0.1`, rede interna sem publicação e credenciais efêmeras geradas pela execução de CI.

## Achado de severidade baixa

### SEC-22 — Ausência de Content Security Policy

**CWE:** CWE-693  
**Confiança:** alta

`FrontEnd/next.config.ts:3-41` define vários headers úteis, mas não CSP. Não foi encontrada uma fonte XSS direta; portanto, este é um controle de defesa em profundidade.

**Correção:** adotar CSP baseada em nonce, começando em modo `Report-Only`, com `default-src 'self'`, `object-src 'none'`, `base-uri 'self'`, `frame-ancestors 'self'` e origens WebSocket explícitas.

## Riscos incomuns e cadeias de exploração

### Corrupção relacional entre projetos

O uso de IDs de colunas externas em `nextStageId`, `prevStageId` ou `stageId` não é apenas um IDOR tradicional. Ele permite modificar indiretamente registros de outro projeto e criar grafos inconsistentes. Essa corrupção pode persistir mesmo depois de o endpoint vulnerável ser corrigido.

### Vazamento entre sessões no mesmo navegador

O cookie é apagado no logout, mas o estado de dados do React Query permanece. Em máquinas compartilhadas, o isolamento entre contas depende também da limpeza do cache cliente.

### Movimento lateral entre containers

O mesmo arquivo de ambiente é entregue a serviços com níveis de confiança diferentes. Uma falha no Grafana ou na API pode revelar credenciais de outros componentes e ampliar o comprometimento.

### Encadeamento mais provável

1. captura de cookie por HTTP ou comprometimento de uma conta comum;
2. listagem de usuários e recursos;
3. exploração de IDOR para ler/adulterar contas, tarefas e projetos;
4. uso do WebSocket anônimo para monitoramento;
5. persistência facilitada por sessões longas e reset que não revoga sessões.

## Itens não confirmados ou dependentes do ambiente

- O alcance do PostgreSQL e Grafana fora da LAN depende de firewall, NAT e encaminhamento de portas.
- Pode existir TLS em um proxy externo não representado no repositório.
- A explorabilidade de cada advisory transitivo do npm depende do lockfile e do fluxo usado. A tentativa de repetir `npm audit --omit=dev` no ambiente da revisão não conseguiu carregar o lockfile pelo executor; o Next.js foi validado diretamente contra o comunicado oficial.
- Backups podem existir fora do repositório. Não foi encontrada rotina automatizada, criptografada e testada de backup/restauração na configuração versionada.
- Source maps e capabilities efetivas devem ser verificados nas imagens implantadas.

## Controles positivos observados

- DTOs passam por `ValidationPipe` com `whitelist: true`;
- queries SQL manuais encontradas usam parâmetros posicionais;
- cookie de sessão é `httpOnly` e `SameSite=Lax`;
- não foram encontrados `dangerouslySetInnerHTML`, `eval`, parser de Markdown/HTML, upload arbitrário, execução de comandos ou SSRF implementado pela aplicação;
- backend e frontend executam como usuários não-root;
- não há `privileged`, Docker socket, host network/PID ou mounts sensíveis;
- mounts de configuração observados são somente leitura;
- há controles de autorização adequados em parte dos fluxos de projeto e timetrack HTTP.

## Plano de remediação priorizado

### Nas próximas 24 horas

1. restringir PostgreSQL e Grafana à interface administrativa;
2. ativar TLS e cookies `Secure`;
3. corrigir SEC-01, SEC-02 e SEC-05;
4. atualizar Next.js para pelo menos 16.2.11;
5. rotacionar e separar credenciais; aplicar `0600` aos `.env`;
6. bloquear `/metrics`, Swagger e rotas operacionais no BFF/proxy.

### Em até 7 dias

1. centralizar autorização por recurso em projetos, colunas, tarefas e subtarefas;
2. tornar reset de senha de uso único e revogar sessões;
3. reduzir duração da sessão e armazenar apenas hashes de tokens;
4. adicionar rate limiting e respostas uniformes de autenticação;
5. limpar caches no logout/login;
6. adicionar transações e restrições para timers e ordenação.

### Em até 30 dias

1. hardening de containers e builds reprodutíveis;
2. segmentação de redes e segredos por serviço;
3. CSP em modo Report-Only e posterior enforcement;
4. backup off-host criptografado com teste de restauração;
5. SAST, SCA, scan de imagens e testes de autorização na CI;
6. pentest dinâmico em ambiente isolado após as correções.

## Critérios mínimos de aceite

- conta A recebe 404/403 ao consultar ou alterar recursos exclusivos da conta B;
- socket sem JWT é recusado e socket autenticado não entra em tarefa sem acesso;
- token de reset usado uma vez falha na segunda tentativa;
- troca de senha revoga todas as sessões anteriores;
- nenhuma credencial ou cookie trafega em HTTP;
- PostgreSQL não responde em interfaces públicas;
- `/api/bff/metrics`, Swagger e documentação operacional não ficam públicos;
- logout remove dados da conta anterior do cache do navegador;
- duas requisições concorrentes não criam timers ativos duplicados;
- scanners não reportam vulnerabilidades altas ou críticas exploráveis nas imagens finais.

## Conclusão

O projeto possui boas decisões pontuais — validação de DTOs, cookies `httpOnly`, queries parametrizadas e execução não-root —, mas a autorização está aplicada de forma inconsistente. A prioridade não deve ser adicionar novos controles cosméticos; deve ser estabelecer uma política única de autorização por recurso no backend, proteger o transporte e reduzir a exposição operacional. Depois disso, sessões, dependências, containers e disponibilidade devem ser endurecidos em camadas.
