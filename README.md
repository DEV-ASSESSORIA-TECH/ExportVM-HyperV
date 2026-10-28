# VM Export Backup v2.1.0

Backup completo de VMs Hyper-V por `Export-VM` e 7-Zip, com publicação e retenção independentes por VM. É uma solução de contingência: não é incremental e não substitui uma plataforma dedicada como Veeam ou Acronis.

Para operação diária e recuperação, consulte [RUNBOOK.md](docs/RUNBOOK.md). Para comandos rápidos, consulte [LEIA-ME.txt](docs/LEIA-ME.txt).

## Organização do repositório

```text
src/                  scripts e Config que formam a instalação
scripts/              testes locais e empacotamento
Tests/                suíte Pester 3.4
docs/                 guia rápido e runbook
.github/workflows/    publicação de release por tag
VERSION               versão SemVer usada pelo pacote
```

O pacote preserva a estrutura de `src/`. Somente os três scripts de entrada ficam na raiz da instalação:

```text
VMsBackups/
  Invoke-CascadeBackup.ps1
  Invoke-VMExportBackup.ps1
  Install-VMExportBackupTask.ps1
  Internal/
    Helpers/          funções compartilhadas
    Workers/          processos de exportação e hash
  Config/
  Logs/               criado durante a execução
  Reports/            criado durante a execução
  docs/
```

Os scripts resolvem os caminhos a partir da própria instalação, independentemente da pasta atual do terminal. A pasta `Internal` deve ser copiada junto com os scripts de entrada; seus arquivos não devem ser executados diretamente.

Ao atualizar uma instalação existente, pare as execuções e desative temporariamente o agendamento, preserve `Config`, `Logs` e `Reports`, e copie os scripts de entrada junto com a pasta `Internal` do novo pacote. Após conferir a cópia, remova da raiz as cópias antigas dos nove arquivos `*Helpers.ps1`, de `Export-VMWorker.ps1` e de `Get-FileHashWorker.ps1`. A pasta local `Locks` das versões antigas deixa de ser usada. Os scripts de entrada mantêm os nomes e caminhos; a tarefa existente não precisa ser recriada por causa desta reorganização. Todas as instalações que escrevem no mesmo repositório devem ser atualizadas: versões antigas não respeitam o novo bloqueio. Reative o agendamento após a conferência.

## Comportamento principal

Em cada noite, `Invoke-CascadeBackup.ps1` cria um `BackupSetId` no formato `YYYY-MM-DD-xxxxxxxx` e executa os tiers configurados, por padrão `SMALL → MEDIUM → BIG`. Cada VM é processada em uma transação isolada:

1. confirma que o destino tem pelo menos `MinFreeGB` livres;
2. exporta com `Export-VM`;
3. compacta em um `.partial.7z` exclusivo;
4. executa obrigatoriamente `7z t`;
5. valida a estrutura, exigindo disco virtual e arquivo `.vmcx`;
6. compara o tamanho descompactado listado pelo 7-Zip com o exportado;
7. opcionalmente calcula SHA-256;
8. finaliza e publica somente o arquivo aprovado daquela VM.

Uma falha não desfaz arquivos já publicados e não impede as VMs ou tiers seguintes. O wrapper consolida os resultados depois de todos os tiers e envia no máximo um alerta de falha por noite.

Uma VM que desapareça após o planejamento gera `VM_NOT_FOUND` individual, sem impedir as demais. Resultado ausente, malformado ou desconhecido de um lote representa falha, mesmo se o processo terminar com código 0. Falhas de inicialização também geram relatório e tentativa de alerta; o envio depende da disponibilidade de SMTP e dos destinatários configurados.

## Concorrência e recuperação de publicação

