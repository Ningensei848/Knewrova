[CmdletBinding()]
param(
    [string]$NameOverride,
    [switch]$DryRun
)

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $ScriptRoot "_Common.ps1")

function Get-OutlookIdentity {
    try {
        $ol = [Runtime.InteropServices.Marshal]::GetActiveObject("Outlook.Application")
    } catch {
        try { $ol = New-Object -ComObject Outlook.Application } catch { throw "[E200] Outlook.Application を作成/取得できませんでした。" }
    }

    $session = $ol.Session
    $accounts = @(); if ($session -and $session.Accounts) { foreach ($a in $session.Accounts) { $accounts += $a } }
    if (-not $accounts) { throw "[E210] Outlookプロファイルにアカウントが見つかりませんでした。" }

    $primary = $accounts | Select-Object -First 1
    $exu = $null
    if ($session -and $session.CurrentUser -and $session.CurrentUser.AddressEntry) {
        try { if ($session.CurrentUser.AddressEntry.Type -eq "EX") { $exu = $session.CurrentUser.AddressEntry.GetExchangeUser() } } catch {}
    }

    $displayName = $null
    if ($exu -and $exu.Name) { $displayName = $exu.Name }
    elseif ($primary -and $primary.DisplayName) { $displayName = $primary.DisplayName }
    elseif ($session.CurrentUser -and $session.CurrentUser.Name) { $displayName = $session.CurrentUser.Name }

    $smtp = $null
    if ($primary -and $primary.SmtpAddress) { $smtp = $primary.SmtpAddress }
    else {
        foreach ($acct in $accounts) { if ($acct.SmtpAddress) { $smtp = $acct.SmtpAddress; break } }
        if (-not $smtp -and $exu) { $smtp = $exu.PrimarySmtpAddress }
    }

    if (-not $displayName) { throw "[E220] Outlookの表示名を取得できませんでした。" }
    if (-not $smtp) { throw "[E230] SMTPアドレスの自動特定に失敗しました。" }

    return [PSCustomObject]@{ DisplayName = $displayName; SmtpAddress = $smtp }
}

function Build-GitUserName {
    param([string]$DisplayName, [string]$OsUserName, [string]$Override)
    if ($Override) { return $Override }
    return "${DisplayName}_(${OsUserName})"
}

function Set-GitGlobalIdentity {
    param([string]$GitExe, [string]$Name, [string]$Email, [switch]$Dry)
    
    Write-Log INFO "設定予定: user.name = '$Name'"
    Write-Log INFO "設定予定: user.email = '$Email'"

    if ($Dry) {
        Write-Log DRY "[DryRun] 実行せずに内容のみ表示します。"
        Write-Log DRY "> $GitExe config --global user.name `"$Name`""
        Write-Log DRY "> $GitExe config --global user.email `"$Email`""
        return
    }

    & $GitExe config --global user.name $Name
    if ($LASTEXITCODE -ne 0) { throw "[E400] Git user.name の設定に失敗しました。" }
    
    & $GitExe config --global user.email $Email
    if ($LASTEXITCODE -ne 0) { throw "[E400] Git user.email の設定に失敗しました。" }

    Write-Log OK "git --global の name/email を更新しました。"
}

# --- Main ---
try {
    $envMap = Load-DotEnv -EnvPath (Join-Path (Get-Location).Path '.env')
    $GitExe = Resolve-GitExe -EnvMap $envMap

    $outId = Get-OutlookIdentity
    $osUser = Get-CurrentUserId
    $name = Build-GitUserName -DisplayName $outId.DisplayName -OsUserName $osUser -Override $NameOverride

    Set-GitGlobalIdentity -GitExe $GitExe -Name $name -Email $outId.SmtpAddress -Dry:$DryRun

} catch {
    Write-Log ERROR $_.Exception.Message
    exit 1
}
