# ==============================================================================
# Bare Repository Creation Script (Air-Gap/SMB Support)
# Creates R:\<ID>.git bare repositories and pushes an initial commit.
# ==============================================================================

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot "_Common.ps1")

$BaseDriveLetter = "R"

function Select-TargetBaseDirectory {
    if (-not (Test-Path "${BaseDriveLetter}:/")) {
        Write-Log ERROR "Target drive '${BaseDriveLetter}' is not mounted."
        return $null
    }

    $Shell = New-Object -ComObject Shell.Application
    $Folder = $Shell.BrowseForFolder(0, "Select the base directory for bare repos", 16, "${BaseDriveLetter}:\")
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($Shell) | Out-Null

    if ($Folder) { return $Folder.Self.Path.Replace('\', '/') }
    return $null
}

Write-Log INFO "--- Bare Repository Creator Script ---"

$ParentRepoRoot = Get-Location
$SourceGitIgnore = Join-Path $ParentRepoRoot ".gitignore"
$SourceGitAttributes = Join-Path $ParentRepoRoot ".gitattributes"

$IDListPath = Select-IdListFile -Title "STEP 1/3: Select the User ID list file"
if (-not $IDListPath) { Write-Log ERROR "File selection cancelled."; exit }

$TargetBasePath = Select-TargetBaseDirectory
if (-not $TargetBasePath) { Write-Log ERROR "Directory selection cancelled."; exit }

$IDs = Get-Content $IDListPath | Where-Object { $_ -match '\S' }
Write-Log INFO "Number of bare repos to create: $($IDs.Count)"

$TempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $TempDirectory | Out-Null

$SuccessCount = 0
$FailureCount = 0
$GitExe = Resolve-GitExe

foreach ($ID in $IDs) {
    $CleanID = $ID.Trim()
    $RepoPath = (Join-Path $TargetBasePath "${CleanID}.git").Replace('\', '/')
    $TempClonePath = Join-Path $TempDirectory $CleanID

    if (Test-Path $RepoPath) {
        Write-Log WARN "[SKIP] Bare repo already exists at $RepoPath"
        $FailureCount++
        continue
    }

    try {
        Write-Log INFO "Processing ${CleanID}..."
        & $GitExe init --bare $RepoPath | Out-Null
        & $GitExe clone $RepoPath $TempClonePath | Out-Null
        
        Set-Location $TempClonePath
        & $GitExe checkout -b main | Out-Null
        if (Test-Path $SourceGitIgnore) { Copy-Item $SourceGitIgnore -Destination . }
        if (Test-Path $SourceGitAttributes) { Copy-Item $SourceGitAttributes -Destination . }
        
        & $GitExe add . | Out-Null
        & $GitExe commit -m "Initial commit" | Out-Null
        & $GitExe push -u origin main | Out-Null
        
        Set-Location $ParentRepoRoot
        Write-Log OK "Successfully initialized ${CleanID}."
        $SuccessCount++
    } catch {
        Write-Log ERROR "Exception for ${CleanID}: $($_.Exception.Message)"
        $FailureCount++
        Set-Location $ParentRepoRoot
    }
}

Remove-Item -Recurse -Force $TempDirectory
Write-Log OK "Completed. Success: $SuccessCount, Failed: $FailureCount"
Read-Host "Press Enter to close."
