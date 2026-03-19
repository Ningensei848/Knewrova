[CmdletBinding()]
param(
  [string]$RemoteGitDir,
  [switch]$DryRun,
  [switch]$EnforceOrigin,
  [string]$UserId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot "_Common.ps1")

# 環境変数の読み込みと統合
$envMap = Load-DotEnv -EnvPath (Join-Path (Get-Location).Path '.env')
$GitExe = Resolve-GitExe -EnvMap $envMap

if ($envMap['DRYRUN'] -and ($envMap['DRYRUN'].ToLower() -in @('1','true','yes'))) { $DryRun = $true }
if ($envMap['REMOTE_GIT_DIR'] -and -not $RemoteGitDir) { $RemoteGitDir = $envMap['REMOTE_GIT_DIR'] }
if ($envMap['USER_ID'] -and -not $UserId) { $UserId = $envMap['USER_ID'] }

function Invoke-Git {
    param([string[]]$Args)
    & $GitExe @Args
}

function Ensure-GitConfigs {
  param([string]$Scope, [hashtable]$Desired, [string]$RepoRoot, [string]$BareGitDir, [switch]$Dry)
  
  $summary = [ordered]@{ OK=0; APPLIED=0; DRYRUN=0; SKIP=0; TOTAL=$Desired.Keys.Count }
  foreach ($k in $Desired.Keys) {
    $want = $Desired[$k]
    $cur = $null

    if ($Scope -eq 'LOCAL') {
      if (-not $RepoRoot) { $summary.SKIP++; continue }
      $cur = (Invoke-Git @('-C', $RepoRoot, 'config', '--local', '--get', $k)) 2>$null
    } elseif ($Scope -eq 'BARE') {
      if (-not $BareGitDir) { $summary.SKIP++; continue }
      $cur = (Invoke-Git @('--git-dir', $BareGitDir, 'config', '--get', $k)) 2>$null
    } elseif ($Scope -eq 'GLOBAL') {
      $cur = (Invoke-Git @('config', '--global', '--get', $k)) 2>$null
    }

    if ($cur -ne $want) {
      if ($Dry) {
        Write-Log DRY "[$Scope] $k: '$cur' -> '$want'"
        $summary.DRYRUN++
      } else {
        if ($Scope -eq 'LOCAL') { Invoke-Git @('-C', $RepoRoot, 'config', '--local', $k, $want) | Out-Null }
        elseif ($Scope -eq 'BARE') { Invoke-Git @('--git-dir', $BareGitDir, 'config', $k, $want) | Out-Null }
        elseif ($Scope -eq 'GLOBAL') { Invoke-Git @('config', '--global', $k, $want) | Out-Null }
        Write-Log OK "[$Scope] $k: '$cur' -> '$want' (Applied)"
        $summary.APPLIED++
      }
    } else {
      $summary.OK++
    }
  }
  return $summary
}

# --- 実行部 ---
try {
    Write-Log INFO "Git version: $(Invoke-Git @('--version'))"
    $repoRoot = (Invoke-Git @('rev-parse','--show-toplevel')).Trim()
    
    # グローバル設定
    $globalDesired = [ordered]@{
        "protocol.file.allow" = "always"
        "init.defaultBranch"  = "main"
        "core.longpaths"      = "true"
        # 必要な他設定はここに記述
    }
    $sumGlobal = Ensure-GitConfigs -Scope GLOBAL -Desired $globalDesired -Dry:$DryRun

    # ローカル設定
    $localDesired = [ordered]@{
        "core.ignoreCase" = "true"
        "pull.ff"         = "true"
        "pull.rebase"     = "false"
        "merge.ff"        = "true"
    }
    $sumLocal = Ensure-GitConfigs -Scope LOCAL -Desired $localDesired -RepoRoot $repoRoot -Dry:$DryRun

    Write-Log OK "Config check completed."
} catch {
    Write-Log ERROR $_.Exception.Message
    exit 1
}
