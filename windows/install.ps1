# install.ps1 — One-time bootstrap for secure Python dev environment (Windows)
# Run from the directory containing the secure-dev scripts.
# Requires: PowerShell 7+, winget or Chocolatey, internet access
#
# Usage: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#        .\install.ps1
#Requires -Version 7

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Colours ────────────────────────────────────────────────────────────────────
function Info    { param($m) Write-Host "[info]  $m" -ForegroundColor Cyan }
function Success { param($m) Write-Host "[ok]    $m" -ForegroundColor Green }
function Warn    { param($m) Write-Host "[warn]  $m" -ForegroundColor Yellow }
function Die     { param($m) Write-Host "[error] $m" -ForegroundColor Red; exit 1 }

# ── Config ─────────────────────────────────────────────────────────────────────
$ConfigDir   = "$env:USERPROFILE\.config\secure-dev"
$ConfigFile  = "$ConfigDir\config.toml"
$BinDir      = "$env:USERPROFILE\bin\secure-dev"
$SecureDir   = "$env:USERPROFILE\Secure"
$ScriptDir   = $PSScriptRoot

# ── Helpers ────────────────────────────────────────────────────────────────────
function Read-Toml {
    param($File, $Section, $Key)
    $inSection = $false
    foreach ($line in Get-Content $File) {
        if ($line -match "^\[$Section\]") { $inSection = $true; continue }
        if ($line -match "^\[" -and $inSection) { break }
        if ($inSection -and $line -match "^\s*$Key\s*=\s*(.+)$") {
            return $Matches[1].Trim().Trim('"')
        }
    }
    return $null
}

function Install-WithWinget {
    param($Id, $Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Info "Installing $Name via winget..."
        winget install --id $Id --silent --accept-source-agreements --accept-package-agreements
        Success "$Name installed"
    } else {
        Success "$Name already present"
    }
}

# ── Step 0: Preflight ──────────────────────────────────────────────────────────
Write-Host "`nSecure Dev Environment — Windows Bootstrap`n" -ForegroundColor White

if (-not ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows))) {
    Die "Windows only."
}

# Check winget
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Die "winget not found. Install App Installer from the Microsoft Store."
}

# ── Gap W1: Ensure PowerShell 7 is present before Task Scheduler wiring ───────
# Task Scheduler tasks invoke 'pwsh' (PS7). If only Windows PowerShell (5.x)
# is present, Get-Command pwsh will throw and abort mid-way.
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Info "PowerShell 7 not found — installing via winget..."
    winget install --id Microsoft.PowerShell --silent --accept-source-agreements --accept-package-agreements
    # Refresh PATH in current session so subsequent Get-Command pwsh succeeds
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('PATH', 'User')
    if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        Die "PowerShell 7 installed but 'pwsh' still not in PATH.`nRestart this shell and re-run install.ps1."
    }
    Success "PowerShell 7 installed"
} else {
    Success "PowerShell 7 present ($(& pwsh --version))"
}

# ── Step 1: Install dependencies ──────────────────────────────────────────────
Info "Checking dependencies..."

# VeraCrypt
if (-not (Test-Path "C:\Program Files\VeraCrypt\VeraCrypt.exe")) {
    Info "Installing VeraCrypt..."
    winget install --id IDRIX.VeraCrypt --silent --accept-source-agreements --accept-package-agreements
    Success "VeraCrypt installed"
} else {
    Success "VeraCrypt already present"
}

Install-WithWinget "Yubico.YubikeyManager"     "ykman"
Install-WithWinget "Bitwarden.CLI"             "bw"
Install-WithWinget "pyenv-win.pyenv-win"       "pyenv"
Install-WithWinget "astral-sh.uv"              "uv"
Install-WithWinget "Git.Git"                   "git"
Install-WithWinget "jqlang.jq"                 "jq"

# ── Step 2: Create directories ────────────────────────────────────────────────
Info "Creating directory structure..."
New-Item -ItemType Directory -Force -Path $ConfigDir  | Out-Null
New-Item -ItemType Directory -Force -Path $BinDir     | Out-Null
New-Item -ItemType Directory -Force -Path $SecureDir  | Out-Null
Success "Directories ready"

# ── Step 3: Install config.toml ───────────────────────────────────────────────
if (-not (Test-Path $ConfigFile)) {
    Copy-Item "$ScriptDir\config.toml" $ConfigFile
    # Expand %USERNAME% in config
    (Get-Content $ConfigFile) -replace '%USERNAME%', $env:USERNAME | Set-Content $ConfigFile
    Success "config.toml installed at $ConfigFile"
} else {
    Warn "config.toml already exists — skipping (edit manually if needed)"
}

