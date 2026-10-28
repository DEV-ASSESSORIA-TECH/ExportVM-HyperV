# Changelog — VM Export Backup

Histórico de versões. Para arquitetura/configuração atual veja [README.md](README.md); para operação do dia a dia, [RUNBOOK.md](docs/RUNBOOK.md).

---

## v2.1.0 — 2026-10-28

Exclusões de VMs, diagnóstico dos backups por e-mail, organização da instalação e proteção contra concorrência e interrupções durante a publicação.

### Adicionado

- **Exclusão por nome:** `ExcludeVMName` em `Config\Settings.json` e parâmetro equivalente no script principal. A comparação usa o nome completo, sem diferenciar maiúsculas/minúsculas e sem interpretar curingas.
- **Exclusão por identificador:** `ExcludeVMId` aceita o GUID completo da VM e mantém a exclusão após renomeações. As listas de nomes e IDs se somam: corresponder a qualquer uma delas exclui a VM, inclusive quando ela é solicitada explicitamente por `-VMName`.
- **Avisos de exclusões ausentes:** nomes ou IDs configurados que não existem no host aparecem no log, no relatório e no alerta por e-mail das execuções reais, mesmo quando os demais backups têm sucesso.
- **Estado `SKIPPED`:** lotes sem VMs elegíveis registram a justificativa e as exclusões no resultado e no consolidado, sem executar backup ou retenção daquele lote. Se todos os lotes forem ignorados, a cascata também fica `SKIPPED`, com código 0 sem avisos ou 2 com avisos.
- **Motivo específico da falha no e-mail:** o corpo HTML informa o erro global do lote e o motivo de cada VM que falhou, como falta de espaço, acesso negado ou timeout, conforme o erro capturado. O alerta consolidado permite identificar o lote e a VM afetados sem depender apenas da abertura do log.
- **Contexto de diagnóstico no relatório e no e-mail:** etapa, classificação da falha, tentativas, espaço mínimo exigido e espaço disponível em GB, quando registrados, além do caminho do log do lote. Os campos usam rótulos em português.
- **Plano único da cascata:** a seleção, as exclusões e a classificação por lote são persistidas em `Reports\Cascade-<BackupSetId>.plan.json`; os processos dos lotes resolvem as VMs pelo VMId desse plano.
- **Journal de publicação:** `_PUBLISHING` registra de forma persistente as publicações aprovadas ainda pendentes, com origem, destino, identidade da VM, tamanho e resultado necessários para retomá-las após uma interrupção.
- **Checkpoint por VM:** `PUBLISHED.marker.json` é atualizado atomicamente a cada publicação e passa a ser a referência principal de descoberta dos arquivos válidos, inclusive durante a troca dos marcadores finais do lote.
- **Grupo de processos por repositório:** workers de exportação, compactação, teste e hash são criados suspensos e vinculados a um Job Object antes de executar código; seus descendentes permanecem no grupo.

### Alterado

