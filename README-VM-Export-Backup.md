# VM Export Backup

## Visão geral

O **VM Export Backup** é uma solução temporária de backup completo para ambientes Hyper-V.

Ele substitui provisoriamente o Windows Server Backup por um fluxo mais previsível, rastreável e validado, baseado em:

- `Export-VM`;
- compactação individual com 7-Zip;
- teste integral dos arquivos;
- validação estrutural do conteúdo;
- cálculo de SHA-256;
- publicação atômica;
- retenção aplicada somente após sucesso;
- geração de logs e relatórios.

> Esta solução é uma contingência de exportação completa. Ela não é incremental e não substitui permanentemente plataformas como Veeam ou Acronis.

---

## Versão atual

```text
Invoke-VMExportBackup.ps1 v1.1.0
```

A versão 1.0.5 já foi validada com:

- VM desligada;
- VM Linux ligada;
- checkpoint de produção;
- múltiplas VMs na mesma execução;
- compactação individual;
- teste integral com `7z t`;
- validação estrutural do arquivo;
- conferência do tamanho descompactado;
- cálculo de SHA-256;
- publicação do ponto completo;
- retenção após sucesso;
- heartbeat em operações longas.

A versão 1.1.0 adiciona (pendente de validação em produção — ver "Status atual"):

- classificação automática de VM em lote por tamanho lógico do disco (`Config\Tiers.json`), sem lista fixa de VMs por lote;
- parâmetros gerais migrados para `Config\Settings.json` (sobrescrevíveis por linha de comando, que sempre tem prioridade);
- retenção (`KeepRestorePoints`) aplicada de forma independente por lote, em vez de um contador compartilhado;
- limpeza automática de diretórios de staging órfãos deixados por uma execução interrompida à força;
- e-mail enviado apenas quando o lote termina em `FAILED`/`PARTIAL_FAILED` — sucesso e plano ficam silenciosos;
- `Install-VMExportBackupTask.ps1` cria uma tarefa agendada por lote automaticamente, a partir de `Config\Tiers.json`.

---

## Funcionamento

A rotina executa as seguintes etapas:

1. Carrega `Config\Settings.json` (se existir) e aplica os valores como default, sem nunca sobrescrever um parâmetro passado explicitamente na linha de comando.
2. Carrega `Config\Tiers.json` e resolve o lote da execução (`-BatchName`, `-VMName` avulso vira o lote `ADHOC`, ou erro se nenhum dos dois for informado com `Tiers.json` presente).
3. Valida o host, o disco de destino e as ferramentas.
4. Confirma o rótulo do volume de backup.
5. Remove tentativas falhas expiradas e diretórios de staging órfãos deixados por uma execução anterior interrompida à força.
6. Classifica cada VM do host pelo tamanho lógico atual do disco e seleciona apenas as VMs do lote resolvido (ou a lista de `-VMName`, quando informada).
7. Exporta uma VM por vez.
8. Usa estado consistente com aplicações quando suportado.
9. Compacta cada VM em um arquivo `.7z` separado.
10. Testa integralmente cada arquivo com `7z t`.
11. Valida a estrutura interna do arquivo.
12. Confirma a existência de discos virtuais e arquivo `.vmcx`.
13. Compara o tamanho exportado com o tamanho listado pelo 7-Zip.
14. Calcula SHA-256, salvo quando `-SkipHash` for utilizado.
15. Remove a exportação temporária após validação.
16. Publica o ponto somente quando todas as VMs do lote terminam com sucesso.
17. Aplica a retenção própria do lote (`KeepRestorePoints` de `Tiers.json`) somente depois da publicação.
18. Gera log, JSON e HTML, com o nome do lote em destaque.
19. Envia e-mail apenas quando o lote termina em falha (`FAILED`/`PARTIAL_FAILED`).
20. Exibe heartbeat a cada 30 segundos durante operações longas.

---

## Arquivos

