$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot "_Common.ps1")

$BaseDriveLetter = "R"
$DefaultSubmoduleBranch = "main"
$DefaultSubmoduleUpdate = "checkout"
$DefaultSubmoduleIgnore = "none"
$DefaultSubmoduleShallow = $true

function Select-SubmoduleParentDirectory {
    $Shell = New-Object -ComObject Shell.Application
    $Folder = $Shell.BrowseForFolder(0, "STEP 2/3: Select parent directory", 16, (Get-Location).Path)
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($Shell) | Out-Null

    if ($Folder) {
        $RelativePath = Resolve-Path -Path $Folder.Self.Path -Relative
        return $RelativePath.TrimStart('./').Replace('\', '/')
    }
    return $null
}

Write-Log INFO "--- .gitmodules Generator Script ---"

$IDListPath = Select-IdListFile -Title "STEP 1/3: Select User ID list"
if (-not $IDListPath) { Write-Log ERROR "Selection cancelled."; exit }

$SubmoduleParentDir = Select-SubmoduleParentDirectory
if ($null -eq $SubmoduleParentDir) { Write-Log ERROR "Selection cancelled."; exit }

$IDs = Get-Content $IDListPath | Where-Object { $_ -match '\S' }
$OutputFile = ".\.gitmodules"

$ExistingPaths = New-Object System.Collections.Generic.HashSet[string]
if (Test-Path $OutputFile) {
    Get-Content $OutputFile | Where-Object { $_ -match '^\s*path\s*=\s*(.+)$' } | ForEach-Object { $null = $ExistingPaths.Add($matches[1].Trim().TrimStart('/')) }
}

$AddCount = 0
foreach ($id in $IDs) {
    $CleanID = $id.Trim()
    $Path = (Join-Path $SubmoduleParentDir $CleanID).Replace('\', '/').TrimStart('/')

    if ($ExistingPaths.Contains($Path)) { continue }

    $URL = "${BaseDriveLetter}:/Submodule/$Path.git"
    $shallowStr = if ($DefaultSubmoduleShallow) { "true" } else { "false" }

    $NewEntry = @(
        "",
        "[submodule `"$Path`"]",
        "    path = $Path",
        "    url = $URL",
        "    branch = $DefaultSubmoduleBranch",
        "    update = $DefaultSubmoduleUpdate",
        "    ignore = $DefaultSubmoduleIgnore",
        "    shallow = $shallowStr"
    )
    $NewEntry | Add-Content -LiteralPath $OutputFile -Encoding UTF8
    $null = $ExistingPaths.Add($Path)
    $AddCount++
}

Write-Log OK "Added $AddCount new submodules to $OutputFile."
Read-Host "Press Enter to close."
