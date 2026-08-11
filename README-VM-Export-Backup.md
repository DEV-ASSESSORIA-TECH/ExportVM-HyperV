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
Invoke-VMExportBackup.ps1 v1.0.5
```

A versão atual já foi validada com:

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

---

## Funcionamento

A rotina executa as seguintes etapas:

1. Valida o host, o disco de destino e as ferramentas.
2. Confirma o rótulo do volume de backup.
3. Lista e registra as VMs selecionadas.
4. Exporta uma VM por vez.
5. Usa estado consistente com aplicações quando suportado.
6. Compacta cada VM em um arquivo `.7z` separado.
7. Testa integralmente cada arquivo com `7z t`.
8. Valida a estrutura interna do arquivo.
9. Confirma a existência de discos virtuais e arquivo `.vmcx`.
10. Compara o tamanho exportado com o tamanho listado pelo 7-Zip.
11. Calcula SHA-256, salvo quando `-SkipHash` for utilizado.
12. Remove a exportação temporária após validação.
13. Publica o ponto somente quando todas as VMs terminam com sucesso.
14. Aplica retenção somente depois da publicação.
15. Gera log, JSON e HTML.
16. Exibe heartbeat a cada 30 segundos durante operações longas.

---

## Arquivos

| Arquivo | Função |
|---|---|
| `Invoke-VMExportBackup.ps1` | Script principal |
| `Export-VMWorker.ps1` | Worker isolado para `Export-VM` |
| `Get-FileHashWorker.ps1` | Worker isolado para SHA-256 |
| `Install-VMExportBackupTask.ps1` | Criação futura da tarefa agendada como `SYSTEM` |

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
├── 2026-08-05_00-30-00-1234abcd\
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
    'C:\Scripts\WindowsServerBackup\Install-VMExportBackupTask.ps1'
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

# Comandos principais atuais

A retenção está temporariamente configurada como:

```text
KeepRestorePoints = 9
```

Isso ocorre porque cada lote publicado conta como um ponto independente.

Com três lotes, nove pontos correspondem aproximadamente a três ciclos completos.

---

## 1. Lote BIG

VMs:

```text
SRV-AMANDA
SRV-CONTABIL-ASS
SRV-DOM-TRS
```

Volume atual aproximado:

```text
427,58 GB
```

Comando:

```powershell
& "C:\Scripts\WindowsServerBackup\Invoke-VMExportBackup.ps1" `
    -BackupDrive F: `
    -ExpectedVolumeLabel "BACKUP-HYPERV" `
    -VMName "SRV-AMANDA","SRV-CONTABIL-ASS","SRV-DOM-TRS" `
    -KeepRestorePoints 9 `
    -CompressionLevel 3 `
    -Execute `
    -SkipEmail
```

---

## 2. Lote MEDIUM

VMs:

```text
SRV-MN
SRV-ZABBIX
SRV-AD
SRV-IA
SRV-AD-TRS
```

Volume atual aproximado:

```text
222,80 GB
```

Comando:

```powershell
& "C:\Scripts\WindowsServerBackup\Invoke-VMExportBackup.ps1" `
    -BackupDrive F: `
    -ExpectedVolumeLabel "BACKUP-HYPERV" `
    -VMName "SRV-MN","SRV-ZABBIX","SRV-AD","SRV-IA","SRV-AD-TRS" `
    -KeepRestorePoints 9 `
    -CompressionLevel 3 `
    -Execute `
    -SkipEmail
```

---

## 3. Lote SMALL

VMs:

```text
SRV-RMM
SRV-N8N
SRV-APPS
SRV-ADM
SRV-DOCS
SRV-SNIPE
SRV-WEB
SRV-VPN
SRV-VoIP
```

Volume atual aproximado:

```text
110,58 GB
```

Comando:

```powershell
& "C:\Scripts\WindowsServerBackup\Invoke-VMExportBackup.ps1" `
    -BackupDrive F: `
    -ExpectedVolumeLabel "BACKUP-HYPERV" `
    -VMName "SRV-RMM","SRV-N8N","SRV-APPS","SRV-ADM","SRV-DOCS","SRV-SNIPE","SRV-WEB","SRV-VPN","SRV-VoIP" `
    -KeepRestorePoints 9 `
    -CompressionLevel 3 `
    -Execute `
    -SkipEmail
```

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
- arquivo individual por VM.

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

O envio de e-mail ainda não está sendo utilizado nos comandos operacionais atuais.

Por enquanto, todos os lotes usam:

```text
-SkipEmail
```

A configuração e validação do envio serão tratadas posteriormente.

---

## Retenção temporária

A retenção atual ainda não diferencia os lotes BIG, MEDIUM e SMALL.

Cada execução publicada conta como um ponto completo.

Por isso, temporariamente, os três comandos utilizam:

```text
-KeepRestorePoints 9
```

A lógica deverá ser aprimorada posteriormente para permitir:

- retenção independente por lote;
- agrupamento lógico por ciclo ou data;
- execução nativa dos três lotes;
- agendamento separado;
- relatório consolidado.

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

---

## Status atual

```text
Fluxo principal: validado
Checkpoint Linux: validado
Lote SMALL de teste: validado
Lote BIG: validado
E-mail: pendente
Agendamento: pendente
Retenção por lote: pendente
Restauração completa de teste: pendente
```
