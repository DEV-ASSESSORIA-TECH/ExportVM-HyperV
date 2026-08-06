# RUNBOOK — Operação diária do VM Export Backup

Guia prático para quem confere o backup no dia a dia. Para arquitetura/configuração completa veja [README-VM-Export-Backup.md](README-VM-Export-Backup.md); para histórico de versões, [CHANGELOG.md](CHANGELOG.md).

---

## Checklist matinal

Depois que a tarefa da cascata (`Backup Hyper-V - Cascata Noturna`) estiver instalada (ver README, "Instalação como tarefa agendada"), confira todo dia:

**1. A cascata rodou e terminou sem erro fatal:**

```powershell
Get-ScheduledTaskInfo -TaskName 'Backup Hyper-V - Cascata Noturna'
```

Olhe `LastRunTime` (bate com `CascadeStartTime`?) e `LastTaskResult` (`0` = todos os lotes terminaram com `ExitCode=0`; `1` = pelo menos um lote teve problema — isso não substitui olhar o log de cada lote, só dá o resumo mais rápido). O wrapper também escreve seu próprio log leve em `Logs\Cascade-<timestamp>.log`, com início/fim/duração de cada lote — útil para ver rapidamente onde a cascata está ou até que horas ela foi ontem.

**2. Os relatórios foram gerados** (um conjunto de log/JSON/HTML por lote, todo dia):

```powershell
Get-ChildItem 'C:\Scripts\WindowsServerBackup\Reports' -Filter '*.json' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 3
```

Abra o `.json` mais recente de cada lote (ou o `.html`, mais legível) e confira `Status`:
- `SUCCESS` → tudo certo, nada mais a fazer.
- `FAILED` ou `PARTIAL_FAILED` → já deve ter chegado e-mail em `suporte@assessoriatech.com` (vira chamado no Tiflux). Veja "Cenários de falha" abaixo.
- Se não existe um relatório novo para algum lote no horário esperado → a cascata pode não ter disparado (host desligado no horário, tarefa desabilitada, etc.) — confira o Agendador de Tarefas diretamente, e o log do wrapper (`Logs\Cascade-*.log`) para ver até onde ele chegou.

**3. O ponto da noite foi publicado** em `F:\HyperV-Exports`:

```powershell
Get-ChildItem 'F:\HyperV-Exports' -Directory |
    Where-Object { $_.Name -notin @('_STAGING', '_FAILED') } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 3 Name, LastWriteTime
```

