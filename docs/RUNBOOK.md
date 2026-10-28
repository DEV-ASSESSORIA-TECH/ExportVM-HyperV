# RUNBOOK — VM Export Backup v2.1.0

Guia de operação, diagnóstico e recuperação. A arquitetura e os parâmetros estão em [README.md](../README.md).

## Estrutura da instalação

Na raiz ficam somente os três scripts de entrada: `Invoke-CascadeBackup.ps1`,
`Invoke-VMExportBackup.ps1` e `Install-VMExportBackupTask.ps1`. Os auxiliares ficam
em `Internal\Helpers` e os processos de exportação/hash em `Internal\Workers`.
Copie sempre a pasta `Internal` junto com os scripts. `Config`, `Logs`, `Reports`
continuam na raiz da instalação, e os comandos da tarefa permanecem iguais. O
bloqueio ativo fica no repositório, em `.VMExportBackup.lock`; a pasta local `Locks`
antiga deixa de ser usada.

Para atualizar a estrutura antiga, siga as instruções de atualização no README,
preservando a configuração local e removendo apenas as cópias antigas dos auxiliares
da raiz depois de conferir os novos arquivos internos.

## Checklist matinal

### 1. Conferir a tarefa

```powershell
Get-ScheduledTaskInfo -TaskName 'Backup Hyper-V - Cascata Noturna'
```

Se a tarefa estiver em uma pasta personalizada:

```powershell
Get-ScheduledTask -TaskPath '\ASSESSORIA SCF\' -TaskName 'BACKUP-VM' |
    Get-ScheduledTaskInfo
```

`LastTaskResult`:

- `0`: sucesso sem avisos;
- `1`: houve falha de backup em algum tier;
- `2`: backups concluídos, mas houve aviso ou falha de observabilidade.

O wrapper continua os tiers posteriores mesmo que um anterior falhe.

`SKIPPED` indica lote sem VMs elegíveis, com justificativa no consolidado. Se todos
os lotes forem ignorados, a cascata também fica `SKIPPED` (código 0, ou 2 com avisos).
As exclusões por nome/VMId são aplicadas antes dos discos no plano único da noite,
salvo em `Reports\Cascade-<BackupSetId>.plan.json`. Confira os avisos de exclusões
ausentes; eles geram e-mail de aviso mesmo quando os backups restantes têm sucesso.
O VMId pode ser consultado com `Get-VM | Select-Object Name, VMId`.

### Pasta personalizada no Agendador

A pasta lógica do Agendador é independente da pasta física da instalação. Para
instalar em uma pasta já existente:

```powershell
& 'C:\TI\Scripts\WindowsServerBackup\Install-VMExportBackupTask.ps1' `
    -TaskPath '\ASSESSORIA SCF\' `
    -TaskName 'BACKUP-VM'
```

O padrão de `TaskPath` é a raiz (`\`). O valor também pode ser informado como
`ASSESSORIA SCF`; o instalador normaliza as barras. Quando uma tarefa de mesmo
nome existir em outro caminho, a nova é registrada primeiro e a anterior é
removida depois. Confirme que a pasta personalizada já existe no Agendador.

### 2. Conferir o consolidado

```powershell
Get-ChildItem 'C:\Scripts\WindowsServerBackup\Reports\Cascade-*.json' |
    Where-Object { $_.Name -notmatch '\.plan\.json$' } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
```

Abra o JSON ou HTML correspondente e verifique `Status`, `TierExecutions`, `DiagnosticFailures`, `NotificationStatus`, `MailSent` e `MailError`. Cada tier também entrega `BackupSet-<id>-<tier>.result.json`.

### 3. Conferir o repositório

```powershell
Get-ChildItem 'F:\HyperV-Exports' -Directory |
    Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}-[0-9a-f]{8}$' } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 3 Name, LastWriteTime