- **Seleção antes dos discos:** as exclusões são aplicadas antes das consultas de tamanho e da classificação nos lotes, evitando consultar os discos das VMs ignoradas. A cascata reutiliza o plano compartilhado em vez de recalcular a seleção em cada lote.
- **Nomes dos logs e relatórios diretos:** o prefixo genérico `VMExportBackup` dá lugar ao nome do lote, como `SMALL`, `MEDIUM` ou `BIG`; execuções avulsas usam `ADHOC` ou `ALL`. Os nomes incluem data, hora e oito caracteres do `RunId` para reduzir colisões entre execuções iniciadas no mesmo segundo. O log da cascata também recebe o RunId curto.
- **Raiz da instalação:** permanecem somente `Invoke-VMExportBackup.ps1`, `Invoke-CascadeBackup.ps1` e `Install-VMExportBackupTask.ps1`. Auxiliares ficam em `Internal\Helpers` e workers em `Internal\Workers`.
- **Referências internas:** scripts de entrada, instalador, testes e empacotamento passam a usar os novos caminhos; o ZIP preserva a árvore `Internal` completa.
- **Bloqueio compartilhado pelo destino:** o lock local antigo é substituído por `<RepositoryRoot>\.VMExportBackup.lock`, aberto com `OpenOrCreate` e `FileShare.None`. O handle exclusivo é mantido durante a execução real e a finalização dos relatórios; o arquivo permanece após o término. O modo `PLAN` não adquire o bloqueio nem altera o repositório de backups.
- **Retomada antes de novos backups:** sob o bloqueio, a execução reconcilia publicações pendentes antes de tratar staging órfão. A recuperação é idempotente, preserva VMs já publicadas e a retenção registrada, e não repete a exportação. Uma publicação anteriormente aprovada pode ser concluída mesmo que a VM esteja excluída da nova seleção.
- **Integridade obrigatória na recuperação:** antes de concluir uma publicação pendente, são verificados caminhos, tamanho registrado e SHA-256 quando registrado, e sempre é repetido `7z t`, mesmo com `SkipHash: true`. O teste respeita `IntegrityTimeoutHours` e grava saídas em `Logs\Recovery-*.stdout.log` e `Logs\Recovery-*.stderr.log`.
- **Documentação e distribuição:** README, runbook, guia rápido e notas da v2.1.0 documentam exclusões, estados, diagnósticos, nova estrutura, bloqueio e recuperação. O pacote passa a incluir a licença MIT.

### Corrigido

- **Corrida ao adquirir o lock:** a aquisição passa a ocorrer em uma única operação de abertura exclusiva, eliminando a janela entre verificar a existência do bloqueio e gravá-lo.
- **Workers sobreviventes ao processo principal:** encerramento abrupto do dono fecha o Job Object e encerra os descendentes. Antes de entregar o repositório a uma nova execução no mesmo host, o grupo remanescente é encerrado e drenado; o timeout do monitor também encerra o grupo completo.
- **Arquivos fora da descoberta após uma queda:** interrupções entre mover metadados, mover o arquivo e gravar o manifesto passam a ser recuperáveis pelo journal e pelo checkpoint, sem perder a referência das publicações aprovadas.
- **Corrupção de mesmo tamanho com hash desabilitado:** a recuperação deixa de depender apenas da quantidade de bytes e exige aprovação no teste integral do 7-Zip. Divergência, timeout, código de saída desconhecido ou diferente de zero impedem a conclusão e preservam a pendência para inspeção.
- **Limpeza de publicação pendente:** falhas durante a publicação preservam o journal e os dados necessários à retomada, evitando mover ou apagar esse staging como se fosse apenas uma transação falha ou órfã.
- **VM removida após o planejamento:** a ausência gera resultado individual `VM_NOT_FOUND` e inventário mínimo, sem nova tentativa para essa falha determinística e sem interromper o processamento das demais VMs.
- **Falso sucesso com zero backups:** lotes totalmente excluídos deixam de retornar `SUCCESS`; o estado e a justificativa `SKIPPED` são preservados na finalização e no consolidado.
- **Resultado de lote ausente ou inválido:** JSON ilegível, campos obrigatórios ausentes ou contagens malformadas geram falha no consolidado, mesmo quando o processo filho retorna código zero.
- **Falhas de inicialização sem alerta:** erros de configuração, planejamento ou carregamento de helpers passam pelo registro do resultado de falha e pela tentativa de envio do alerta consolidado, com fallback quando os helpers de relatório não estão disponíveis.
- **Conteúdo dos erros no HTML:** mensagens e demais valores dinâmicos são escapados antes de entrar no relatório e no corpo do e-mail, preservando a exibição de caracteres especiais.
- **Busca do consolidado:** os exemplos operacionais excluem arquivos `.plan.json`, evitando confundir o plano de seleção com o resultado final da cascata.

### Compatibilidade e atualização