Cada execução real mantém um handle exclusivo em `<RepositoryRoot>\.VMExportBackup.lock`, adquirido por `OpenOrCreate` com `FileShare.None` após validar o destino. O bloqueio é compartilhado por instalações que usam o mesmo repositório e fica ativo até a finalização dos relatórios. A existência do arquivo não significa execução ativa: ele permanece no disco, e o Windows libera o handle quando o processo termina, inclusive abruptamente. Workers de exportação, compactação, teste e hash iniciam suspensos e entram em um Job Object antes de executar. O grupo encerra os descendentes se o dono morrer; um novo dono drena qualquer grupo remanescente antes de alterar o repositório. A identidade usa o arquivo de lock no volume, inclusive por caminhos alternativos no mesmo host. O destino deve ter um único host escritor: Job Objects não coordenam workers entre máquinas. Não apague o arquivo para tentar liberar um backup em andamento. O modo `PLAN` não adquire esse bloqueio nem altera o repositório.

Antes de mover um arquivo aprovado, o script grava um registro persistente em `_PUBLISHING\<BackupSetId>\<Tier>\<VMIdentity>.json`. Arquivo e metadados são publicados por VM, seguidos de `PUBLISHED.marker.json`, um checkpoint substituído atomicamente com `File.Replace`. O checkpoint é atualizado a cada VM e tem precedência na descoberta sobre `COMPLETE.marker.json` e `PARTIAL.marker.json`, preservados como marcadores de apresentação. Repositórios anteriores sem checkpoint continuam sendo lidos pelos marcadores schema 2 existentes.

Na próxima execução real, sob o bloqueio, as publicações pendentes são reconciliadas antes da seleção e do tratamento de staging órfão. A recuperação verifica os caminhos, o tamanho registrado, o SHA-256 quando registrado e sempre repete o teste integral `7z t`, inclusive com `SkipHash` habilitado. O teste usa `IntegrityTimeoutHours`; suas saídas ficam em `Logs/Recovery-*.stdout.log` e `Logs/Recovery-*.stderr.log`. Ela é idempotente e não refaz a exportação. Uma publicação já aprovada pode ser concluída mesmo que a VM tenha sido excluída da seleção da nova noite. Em caso de divergência, o registro e os arquivos são preservados e a execução falha para inspeção, sem limpeza desse staging. Não remova `_PUBLISHING` manualmente.

Durante uma execução ou após recuperação de uma interrupção, o checkpoint pode indicar `PARTIAL_SUCCESS` com os arquivos aprovados até aquele momento. Isso não afirma que todas as VMs planejadas foram processadas. O relatório final da execução informa os totais de sucesso e falha. A proteção contra interrupção depende de o armazenamento respeitar as operações de flush e substituição atômica; ela não substitui testes de restauração nem protege contra falhas físicas do volume.

## Layout schema 2

```text
F:\HyperV-Exports\
├── .VMExportBackup.lock
├── _PUBLISHING\
├── _STAGING\
├── _FAILED\
│   ├── SRV-ERP--aaaaaaaa\
│   │   └── 2026-08-27_21-00-00--01234567\
│   │       ├── Payload\
│   │       └── failure.json
│   └── _ORPHANED\
└── 2026-08-27-89abcdef\
    ├── SMALL\
    │   ├── Archives\
    │   │   ├── SRV-AD--11111111.7z
    │   │   └── SRV-DOCS--22222222.7z
    │   ├── Metadata\
    │   │   ├── SRV-AD--11111111\
    │   │   ├── SRV-DOCS--22222222\
    │   │   └── _Tier\
    │   ├── PUBLISHED.marker.json
    │   └── COMPLETE.marker.json
    ├── MEDIUM\
    │   ├── PUBLISHED.marker.json
    │   └── PARTIAL.marker.json
    └── BIG\
        └── ...
```

O nome visível usa `<nome-seguro>--<VMId-curto>`. O manifest grava o `VMId` completo, que é a identidade usada na retenção. Renomear uma VM ou movê-la de tier não cria um novo histórico de retenção.