| Arquivo | Função |
|---|---|
| `Invoke-VMExportBackup.ps1` | Script principal |
| `Export-VMWorker.ps1` | Worker isolado para `Export-VM` |
| `Get-FileHashWorker.ps1` | Worker isolado para SHA-256 |
| `TierHelpers.ps1` | Funções compartilhadas de lote: carregamento/validação de `Tiers.json`, tamanho lógico da VM, cálculo de timeout por lote |
| `Install-VMExportBackupTask.ps1` | Cria uma tarefa agendada por lote como `SYSTEM`, a partir de `Config\Tiers.json` |
| `Config\Tiers.json` | Limiares de tamanho, retenção e horário de agendamento de cada lote |
| `Config\Settings.json` | Parâmetros gerais (drive, timeouts, SMTP etc.), sobrescrevíveis por linha de comando |

---

## Diretório de instalação

Copie os quatro scripts para:

```text
C:\Scripts\WindowsServerBackup
```

Eles podem coexistir com scripts antigos do Windows Server Backup, mas não utilizam o WSB.

---

## Destino do backup

```text
F:\HyperV-Exports
```

Estrutura esperada:

```text
F:\HyperV-Exports\
├── _STAGING\
├── _FAILED\
├── 2026-08-05_00-30-00_SMALL_1234abcd\
│   ├── Archives\
│   │   ├── SRV-AD.7z
│   │   ├── SRV-DOCS.7z
│   │   └── ...
│   ├── Metadata\
│   │   ├── HostInventory.json
│   │   └── logs por VM
│   ├── Working\
│   └── COMPLETE.marker.json
└── ...
```

O nome do ponto de restauração inclui o nome do lote (`SMALL`/`MEDIUM`/`BIG`/`ADHOC`), e o `COMPLETE.marker.json` grava esse mesmo nome em `TierName` — é isso que permite a retenção contar cada lote separadamente (ver "Retenção por lote").

### `_STAGING`

Área temporária usada enquanto o conjunto está em processamento.

Um ponto ainda localizado em `_STAGING` não deve ser tratado como backup completo.

### `_FAILED`

Recebe conjuntos que falharam ou foram interrompidos.

Esses conjuntos:

- não são publicados;
- não contam para retenção;
- podem ser analisados antes da remoção.

### Pontos completos

Os pontos válidos ficam diretamente em:

```text
F:\HyperV-Exports\AAAA-MM-DD_HH-MM-SS-xxxxxxxx
```

e contêm:

```text
COMPLETE.marker.json
```

> O script não utiliza nem altera `F:\WindowsImageBackup`.

---

## Pré-requisitos

### No host Hyper-V

1. Windows PowerShell executado como administrador.
2. Módulo Hyper-V disponível.
3. 7-Zip instalado em:

```text
C:\Program Files\7-Zip\7z.exe
```

4. Disco de backup montado como:

```text
F:
```

5. Rótulo esperado:

```text
BACKUP-HYPERV
```

6. Nenhuma tarefa antiga executando scripts conflitantes.

### Nas VMs Linux

Para exportação consistente de VMs Linux ligadas, o serviço abaixo deve estar instalado e ativo:

```text
hv-vss-daemon.service
```

Pacotes utilizados no Ubuntu:

```bash
sudo apt-get update

sudo apt-get install -y \
  linux-cloud-tools-virtual \
  "linux-cloud-tools-$(uname -r)"

sudo systemctl daemon-reload
sudo systemctl enable --now hv-vss-daemon.service
```

Validação:

```bash
systemctl is-enabled hv-vss-daemon.service
systemctl is-active hv-vss-daemon.service
```

Saída esperada:

```text
enabled
active
```

Depois da instalação ou atualização de kernel, pode ser necessário reiniciar a VM.

---

## Checkpoint de produção

As VMs de produção devem permanecer configuradas para checkpoint de produção.

Exemplo:

