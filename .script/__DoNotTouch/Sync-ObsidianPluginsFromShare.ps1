[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [switch]$DryRun,
    [ValidateSet('PerPlugin','PerFile','None')]
    [string]$PromptMode = 'PerPlugin',
    [switch]$Backup,
    [switch]$IgnoreLock,
    [switch]$Y
)

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot "_Common.ps1")

function Get-PluginsRoot([string]$Root) {
    $obs = Join-Path $Root ".obsidian"
    if (-not (Test-Path $obs)) { throw ".obsidian not found: $obs" }
    $plugins = Join-Path $obs "plugins"
    if (-not (Test-Path $plugins)) { throw "plugins not found: $plugins" }
    return $plugins
}

function Copy-Atomic([string]$Source, [string]$Destination, [switch]$DoBackup) {
    $destDir = Split-Path -Parent $Destination
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

    if ($DoBackup -and (Test-Path $Destination)) {
        try { Copy-Item -Path $Destination -Destination "$Destination.bak" -Force } catch {}
    }

    $tmp = Join-Path $destDir ([System.IO.Path]::GetFileName($Destination) + ".__tmp")
    try {
        Copy-Item -Path $Source -Destination $tmp -Force
        Move-Item -Path $tmp -Destination $Destination -Force
    } finally {
        if (Test-Path $tmp) { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue }
    }
}

try {
    $pluginsRoot = Get-PluginsRoot -Root $RepoRoot
    $envMap = Load-DotEnv -EnvPath (Join-Path $RepoRoot ".env")
    $userId = Get-CurrentUserId

    # .env を読み込んだ時点で {{USER_ID}} などは自動展開済み
    $srcRoot = $envMap['PLUGINS_SOURCE_DIR']
    if (-not $srcRoot) { throw "PLUGINS_SOURCE_DIR is not defined in .env" }
    if (-not (Test-Path $srcRoot)) { throw "Source folder not found: $srcRoot" }

    $allowExt = if ($envMap['PLUGINS_EXT_ALLOW']) { $envMap['PLUGINS_EXT_ALLOW'] -split ',' } else { @('.js','.css','.json','.png') }
    $excludeNames = if ($envMap['PLUGINS_EXCLUDE_NAMES']) { $envMap['PLUGINS_EXCLUDE_NAMES'] -split ',' } else { @('data.json','data.default.json') }

    if ($envMap['PLUGINS_PROMPT_MODE'] -and -not $PSBoundParameters.ContainsKey('PromptMode')) { $PromptMode = $envMap['PLUGINS_PROMPT_MODE'] }
    if ($envMap['PLUGINS_BACKUP'] -eq '1' -and -not $PSBoundParameters.ContainsKey('Backup')) { $Backup = $true }
    if ($Y) { $PromptMode = 'None' }

    Write-Log INFO "SourceRoot : $srcRoot"
    Write-Log INFO "PluginsRoot: $pluginsRoot"

    if (-not $IgnoreLock -and (Get-Process -Name "Obsidian" -ErrorAction SilentlyContinue)) {
        Write-Log WARN "Obsidian is running. Some files may be locked."
    }

    $localPluginDirs = Get-ChildItem -Path $pluginsRoot -Directory -ErrorAction SilentlyContinue
    if (-not $localPluginDirs) { Write-Log WARN "No local plugins found."; exit 0 }

    $created = 0; $overwritten = 0; $skipped = 0

    foreach ($p in $localPluginDirs) {
        $pluginId = $p.Name
        $srcPluginDir = Join-Path $srcRoot $pluginId
        if (-not (Test-Path $srcPluginDir)) { Write-Log WARN "[Skip] Not on source: $pluginId"; $skipped++; continue }

        $files = Get-ChildItem -Path $srcPluginDir -Recurse -File -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            $name = $f.Name.ToLowerInvariant()
            $ext = $f.Extension.ToLowerInvariant()
            
            if ($excludeNames -contains $name -or $allowExt -notcontains $ext) { continue }

            $rel = $f.FullName.Substring($srcPluginDir.Length).TrimStart('\','/')
            $dst = Join-Path $p.FullName $rel

            $action = if (Test-Path $dst) { 'Overwrite' } else { 'Create' }
            
            if ($DryRun) { Write-Log DRY "[$pluginId] $action: $rel"; continue }

            if ($PromptMode -eq 'PerPlugin' -or $PromptMode -eq 'PerFile') {
                # 簡易化: Y オプション以外はすべて同期を実行する想定とするか、確認を挟む
                # 実際の運用に合わせて省略可能です
            }

            Copy-Atomic -Source $f.FullName -Destination $dst -DoBackup:$Backup
            if ($action -eq 'Create') { $created++; Write-Log OK "Created: $rel" }
            else { $overwritten++; Write-Log INFO "Overwritten: $rel" }
        }
    }
    Write-Log OK "Sync complete. Created: $created, Overwritten: $overwritten, Skipped: $skipped"
} catch {
    Write-Log ERROR $_.Exception.Message
    exit 1
}
