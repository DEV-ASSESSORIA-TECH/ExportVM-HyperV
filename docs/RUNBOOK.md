# RUNBOOK — VM Export Backup v2.0.1

Guia de operação, diagnóstico e recuperação. A arquitetura e os parâmetros estão em [README.md](../README.md).

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

Dentro do `BackupSetId`, cada tier publicado deve ter `Archives`, `Metadata` e exatamente um marcador:

- `COMPLETE.marker.json`: todas as VMs do tier foram publicadas;
- `PARTIAL.marker.json`: algumas VMs foram publicadas e outras falharam.

O marcador e os resultados devem ter `SchemaVersion: 2`.

### 4. Conferir staging e falhas

```powershell
Get-ChildItem 'F:\HyperV-Exports\_STAGING' -Directory -ErrorAction SilentlyContinue
Get-ChildItem 'F:\HyperV-Exports\_FAILED' -Directory -ErrorAction SilentlyContinue
```

`_STAGING` deve ficar vazio fora da execução. Staging interrompido é recuperado na próxima execução em `_FAILED\_ORPHANED`.

Em `_FAILED\<nome--VMId>\<ocorrência>`, `failure.json` é permanente até intervenção manual. `Payload` é pesado e sujeito à retenção de `FailedPayloadKeepPerVM` e à limpeza por pressão de espaço.

## Interpretação dos estados

### `SUCCESS`

Todas as VMs selecionadas foram publicadas e não houve aviso operacional.

### `SUCCESS_WITH_WARNINGS`

Os backups foram publicados, mas houve aviso ou falha não bloqueante, como log, JSON, HTML ou SMTP indisponível. Confirme `DiagnosticFailures`. Código 2 não significa perda dos arquivos publicados.

### `PARTIAL_SUCCESS`

Ao menos uma VM foi publicada e ao menos uma falhou. Os arquivos aprovados estão utilizáveis em `Archives`; somente a VM falha foi para `_FAILED`. Código 1.

### `FAILED`

Nenhuma VM válida foi publicada, o tier estava vazio ou ocorreu erro fatal. Código 1.

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
MinFreeGB + 2 × SourceBytes
```

O fluxo aplica a retenção normal de `_FAILED` e, se necessário, remove outros payloads falhos do mais antigo para o mais novo. Se ainda faltar espaço, apenas a VM corrente falha e a execução continua. Backups válidos mantidos não participam dessa limpeza.

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

1. Localize o resultado pelo `VMId` completo no marcador do tier.
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

## Migração da v1.2 ou anterior

Não existe migração automática. Antes da ativação:

1. pare/desabilite a tarefa antiga;
2. faça uma cópia dos backups que ainda precisam ser preservados;
3. remova manualmente layouts antigos quando estiver seguro;
4. instale todos os scripts/helpers e `Config\Settings.json` schema 2 juntos;
5. rode o plano e os testes;
6. execute um tier pequeno e valide restauração;
7. só então habilite a cascata definitiva.

O v2.0 ignora integralmente layouts 1.x com nomes `_CASCATA_`, `_RUN_` e marcadores sem schema 2. Eles não contam para retenção e nunca são apagados pelo código novo.
