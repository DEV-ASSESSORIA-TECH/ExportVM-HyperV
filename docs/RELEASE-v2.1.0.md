# VM Export Backup v2.1.0

Versão preparada em 28/10/2026. Compatível com os backups schema 2 existentes.

- Raiz de produção com três scripts de entrada; auxiliares em `Internal/Helpers` e `Internal/Workers`.
- Exclusões por nome ou VMId, aplicadas antes da consulta aos discos, com avisos para exclusões ausentes.
- Plano único da cascata; lotes sem VMs elegíveis usam `SKIPPED` e apresentam justificativa.
- Falhas por VM com tentativas, espaço em GB e caminho do log; nomes de log incluem RunId curto.
- VM removida após o planejamento falha individualmente, preservando o processamento das demais.
- Resultados de lote ausentes/inválidos e falhas de inicialização geram relatório de falha e tentativa de alerta.
- Bloqueio exclusivo por repositório, compartilhado entre instalações e liberado pelo Windows após término abrupto.
- Publicação com registro persistente em `_PUBLISHING`, checkpoint atômico por VM e recuperação idempotente na próxima execução real.

Antes de atualizar, pare os backups e suspenda o agendamento. Preserve a configuração local, copie a pasta `Internal` junto dos três scripts e atualize todas as instalações que escrevem no mesmo destino. Consulte o [runbook](RUNBOOK.md) antes de intervir em publicações pendentes.

Validação: suíte Pester no Windows PowerShell 5.1, cenários de erro de configuração/resultado, concorrência entre processos reais e recuperação após encerramento abrupto durante a publicação. Backup/restauração real de Hyper-V e entrega SMTP devem ser homologados no ambiente de destino.

Artefatos: `VM-Export-Backup-2.1.0.zip` e `VM-Export-Backup-2.1.0.zip.sha256`. Esta preparação local não faz push nem publica a release remota.