# ── Step 4: Install scripts ───────────────────────────────────────────────────
Info "Installing scripts to $BinDir..."
foreach ($script in @('mount-secure.ps1', 'detach.ps1', 'create-container.ps1')) {
    if (Test-Path "$ScriptDir\$script") {
        Copy-Item "$ScriptDir\$script" "$BinDir\$script" -Force
        Success "$script installed"
    } else {
        Warn "$script not found in $ScriptDir — skipping"
    }
}

# ── Step 5: Add bin dir to user PATH ─────────────────────────────────────────
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($userPath -notlike "*$BinDir*") {
    Info "Adding $BinDir to user PATH..."
    [Environment]::SetEnvironmentVariable('PATH', "$userPath;$BinDir", 'User')
    Success "PATH updated — restart your shell"
} else {
    Success "$BinDir already in PATH"
}

# ── Step 6: Install Task Scheduler tasks ──────────────────────────────────────
Info "Installing Task Scheduler tasks..."

$detachScript = "$BinDir\detach.ps1"
$pwsh = (Get-Command pwsh).Source

# Helper to register a task cleanly
function Register-SecureDevTask {
    param($TaskName, $Trigger, $TriggerArgs)
    $action = New-ScheduledTaskAction `
        -Execute $pwsh `
        -Argument "-NonInteractive -WindowStyle Hidden -File `"$detachScript`" $TriggerArgs"
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal `
        -UserId $env:USERNAME `
        -LogonType Interactive `
        -RunLevel Limited

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask `
        -TaskName  $TaskName `
        -Action    $action `
        -Trigger   $Trigger `
        -Settings  $settings `
        -Principal $principal `
        -Force | Out-Null
    Success "Task registered: $TaskName"
}

# Screen lock — Event ID 4800 (workstation locked)
# Requires "Audit Other Logon/Logoff Events" in Local Security Policy
# Gap W2 fix: do not nest here-strings — build the full XML as a single literal
$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <EventTrigger>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Security"&gt;&lt;Select Path="Security"&gt;*[System[EventID=4800]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>$pwsh</Command>
      <Arguments>-NonInteractive -WindowStyle Hidden -File "$detachScript" --trigger screenlock</Arguments>
    </Exec>
  </Actions>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <ExecutionTimeLimit>PT1M</ExecutionTimeLimit>
  </Settings>
  <Principals>
    <Principal id="Author">
      <UserId>$env:USERDOMAIN\$env:USERNAME</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
</Task>
"@
$taskXml | Out-File "$env:TEMP\securedev-screenlock.xml" -Encoding Unicode
schtasks /Create /TN "SecureDev\ScreenLock" /XML "$env:TEMP\securedev-screenlock.xml" /F | Out-Null
Remove-Item "$env:TEMP\securedev-screenlock.xml" -ErrorAction SilentlyContinue
Success "Task registered: SecureDev\ScreenLock"

# Sleep trigger — Event ID 42 (system entering sleep, Kernel-Power provider)
$sleepXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <EventTrigger>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=42]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>$pwsh</Command>
      <Arguments>-NonInteractive -WindowStyle Hidden -File "$detachScript" --trigger sleep</Arguments>
    </Exec>
  </Actions>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <ExecutionTimeLimit>PT1M</ExecutionTimeLimit>
  </Settings>
  <Principals>
    <Principal id="Author">
      <UserId>$env:USERDOMAIN\$env:USERNAME</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
</Task>
"@
$sleepXml | Out-File "$env:TEMP\securedev-sleep.xml" -Encoding Unicode
schtasks /Create /TN "SecureDev\Sleep" /XML "$env:TEMP\securedev-sleep.xml" /F | Out-Null
Remove-Item "$env:TEMP\securedev-sleep.xml" -ErrorAction SilentlyContinue
Success "Task registered: SecureDev\Sleep"

# Idle trigger — Gap W3 fix: set RepetitionDuration to indefinite (PT0S = infinite in schtasks XML)
# Build via XML to avoid the PS cmdlet's -Once + -RepetitionInterval bug on Windows 11
$idleXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <TimeTrigger>
      <Repetition>
        <Interval>PT${idleInterval}S</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <StartBoundary>$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>$pwsh</Command>
      <Arguments>-NonInteractive -WindowStyle Hidden -File "$detachScript" --trigger idle --check-idle</Arguments>
    </Exec>
  </Actions>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <ExecutionTimeLimit>PT1M</ExecutionTimeLimit>
  </Settings>
  <Principals>
    <Principal id="Author">
      <UserId>$env:USERDOMAIN\$env:USERNAME</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
