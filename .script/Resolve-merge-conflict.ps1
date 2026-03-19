[CmdletBinding()]
param(
  [string]$RepoRoot,
  [string]$Origin   = "origin",
  [string]$Upstream = "upstream",
  [switch]$DryRun,
  [switch]$Refresh,
  [string]$GitExe
)

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot "_Common.ps1")

$GitExe = Resolve-GitExe -ExplicitPath $GitExe

if (-not $RepoRoot) { $RepoRoot = (Get-Location).Path }

function Invoke-Git { 
  param([string[]]$Args)
  & $GitExe -C $RepoRoot @Args 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Git failed: git $($Args -join ' ')" }
}

if ($Refresh) {
  if ($DryRun) { Write-Log DRY "fetch $Origin / $Upstream" }
  else {
    Invoke-Git @("fetch", $Origin)
    Invoke-Git @("fetch", $Upstream)
  }
}

Write-Log INFO "== Plan (FF保証) =="
Write-Log INFO "1) merge --no-ff $Origin/main"
Write-Log INFO "2) merge --no-ff -X theirs $Upstream/main"
Write-Log INFO "3) push $Origin main"

if ($DryRun) {
  Write-Log DRY "git merge --no-ff $Origin/main"
  Write-Log DRY "git merge --no-ff -X theirs $Upstream/main"
  Write-Log DRY "git push $Origin main"
} else {
  try {
    Invoke-Git @("checkout","main")
    Invoke-Git @("merge","--no-ff","$Origin/main")
    Invoke-Git @("merge","--no-ff","-X","theirs","$Upstream/main")
    Invoke-Git @("push",$Origin,"main")
    
    Write-Log OK "origin へ FF push 完了"
  } catch {
    Write-Log ERROR $_.Exception.Message
    exit 1
  }
}