- Backups schema 2 anteriores continuam legíveis pelos marcadores existentes; o novo checkpoint tem precedência quando presente. Não é necessário converter esses backups.
- Os caminhos dos três scripts de entrada permanecem iguais. A reorganização, por si só, não exige recriar a tarefa agendada quando a pasta de instalação e sua ação continuam as mesmas.
- Na atualização, suspenda o agendamento e aguarde o término das execuções; preserve `Config`, `Logs` e `Reports`, copie a pasta `Internal` com os scripts de entrada e remova as cópias antigas dos auxiliares/workers da raiz após conferir a instalação. A pasta local `Locks` antiga deixa de ser usada.
- Todas as instalações que escrevem no mesmo repositório precisam ser atualizadas, pois as versões antigas não respeitam o novo bloqueio. A coordenação dos workers por Job Object é local: use um único host escritor por repositório.
- SHA-256 continua opcional e desabilitado por padrão. O teste obrigatório do 7-Zip na recuperação não altera essa configuração. A proteção de publicação depende de o armazenamento respeitar flush e substituição atômica.

### Validação

- Suíte Pester validada no Windows PowerShell 5.1: **120 testes aprovados, nenhuma falha e nenhum teste omitido**, incluindo a integração com 7-Zip real.
- Cenários cobertos incluem exclusões antes das consultas aos discos, plano compartilhado, `SKIPPED`, erros no relatório/e-mail, VM removida, resultados inválidos, disputa do lock, timeout, encerramento abrupto do dono e de seus descendentes, recuperação nas etapas da publicação e corrupção de arquivo mantendo o mesmo tamanho.
- O teste com arquivo 7z real pode ser habilitado por `VMEXPORT_TEST_7ZIP`; sem essa variável, somente esse teste de integração é omitido. A suíte não baixa ferramentas automaticamente.
- ZIP de distribuição conferido com 24 arquivos idênticos às fontes e checksum SHA-256 validado. Backup/restauração real no Hyper-V e entrega SMTP ainda exigem homologação no ambiente de destino.

---

## v2.0.3 — 2026-09-08

### Alterado

- Removido do script principal o fluxo v1.2 mantido sob `if ($false)`, junto das funções e do teste que existiam somente para sustentá-lo.
- Removida do instalador a migração automática das tarefas agendadas anteriores à cascata única, pois o único host de produção já está atualizado.
- Retiradas da documentação operacional as instruções de migração da linha 1.x e alinhadas as referências de versão em `README.md`, `LEIA-ME.txt` e `RUNBOOK.md`.

---

## v2.0.2 — 2026-08-31

### Corrigido

- `MinFreeGB` volta a ser o único limite de espaço antes de cada VM, sem somar ou multiplicar o tamanho atual dos discos.
- A limpeza `SPACE_PRESSURE` preserva payloads protegidos quando a soma elegível não pode cobrir o déficit e interrompe exclusões que não recuperam espaço.
- Logs de limpeza passam a informar estimativa, ganho real e motivo de interrupção; falhas em `INITIALIZE` não alegam mais preservar um payload inexistente.

---

## v2.0.1 — 2026-08-27

### Adicionado