Ao finalizar normalmente, um tier com todas as VMs aprovadas recebe `COMPLETE.marker.json`. Se ao menos uma VM for publicada e outra falhar, recebe `PARTIAL.marker.json`. O checkpoint `PUBLISHED.marker.json` e os dois marcadores usam `SchemaVersion: 2`.

## Estados e códigos

| Estado | Código | Significado |
|---|---:|---|
| `SUCCESS` | 0 | Todas as VMs aprovadas, sem avisos operacionais |
| `SUCCESS_WITH_WARNINGS` | 2 | Backups aprovados, mas houve aviso ou falha de observabilidade |
| `PARTIAL_SUCCESS` | 1 | Ao menos uma VM publicada e ao menos uma VM falhou |
| `FAILED` | 1 | Falha de backup ou erro fatal; na cascata, ao menos um lote falhou |
| `SKIPPED` | 0 ou 2 | Lote sem VMs elegíveis; código 2 quando há avisos |
| `PLAN` | 0 | Validação sem `-Execute` |

Falha de backup sempre prevalece sobre avisos. Falhas de log, JSON, HTML ou SMTP não removem nem invalidam arquivos publicados.

## Retenção

### Backups válidos

`KeepRestorePoints` conta arquivos válidos por `VMId` completo através de noites, nomes e tiers. Ao surgir um quarto ponto com limite 3, somente o `.7z` e os metadados correspondentes mais antigos daquela VM são removidos. O tier e o `BackupSetId` só são removidos quando ficarem vazios.

O valor do tier em `Config\Tiers.json` tem a precedência já existente. Execuções `ADHOC` usam o valor geral de `Config\Settings.json`.

### Falhas

Cada ocorrência grava um `failure.json`. `FailedPayloadKeepPerVM` limita somente os diretórios `Payload` pesados; os JSON leves são preservados. Antes de cada VM a retenção normal é aplicada. `MinFreeGB` é o único limite de admissão: o tamanho da VM não aumenta essa exigência. Se o volume ficar abaixo do mínimo, a limpeza emergencial só começa quando a soma dos payloads elegíveis pode cobrir o déficit; caso contrário, eles são preservados e somente a VM corrente falha. Quando viável, os payloads são removidos globalmente do mais antigo para o mais novo, com conferência do espaço realmente recuperado após cada exclusão. Essa limpeza nunca toca nos backups válidos mantidos.

Staging ilegível ou deixado por interrupção abrupta é movido para `_FAILED\_ORPHANED` na execução seguinte.

## Integridade e SHA-256

O padrão é `"SkipHash": true`, pois o hash aumentava significativamente a janela e ainda não participa do processo operacional de restauração. Para habilitá-lo numa execução:

```powershell
& 'C:\Scripts\WindowsServerBackup\Invoke-VMExportBackup.ps1' -BatchName SMALL -Execute -SkipHash:$false
```

Desativar SHA-256 não desativa as validações obrigatórias: `7z t`, estrutura interna e igualdade do tamanho listado continuam sendo executadas em todo backup.

## Configuração

`Config\Settings.json` usa schema 2:

```json
{
  "SchemaVersion": 2,
  "ExcludeVMName": [],
  "ExcludeVMId": [],
  "BackupDrive": "F:",
  "ExpectedVolumeLabel": "BACKUP-HYPERV",
  "RepositoryFolder": "HyperV-Exports",
  "MinFreeGB": 200,
  "RetryCount": 1,
  "FailedPayloadKeepPerVM": 3,
  "SkipHash": true,
  "KeepRestorePoints": 3
}
```

Os demais campos de timeout, 7-Zip e SMTP permanecem no arquivo entregue. Um parâmetro explícito na linha de comando vence o valor do JSON.

Para ignorar uma VM em todos os lotes da cascata, configure `"ExcludeVMName": ["VM-SEM-BACKUP"]` em `Config\Settings.json`. Use os nomes exatos do Hyper-V; a comparação ignora maiúsculas/minúsculas e não interpreta curingas. A exclusão também prevalece quando a VM é solicitada por `-VMName`.

