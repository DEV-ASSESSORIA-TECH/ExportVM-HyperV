# VM Export Backup v2.0.2

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

O conteúdo de `src/` permanece coeso: no pacote publicado, seus scripts são colocados na raiz e `Config/` continua ao lado deles, preservando os paths usados em produção.

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

## Layout schema 2

```text
F:\HyperV-Exports\
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
    │   └── COMPLETE.marker.json
    ├── MEDIUM\
    │   └── PARTIAL.marker.json
    └── BIG\
        └── ...
```

O nome visível usa `<nome-seguro>--<VMId-curto>`. O manifest grava o `VMId` completo, que é a identidade usada na retenção. Renomear uma VM ou movê-la de tier não cria um novo histórico de retenção.

Um tier com todas as VMs aprovadas recebe `COMPLETE.marker.json`. Se ao menos uma VM for publicada e outra falhar, recebe `PARTIAL.marker.json`. Ambos usam `SchemaVersion: 2`.

## Estados e códigos

| Estado | Código | Significado |
|---|---:|---|
| `SUCCESS` | 0 | Todas as VMs aprovadas, sem avisos operacionais |
| `SUCCESS_WITH_WARNINGS` | 2 | Backups aprovados, mas houve aviso ou falha de observabilidade |
| `PARTIAL_SUCCESS` | 1 | Ao menos uma VM publicada e ao menos uma VM falhou |
| `FAILED` | 1 | Nenhuma VM válida foi publicada, tier vazio ou erro fatal |
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

`Config\Tiers.json` usa schema 2 e define faixas contínuas de tamanho, retenção, `CascadeStartTime` e `CascadeExecutionTimeLimitHours`. O início padrão permanece às 21:00.

## Retry

São retentáveis: timeout/processo, `Export-VM`, 7-Zip, hash opcional e I/O transitório. Não são retentáveis: configuração inválida, ferramenta ausente, volume/label/saúde, falta de espaço e estrutura inválida. `RetryCount` continua configurável; a espera de 60 segundos só ocorre quando uma nova tentativa transitória será feita.

## Relatórios e e-mail

- Execução direta: pode alertar imediatamente em `FAILED` ou `PARTIAL_SUCCESS`; `-SkipEmail` força silêncio.
- Cascata: cada tier usa `-DeferEmail` e grava um resultado determinístico em `Reports`; o wrapper executa todos os tiers e envia no máximo um alerta consolidado.
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
`Reports`, `Locks` e os helpers continuam sendo localizados relativamente ao
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

## Empacotamento e release

Gerar localmente `dist\VM-Export-Backup-2.0.2.zip` e seu SHA-256:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Package.ps1
```

`Package.ps1` exige que `VERSION`, o parâmetro `-Version` e `$ScriptVersion` sejam iguais. O ZIP contém somente os arquivos de instalação e documentação; testes, workflow e ferramentas de desenvolvimento ficam fora.

O workflow `.github/workflows/release.yml` não é CI: ele não executa testes. Ao receber uma tag `vMAJOR.MINOR.PATCH`, gera o pacote e usa o token padrão do GitHub para publicar uma release com ZIP, checksum e notas automáticas. A tag precisa existir no remoto; o workflow usa `--verify-tag`.

Para esta versão, depois do commit local:

```powershell
git push origin main
git push origin v2.0.2
```

## Restauração parcial

Cada `.7z` aprovado é um ponto restaurável independente. Para recuperar uma VM de uma noite parcialmente bem-sucedida, selecione seu arquivo em `Archives`, extraia-o para uma área separada e importe o `.vmcx` no Hyper-V usando a opção de copiar e gerar novo identificador. Para teste, conecte primeiro a um switch isolado. O procedimento completo está no runbook.

## Compatibilidade com versões anteriores

O v2.0 descobre, retém e remove somente schema 2. Pastas antigas da linha 1.x com `_CASCATA_`, `_RUN_` ou marcadores sem `SchemaVersion: 2` ficam totalmente fora da automação: não são migradas, contadas ou apagadas. Faça backup e remoção manual desses layouts antes da ativação em produção.
