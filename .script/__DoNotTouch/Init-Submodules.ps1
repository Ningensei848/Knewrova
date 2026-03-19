[CmdletBinding()]
param(
    [string]$EnvPath = ".\.env",
    [ValidateSet('Stable','Latest')] [string]$Mode = 'Stable',
    [switch]$DryRun,
    [switch]$Summary,
    [string]$GitExe,
    [switch]$Lock = $true,
    [switch]$NoCommit
)

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot "_Common.ps1")

$script:GitCmd = 'git'

# --- Utility Functions ---

function To-Bool {
    param([string]$Text, [bool]$Default=$false)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Default }
    switch ($Text.ToLowerInvariant()) {
        'true' { return $true }; '1' { return $true }; 'yes' { return $true }
        'false' { return $false }; '0' { return $false }; 'no' { return $false }
        default { return $Default }
    }
}

function Convert-BashDateFormatToDotNet {
    param([string]$BashFmt)
    $pairs = @( @('%Y','yyyy'), @('%y','yy'), @('%m','MM'), @('%d','dd'), @('%H','HH'), @('%M','mm'), @('%S','ss'), @('%z','zzz'), @('%Z','zzz') )
    $dotnet = $BashFmt
    foreach ($p in $pairs) { $dotnet = $dotnet.Replace($p[0], $p[1]) }
    return $dotnet
}

function Get-Timestamp {
    param([string]$TimeZoneId, [string]$BashFmt='%Y-%m-%d %H:%M:%S')
    $fmt = Convert-BashDateFormatToDotNet -BashFmt $BashFmt
    try {
        if ([string]::IsNullOrWhiteSpace($TimeZoneId)) { return (Get-Date).ToString($fmt) }
        $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
        $utc = [DateTime]::UtcNow
        $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($utc, $tz)
        return $local.ToString($fmt)
    } catch {
        Write-Log WARN "Invalid TIMEZONE '$TimeZoneId', fallback to local."
        return (Get-Date).ToString($fmt)
    }
}

function Test-GitAvailable {
    param([string]$GitExeCandidate)
    try { & $GitExeCandidate --version | Out-Null; return $true } catch { return $false }
}

function Invoke-GitArgs {
    param([string[]]$Arguments, [switch]$Quiet)
    if ($DryRun) {
        if (-not $Quiet) { Write-Log DRY "SKIP actual execution: git $($Arguments -join ' ')" }
        return 0
    }
    & $script:GitCmd @Arguments
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $Quiet) { Write-Log WARN "git exit code: $code (cmd: git $($Arguments -join ' '))" }
    return $code
}

function Acquire-Lock {
    param([string]$LockPath)
    if (-not $Lock) { Write-Log WARN "[Lock] Disabled. Skipping."; return $true }
    try {
        $fullLock = [System.IO.Path]::GetFullPath($LockPath)
        $dir = [System.IO.Path]::GetDirectoryName($fullLock)
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
        
        if ([System.IO.File]::Exists($fullLock)) { Write-Log WARN "[Lock] Already exists: $fullLock"; return $false }
        
        $fs = New-Object System.IO.FileStream($fullLock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $enc = New-Object System.Text.UTF8Encoding($true)
        $bytes = $enc.GetBytes(("{0} {1}" -f (Get-Date), $env:COMPUTERNAME))
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush(); $fs.Dispose()
        
        Write-Log OK "[Lock] Acquired."
        return $true
    } catch {
        Write-Log ERROR "[Lock] Acquire failed: $($_.Exception.Message)"
        return $false
    }
}

function Release-Lock {
    param([string]$LockPath)
    if (-not $Lock) { return }
    try {
        $fullLock = [System.IO.Path]::GetFullPath($LockPath)
        if ([System.IO.File]::Exists($fullLock)) {
            [System.IO.File]::Delete($fullLock)
            Write-Log OK "[Lock] Released: $fullLock"
        }
    } catch { Write-Log WARN "[Lock] Release failed: $($_.Exception.Message)" }
}

# --- Gitmodules Parsing & Checks ---

function Get-GitmodulesKeys {
    $keys = & $script:GitCmd config --file .gitmodules --name-only --get-regexp "submodule\..*\.path" 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    return $keys
}

function Get-GitmodulesValue {
    param([string]$Name, [switch]$Optional)
    $val = & $script:GitCmd config --file .gitmodules $Name 2>$null
    if ($LASTEXITCODE -ne 0 -and -not $Optional) { Write-Log WARN "Failed to read '$Name' from .gitmodules" }
    return $val
}

function Test-GitlinkExistsInHead {
    param([string]$SubmodulePath)
    $output = & $script:GitCmd ls-tree HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) { return $false }
    foreach ($line in $output) {
        if ($line -match '^\s*160000\s+commit\s+[0-9a-fA-F]+\s+(.+)$' -and $Matches[1].Trim() -eq $SubmodulePath) { return $true }
    }
    return $false
}

# --- Main Flow ---

