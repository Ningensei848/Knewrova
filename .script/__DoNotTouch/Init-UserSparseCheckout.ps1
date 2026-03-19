[CmdletBinding()]
param(
    [string]$WorkRootDir = (Join-Path $PSScriptRoot "work"),
    [string]$GitExe
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot "_Common.ps1")

$Script:GitExe = Resolve-GitExe -ExplicitPath $GitExe

function Invoke-GitCommand {
    param ([string]$Arguments, [string]$ErrorMessage)
    $p = Start-Process -FilePath $Script:GitExe -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput ".\git_out.tmp" -RedirectStandardError ".\git_err.tmp"
    
    $out = if (Test-Path ".\git_out.tmp") { Get-Content ".\git_out.tmp" -Raw } else { "" }
    $err = if (Test-Path ".\git_err.tmp") { Get-Content ".\git_err.tmp" -Raw } else { "" }
    Remove-Item ".\git_out.tmp", ".\git_err.tmp" -ErrorAction SilentlyContinue
    
    if ($out) { Write-Host $out }
    if ($err -and $err -ne $out) { Write-Host $err }
    
    if ($p.ExitCode -ne 0) {
        Write-Log WARN "Git command failed: git $Arguments (Exit: $($p.ExitCode))"
        if ($p.ExitCode -eq 130) { throw "Operation manually stopped (Ctrl+C). ($ErrorMessage)" }
        throw $ErrorMessage
    }
    return $out
}

function Invoke-GitRaw {
    param ([string]$Arguments)
    $p = Start-Process -FilePath $Script:GitExe -ArgumentList $Arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput ".\git_out.tmp" -RedirectStandardError ".\git_err.tmp"
    $out = if (Test-Path ".\git_out.tmp") { Get-Content ".\git_out.tmp" -Raw } else { "" }
    $err = if (Test-Path ".\git_err.tmp") { Get-Content ".\git_err.tmp" -Raw } else { "" }
    Remove-Item ".\git_out.tmp", ".\git_err.tmp" -ErrorAction SilentlyContinue
    
    [pscustomobject]@{ ExitCode = $p.ExitCode; StdOut = $out; StdErr = $err }
}

function Get-UserIdsFromFile {
    param([string]$IdListFile)
    $ids = Get-Content $IdListFile | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    if (-not $ids) { throw "ID list file is empty." }
    return $ids
}

function Initialize-WorkDirectory {
    param([string]$WorkRootDir, [string]$IdListFile)
    [System.IO.Directory]::CreateDirectory($WorkRootDir) | Out-Null
    $RunKey = "{0}_nohash_pid{1}" -f (Get-Date -Format 'yyyyMMdd_HHmmssfff'), $PID
    $WorkBaseDir = Join-Path $WorkRootDir $RunKey
    Write-Log INFO "Creating per-run work directory at: $WorkBaseDir"
    [System.IO.Directory]::CreateDirectory($WorkBaseDir) | Out-Null
    return $WorkBaseDir
}

function Select-SourceRepository {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "ソースリポジトリのフォルダを選択してください（例：R:\Knewrova.git）"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    Write-Log WARN "ソースリポジトリの選択がキャンセルされました。"
    return $null
}

# (省略: Ensure-TargetBareRepoInitialized 等の各ステップ関数はロジック変更なし。Write-Host を Write-Log に変更)
function Configure-SparseCheckout {
    param([string]$UserWorkDir, [string]$UserID)
    Set-Location $UserWorkDir
    Write-Log INFO "[2/10] Initializing sparse-checkout (cone mode)..."
    Invoke-GitCommand "sparse-checkout init --cone" "Failed sparse-checkout init"
    
    Write-Log INFO "[3/10] Setting sparse-checkout paths for $UserID..."
    $sparsePaths = @(".obsidian/", ".vscode/", ".script/", "MyWork/", "Shared/Project/", "Shared/User/", "__Attachment/", "__Document/", "__Template/")
    Invoke-GitCommand "sparse-checkout set $sparsePaths" "Failed sparse-checkout set"
}

function Main {
    $IdListFile = Select-IdListFile -Title "Select User ID List File"
    if (-not $IdListFile) { return }
    $UserIDs = Get-UserIdsFromFile -IdListFile $IdListFile
    $WorkBaseDir = Initialize-WorkDirectory -WorkRootDir $WorkRootDir -IdListFile $IdListFile
    
    $SourceRepoPath = Select-SourceRepository
    if (-not $SourceRepoPath) { return }
    
    Write-Log INFO "Starting processing for $($UserIDs.Count) users..."
    # 実際のユーザーごとのループ処理は既存ロジックを継承
}

Main
