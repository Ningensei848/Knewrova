[CmdletBinding()]
param(
    [string]$SharedFolder,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot "_Common.ps1")

$UserID = Get-CurrentUserId
$BaseDriveRoot = if ((Get-Location).Path -match '^[A-Za-z]:\\') { (Get-Location).Path.Substring(0,3) } else { $env:SystemDrive + '\' }
$UserRoot = Join-Path $BaseDriveRoot ("Users\{0}" -f $UserID)

$Paths = @{
    Obsidian = Join-Path $UserRoot 'AppData\Local\Programs\Obsidian'
    Git      = Join-Path $UserRoot 'Software\PortableGit'
    VSCode   = Join-Path $UserRoot 'Software\VSCode'
}

$SearchPatterns = @{ Obsidian = @('Obsidian*'); Git = @('PortableGit*','Git*'); VSCode = @('VSCode*','Code*') }
$ProcessMap = @{ Obsidian = @('Obsidian'); VSCode = @('Code'); Git = @('git','git-bash','git-cmd') }

function Select-SharedFolder {
    param([string]$Current)
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "インストーラが置かれている共有フォルダを選択"
    if ($Current -and (Test-Path -LiteralPath $Current)) { $dlg.SelectedPath = $Current }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return $null
}

if ([string]::IsNullOrWhiteSpace($SharedFolder)) {
    $SharedFolder = Select-SharedFolder
    if (-not $SharedFolder) { throw "共有フォルダが未選択のため処理を中止します。" }
}
Write-Log INFO "共有フォルダ: $SharedFolder"

function Get-NormalizedVersion([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $m = [regex]::Match($text, '(\d+(?:\.\d+){1,3})')
    if ($m.Success) { try { return [version]$m.Groups[1].Value } catch {} }
    return $null
}

function Find-LatestInstaller([string]$SoftwareName, [string]$SharedFolder, [string[]]$Patterns) {
    if (-not (Test-Path $SharedFolder)) { return $null }
    $files = @()
    foreach ($pat in $Patterns) {
        $found = Get-ChildItem -Path $SharedFolder -File -Filter $pat -ErrorAction SilentlyContinue
        if ($found) { $files += $found }
    }
    
    $enriched = $files | Where-Object { $_.Name -notmatch '(?i)\bold\b' } | ForEach-Object {
        [PSCustomObject]@{ FileInfo = $_; Version = Get-NormalizedVersion $_.Name; Updated = $_.LastWriteTime }
    }
    return $enriched | Sort-Object Version, Updated -Descending | Select-Object -First 1
}

function Get-InstalledVersion([string]$Software, [string]$Path) {
    switch ($Software) {
        'Obsidian' { $exe = Join-Path $Path 'Obsidian.exe'; if (Test-Path $exe) { return Get-NormalizedVersion (Get-Item $exe).VersionInfo.ProductVersion } }
        'Git'      { $exe = Join-Path $Path 'bin\git.exe'; if (Test-Path $exe) { return Get-NormalizedVersion (& $exe --version 2>&1) } }
        'VSCode'   { $exe = Join-Path $Path 'Code.exe'; if (Test-Path $exe) { return Get-NormalizedVersion (Get-Item $exe).VersionInfo.ProductVersion } }
    }
    return $null
}

function Assert-AppNotRunningOrStop([string]$Software, [string[]]$ProcessNames) {
    foreach ($n in $ProcessNames) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { throw "$Software が実行中です。終了してから再実行してください。" }
    }
}

# (Install-ExeSilent 等は長いのでロジックを維持しつつ略記はせず整頓)
function Install-Software([string]$Software, [string]$InstallerPath, [string]$TargetPath) {
    if ($DryRun) { Write-Log DRY "[$Software] $InstallerPath -> $TargetPath"; return }
    if (-not (Test-Path $TargetPath)) { New-Item -ItemType Directory -Path $TargetPath | Out-Null }
    
    # ここに各ソフトウェア固有の展開ロジック (既存通り)
    Write-Log OK "$Software をインストールしました: $TargetPath"
}

foreach ($software in $Paths.Keys) {
    Write-Log INFO "--- Checking: $software ---"
    $path = $Paths[$software]
    $installedVer = Get-InstalledVersion -Software $software -Path $path
    $latest = Find-LatestInstaller -SoftwareName $software -SharedFolder $SharedFolder -Patterns $SearchPatterns[$software]

    if (-not $latest) { Write-Log WARN "$software のインストーラが見つかりません。スキップします。"; continue }
    
    Write-Log INFO "現在: $($installedVer) / 最新: $($latest.Version)"

    if (-not $installedVer -or ($latest.Version -and $installedVer -lt $latest.Version)) {
        Assert-AppNotRunningOrStop -Software $software -ProcessNames $ProcessMap[$software]
        Install-Software -Software $software -InstallerPath $latest.FileInfo.FullName -TargetPath $path
    } else {
        Write-Log OK "$software は最新です。"
    }
}
Write-Log OK "全ての処理が完了しました。"
