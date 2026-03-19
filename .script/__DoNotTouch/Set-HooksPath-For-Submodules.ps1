[CmdletBinding()]
param([switch]$DryRun)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot "_Common.ps1")

$envMap = Load-DotEnv -EnvPath (Join-Path (Get-Location).Path '.env')
$GitExe = Resolve-GitExe -EnvMap $envMap

function Invoke-Git {
    param([string[]]$Args)
    & $GitExe @Args
}

function Get-RelativePath([string]$From, [string]$To) {
    $fromFull = (Resolve-Path -LiteralPath $From -ErrorAction Stop).ProviderPath
    $toFull   = (Resolve-Path -LiteralPath $To   -ErrorAction Stop).ProviderPath

    if ([System.IO.Path]::GetPathRoot($fromFull) -ne [System.IO.Path]::GetPathRoot($toFull)) {
        return ($toFull -replace '\\','/')
    }

    $baseUri = [System.Uri]::new(($fromFull -replace '[\\/]\s*$', '') + [System.IO.Path]::DirectorySeparatorChar)
    $relUri  = $baseUri.MakeRelativeUri([System.Uri]::new($toFull)).ToString()
    return ([System.Uri]::UnescapeDataString($relUri) -replace '\\','/')
}

function Set-HooksPath([string]$repoPath, [string]$hooksDirInSuper) {
    $rel = Get-RelativePath -From $repoPath -To $hooksDirInSuper
    if ($DryRun) {
        Write-Log DRY "[$repoPath] 設定予定 core.hooksPath = $rel"
    } else {
        Invoke-Git @('-C', $repoPath, 'config', '--local', 'core.hooksPath', $rel) | Out-Null
        $setVal = Invoke-Git @('-C', $repoPath, 'config', '--local', '--get', 'core.hooksPath')
        Write-Log OK "[$repoPath] hooksPath = $setVal"
    }
}

# --- Main ---
try {
    $superRoot = (Invoke-Git @('rev-parse', '--show-toplevel')).Trim()
    if (-not $superRoot) { throw "親リポジトリのルートが取得できませんでした。" }

    $hooksDir = Join-Path $superRoot '.script\__DoNotTouch\hooks'
    if (-not (Test-Path -LiteralPath $hooksDir)) { throw "hooks ディレクトリが見つかりません: $hooksDir" }

    Write-Log INFO "親リポジトリへの適用を開始します..."
    Set-HooksPath -repoPath $superRoot -hooksDirInSuper $hooksDir

    Invoke-Git @('submodule', 'update', '--init', '--recursive', '--merge') | Out-Null

    $subRoots = @()
    $lines = Invoke-Git @('submodule', 'foreach', '--recursive', 'git rev-parse --show-toplevel') 2>$null
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -match '^[A-Za-z]:\\') { $subRoots += $t }
    }

    Write-Log INFO "サブモジュールへの適用を開始します..."
    foreach ($sub in $subRoots) {
        try { Set-HooksPath -repoPath $sub -hooksDirInSuper $hooksDir }
        catch { Write-Log WARN "失敗: $sub -> $($_.Exception.Message)" }
    }

    Write-Log OK "完了: 親＋全サブモジュールの hooksPath を登録しました。"
} catch {
    Write-Log ERROR $_.Exception.Message
    exit 1
}