Deve aparecer uma pasta nova com `_CASCATA_` no nome (ex.: `2026-08-06_CASCATA_a1b2c3d4`). Dentro dela, três subpastas — `SMALL\`, `MEDIUM\`, `BIG\` — cada uma com seu próprio `Archives\` (um `.7z` por VM daquele lote) e `COMPLETE.marker.json`. Se uma das três estiver faltando, aquele lote específico não publicou (falhou ou ainda está rodando) — confira o relatório/log dele.

**4. `_FAILED` e `_STAGING` não estão acumulando lixo:**

```powershell
Get-ChildItem 'F:\HyperV-Exports\_FAILED' -Directory -ErrorAction SilentlyContinue
Get-ChildItem 'F:\HyperV-Exports\_STAGING' -Directory -ErrorAction SilentlyContinue
```

`_FAILED` guarda tentativas falhas por `FailedRetentionDays` (padrão 7 dias) antes de expurgar sozinho. `_STAGING` deve estar **vazio** fora do horário de execução dos lotes — qualquer diretório parado lá fora desses horários é órfão e será limpo automaticamente na próxima execução do lote correspondente (mas você pode investigar antes, veja abaixo).

---

## Como ler o log

Os logs (`Logs\VMExportBackup-AAAA-MM-DD_HH-MM-SS.log`) são verbosos de propósito. O que é **normal**, não indica problema:

```text
[WARNING] ExitCode do worker indisponivel; sucesso confirmado pelo JSON e pelos arquivos exportados.
[WARNING] ExitCode do 7-Zip indisponivel; conclusao confirmada pela saida 'Everything is Ok'.
```

Isso é uma peculiaridade do PowerShell 5.1 com processos redirecionados — o script já contorna isso confirmando sucesso por outra via (arquivo JSON do worker, ou a string `Everything is Ok` do 7-Zip). Não é falha.

O que **é** sinal real de problema:

```text
[ERROR] [SRV-XXX] Tentativa 1 falhou: <mensagem>
[ERROR] <mensagem de erro geral>
```

Toda linha `[ERROR]` é significativa. Se aparecer `Tentativa 1 falhou` seguida de `Nova tentativa em 60 segundos`, o script está retentando sozinho (`RetryCount` em `Settings.json`, padrão 1 nova tentativa) — só é um problema definitivo se a segunda tentativa também falhar e a VM aparecer como `Success = False` no relatório final.

Linhas `[WAIT]` são só heartbeat (a cada 30s) durante exportação/compactação/hash — úteis para confirmar que o processo está vivo e trabalhando (CPU acumulada crescendo, RAM estável).

---

## Cenários de falha

### `FAILED` vs `PARTIAL_FAILED`

- `FAILED`: erro antes ou durante o processamento que impediu a rotina de terminar normalmente (ex.: rótulo do volume errado, espaço insuficiente, uma exceção não tratada). Nenhum ponto novo é publicado.
- `PARTIAL_FAILED`: pelo menos uma VM do lote falhou depois de esgotar as tentativas, mas o script rodou até o fim. O conjunto inteiro (mesmo as VMs que deram certo) é movido para `_FAILED` — **não é publicado parcialmente**. As VMs que tiveram sucesso nessa tentativa não geram um `.7z` órfão utilizável isoladamente; rode o lote de novo depois de corrigir a causa.

Em ambos os casos, o `.7z` das VMs que já tinham sido processadas fica dentro de `_FAILED\<nome-do-ponto>\Archives\` — pode ser recuperado manualmente se for urgente, mas o fluxo oficial é corrigir e rodar o lote de novo.

**O que checar quando um lote falha:**
1. Abra o `.html` do relatório daquele lote — a seção "Motivo da falha" (quando existe) já mostra o erro no topo, sem precisar rolar.
2. Rótulo/volume errado → confira `Get-Volume -DriveLetter F` e compare com `ExpectedVolumeLabel` em `Config\Settings.json`.
3. Espaço insuficiente → confira `Get-Volume -DriveLetter F` (campo `SizeRemaining`) contra `MinFreeGB`.
4. Falha específica de uma VM (Export-VM, 7-Zip, hash) → a mensagem de erro no log já indica qual etapa falhou; geralmente é I/O, VM sem integration services atualizados, ou disco da VM inacessível no momento.

### Staging órfão

Se uma execução for morta à força (falta de energia, `Stop-Process`, Task Scheduler batendo no `ExecutionTimeLimit` da cascata), o diretório em `_STAGING` daquela execução fica órfão — sem lock ativo apontando pra ele. A **próxima** execução do mesmo lote detecta isso automaticamente (antes de começar seu próprio staging), move o órfão para `_FAILED` com um `ORPHANED.marker.json` e registra um aviso no log/relatório (`Warnings`). Não requer ação manual, mas vale investigar por que a execução anterior morreu (geralmente aponta pra um `CascadeExecutionTimeLimitHours` baixo demais em `Tiers.json` — ver README).

### Colisão de lock

Diferente da v1.1.0, os três lotes de uma cascata nunca competem entre si — `Invoke-CascadeBackup.ps1` só inicia o próximo depois que o anterior termina. A colisão de lock só deveria acontecer se alguém rodar um lote manualmente (`-BatchName`/`-VMName`) enquanto a cascata da noite ainda está em andamento. Nesse caso, a execução manual falha imediatamente com `Ja existe uma execucao ativa` e isso gera e-mail de falha. Verifique:

```powershell
Test-Path 'C:\Scripts\WindowsServerBackup\Locks\VMExportBackup.lock.json'
Get-Content 'C:\Scripts\WindowsServerBackup\Locks\VMExportBackup.lock.json' -ErrorAction SilentlyContinue
```

Se o lock existir mas o `Pid` registrado não corresponder a nenhum processo vivo (`Get-Process -Id <pid>` não retorna nada), é um lock travado de uma execução morta — a próxima execução de qualquer lote já limpa isso sozinha ao detectar que o PID não está mais ativo. Se quiser liberar na mão antes disso, confirme primeiro que não há mesmo nenhum `powershell.exe`/`7z.exe` do backup rodando, e só então apague o arquivo do lock.

---

## Teste de restauração

Repita periodicamente (não só quando há suspeita de problema):

1. Escolha um `.7z` recente em `F:\HyperV-Exports\<pasta-da-noite>\<LOTE>\Archives\` (ex.: `...\2026-08-06_CASCATA_a1b2c3d4\SMALL\Archives\`).
2. Extraia para um diretório alternativo (fora de `F:\HyperV-Exports`, para não confundir com backups ativos).
3. Localize o arquivo `.vmcx` dentro da pasta extraída.
4. No Gerenciador do Hyper-V, **Importar Máquina Virtual** → aponte para a pasta extraída.
5. Escolha a opção de **copiar** a VM e gerar um **novo identificador** (nunca importar em modo "registrar no local" sobre uma VM de produção existente).
6. Antes de ligar, desconecte ou troque o adaptador de rede para um **switch isolado** — evita IP/hostname duplicado na rede real.
7. Ligue a VM e valide: sistema operacional inicializa, serviços sobem, aplicação responde.
8. Descarte a VM de teste depois de validar (ela não deve ficar rodando em paralelo com a original).

Se o passo 4 falhar por integridade do arquivo, isso é grave — indica que o teste `7z t` feito durante o backup não pegou uma corrupção (não deveria acontecer; reporte/investigue o arquivo `.7z` e o hash SHA-256 registrado no relatório daquele ponto).

---

## Ajustando a configuração com segurança

### `Config\Tiers.json`

- Mudar `MinSizeGB`/`MaxSizeGB`: efeito imediato na próxima execução (o script recalcula o tamanho de cada VM toda vez, não precisa reiniciar nada). Não precisa rodar o instalador de novo — só afeta classificação, não agendamento.
- Adicionar/remover/renomear um lote: efeito imediato na classificação (próxima execução), mas **precisa rodar `Install-VMExportBackupTask.ps1` de novo** para `Invoke-CascadeBackup.ps1` passar a incluir/excluir esse lote na sequência (ele lê `Tiers.json` a cada disparo, então na prática já pega o lote novo automaticamente — rodar o instalador de novo é necessário mesmo assim se você também mudou `CascadeStartTime`/`CascadeExecutionTimeLimitHours`, que ficam gravados na tarefa do Agendador).
- Mudar `KeepRestorePoints` (por lote): efeito na próxima vez que aquele lote publicar um ponto com sucesso (é quando a retenção roda).
- Mudar `CascadeStartTime` ou `CascadeExecutionTimeLimitHours`: só tem efeito depois de rodar `Install-VMExportBackupTask.ps1` de novo (esses dois valores são gravados no gatilho/configurações da tarefa do Agendador no momento da instalação, não são lidos em tempo de execução).

### `Config\Settings.json`

Efeito imediato na próxima execução de qualquer lote — é lido pelo script principal a cada run. Não precisa rodar o instalador. Um parâmetro passado explicitamente na linha de comando sempre vence sobre o que está em `Settings.json`.

### Validar antes de aplicar

Depois de editar qualquer um dos dois JSONs:

```powershell
Get-Content 'C:\Scripts\WindowsServerBackup\Config\Tiers.json' -Raw | ConvertFrom-Json | Out-Null
Get-Content 'C:\Scripts\WindowsServerBackup\Config\Settings.json' -Raw | ConvertFrom-Json | Out-Null
```

Se algum dos dois lançar erro, o JSON está malformado — corrija antes de deixar a próxima execução tentar ler.