```powershell
Set-VM `
    -Name "SRV-VPN" `
    -CheckpointType ProductionOnly
```

Teste manual:

```powershell
$vmName = "SRV-VPN"
$checkpointName = "DIAG-PRODUCTION-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

try {
    Checkpoint-VM `
        -Name $vmName `
        -SnapshotName $checkpointName `
        -ErrorAction Stop

    Write-Host "Checkpoint de produção criado com sucesso." `
        -ForegroundColor Green
}
finally {
    Get-VMSnapshot `
        -VMName $vmName `
        -Name $checkpointName `
        -ErrorAction SilentlyContinue |
        Remove-VMSnapshot `
            -Confirm:$false `
            -ErrorAction SilentlyContinue
}
```

---

## Limite de CPU do 7-Zip

O 7-Zip pode utilizar todos os processadores disponíveis quando configurado com:

```text
-mmt=on
```

No host atual, foi adotado temporariamente:

```text
-mmt=8
```

Isso limita a compactação a oito threads e mantém o uso total do host em um nível mais adequado para o ambiente Hyper-V.

A configuração está dentro do script principal, nos argumentos de compactação do 7-Zip.

---

## Validação de sintaxe

```powershell
$files = @(
    'C:\Scripts\WindowsServerBackup\Invoke-VMExportBackup.ps1',
    'C:\Scripts\WindowsServerBackup\Export-VMWorker.ps1',
    'C:\Scripts\WindowsServerBackup\Get-FileHashWorker.ps1',
    'C:\Scripts\WindowsServerBackup\Install-VMExportBackupTask.ps1',
    'C:\Scripts\WindowsServerBackup\TierHelpers.ps1'
)

