<#
.SYNOPSIS
    Подключает скиллы и правила репозитория к Claude Code и Codex через junction-ссылки.

.DESCRIPTION
    Для каждого каталога skills/<имя> создает ссылку <каталог агента>/skills/<имя> на каталог репозитория.
    Для Claude также подключает rules-1c как ~/.claude/rules-1c (на него ссылаются скиллы).

    Существующий обычный каталог с тем же именем не удаляется: он переносится в резервную копию
    <каталог агента>/skills-backup-<дата>/. Ссылка, которая уже ведет в этот репозиторий, пропускается.

    Для Codex каталоги с собственными правками не заменяются, пока не задан -Force: копии Codex
    могли разойтись с репозиторием, и их сначала нужно слить вручную.

.PARAMETER Agent
    Claude, Codex или All (по умолчанию Claude).

.PARAMETER Force
    Для Codex: заменить и разошедшиеся каталоги (с резервной копией).

.PARAMETER WhatIf
    Только показать, что будет сделано.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Agent All
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Claude', 'Codex', 'All')]
    [string]$Agent = 'Claude',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Test-SameTree([string]$Left, [string]$Right) {
    # Сравнение только читает файлы, поэтому идет через .NET: командлеты подчиняются -WhatIf.
    $sha = [Security.Cryptography.SHA256]::Create()
    $leftFiles = @(Get-ChildItem -LiteralPath $Left -Recurse -File |
        Where-Object { $_.FullName -notmatch '\\__pycache__\\' })
    $rightFiles = @(Get-ChildItem -LiteralPath $Right -Recurse -File |
        Where-Object { $_.FullName -notmatch '\\__pycache__\\' })
    if ($leftFiles.Count -ne $rightFiles.Count) { return $false }
    foreach ($file in $leftFiles) {
        $relative = $file.FullName.Substring($Left.TrimEnd('\').Length)
        $other = Join-Path $Right $relative
        if (-not (Test-Path -LiteralPath $other -PathType Leaf)) { return $false }
        $leftBytes = [IO.File]::ReadAllBytes($file.FullName)
        $rightBytes = [IO.File]::ReadAllBytes($other)
        if ($leftBytes.Length -ne $rightBytes.Length) { return $false }
        if ([Convert]::ToBase64String($sha.ComputeHash($leftBytes)) -ne [Convert]::ToBase64String($sha.ComputeHash($rightBytes))) { return $false }
    }
    return $true
}

function Connect-Folder([string]$Source, [string]$Link, [string]$BackupRoot, [bool]$KeepChanged) {
    $item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType -eq 'Junction') {
        if ((@($item.Target)[0]).TrimEnd('\') -eq $Source.TrimEnd('\')) {
            Write-Output "  = $Link"
            return
        }
        if ($PSCmdlet.ShouldProcess($Link, 'удалить ссылку на другой каталог')) {
            [IO.Directory]::Delete($Link)
        }
    } elseif ($item) {
        if ($KeepChanged -and -not (Test-SameTree $Link $Source)) {
            Write-Output "  ! $Link - свои правки, пропущен (слейте вручную или -Force)"
            return
        }
        $backup = Join-Path $BackupRoot $item.Name
        if ($PSCmdlet.ShouldProcess($Link, "перенести в $backup")) {
            New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
            Move-Item -LiteralPath $Link -Destination $backup
        }
    }
    if ($PSCmdlet.ShouldProcess($Link, "ссылка на $Source")) {
        New-Item -ItemType Junction -Path $Link -Target $Source | Out-Null
        Write-Output "  + $Link"
    }
}

function Install-Agent([string]$AgentHome, [bool]$KeepChanged, [bool]$WithRules) {
    $skillsDir = Join-Path $AgentHome 'skills'
    New-Item -ItemType Directory -Path $skillsDir -Force | Out-Null
    $backupRoot = Join-Path $AgentHome "skills-backup-$stamp"
    Write-Output "$skillsDir"
    foreach ($skill in Get-ChildItem -LiteralPath (Join-Path $repo 'skills') -Directory) {
        Connect-Folder $skill.FullName (Join-Path $skillsDir $skill.Name) $backupRoot $KeepChanged
    }
    if ($WithRules) {
        Connect-Folder (Join-Path $repo 'rules-1c') (Join-Path $AgentHome 'rules-1c') (Join-Path $AgentHome "rules-backup-$stamp") $false
    }
}

if ($Agent -in 'Claude', 'All') {
    Install-Agent (Join-Path $env:USERPROFILE '.claude') $false $true
}
if ($Agent -in 'Codex', 'All') {
    Install-Agent (Join-Path $env:USERPROFILE '.codex') (-not $Force) $false
}
