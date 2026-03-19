# ==============================================================================
# _Common.ps1
# 各セットアップスクリプトで利用される共通関数群
# ==============================================================================

# --- 1. ロギング ---
function Write-Log {
    param(
        [ValidateSet('INFO','OK','WARN','ERROR','DRY')]
        [string]$Level,
        [string]$Message
    )
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $color = switch ($Level) {
        'INFO'  { 'Cyan' }
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'DRY'   { 'Magenta' }
        default { 'White' }
    }
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
}

# --- 2. ユーザーID解決 ---
function Get-CurrentUserId {
    try {
        $leaf = Split-Path -Leaf $env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($leaf)) { return $env:USERNAME }
        return $leaf
    } catch { return $env:USERNAME }
}

# --- 3. 環境変数とプレースホルダの展開 ---
function Expand-EnvPlaceholders {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
    $v = [Environment]::ExpandEnvironmentVariables($Value)
    $uid = Get-CurrentUserId
    return $v.Replace('{{USER_ID}}', $uid)
}

# --- 4. .env ファイルの読み込み ---
function Load-DotEnv {
    param([string]$EnvPath)
    $map = @{}
    if (-not (Test-Path -LiteralPath $EnvPath)) { return $map }
    
    Get-Content -LiteralPath $EnvPath -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#') -or $line -notmatch '=') { return }
        $kv = $line -split '=', 2
        $key = $kv[0].Trim()
        $val = $kv[1].Trim()
        
        if ($val.StartsWith('"') -and $val.EndsWith('"')) { $val = $val.Substring(1, $val.Length - 2) }
        elseif ($val.StartsWith("'") -and $val.EndsWith("'")) { $val = $val.Substring(1, $val.Length - 2) }
        
        $map[$key] = Expand-EnvPlaceholders $val
    }
    return $map
}

# --- 5. Git 実行パスの解決 ---
function Resolve-GitExe {
    param([string]$ExplicitPath, [hashtable]$EnvMap)
    
    if ($ExplicitPath -and (Test-Path -LiteralPath $ExplicitPath)) { return $ExplicitPath }
    if ($EnvMap -and $EnvMap['GIT_EXE'] -and (Test-Path -LiteralPath $EnvMap['GIT_EXE'])) { return $EnvMap['GIT_EXE'] }
    if ($env:GIT_EXE -and (Test-Path -LiteralPath $env:GIT_EXE)) { return $env:GIT_EXE }
    
    $cand = Join-Path $env:USERPROFILE 'Software\PortableGit\cmd\git.exe'
    if (Test-Path -LiteralPath $cand) { return $cand }
    
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Path }
    
    throw "Git 実行ファイルが見つかりません。環境変数または .env に GIT_EXE を指定してください。"
}

# --- 6. 汎用 GUI: IDリストファイルの選択 ---
function Select-IdListFile {
    param([string]$Title = "Select the User ID list file (*.txt)")
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.Application]::EnableVisualStyles() | Out-Null
    
    $Dialog = New-Object System.Windows.Forms.OpenFileDialog
    $Dialog.InitialDirectory = Get-Location
    $Dialog.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
    $Dialog.Title = $Title
    
    if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $Dialog.FileName
    }
    return $null
}