Prefira `"ExcludeVMId": ["11111111-1111-1111-1111-111111111111"]` para manter a exclusão após renomear a VM. Consulte o identificador real com `Get-VM | Select-Object Name, VMId`. As duas listas se somam: basta corresponder ao nome ou ao VMId para excluir. O identificador sobrevive à renomeação; uma VM recriada com outro VMId exige atualizar a lista. Nomes ou IDs configurados que não existem no host geram aviso no log, no relatório e no e-mail de aviso, inclusive se os backups restantes tiverem sucesso. `-SkipEmail` continua disponível nas execuções diretas.

A cascata cria um plano único em `Reports\Cascade-<BackupSetId>.plan.json`, aplicando exclusões antes de consultar discos e classificando somente as VMs elegíveis. Os processos filhos usam o mesmo plano e resolvem as VMs por VMId; alterações de tamanho durante a noite não mudam o lote escolhido. VMs criadas depois do planejamento entram na próxima cascata. Uma VM planejada que desapareça gera falha explícita. Os nomes ignorados ficam em `ExcludedVMs`, e os identificadores e regras em `ExcludedVMDetails` nos resultados dos lotes.

Um lote sem VMs elegíveis termina com `SKIPPED`, justificativa em `SkipReason` e nenhum backup ou retenção. Se todos os lotes forem ignorados, o consolidado também será `SKIPPED`; lotes vazios não transformam uma cascata com backups bem-sucedidos em falha. O código é `0`, ou `2` se houver avisos. Uma falha em qualquer lote continua prevalecendo com código `1`.

Em uma execução avulsa, `-ExcludeVMName 'VM-SEM-BACKUP'` substitui a lista do JSON; `-ExcludeVMName @()` limpa essa lista somente para a execução atual.
O mesmo vale para `-ExcludeVMId '<GUID>'` e `-ExcludeVMId @()`; cada parâmetro substitui somente a respectiva lista.

`Config\Tiers.json` usa schema 2 e define faixas contínuas de tamanho, retenção, `CascadeStartTime` e `CascadeExecutionTimeLimitHours`. O início padrão permanece às 21:00.

## Retry

São retentáveis: timeout/processo, `Export-VM`, 7-Zip, hash opcional e I/O transitório. Não são retentáveis: configuração inválida, ferramenta ausente, volume/label/saúde, falta de espaço e estrutura inválida. `RetryCount` continua configurável; a espera de 60 segundos só ocorre quando uma nova tentativa transitória será feita.

## Relatórios e e-mail

- Execução direta: pode alertar imediatamente em `FAILED` ou `PARTIAL_SUCCESS`; `-SkipEmail` força silêncio.
- Cascata: cada tier usa `-DeferEmail` e grava um resultado determinístico em `Reports`; o wrapper executa todos os tiers e envia no máximo um alerta consolidado.
- O corpo do alerta consolidado inclui os motivos das falhas por lote e VM, etapa, classificação, tentativas, espaço mínimo exigido/disponível em GB e caminho do log. O espaço exigido corresponde a `MinFreeGB`; o disponível é registrado na preparação ou, em falhas da transação, consultado novamente ao término dela.
- Logs e relatórios avulsos usam o lote e oito caracteres do `RunId`: `BIG-2026-10-28_21-00-00-a1b2c3d4.log`, `MEDIUM-...` ou `SMALL-...`. Execuções manuais usam `ADHOC` (seleção por VM) ou `ALL`; o log geral usa `Cascade-<data-hora>-<RunId-curto>.log`. Relatórios da cascata preservam o nome `BackupSet-<id>-<lote>.result.json/html`.
- JSON e HTML são gravados por snapshot atômico antes de serem anexados.
- Depois da tentativa SMTP, os relatórios locais são regravados com `NotificationStatus`, `MailSent` e `MailError`.
- `DiagnosticFailures` registra falhas não bloqueantes de observabilidade.