```

Dentro do `BackupSetId`, cada tier publicado deve ter `Archives`, `Metadata` e o
checkpoint `PUBLISHED.marker.json` nas publicações da v2.1.0. Ele tem precedência
para descoberta. Ao final normal há também um dos marcadores de apresentação:

- `COMPLETE.marker.json`: todas as VMs do tier foram publicadas;
- `PARTIAL.marker.json`: publicação parcial; pode refletir falhas ou uma execução interrompida antes da conclusão.

O marcador e os resultados devem ter `SchemaVersion: 2`.
Os backups anteriores sem checkpoint continuam válidos pelos marcadores existentes.

### 4. Conferir staging e falhas

```powershell
Get-ChildItem 'F:\HyperV-Exports\_STAGING' -Directory -ErrorAction SilentlyContinue
Get-ChildItem 'F:\HyperV-Exports\_FAILED' -Directory -ErrorAction SilentlyContinue
```

`_STAGING` normalmente fica vazio fora da execução. Se houver registro em
`_PUBLISHING`, o staging correspondente deve permanecer até a reconciliação.
Staging sem publicação pendente é preservado na próxima execução em `_FAILED\_ORPHANED`.

### Publicação interrompida ou bloqueio ocupado

Confira `_PUBLISHING` antes de mover ou apagar qualquer staging. A próxima execução
real tenta completar automaticamente cada publicação aprovada, sob bloqueio exclusivo,
antes de iniciar novos backups. Tamanho, caminhos e SHA-256 (quando habilitado) são
verificados. O teste integral `7z t` é obrigatório na recuperação mesmo com SkipHash
habilitado, respeita IntegrityTimeoutHours e grava Logs/Recovery-*.stdout.log e *.stderr.log.
Divergências fazem a execução falhar e preservam os dados para inspeção.
Não remova registros para contornar uma falha de recuperação.

O arquivo `.VMExportBackup.lock` permanece depois do término; sua presença não indica
um lock preso. O bloqueio real é o handle exclusivo, liberado pelo Windows ao encerrar
o processo. Confira os processos ativos e os logs. Não apague o arquivo durante um backup.
Workers e seus descendentes pertencem a um Job Object e são encerrados se o dono morrer.
Antes de reutilizar o destino, o novo dono aguarda o grupo remanescente terminar.
Use um único host escritor por repositório; Job Objects são locais ao host.
Somente execuções reais adquirem o bloqueio; o plano não altera o repositório.

Um checkpoint parcial recuperado pode conter apenas as VMs publicadas antes da queda.
Use seus resultados para restaurar uma VM aprovada, sem interpretar esse estado como
confirmação de backup de todas as VMs daquela noite.

Em `_FAILED\<nome--VMId>\<ocorrência>`, `failure.json` é permanente até intervenção manual. `Payload` é pesado e sujeito à retenção de `FailedPayloadKeepPerVM` e à limpeza por pressão de espaço.

## Interpretação dos estados

### `SUCCESS`

Todas as VMs selecionadas foram publicadas e não houve aviso operacional.

### `SUCCESS_WITH_WARNINGS`

Os backups foram publicados, mas houve aviso ou falha não bloqueante, como log, JSON, HTML ou SMTP indisponível. Confirme `DiagnosticFailures`. Código 2 não significa perda dos arquivos publicados.

### `PARTIAL_SUCCESS`

Ao menos uma VM foi publicada e ao menos uma falhou. Os arquivos aprovados estão utilizáveis em `Archives`; somente a VM falha foi para `_FAILED`. Código 1.

### `FAILED`

Houve falha de backup ou erro fatal. Na cascata, indica que ao menos um lote falhou,
mesmo que outros tenham publicado backups válidos. Código 1. Lotes sem VMs elegíveis
usam `SKIPPED`, com justificativa no consolidado.

Falha de backup prevalece sobre falha de observabilidade: se ambas ocorrerem, o código continua 1.

## Diagnóstico por VM

No relatório do tier, localize a VM por `VMId` e confira:

- `CurrentStage` / `FailedStage`;
- `FailureKind`;
- `Retryable`;
- `Attempts`;
- `Error`;
- `ArchivePath` e `MetadataPath` para sucessos.

Falhas transitórias de processo, timeout, `Export-VM`, 7-Zip, hash ou I/O podem repetir conforme `RetryCount`. Configuração inválida, ferramenta ausente, volume incorreto, falta de espaço e estrutura inválida não aguardam nem repetem.

### Espaço insuficiente

Antes de cada VM o requisito exato é:

```text
MinFreeGB
```

Esse é um limite de admissão: a VM começa quando o espaço livre naquele instante é igual ou superior a `MinFreeGB`. O tamanho atual dos discos não altera o requisito e o consumo durante exportação ou compactação pode reduzir o espaço abaixo do mínimo até a avaliação da VM seguinte.

O fluxo aplica primeiro a retenção normal de `_FAILED`. Se ainda estiver abaixo do mínimo, soma o tamanho dos payloads protegidos elegíveis. Quando o total não cobre o déficit, não apaga nenhum deles e apenas a VM corrente falha. Quando pode cobrir, remove do mais antigo para o mais novo, mede o ganho real após cada exclusão e para ao atingir o mínimo, ao não recuperar espaço ou quando os restantes deixam de ser suficientes. Backups válidos mantidos nunca participam dessa limpeza.

### Falha estrutural

`7z t` é obrigatório. A listagem também precisa confirmar:

- formato 7z;
- pelo menos um VHD/VHDX/AVHD/AVHDX;
- pelo menos um `.vmcx`;
- tamanho descompactado igual ao diretório exportado.

Uma divergência estrutural é determinística e não deve ser retentada.

## E-mail

Na cascata, os processos de tier não enviam mensagens. Depois de executar todos, o wrapper pode enviar um único alerta consolidado. Falha abrupta do próprio wrapper antes do encerramento pode impedir esse e-mail; use o Agendador e os logs como fonte adicional.

Execuções diretas continuam podendo alertar imediatamente. Use `-SkipEmail` somente quando quiser suprimir conscientemente a notificação manual.

Os relatórios são gravados antes do anexo e regravados depois do SMTP com:

- `NotificationStatus`;
- `MailSent`;
- `MailError`.

## Restauração de uma VM publicada

Uma noite parcial não invalida as VMs aprovadas.

1. Localize o resultado pelo `VMId` completo em `PUBLISHED.marker.json`; para backups anteriores sem checkpoint, use o marcador `COMPLETE` ou `PARTIAL` do tier.
2. Confirme que `Success` é `true` e obtenha o path relativo `Archive`.
3. Copie o `.7z` para uma área de restauração fora do repositório ativo.
4. Execute opcionalmente um novo `7z t` antes de extrair.
5. Extraia todo o conteúdo.
6. Localize o `.vmcx`.
7. No Hyper-V, escolha **Importar Máquina Virtual**.
8. Para teste, escolha copiar a VM e gerar um novo identificador.
9. Conecte a VM restaurada a um switch isolado antes de ligar.
10. Valide boot, serviços e aplicação; depois descarte ou promova conforme o procedimento do ambiente.

Se SHA-256 estava habilitado naquele backup, compare o valor do relatório. Com `SkipHash: true`, use o `7z t` e o procedimento de restauração; não presuma a existência de hash.

## Retenção e exclusão

- Backups válidos são agrupados pelo `VMId` completo através de nomes, noites e tiers.
- A remoção válida exclui o `.7z` e os metadados daquela VM juntos.
- Tier e `BackupSetId` só desaparecem quando vazios.
- Todos os `failure.json` são preservados; somente `Payload` é limpo automaticamente.
- Não existe `_AUDIT`; exclusões ficam em logs, relatórios e no próprio `failure.json`.

## Alteração segura de configuração

Depois de editar os JSONs:

```powershell
Get-Content 'C:\Scripts\WindowsServerBackup\Config\Tiers.json' -Raw | ConvertFrom-Json | Out-Null
Get-Content 'C:\Scripts\WindowsServerBackup\Config\Settings.json' -Raw | ConvertFrom-Json | Out-Null
```

No clone do repositório de código, e não no pacote enxuto de produção, execute também:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\scripts\Invoke-Tests.ps1'
```

Reexecute `Install-VMExportBackupTask.ps1` após mudar horário ou limite da cascata.
