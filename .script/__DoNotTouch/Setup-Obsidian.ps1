[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$VaultPath = (Get-Location).Path,
    [switch]$PickFolder,
    [switch]$Force,
    [switch]$Backup,
    [switch]$DryRun,
    [switch]$Y
)

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot "_Common.ps1")

function Ensure-ObsidianRootPath {
    param([string]$BasePath, [switch]$Pick)
    $resolved = $BasePath

    if ($Pick) {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Select Vault root (contains .obsidian)"
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $resolved = $fbd.SelectedPath }
        else { throw "Folder picking was cancelled." }
    }

    if (Test-Path (Join-Path $resolved ".obsidian")) { return (Join-Path $resolved ".obsidian") }
    if ((Split-Path -Leaf $resolved) -eq ".obsidian") { return $resolved }
    throw "'.obsidian' not found under: $resolved"
}

function Write-Utf8NoBom {
    param([string]$TargetPath, [string]$Content)
    $dir = Split-Path -Parent $TargetPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $sw = New-Object System.IO.StreamWriter($TargetPath, $false, $encoding)
    try { $sw.Write($Content) } finally { $sw.Dispose() }
}

function Initialize-DefaultJsons {
    param([string]$ObsRoot, [string]$VaultRoot)

    $userId = Get-CurrentUserId
    Write-Log INFO "UserID: $userId | Scan Root: $ObsRoot"

    $targets = Get-ChildItem -Path $ObsRoot -Recurse -Filter "*.default.json" -File -ErrorAction SilentlyContinue
    if (-not $targets) { Write-Log WARN "No targets (*.default.json not found)."; return }

    $processed = 0; $skipped = 0; $overwritten = 0; $created = 0
    $driveLetter = (Split-Path (Get-Location) -Qualifier).Substring(0,1)

    foreach ($t in $targets) {
        $src = $t.FullName
        $dst = Join-Path $t.DirectoryName (($t.Name -replace '\.default\.json$', '') + ".json")
        
        $raw = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)
        $new = $raw.Replace("{{USER_ID}}", $userId).Replace("{{DRIVE_LETTER}}", $driveLetter)
        if ($VaultRoot) { $new = $new.Replace("{{VAULT_ROOT}}", $VaultRoot) }

        if (Test-Path $dst) {
            if (-not $Force) { Write-Log INFO "Skip: exists -> $dst"; $skipped++; $processed++; continue }
            if ($Backup) { Copy-Item -Path $dst -Destination "$dst.bak" -Force -ErrorAction SilentlyContinue }
            
            if ($PSCmdlet.ShouldProcess($dst, "Overwrite")) {
                if (-not $DryRun) { Write-Utf8NoBom -TargetPath $dst -Content $new }
                Write-Log OK "Overwrite: $dst"; $overwritten++
            }
        } else {
            if ($PSCmdlet.ShouldProcess($dst, "Create")) {
                if (-not $DryRun) { Write-Utf8NoBom -TargetPath $dst -Content $new }
                Write-Log OK "Create: $dst"; $created++
            }
        }
        $processed++
    }

    Write-Log INFO "Summary: Processed=$processed, Created=$created, Overwrote=$overwritten, Skipped=$skipped"
}

function Invoke-OptionalSyncFromShare {
    param([string]$VaultOrObsPath)
    
    $repoRoot = if ((Split-Path -Leaf $VaultOrObsPath) -eq ".obsidian") { Split-Path -Parent $VaultOrObsPath } else { $VaultOrObsPath }
    $target = Join-Path $ScriptRoot "Sync-ObsidianPluginsFromShare.ps1"
    if (-not (Test-Path $target)) { $target = Join-Path $repoRoot ".script\__DoNotTouch\Sync-ObsidianPluginsFromShare.ps1" }

    if (Test-Path $target) {
        Write-Log INFO "Sync script detected: $target"
        if ($PSCmdlet.ShouldProcess($target, "Invoke Sync")) {
            $invokeArgs = @{ RepoRoot = $repoRoot }
            if ($DryRun) { $invokeArgs['DryRun'] = $true }
            if ($Backup) { $invokeArgs['Backup'] = $true }
            if ($Y)      { $invokeArgs['Y'] = $true }
            & $target @invokeArgs
            Write-Log OK "Sync script invocation completed."
        }
    }
}

try {
    $obsRoot = Ensure-ObsidianRootPath -BasePath $VaultPath -Pick:$PickFolder
    $vaultRoot = if ((Split-Path -Leaf $obsRoot) -eq ".obsidian") { Split-Path -Parent $obsRoot } else { $obsRoot }
    
    Initialize-DefaultJsons -ObsRoot $obsRoot -VaultRoot $vaultRoot
    Invoke-OptionalSyncFromShare -VaultOrObsPath $VaultPath
    exit 0
} catch {
    Write-Log ERROR $_.Exception.Message
    exit 1
}