Não existe `_AUDIT`. `Logs\` e `Reports\`, ao lado dos scripts, são a auditoria operacional aceita. Metadados específicos de uma VM ficam no repositório de backup e são removidos junto com seu arquivo pela retenção.

## Instalação e execução

Extraia o ZIP da release e copie o conteúdo de `VM-Export-Backup-<versão>` para `C:\Scripts\WindowsServerBackup`. No host Hyper-V, execute como administrador com o módulo Hyper-V e o 7-Zip disponíveis.

Instalar ou atualizar a tarefa diária:

```powershell
& 'C:\Scripts\WindowsServerBackup\Install-VMExportBackupTask.ps1'
```

Por padrão, a tarefa é registrada na raiz (`\`) do Agendador. Para usar uma pasta
personalizada já existente, informe `-TaskPath`; o instalador aceita o nome com ou
sem as barras externas:

```powershell
& 'C:\TI\Scripts\WindowsServerBackup\Install-VMExportBackupTask.ps1' `
    -TaskPath '\ASSESSORIA SCF\' `
    -TaskName 'BACKUP-VM'
```

Ao mudar `TaskPath`, o instalador registra primeiro a nova tarefa e depois remove
outras cópias com o mesmo `TaskName`, evitando duas cascatas concorrentes. A pasta
do Agendador é independente da pasta física dos scripts. `Config`, `Logs`,
`Reports` e os helpers continuam sendo localizados relativamente ao
diretório do próprio script.

Plano de um tier:

```powershell
& 'C:\Scripts\WindowsServerBackup\Invoke-VMExportBackup.ps1' -BatchName SMALL
```

Execução direta:

```powershell
& 'C:\Scripts\WindowsServerBackup\Invoke-VMExportBackup.ps1' -BatchName SMALL -Execute
```

Cascata manual completa:

```powershell
& 'C:\Scripts\WindowsServerBackup\Invoke-CascadeBackup.ps1'
```

Testes no diretório do projeto:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-Tests.ps1
```

Para incluir o teste de recuperação com um arquivo 7z real, defina `VMEXPORT_TEST_7ZIP` com o caminho absoluto de `7z.exe` ou `7zr.exe` antes de executar a suíte. Sem essa variável, somente esse teste de integração é omitido; a suíte não baixa ferramentas.

## Empacotamento e release

Gerar localmente `dist\VM-Export-Backup-2.1.0.zip` e seu SHA-256:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Package.ps1
```

`Package.ps1` exige que `VERSION`, o parâmetro `-Version` e `$ScriptVersion` sejam iguais. O ZIP contém os arquivos de instalação, documentação e licença MIT; testes, workflow e ferramentas de desenvolvimento ficam fora. As notas da versão estão em [RELEASE-v2.1.0.md](docs/RELEASE-v2.1.0.md).

O workflow `.github/workflows/release.yml` não é CI: ele não executa testes. Ao receber uma tag `vMAJOR.MINOR.PATCH`, gera o pacote e usa o token padrão do GitHub para publicar uma release com ZIP, checksum e notas automáticas. A tag precisa existir no remoto; o workflow usa `--verify-tag`.

Preparar a versão localmente não faz push nem publica uma release. Após revisar o commit e a tag local `v2.1.0`, a publicação pode ser disparada manualmente pelo responsável:

```powershell
git push origin main
git push origin v2.1.0
```

## Restauração parcial

Cada `.7z` aprovado é um ponto restaurável independente. Para recuperar uma VM de uma noite parcialmente bem-sucedida, selecione seu arquivo em `Archives`, extraia-o para uma área separada e importe o `.vmcx` no Hyper-V usando a opção de copiar e gerar novo identificador. Para teste, conecte primeiro a um switch isolado. O procedimento completo está no runbook.