foreach ($file in $files) {
    $tokens = $null
    $errors = $null

    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file,
        [ref]$tokens,
        [ref]$errors
    )

    [pscustomobject]@{
        File   = $file
        Errors = $errors.Count
    }

    $errors
}
```

O esperado é:

```text
Errors = 0
```

---

# Lotes automáticos por tamanho

A partir da v1.1.0 os lotes deixaram de ser listas fixas de VM mantidas à mão. Cada execução classifica automaticamente todas as VMs do host pelo tamanho lógico atual do disco, usando os limiares definidos em `Config\Tiers.json` — não é preciso atualizar nada quando uma VM é criada ou removida do host.

Configuração atual (ajustável no arquivo, sem precisar editar nenhum script):

```json
{
    "Tiers": [
        { "Name": "SMALL",  "MinSizeGB": 0,  "MaxSizeGB": 25,   "KeepRestorePoints": 3, "ScheduleTime": "00:30" },
        { "Name": "MEDIUM", "MinSizeGB": 25, "MaxSizeGB": 75,   "KeepRestorePoints": 3, "ScheduleTime": "06:00" },
        { "Name": "BIG",    "MinSizeGB": 75, "MaxSizeGB": null, "KeepRestorePoints": 3, "ScheduleTime": "12:00" }
    ],
    "DefaultTier": "SMALL"
}
```

`MinSizeGB` é inclusivo, `MaxSizeGB` é exclusivo (as faixas precisam ser contínuas, sem lacuna nem sobreposição — o script valida isso e recusa a rodar se `Tiers.json` estiver inconsistente). Os cortes atuais (25 GB e 75 GB) foram calibrados com os tamanhos reais observados nas primeiras execuções dos três lotes manuais. Ajuste livremente conforme VMs forem adicionadas ou removidas do host.

---

## Instalação como tarefa agendada (recomendado)

```powershell
& "C:\Scripts\WindowsServerBackup\Install-VMExportBackupTask.ps1"
```

Cria/atualiza uma tarefa agendada por lote (`Backup Hyper-V - Lote SMALL`, `Backup Hyper-V - Lote MEDIUM`, `Backup Hyper-V - Lote BIG`), cada uma disparando no horário definido em `Tiers.json` e já com e-mail de falha habilitado (sem `-SkipEmail`). O `ExecutionTimeLimit` de cada tarefa é calculado a partir do pior caso teórico (VMs do lote × tentativas × timeouts configurados); se o valor calculado parecer alto demais, fixe um `ExecutionTimeLimitHours` mais realista por lote em `Tiers.json` depois de observar a duração real nos logs.

Rodar o instalador de novo depois de mudar `Tiers.json` (adicionar, remover ou renomear um lote) atualiza as tarefas existentes e remove automaticamente as tarefas de lotes que não existem mais no config.

---

## Execução manual de um lote

```powershell
& "C:\Scripts\WindowsServerBackup\Invoke-VMExportBackup.ps1" -BatchName BIG -Execute
```

Troque `BIG` por `MEDIUM` ou `SMALL`. Sem `-Execute`, roda em modo PLAN — só mostra no log qual VM caiu em qual lote, sem exportar nada.

## Execução manual de VMs específicas (fora do esquema de lotes)

```powershell
& "C:\Scripts\WindowsServerBackup\Invoke-VMExportBackup.ps1" -VMName "SRV-VPN","SRV-VoIP" -Execute
```

Esse tipo de execução conta como o lote `ADHOC`, com retenção própria (usa o `KeepRestorePoints` geral de `Config\Settings.json`, já que não corresponde a nenhum lote real de `Tiers.json`).

---

## Verificação de execução ativa

Antes de iniciar um novo lote:

```powershell
Test-Path "C:\Scripts\WindowsServerBackup\Locks\VMExportBackup.lock.json"
```

Saída esperada:

```text
False
```

Confirme também que não existe processo 7-Zip ativo:

```powershell
Get-Process 7z, 7zG -ErrorAction SilentlyContinue
```

Nenhuma saída é o esperado quando não há backup em execução.

---

## Monitoramento

Durante operações longas, o script exibe heartbeat:

```text
[WAIT] 7-Zip compactar SRV-AMANDA |
decorrido=01:07:30 |
PID=7616 |
CPU=31313.1s |
RAM=507,02 MB
```

Um processo saudável normalmente apresenta:

- heartbeat contínuo;
- CPU acumulada aumentando;
- PID estável;
- memória estável;
- atividade no disco de backup.

CPU acumulada crescendo indica que o processo continua trabalhando.

---

## Segurança

O fluxo adota as seguintes proteções:

- validação do rótulo do volume antes da gravação;
- lock contra duas execuções simultâneas;
- processamento sequencial das VMs;
- checkpoint de produção;
- arquivo temporário com extensão `.partial.7z`;
- teste integral antes da publicação;
- validação estrutural do arquivo;
- conferência do tamanho descompactado;
- hash SHA-256;
- publicação somente depois de sucesso completo;
- retenção somente após publicação;
- preservação do conjunto em `_FAILED` quando ocorre erro;
- arquivo individual por VM;
- limpeza automática de diretórios de staging órfãos deixados por uma execução interrompida à força (kill do Task Scheduler, queda de energia);
- retenção independente por lote, sem contador compartilhado entre BIG/MEDIUM/SMALL.

Uma falha em uma VM impede a publicação daquele lote, mas não altera pontos completos já existentes.

---

## SHA-256

O SHA-256 funciona como uma impressão digital do arquivo `.7z`.

Ele permite confirmar futuramente que o arquivo continua exatamente igual ao que foi validado no momento do backup.

O hash muda quando:

- qualquer byte do `.7z` é alterado;
- um arquivo é adicionado dentro do `.7z`;
- um arquivo interno é removido;
- o conteúdo é recompresso.

O hash não muda apenas por:

- renomear o `.7z`;
- mover o `.7z`;
- adicionar um arquivo ao lado dele;
- alterar o diretório onde ele está armazenado.

O SHA-256 não substitui:

- `7z t`;
- teste de restauração;
- validação de inicialização da VM.

---

## Restauração

Procedimento básico para teste:

1. Escolha o arquivo `.7z` da VM.
2. Extraia para um diretório alternativo.
3. Localize o arquivo `.vmcx`.
4. Abra o Gerenciador do Hyper-V.
5. Use **Importar Máquina Virtual**.
6. Escolha a opção de copiar a VM e gerar um novo identificador.
7. Conecte a VM importada a um switch isolado.
8. Inicie a VM.
9. Valide sistema operacional, serviços e aplicações.

A restauração deve ser testada periodicamente.

---

## Logs e relatórios

Diretórios:

```text
C:\Scripts\WindowsServerBackup\Logs
C:\Scripts\WindowsServerBackup\Reports
```

Arquivos gerados:

```text
VMExportBackup-AAAA-MM-DD_HH-MM-SS.log
VMExportBackup-AAAA-MM-DD_HH-MM-SS.json
VMExportBackup-AAAA-MM-DD_HH-MM-SS.html
```

---

## E-mail

A partir da v1.1.0 o e-mail para `suporte@assessoriatech.com` (integrado ao Tiflux, que abre um chamado a cada mensagem recebida) só é enviado quando o lote termina em `FAILED` ou `PARTIAL_FAILED`. Execuções `SUCCESS` e `PLAN` ficam completamente silenciosas — não geram chamado nenhum.

`-SkipEmail` passou a significar "forçar silêncio mesmo em falha", útil só para testes manuais onde uma falha é esperada e não deve virar chamado. As tarefas agendadas criadas por `Install-VMExportBackupTask.ps1` **não** usam `-SkipEmail`, de propósito — é isso que garante que uma falha noturna gere aviso.

---

## Retenção por lote

Cada lote tem sua própria contagem de retenção, definida em `Config\Tiers.json` (`KeepRestorePoints`). Um ponto publicado pelo lote `BIG` nunca é contado nem removido pela retenção do lote `MEDIUM` ou `SMALL` — cada um mantém seus próprios pontos completos mais recentes, independente dos outros.

Pontos completos publicados por versões do script anteriores à v1.1.0 (sem `TierName` no marcador) caem num grupo `LEGACY` à parte, com retenção baseada no `KeepRestorePoints` geral de `Config\Settings.json` — não são apagados por engano pela retenção de um lote real.

---

## Observações operacionais

- Não selecione texto na janela clássica do PowerShell durante a execução.
- O modo QuickEdit pode pausar o console.
- Prefira executar em janela sem interação.
- Não apague `_STAGING` durante uma execução ativa.
- Não apague arquivos `.avhdx` manualmente.
- Não execute dois lotes simultaneamente.
- Verifique espaço livre antes de iniciar.
- Mantenha os backups lógicos dos bancos de dados em paralelo.
- Ajuste `MinSizeGB`/`MaxSizeGB` em `Config\Tiers.json` conforme VMs forem adicionadas, removidas ou crescerem de tamanho no host.
- Depois de observar a duração real de cada lote nos logs, considere fixar um `ExecutionTimeLimitHours` realista por lote em `Tiers.json` — o valor calculado automaticamente pelo instalador é intencionalmente conservador (pode passar de 100h) e serve como teto de segurança, não como estimativa de duração.

---

## Status atual

```text
Fluxo principal (v1.0.5): validado
Checkpoint Linux: validado
Lote SMALL de teste: validado
Lote BIG: validado
Classificação automática por tamanho (v1.1.0): implementada, pendente de validação em producao
Retenção por lote (v1.1.0): implementada, pendente de validação em producao
Limpeza de staging órfão (v1.1.0): implementada, pendente de validação em producao
E-mail apenas em falha (v1.1.0): implementado, pendente de validação em producao
Agendamento por lote via instalador (v1.1.0): implementado, pendente de instalação em producao
Restauração completa de teste: pendente
```
