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

Este documento é a referência técnica (arquitetura, configuração, formatos de arquivo). Para o dia a dia (checklist matinal, leitura de log, o que fazer se algo falhar) use o [RUNBOOK.md](RUNBOOK.md). Para o histórico de versões e os números da validação em produção, veja o [CHANGELOG.md](CHANGELOG.md). Para comandos rápidos de instalação/teste, veja o [LEIA-ME.txt](LEIA-ME.txt).

---

## Versão atual

```text
Invoke-VMExportBackup.ps1 v1.2.0
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

A versão 1.1.0 adiciona (validada em produção em 2026-08-05/06 — ver "Status atual" e [CHANGELOG.md](CHANGELOG.md)):

- classificação automática de VM em lote por tamanho lógico do disco (`Config\Tiers.json`), sem lista fixa de VMs por lote;
- parâmetros gerais migrados para `Config\Settings.json` (sobrescrevíveis por linha de comando, que sempre tem prioridade);
- retenção (`KeepRestorePoints`) aplicada de forma independente por lote, em vez de um contador compartilhado;
- limpeza automática de diretórios de staging órfãos deixados por uma execução interrompida à força;
- e-mail enviado apenas quando o lote termina em `FAILED`/`PARTIAL_FAILED` — sucesso e plano ficam silenciosos;
- `Install-VMExportBackupTask.ps1` cria uma tarefa agendada por lote automaticamente, a partir de `Config\Tiers.json`.

A versão 1.2.0 adiciona (motivada pela cascata da v1.1.0 ter terminado perto demais do horário de expediente):

- **cascata real**: uma única tarefa agendada (`Invoke-CascadeBackup.ps1`), disparando uma vez por noite, roda SMALL → MEDIUM → BIG em sequência — cada lote começa assim que o anterior termina, em vez de três horários fixos independentes;
- **agrupamento por noite**: os três lotes de uma mesma cascata compartilham uma assinatura (`CascadeId`) e publicam dentro da mesma pasta na raiz do repositório, nomeada com o dia de início da cascata (ver "Destino do backup");
- `Config\Tiers.json` schema v2: `ScheduleTime`/`ExecutionTimeLimitHours` por lote deram lugar a `CascadeStartTime`/`CascadeExecutionTimeLimitHours` no nível raiz do arquivo;
- `Install-VMExportBackupTask.ps1` passa a criar **uma única tarefa** (não mais uma por lote), e remove automaticamente as tarefas do modelo antigo (v1.1.0) se existirem no host.

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
16. Publica o ponto somente quando todas as VMs do lote terminam com sucesso, dentro da pasta compartilhada da cascata (`-CascadeId`) quando informado, ou de uma pasta própria em execuções manuais/avulsas.
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
| `Invoke-CascadeBackup.ps1` | Wrapper da cascata noturna: gera o `CascadeId` compartilhado e roda os lotes em sequência, um processo por vez |
| `Install-VMExportBackupTask.ps1` | Cria a tarefa agendada única (cascata) como `SYSTEM`, a partir de `Config\Tiers.json`; migra tarefas do modelo antigo se existirem |
| `Config\Tiers.json` | Limiares de tamanho e retenção por lote, horário/teto de tempo da cascata (`CascadeStartTime`/`CascadeExecutionTimeLimitHours`) |
| `Config\Settings.json` | Parâmetros gerais (drive, timeouts, SMTP etc.), sobrescrevíveis por linha de comando |

---

## Diretório de instalação

Copie a pasta inteira (os seis scripts `.ps1` **e** a pasta `Config\` com `Tiers.json`/`Settings.json`) para:

```text
C:\Scripts\WindowsServerBackup
```

Eles podem coexistir com scripts antigos do Windows Server Backup, mas não utilizam o WSB. Sem a pasta `Config\`, `Invoke-VMExportBackup.ps1` roda em modo legado (sem lotes, exige `-VMName` ou processa todas as VMs) e `Install-VMExportBackupTask.ps1` recusa a rodar — ambos exigem `TierHelpers.ps1` presente.

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
├── 2026-08-06_CASCATA_a1b2c3d4\
│   ├── SMALL\
│   │   ├── Archives\
│   │   │   ├── SRV-AD.7z
│   │   │   ├── SRV-DOCS.7z
│   │   │   └── ...
│   │   ├── Metadata\
│   │   │   ├── HostInventory.json
│   │   │   └── logs por VM
│   │   └── COMPLETE.marker.json
│   ├── MEDIUM\
│   │   └── ...
│   └── BIG\
│       └── ...
└── ...
```

