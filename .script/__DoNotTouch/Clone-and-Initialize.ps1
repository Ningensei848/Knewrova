[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$rShareUNC,
    [string]$repoPath,
    [string]$teamRepo,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 共通モジュールのインクルード
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot "_Common.ps1")

function Assert-BareRepo {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "指定パスが存在しません: $Path" }
    
    $hasConfig  = Test-Path -LiteralPath (Join-Path $Path 'config')
    $hasObjects = Test-Path -LiteralPath (Join-Path $Path 'objects')
    $hasRefs    = Test-Path -LiteralPath (Join-Path $Path 'refs')
    if (-not ($hasConfig -and $hasObjects -and $hasRefs)) {
        throw "ベアリポジトリではない可能性があります: $Path"
    }
}

function Get-UpstreamHeadBranch {
    param([Parameter(Mandatory=$true)][string]$RepoPath, [Parameter(Mandatory=$true)][string]$GitExe)
    try {
        $out = & $GitExe -C "$RepoPath" ls-remote --symref upstream HEAD 2>$null
        foreach ($line in $out) { if ($line -match '^ref:\s+refs/heads/([^ ]+)\s+HEAD$') { return $Matches[1].Trim() } }
    } catch { }
    return 'main'
}

# ===== .env 読み込みと統合 =====
$VaultPathCandidate = Join-Path $env:USERPROFILE 'MyVault'
$EnvCandidates = @( (Join-Path $ScriptRoot '.env'), (Join-Path $VaultPathCandidate '.env') )

$envMap = @{}
$UsedEnvPath = $null
foreach ($envPath in $EnvCandidates) {
    if (Test-Path -LiteralPath $envPath) {
        $envMap = Load-DotEnv -EnvPath $envPath
        $UsedEnvPath = $envPath
        Write-Log INFO ".env を読み込みました: $envPath"
        break
    }
}

$UserId = Get-CurrentUserId
$rShareUNC_Final = if ($rShareUNC) { $rShareUNC } else { $envMap['R_SHARE_UNC'] }
$repoPath_Final = if ($repoPath) { $repoPath } elseif ($envMap['REPO_PATH']) { $envMap['REPO_PATH'] } else { "R:\UsersVault\${UserId}.git" }
$teamRepo_Final = if ($teamRepo) { $teamRepo } else { $envMap['TEAM_REPO'] }

if (-not $rShareUNC_Final -or -not $teamRepo_Final) {
    Write-Log ERROR "rShareUNC または teamRepo が不足しています。"
    exit 1
}

$GitExe = Resolve-GitExe -EnvMap $envMap
Write-Log INFO "Git 実行ファイル: $GitExe"

# ===== Step 1: R ドライブの準備 =====
try {
    $rDrive = Get-PSDrive -Name R -ErrorAction SilentlyContinue
    if (-not $rDrive) {
        Write-Log INFO "UNC 実在確認: $rShareUNC_Final"
        if (-not (Test-Path -LiteralPath $rShareUNC_Final)) { throw "UNC にアクセスできません: $rShareUNC_Final" }

        if (-not $DryRun) {
            Write-Log INFO "R: ドライブをマウントします"
            cmd.exe /c "net use R: `"$rShareUNC_Final`" /persistent:yes"
            if ($LASTEXITCODE -ne 0) { throw "net use 失敗。" }
        } else {
            Write-Log DRY "net use R: `"$rShareUNC_Final`" /persistent:yes"
        }
    }
} catch {
    Write-Log ERROR $_.Exception.Message
    exit 1
}

# ===== Step 2: MyVault へ clone =====
$VaultPath = Join-Path $env:USERPROFILE 'MyVault'
try {
    if (-not (Test-Path -LiteralPath $VaultPath)) {
        Assert-BareRepo -Path $repoPath_Final
        if (-not $DryRun) {
            Write-Log INFO "clone を開始します: $repoPath_Final"
            & $GitExe -c protocol.file.allow=always clone --recurse-submodules --shallow-submodules --single-branch --jobs 4 --progress -- "file:///$repoPath_Final" "$VaultPath"
        } else {
            Write-Log DRY "clone: $repoPath_Final -> $VaultPath"
        }
    } else {
        Write-Log WARN "MyVault は既に存在します。"
        # ここに既存リポジトリの検証ロジック等（略記）
    }
} catch {
    Write-Log ERROR $_.Exception.Message
    exit 1
}

# 以降、upstream の追加や外部スクリプトの呼び出し処理が続きます...
Write-Log OK "処理が完了しました。"
exit 0
