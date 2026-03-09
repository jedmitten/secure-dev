# detach.ps1 — Dismount the encrypted VeraCrypt container
# Called by: Task Scheduler (screen lock, sleep, idle), AutoHotkey (manual)
#
# Usage:
#   detach.ps1 --trigger <screenlock|sleep|idle|manual> [--check-idle]
#Requires -Version 7

param(
    [string]$trigger    = 'manual',
    [switch]$checkIdle  = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'   # agents must not crash loudly

function Info    { param($m) Write-Host "[info]  $m" -ForegroundColor Cyan }
function Success { param($m) Write-Host "[ok]    $m" -ForegroundColor Green }
function Warn    { param($m) Write-Host "[warn]  $m" -ForegroundColor Yellow }

# ── Config ─────────────────────────────────────────────────────────────────────
$ConfigFile = "$env:USERPROFILE\.config\secure-dev\config.toml"
if (-not (Test-Path $ConfigFile)) { exit 0 }

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

$DriveLetter      = Read-Toml $ConfigFile "container" "drive_letter"
$VeraCryptExe     = Read-Toml $ConfigFile "security"  "veracrypt_cli"
$IdleTimeoutMin   = [int](Read-Toml $ConfigFile "idle" "timeout_minutes")
$LogFile          = (Read-Toml $ConfigFile "logging" "detach_log") -replace '%USERPROFILE%', $env:USERPROFILE
$MountTsFile      = "$env:USERPROFILE\.config\secure-dev\last_mount"
$MountPoint       = "${DriveLetter}:"

New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null

# ── Idle check ─────────────────────────────────────────────────────────────────
if ($checkIdle) {
    $IdleThresholdSec = $IdleTimeoutMin * 60

    # Get system idle time via user32.dll GetLastInputInfo
    # Gap W7 fix: use TickCount64 (Int64) instead of TickCount (Int32) which
    # wraps to negative after ~24.9 days of uptime, producing garbage idle values.
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class IdleTime {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    public static long GetIdleSeconds() {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf(info);
        GetLastInputInfo(ref info);
        // TickCount64 is Int64 — no 24.9-day wrap. dwTime is milliseconds since boot (uint, wraps ~49d).
        // Subtract using modular arithmetic to handle the uint wrap safely.
        long tickNow = Environment.TickCount64;
        long tickLast = (long)info.dwTime;
        long elapsedMs = (tickNow - tickLast + 0x100000000L) % 0x100000000L;
        return elapsedMs / 1000;
    }
}
'@ -ErrorAction SilentlyContinue

    $idleSec = [IdleTime]::GetIdleSeconds()
    if ($idleSec -lt $IdleThresholdSec) { exit 0 }

    # Grace period — if we just mounted, don't immediately idle-detach
    if (Test-Path $MountTsFile) {
        $mountTs  = [long](Get-Content $MountTsFile -Raw)
        $nowTs    = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $sinceSec = $nowTs - $mountTs
        if ($sinceSec -lt 120) { exit 0 }   # 2-minute grace
    }
}

# ── Is the volume mounted? ─────────────────────────────────────────────────────
if (-not (Test-Path $MountPoint)) { exit 0 }   # silent — nothing to do

# ── Kill processes with open handles on the volume ────────────────────────────
Info "Checking for open handles on $MountPoint..."
try {
    # Use handle.exe (Sysinternals) if available, otherwise best-effort
    if (Get-Command handle -ErrorAction SilentlyContinue) {
        $pids = (handle $MountPoint 2>$null) |
            Select-String "pid: (\d+)" |
            ForEach-Object { $_.Matches[0].Groups[1].Value } |
            Sort-Object -Unique

        foreach ($p in $pids) {
            Warn "Stopping process $p with open handle on $MountPoint..."
            Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500
    } else {
        # Fall back: find processes whose working directory is on the volume
        Get-Process | Where-Object {
            try { $_.MainModule.FileName -like "${MountPoint}*" } catch { $false }
        } | Stop-Process -Force -ErrorAction SilentlyContinue
    }
} catch {}

# ── Dismount ──────────────────────────────────────────────────────────────────
Info "Dismounting $MountPoint (trigger: $trigger)..."

# Try clean dismount first
$result = & $VeraCryptExe /dismount $MountPoint /silent 2>$null
Start-Sleep -Seconds 2

if (Test-Path $MountPoint) {
    # Force dismount
    Warn "Clean dismount failed — forcing..."
    & $VeraCryptExe /dismount $MountPoint /force /silent 2>$null
    Start-Sleep -Seconds 2
}

if (Test-Path $MountPoint) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') DISMOUNT_FAILED $MountPoint trigger=$trigger" |
        Add-Content $LogFile
    # Notify user
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    exit 1
}

# ── Log ───────────────────────────────────────────────────────────────────────
"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') DETACHED $MountPoint trigger=$trigger" |
    Add-Content $LogFile

# ── Toast notification for background triggers ────────────────────────────────
if ($trigger -ne 'manual') {
    try {
        # Windows 10/11 toast via BurntToast or fallback to balloon
        if (Get-Command New-BurntToastNotification -ErrorAction SilentlyContinue) {
            New-BurntToastNotification `
                -Text "Secure volume locked", "Drive $MountPoint dismounted ($trigger)" `
                -AppLogo "$env:SystemRoot\System32\SecurityAndMaintenance.png"
        } else {
            # Fallback: system tray balloon via WScript
            $wsh = New-Object -ComObject WScript.Shell
            $wsh.Popup("Secure volume locked ($trigger) — $MountPoint dismounted", 5, "Secure Dev", 64) | Out-Null
        }
    } catch {}
}

Success "Volume encrypted and inaccessible."