[CmdletBinding()]
param(
  [string[]]$IdBaseDir,
  [string[]]$TargetDir,
  [string]$IdListPath,
  [string]$GitExe,
  [switch]$DryRun,
  [switch]$NoPrompt
)

$ErrorActionPreference = 'Stop'

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot "_Common.ps1")

# 環境変数ロードと GitExe 解決
$envMap = Load-DotEnv -EnvPath (Join-Path $ScriptRoot '.env')
$rShareUNC_Final = $envMap['R_SHARE_UNC']
$git = Resolve-GitExe -ExplicitPath $GitExe -EnvMap $envMap

function Assert-NonUNC([string]$p){
  if($p -and $p.StartsWith('\\')){ throw "UNC は禁止です: $p" }
}

function Read-ListFile([string]$Path){
  if(-not $Path -or -not (Test-Path -LiteralPath $Path)){ return @() }
  return Get-Content -LiteralPath $Path | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $_.Trim() }
}

function AbsSlash([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return $null }
  try{ $a=[System.IO.Path]::GetFullPath($p) } catch { $a=$p }
  return $a.Replace('\','/')
}

function Mount-RDrive {
    param([string]$ShareUNC, [switch]$Dry)
    $rDrive = Get-PSDrive -Name R -ErrorAction SilentlyContinue
    if ($rDrive) { Write-Log INFO "R: ドライブは既に存在します。"; return }
    
    if (-not (Test-Path -LiteralPath $ShareUNC)) { throw "UNC にアクセスできません: $ShareUNC" }
    if ($Dry) { Write-Log DRY "net use R: `"$ShareUNC`" /persistent:yes"; return }
    
    cmd.exe /c "net use R: `"$ShareUNC`" /persistent:yes"
    if ($LASTEXITCODE -ne 0) { throw "net use 失敗。" }
}

function Normalize-StringArray([string[]]$arr) {
  if(-not $arr){ return @() }
  if($arr.Count -gt 1){ return $arr }
  if($arr[0].Contains(',')){ return ,($arr[0].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
  return $arr
}

function Get-SafeDirs {
  $o = & $git config --global --get-all safe.directory 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $o) { return @() }
  return $o | ForEach-Object { $_.Trim().Replace('\','/') } | Where-Object { $_ }
}

# --- Main ---
try {
    Mount-RDrive -ShareUNC $rShareUNC_Final -Dry:$DryRun

    $IdBaseDir = Normalize-StringArray $IdBaseDir
    $TargetDir = Normalize-StringArray $TargetDir

    $bases = @(); foreach($b in $IdBaseDir){ Assert-NonUNC $b; $bases += AbsSlash $b }
    $targetsExplicit = @(); foreach($d in $TargetDir){ Assert-NonUNC $d; $targetsExplicit += AbsSlash $d }

    $idPath = $IdListPath
    if ($bases.Count -gt 0 -and -not (Test-Path -LiteralPath "$idPath")) {
        $idPath = Select-IdListFile -Title "id_list.txt を選択"
    }

    $targets = @()
    if ($idPath -and (Test-Path -LiteralPath $idPath)) {
        foreach($id in (Read-ListFile $idPath)){
            foreach($bd in $bases){ $targets += AbsSlash (Join-Path $bd "$id.git") }
        }
    }
    $targets += $targetsExplicit
    $targets = $targets | Where-Object { $_ } | Select-Object -Unique

    $current = Get-SafeDirs
    $toAdd = @(); foreach($t in $targets){ if($current -notcontains $t){ $toAdd += $t } }

    Write-Log INFO "=== To add: $($toAdd.Count) ==="
    foreach($p in $toAdd){ Write-Log INFO "  + $p" }

    if ($DryRun -or $toAdd.Count -eq 0) {
        if ($DryRun) { Write-Log DRY "DRY-RUN: 適用なし" } else { Write-Log INFO "差分なし" }
        return
    }

    if (-not $NoPrompt) {
        $ans = Read-Host "Proceed to add ($($toAdd.Count)) entries? [y/N]"
        if ($ans.ToLower() -ne 'y') { Write-Log WARN "Aborted."; return }
    }

    & $git config --global protocol.file.allow always
    & $git config --global core.longpaths true
    foreach($p in $toAdd){
        & $git config --global --add safe.directory $p
        if($LASTEXITCODE -ne 0){ Write-Log ERROR "Failed: $p" } else { Write-Log OK "Added: $p" }
    }
} catch {
    Write-Log ERROR $_.Exception.Message
    exit 1
}