- Parâmetro `-TaskPath` em `Install-VMExportBackupTask.ps1` para registrar a cascata em uma pasta personalizada já existente no Agendador do Windows.
- Normalização do caminho lógico, aceitando por exemplo `ASSESSORIA SCF` ou `\ASSESSORIA SCF\`.

### Alterado

- Ao mudar a pasta, o instalador registra a nova tarefa antes de remover cópias de mesmo `TaskName` em outros caminhos, evitando cascatas duplicadas.
- A remoção das tarefas legadas agora informa explicitamente `TaskPath` e `TaskName`.

## v2.0.0 — 2026-08-27

Repaginação do repositório para tolerar falhas por VM sem reescrever o fluxo validado de exportação e 7-Zip.

### Adicionado

- Organização do projeto em `src/`, `scripts/`, `Tests/` e `docs/`, sem alterar o layout interno do pacote instalado.
- `VERSION`, `scripts/Package.ps1` e checksum SHA-256 do ZIP de distribuição.
- Workflow de publicação por tag `v*.*.*`, limitado a empacotar e criar a GitHub Release, sem CI.
- `BackupSetId` no formato `YYYY-MM-DD-xxxxxxxx` e manifests `SchemaVersion: 2`.
- Identidade persistente `<nome-seguro>--<VMId-curto>`; o `VMId` completo governa descoberta e retenção mesmo após renomear a VM ou mudar seu tier.
- Transação isolada por VM e publicação independente em `<BackupSetId>\<Tier>\Archives|Metadata`.
- Marcadores `COMPLETE.marker.json` e `PARTIAL.marker.json` schema 2.
- Retenção dos backups válidos por VM através de noites e tiers.
- `_FAILED\<nome--VMId>\<ocorrência>\Payload` com `failure.json`; três payloads pesados por VM são mantidos, enquanto todos os registros leves permanecem.
- Reserva por VM de `MinFreeGB + 2 × SourceBytes`, com limpeza de `_FAILED` antes de falhar apenas a VM corrente.
- Classificação de falhas transitórias e determinísticas; espera de 60 segundos somente quando haverá nova tentativa.
- Relatórios por snapshot, `DiagnosticFailures` e logs tolerantes a falha de arquivo.
- Resultado determinístico por tier e um único alerta consolidado após toda a cascata.

### Alterado

- Estados finais: `SUCCESS`/0, `SUCCESS_WITH_WARNINGS`/2, `PARTIAL_SUCCESS`/1 e `FAILED`/1.
- SHA-256 passa a ser opcional e fica desativado por padrão (`SkipHash: true`). `7z t`, validação estrutural e comparação do tamanho listado continuam obrigatórios.
- `FailedRetentionDays` foi substituído por `FailedPayloadKeepPerVM`.
- Falha de uma VM não impede publicar as demais nem executar tiers posteriores.

### Compatibilidade

- O código v2.0 descobre, retém e remove somente backups com schema 2 e é intencionalmente incompatível com a linha 1.x.
- Layouts anteriores (`_CASCATA_`, `_RUN_` ou marcadores sem `SchemaVersion: 2`) não são migrados, descobertos ou excluídos automaticamente. A cópia e remoção desses dados é responsabilidade operacional manual.
- Não foi criado `_AUDIT`: logs e relatórios locais são a auditoria operacional; metadados volumosos acompanham a retenção do arquivo da VM.

---

## v1.2.0 — 2026-08-06

Cascata real (um único horário de disparo, lotes em sequência) e agrupamento por noite. Motivação: a validação da v1.1.0 usou três horários fixos espaçados (`00:30`/`06:00`/`12:00`) — funcionou, mas o teste manual do dia anterior (rodado às 22h em vez dos horários definitivos) só terminou às 6h30, perto demais do início do expediente. O modelo de horários independentes não garantia isso de forma robusta caso algum lote demorasse mais que o previsto.

### Adicionado
- **Cascata real**: `Invoke-CascadeBackup.ps1` (novo) gera uma assinatura compartilhada e roda os lotes definidos em `Tiers.json` em sequência (ordem de `MinSizeGB` ascendente — SMALL → MEDIUM → BIG), cada um como processo separado, só iniciando o próximo depois que o anterior termina. Substitui os três horários fixos independentes da v1.1.0 por um único horário de disparo (`CascadeStartTime`, `21:00`).
- **Agrupamento por noite**: os três lotes de uma mesma cascata publicam dentro da mesma pasta na raiz do repositório (`<data-de-início>_CASCATA_<assinatura>`), cada um em sua própria subpasta (`SMALL\`, `MEDIUM\`, `BIG\`) com `Archives`/`Metadata`/marcador próprios — continuam sendo processos isolados, só a pasta pai é compartilhada. A data usada é a do início da cascata, não a de cada lote (resolve o caso do lote BIG cruzar a virada do dia). Novo parâmetro `-CascadeId` em `Invoke-VMExportBackup.ps1`; execuções manuais/avulsas (sem cascata) continuam funcionando, gerando sua própria pasta (rótulo `RUN`).
- **`Config\Tiers.json` schema v2**: `ScheduleTime`/`ExecutionTimeLimitHours` por lote (v1.1.0) deram lugar a `CascadeStartTime`/`CascadeExecutionTimeLimitHours` no nível raiz — a cascata tem um único horário e um único teto de tempo (o Agendador do Windows só aplica um `ExecutionTimeLimit` por tarefa, não por etapa interna).
- **`Install-VMExportBackupTask.ps1` simplificado**: cria uma única tarefa (`Backup Hyper-V - Cascata Noturna`, antes três — uma por lote) e migra hosts do modelo antigo removendo automaticamente as tarefas `Backup Hyper-V - Lote SMALL/MEDIUM/BIG` se existirem.
- **Retenção e expiração compatíveis com os dois layouts**: `Invoke-Retention` e `Remove-ExpiredFailedPoints` passam a distinguir pasta-folha (ponto publicado direto, layout anterior à v1.2.0) de pasta-container (noite/cascata, layout atual), recursando um nível quando necessário. Os três pontos publicados na validação da v1.1.0 (layout raso) continuam sendo contados corretamente na retenção por `TierName`, sem precisar de migração.

### Por que a retenção por lote não mudou
Cada lote continua com sua própria contagem de `KeepRestorePoints`, independente dos outros — só a descoberta no disco passou a olhar dentro das pastas de cascata também. Decisão consciente: agrupar por noite só na organização de pastas, não na semântica de retenção (evita que uma noite parcial — 2 de 3 lotes OK — derrube a retenção dos lotes que tiveram sucesso).

---

## v1.1.0 — 2026-08-06

Lotes automáticos por tamanho, retenção por lote, alertas só em falha. Motivação: o desenho anterior (v1.0.5) exigia manter à mão uma lista fixa de VM por lote (BIG/MEDIUM/SMALL), tinha um único contador de retenção compartilhado entre os três lotes, não tinha limpeza de execuções interrompidas à força, e todos os comandos de produção rodavam com `-SkipEmail` — uma falha noturna não gerava nenhum aviso.

### Adicionado
- **Classificação automática por tamanho**: cada VM é reclassificada em lote (SMALL/MEDIUM/BIG) a cada execução, pelo tamanho lógico atual do disco, contra limiares configuráveis em `Config\Tiers.json`. Não é mais preciso manter lista de nomes por lote.
- **`Config\Tiers.json`**: definição de lotes — limiares de tamanho, retenção (`KeepRestorePoints`) e horário de agendamento (`ScheduleTime`), independentes por lote.
- **`Config\Settings.json`**: parâmetros gerais do script (drive, timeouts, SMTP, etc.) como defaults sobrescrevíveis — parâmetro explícito na linha de comando sempre vence sobre o config.
- **`TierHelpers.ps1`**: módulo compartilhado entre o script principal e o instalador (carregamento/validação de `Tiers.json`, cálculo de tamanho de VM, classificação por tier, cálculo de pior-caso de duração por lote).
- **Retenção por lote**: cada lote (`TierName` gravado no marcador do ponto) mantém sua própria contagem de retenção. Pontos publicados por versões anteriores (sem `TierName`) caem num grupo `LEGACY` próprio, protegidos de serem apagados pela retenção de um lote real.
- **Limpeza de staging órfão**: diretórios em `_STAGING` deixados por uma execução morta à força (kill do Task Scheduler, queda de energia) são detectados e movidos para `_FAILED` automaticamente no início da próxima execução, com marcador `ORPHANED.marker.json`.
- **E-mail apenas em falha**: `suporte@assessoriatech.com` (integrado ao Tiflux) só recebe e-mail quando um lote termina em `FAILED`/`PARTIAL_FAILED`. Sucesso e modo PLAN ficam silenciosos. `-SkipEmail` foi reaproveitado para significar "forçar silêncio mesmo em falha" (uso manual/teste).
- **`Install-VMExportBackupTask.ps1` reescrito**: lê `Config\Tiers.json` e cria uma tarefa agendada por lote (antes: uma única tarefa cobrindo todas as VMs, sem suporte a lotes). Calcula `ExecutionTimeLimit` a partir do pior caso teórico quando não fixado no config, avisa sobre possível colisão de horário entre lotes, e remove automaticamente tarefas de lotes descontinuados.
- Relatório HTML: nome do lote no resumo e bloco de erro/falha em destaque logo após o status (já que agora só falha gera e-mail).

### Validação em produção — 2026-08-05 22:00 até 2026-08-06 06:30 (America/Cuiaba)

Execução real dos três lotes em sequência (tarefa de teste único, um atrás do outro), no host de produção, sem intervenção manual durante a execução.

| Lote | Início | Fim | Duração | VMs | Exportado | Compactado | Redução | Status |
|---|---|---|---|---|---|---|---|---|
| SMALL | 22:00:00 | 22:31:34 | 00:31:33 | 9/9 | ~110,9 GB | ~32,2 GB | -70,9% | SUCCESS |
| MEDIUM | 22:31:34 | 00:44:24 | 02:12:49 | 5/5 | ~225,4 GB | ~101,1 GB | -55,2% | SUCCESS |
| BIG | 00:44:24 | 06:30:33 | 05:46:08 | 3/3 | ~433,8 GB | ~264,5 GB | -39,0% | SUCCESS |
| **Total** | 22:00:00 | 06:30:33 | **08:30:33** | **17/17** | **~770,0 GB** | **~397,8 GB** | **-48,4%** | **SUCCESS** |

Pontos publicados:
- `F:\HyperV-Exports\2026-08-05_22-00-00_SMALL_ca628dec`
- `F:\HyperV-Exports\2026-08-05_22-31-34_MEDIUM_02f26b96`
- `F:\HyperV-Exports\2026-08-06_00-44-24_BIG_4c0a9541`

Confirmado nessa validação:
- Classificação automática bateu com o tamanho real de cada VM (limiares de 25 GB e 75 GB calibrados a partir dos dados reais das execuções anteriores).
- Retenção por lote isolada corretamente — cada lote encontrou só o próprio ponto (1 de cada), abaixo do limite de 3, nada removido.
- Execução sequencial sem colisão de lock — cada lote só começou no momento exato em que o anterior liberou o lock.
- Política de e-mail silenciosa em sucesso — as três execuções logaram `E-mail nao enviado (Status=SUCCESS, SkipEmail=False)`, zero chamados abertos no Tiflux.
- VM mais lenta do parque: `SRV-AMANDA` (192 GB), ~1h35 só na etapa de compactação — maior componente de tempo do lote BIG.

A partir desses números reais, `ExecutionTimeLimitHours` em `Config\Tiers.json` foi ajustado de `null` (pior caso calculado, 290h/482h/866h — matematicamente seguro mas impraticável como teto) para valores realistas: **SMALL 2h, MEDIUM 5h, BIG 12h** (~2-4x de folga sobre o observado).

Pendente: instalação definitiva das 3 tarefas diárias recorrentes via `Install-VMExportBackupTask.ps1` (até aqui só a tarefa de teste único foi usada) e teste de restauração completa de uma VM a partir do `.7z` publicado.

---

## v1.0.5

Versão validada manualmente em produção antes da reestruturação em lotes automáticos:

- VM desligada;
- VM Linux ligada (via `hv-vss-daemon.service`);
- checkpoint de produção;
- múltiplas VMs na mesma execução;
- compactação individual por VM;
- teste integral com `7z t`;
- validação estrutural do arquivo (presença de VHD/VHDX/AVHDX + VMCX, tamanho descompactado conferido contra o exportado);
- cálculo de SHA-256;
- publicação atômica do ponto completo;
- retenção após sucesso (contador único, sem distinção de lote);
- heartbeat em operações longas.

Nesta versão os três lotes (BIG/MEDIUM/SMALL) eram listas fixas de `-VMName` mantidas manualmente no README, com `-KeepRestorePoints 9` compartilhado entre os três (workaround para simular ~3 pontos reais por lote) e `-SkipEmail` em todos os comandos de produção (e-mail não estava em uso).

## v1.0 → v1.0.5

Linha original do projeto: substituir o Windows Server Backup por um fluxo de exportação via `Export-VM` + 7-Zip, corrigindo os problemas do script anterior (senha SMTP em texto puro, falta de validação de integridade, sem teste de restauração documentado). Versões incrementais nesse intervalo endureceram o parsing de saída do 7-Zip, o tratamento de `ExitCode` indisponível do PowerShell 5.1 com redirecionamento, e o limite de threads do 7-Zip (`-mmt=8` fixo, para não competir com o Hyper-V pelos núcleos do host).