</Task>
"@
$idleXml | Out-File "$env:TEMP\securedev-idle.xml" -Encoding Unicode
schtasks /Create /TN "SecureDev\IdleCheck" /XML "$env:TEMP\securedev-idle.xml" /F | Out-Null
Remove-Item "$env:TEMP\securedev-idle.xml" -ErrorAction SilentlyContinue
Success "Task registered: SecureDev\IdleCheck"

# ── Step 7: Enable audit policy for screen lock event (requires elevation) ────
Info "Checking audit policy for screen lock events (Event ID 4800)..."
$auditResult = auditpol /get /subcategory:"Other Logon/Logoff Events" 2>$null
if ($auditResult -notmatch "Success") {
    Warn "Screen lock event (4800) audit not enabled. Enabling now (requires admin)..."
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        auditpol /set /subcategory:"Other Logon/Logoff Events" /success:enable /failure:enable | Out-Null
        Success "Audit policy enabled for screen lock events"
    } else {
        Warn "Run this as Administrator to enable audit policy:"
        Write-Host '  auditpol /set /subcategory:"Other Logon/Logoff Events" /success:enable /failure:enable'
        Warn "Without this, the screen lock trigger will not fire."
    }
}

# ── Step 8: AutoHotkey keyboard shortcut ──────────────────────────────────────
# Gap W4 fix: script the AHK install and .ahk file creation rather than leaving
# it as a manual step. AutoHotkey v2 is available via winget.
Info "Setting up AutoHotkey keyboard shortcut..."

if (-not (Get-Command AutoHotkey -ErrorAction SilentlyContinue) -and
    -not (Test-Path "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe")) {
    Info "Installing AutoHotkey v2 via winget..."
    winget install --id AutoHotkey.AutoHotkey --silent --accept-source-agreements --accept-package-agreements
    Success "AutoHotkey v2 installed"
} else {
    Success "AutoHotkey already present"
}

# Write the .ahk script — Gap W8 fix: use A_UserProfile directly, not A_MyDocuments\..\
$ahkPath = "$env:USERPROFILE\Documents\SecureDev.ahk"
$ahkContent = @"
; SecureDev — Lock Secure Volume
; Ctrl+Shift+L dismounts the VeraCrypt container via detach.ps1
; Place this file in your Documents folder and add a shortcut to shell:startup
#Requires AutoHotkey v2.0
^+l::Run('pwsh.exe -NonInteractive -WindowStyle Hidden -File "' . A_UserProfile . '\bin\secure-dev-windows\detach.ps1" --trigger manual')
"@

if (-not (Test-Path $ahkPath)) {
    $ahkContent | Set-Content $ahkPath -Encoding UTF8
    Success "AutoHotkey script written to $ahkPath"
} else {
    Warn "$ahkPath already exists — skipping (verify it points to $BinDir\detach.ps1)"
}

# Add to shell:startup so it auto-runs at login
$startupDir = [Environment]::GetFolderPath('Startup')
$startupShortcut = "$startupDir\SecureDev.lnk"
if (-not (Test-Path $startupShortcut)) {
    # Determine AHK executable path
    $ahkExe = Get-ChildItem "$env:ProgramFiles\AutoHotkey" -Filter "AutoHotkey*.exe" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if ($ahkExe) {
        $wsh = New-Object -ComObject WScript.Shell
        $sc  = $wsh.CreateShortcut($startupShortcut)
        $sc.TargetPath  = $ahkExe
        $sc.Arguments   = "`"$ahkPath`""
        $sc.Description = "SecureDev lock shortcut"
        $sc.Save()
        Success "Startup shortcut created — shortcut active after next login"
        # Also launch immediately so it's active now
        Start-Process $ahkExe -ArgumentList "`"$ahkPath`"" -WindowStyle Hidden
        Success "AutoHotkey script launched (Ctrl+Shift+L now active)"
    } else {
        Warn "AutoHotkey executable not found — launch $ahkPath manually to activate shortcut"
    }
} else {
    Success "Startup shortcut already present"
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Bootstrap complete." -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:"
Write-Host "  1. Restart your shell (PATH update)"
Write-Host "  2. Run: create-container.ps1"
Write-Host "  3. Run: mount-secure.ps1"
Write-Host "  4. Lock shortcut: Ctrl+Shift+L (active now and at every login)"
Write-Host ""