function Main {
    Write-Log INFO "Setup submodules (Env + Safety + Register + Finalize)"
    $envVals = Load-DotEnv -EnvPath $EnvPath
    
    $gitUse = Resolve-GitExe -ExplicitPath $GitExe -EnvMap $envVals
    if (-not (Test-GitAvailable -GitExeCandidate $gitUse)) { throw "git not available: $gitUse" }
    $script:GitCmd = $gitUse

    # Handle DryRun override from .env
    $dryUse = $DryRun
    if (-not $dryUse -and $envVals.ContainsKey('DRY_RUN')) { $dryUse = To-Bool $envVals['DRY_RUN'] }
    if ($dryUse) { Write-Log DRY "Mode: DryRun (No changes will be made)" }

    # Generate Commit Message
    $prefix = if ($envVals['COMMIT_MESSAGE_PREFIX']) { $envVals['COMMIT_MESSAGE_PREFIX'] } else { 'Setup Submodules' }
    $bashFmt = if ($envVals['DATE_FORMAT']) { $envVals['DATE_FORMAT'] } else { '%Y-%m-%d %H:%M:%S' }
    $tzId = $envVals['TIMEZONE']
    $message = "$prefix - $(Get-Timestamp -TimeZoneId $tzId -BashFmt $bashFmt)"

    # Get Submodules
    $keys = Get-GitmodulesKeys
    if (-not $keys) { throw "No submodule path keys found in .gitmodules" }
    Write-Log INFO "Submodules defined: $($keys.Count)"

    $lockPath = ".\.script\__DoNotTouch\.setup_submodules.lock"
    if (-not (Acquire-Lock -LockPath $lockPath)) { throw "Lock acquisition failed." }

    try {
        # --- Phase 1: Register ---
        Write-Log INFO "--- Phase 1: Registering Submodules ---"
        $results = @()
        $validPaths = @()

        foreach ($key in $keys) {
            $name = $key -replace '^submodule\.', '' -replace '\.path$', ''
            $path = Get-GitmodulesValue -Name ("submodule.{0}.path" -f $name)
            $url = Get-GitmodulesValue -Name ("submodule.{0}.url" -f $name)
            $branch = Get-GitmodulesValue -Name ("submodule.{0}.branch" -f $name) -Optional
            
            if (-not $path -or -not $url) { Write-Log WARN "[$name] Missing URL or Path. Skipping."; continue }
            $validPaths += $path

            if (Test-Path -LiteralPath $path) {
                $items = Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue
                if ($items) { Write-Log WARN "[$name] Path non-empty: $path -> Skip add"; continue }
            }

            if (Test-GitlinkExistsInHead -SubmodulePath $path) {
                Write-Log WARN "[$name] HEAD already has gitlink. Skipping add."
                continue
            }

            $addArgs = @('submodule','add','--force')
            if ($branch) { $addArgs += @('--branch', $branch) }
            $addArgs += @($url, $path)

            $code = Invoke-GitArgs -Arguments $addArgs -Quiet
            if ($code -ne 0) { Write-Log ERROR "[$name] Add failed" }
            else { Write-Log OK "[$name] Add done" }
        }

        # --- Phase 2: Finalize ---
        Write-Log INFO "--- Phase 2: Finalizing Submodules ---"
        
        # Stage .gitmodules and paths
        $stagedCount = 0
        if (Test-Path -LiteralPath ".gitmodules") {
            Invoke-GitArgs -Arguments @('add','.gitmodules') -Quiet | Out-Null
            $stagedCount++
        }
        foreach ($p in $validPaths) {
            if (Test-Path -LiteralPath $p) {
                Invoke-GitArgs -Arguments @('add',$p) -Quiet | Out-Null
                $stagedCount++
            }
        }

        # Commit
        if (-not $NoCommit) {
            & $script:GitCmd diff --cached --quiet 2>$null
            if ($LASTEXITCODE -ne 0) {
                $code = Invoke-GitArgs -Arguments @('commit','-m',$message) -Quiet
                if ($code -eq 0) { Write-Log OK "Commit done." }
            } else {
                Write-Log INFO "Nothing to commit (No staged changes)."
            }
        } else {
            Write-Log WARN "NoCommit: commit skipped."
        }

        # Sync and Update
        Invoke-GitArgs -Arguments @('submodule','sync','--recursive') -Quiet | Out-Null
        $argsUpdate = if ($Mode -eq 'Latest') { @('submodule','update','--remote','--recursive','--merge') } else { @('submodule','update','--recursive','--merge') }
        Invoke-GitArgs -Arguments $argsUpdate -Quiet | Out-Null

        Write-Log OK "Finished submodule setup."

        # --- Phase 3: Summary ---
        if ($Summary) {
            Write-Log INFO "[Setup Summary] Mode: $Mode, DryRun: $dryUse, GitExe: $gitUse"
            Write-Log INFO "Processed submodules: $($keys.Count)"
            Write-Log INFO "Commit Message: $message"
        }
        Write-Log INFO "Recommended next: git push"

    } finally {
        Release-Lock -LockPath $lockPath
    }
}

try { Main } catch { Write-Log ERROR "[Error] $($_.Exception.Message)"; exit 1 }