A pasta de primeiro nível é a **pasta da cascata** — uma por noite, nomeada com o dia em que a cascata começou e uma assinatura (`CascadeId`) compartilhada pelos três lotes daquela execução (ver "Instalação como tarefa agendada"). Dentro dela, cada lote mantém sua própria subpasta (`SMALL`/`MEDIUM`/`BIG`), cada uma com seu `Archives`/`Metadata`/`COMPLETE.marker.json` — os três continuam sendo processos isolados (retry, falha e relatório independentes por lote); só a pasta pai é compartilhada.

Execuções manuais/avulsas (sem passar por uma cascata) geram sua própria pasta de primeiro nível no mesmo padrão, rotulada `RUN` em vez de `CASCATA` (ex.: `2026-08-06_RUN_9f8e7d6c\BIG\`) — o layout aninhado é sempre o mesmo, com ou sem cascata real.

O `COMPLETE.marker.json` de cada lote grava `TierName` (o lote) e `CascadeId` (o nome da pasta da noite) — é o `TierName` que permite a retenção contar cada lote separadamente, independente de qual noite/cascata publicou o ponto (ver "Retenção por lote").

> Pontos publicados antes da v1.2.0 ficam num layout raso mais antigo (a própria pasta de primeiro nível já é o ponto, sem subpasta por lote) e continuam funcionando normalmente — retenção e limpeza reconhecem os dois layouts.

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

Os pontos válidos ficam em:

```text
F:\HyperV-Exports\<AAAA-MM-DD>_CASCATA_<assinatura>\<LOTE>\
```

e cada subpasta de lote contém:

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
    'C:\Scripts\WindowsServerBackup\TierHelpers.ps1',
    'C:\Scripts\WindowsServerBackup\Invoke-CascadeBackup.ps1'
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

Cada execução classifica automaticamente todas as VMs do host pelo tamanho lógico atual do disco, usando os limiares definidos em `Config\Tiers.json` — não é preciso atualizar nada quando uma VM é criada ou removida do host.

Configuração atual (ajustável no arquivo, sem precisar editar nenhum script):

```json
{
    "SchemaVersion": 2,
    "CascadeStartTime": "21:00",
    "CascadeExecutionTimeLimitHours": 20,
    "Tiers": [
        { "Name": "SMALL",  "MinSizeGB": 0,  "MaxSizeGB": 25,   "KeepRestorePoints": 3 },
        { "Name": "MEDIUM", "MinSizeGB": 25, "MaxSizeGB": 75,   "KeepRestorePoints": 3 },
        { "Name": "BIG",    "MinSizeGB": 75, "MaxSizeGB": null, "KeepRestorePoints": 3 }
    ],
    "DefaultTier": "SMALL"
}
```

`MinSizeGB` é inclusivo, `MaxSizeGB` é exclusivo (as faixas precisam ser contínuas, sem lacuna nem sobreposição — o script valida isso e recusa a rodar se `Tiers.json` estiver inconsistente). Os cortes atuais (25 GB e 75 GB) foram calibrados com os tamanhos reais observados nas execuções dos três lotes. Ajuste livremente conforme VMs forem adicionadas ou removidas do host.

`CascadeStartTime` é o horário único de disparo da cascata inteira (não mais um horário por lote — ver "Instalação como tarefa agendada"). `CascadeExecutionTimeLimitHours` é o teto de tempo para a cascata inteira (SMALL+MEDIUM+BIG somados); o valor atual (20h) reflete a duração real medida na validação de produção de 2026-08-05/06 (SMALL 0h32, MEDIUM 2h13, BIG 5h46, total 8h30 — ver [CHANGELOG.md](CHANGELOG.md)), com folga de mais de 2x sobre o observado.

---

## Instalação como tarefa agendada

```powershell
& "C:\Scripts\WindowsServerBackup\Install-VMExportBackupTask.ps1"
```

**Roda uma única vez**, como administrador. Nessa execução ele:

1. Lê `Config\Tiers.json`.
2. Conta quantas VMs caem em cada lote hoje e loga (informativo, não bloqueante) a soma do pior caso teórico por lote comparada ao `CascadeExecutionTimeLimitHours` configurado.
3. Cria/atualiza **uma única tarefa** no Agendador de Tarefas do Windows (`Backup Hyper-V - Cascata Noturna`), com gatilho **diário recorrente** em `CascadeStartTime`, apontando para `Invoke-CascadeBackup.ps1`, rodando como `SYSTEM`, com `ExecutionTimeLimit` = `CascadeExecutionTimeLimitHours`.
4. Remove automaticamente as tarefas do modelo antigo (uma por lote, v1.1.0) se ainda existirem no host — evita rodar os dois modelos em paralelo, competindo pelo mesmo lock.

Depois dessa execução, o Agendador do Windows dispara `Invoke-CascadeBackup.ps1` uma vez por noite, sem precisar rodar o instalador de novo — só é preciso rodá-lo outra vez se `Tiers.json` mudar (novo lote, lote removido, horário ou teto de tempo diferente, retenção diferente).

**Como a cascata funciona de fato**: `Invoke-CascadeBackup.ps1` gera uma assinatura (`CascadeId`) uma única vez, e roda cada lote definido em `Tiers.json`, na ordem em que aparecem (`MinSizeGB` ascendente — hoje SMALL → MEDIUM → BIG), como um processo `powershell.exe` separado por vez, esperando cada um terminar antes de iniciar o próximo — diferente da v1.1.0, aqui não há mais horários fixos independentes por lote nem risco de colisão de lock entre eles (é sempre um de cada vez, garantido pelo próprio wrapper, não só por espaçamento de horário). Uma falha num lote não impede os seguintes de rodar; cada lote continua alertando por e-mail individualmente.

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

Esse tipo de execução conta como o lote `ADHOC`, com retenção própria (usa o `KeepRestorePoints` geral de `Config\Settings.json`, já que não corresponde a nenhum lote real de `Tiers.json`). Execuções manuais (com `-BatchName` ou `-VMName`, fora da cascata) não usam `-CascadeId` — o script gera sua própria pasta de primeiro nível (rótulo `RUN`, ver "Destino do backup").

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

Cada lote tem sua própria contagem de retenção, definida em `Config\Tiers.json` (`KeepRestorePoints`). Um ponto publicado pelo lote `BIG` nunca é contado nem removido pela retenção do lote `MEDIUM` ou `SMALL` — cada um mantém seus próprios pontos completos mais recentes, independente dos outros e independente de em qual pasta de cascata/noite ele está.

A busca por pontos reconhece os dois layouts: pastas de primeiro nível que já são o ponto (`COMPLETE.marker.json` direto — layout anterior à v1.2.0) e pastas de primeiro nível que são uma cascata/noite (sem marcador direto, com subpastas por lote — layout atual). Em ambos os casos, o lote de cada ponto é lido do `TierName` gravado no marcador, não da posição no disco. Ao apagar o último lote restante de uma pasta de cascata, a pasta vazia também é removida.

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
- `CascadeExecutionTimeLimitHours` está fixado com base na duração real observada (ver [CHANGELOG.md](CHANGELOG.md)). Se o parque de VMs crescer bastante, reavalie esse valor — o comparativo informativo que o instalador imprime (soma do pior caso teórico por lote) ajuda a perceber se o teto configurado ficou apertado demais.
- Depois de mudar `Tiers.json` (horário, teto de tempo, lotes), rode `Install-VMExportBackupTask.ps1` de novo para a tarefa agendada refletir a mudança.

---

## Status atual

```text
Fluxo principal (v1.0.5): validado
Checkpoint Linux: validado
Classificação automática por tamanho (v1.1.0): validado em produção (2026-08-05/06, 17/17 VMs, 3/3 lotes)
Retenção por lote (v1.1.0): validado em produção (cada lote manteve seu próprio ponto, 0 remoções indevidas)
Limpeza de staging órfão (v1.1.0): implementado, sem caso real acionado ainda
E-mail apenas em falha (v1.1.0): validado em produção (3 sucessos, 3 execuções silenciosas, 0 chamados abertos)
Cascata real via Invoke-CascadeBackup.ps1 (v1.2.0): implementada, pendente de validação em produção
Agrupamento por noite (CascadeId, pasta compartilhada) (v1.2.0): implementado, pendente de validação em produção
Instalador de tarefa unica + migração do modelo antigo (v1.2.0): implementado, pendente de instalação em produção
Restauração completa de teste: pendente
```

Detalhes da validação de produção (durações reais, tamanhos, taxa de compactação) em [CHANGELOG.md](CHANGELOG.md). Checklist do dia a dia em [RUNBOOK.md](RUNBOOK.md).
