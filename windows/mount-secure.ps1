# mount-secure.ps1 — Mount the encrypted VeraCrypt container
# Retrieves password via HMAC-unwrap from Credential Manager + YubiKey touch.
# Falls back to Bitwarden if credential cache is stale or YubiKey absent.
#Requires -Version 7

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info    { param($m) Write-Host "[info]  $m" -ForegroundColor Cyan }
function Success { param($m) Write-Host "[ok]    $m" -ForegroundColor Green }
function Warn    { param($m) Write-Host "[warn]  $m" -ForegroundColor Yellow }
function Die     { param($m) Write-Host "[error] $m" -ForegroundColor Red; exit 1 }

# ── Config ─────────────────────────────────────────────────────────────────────
$ConfigFile = "$env:USERPROFILE\.config\secure-dev\config.toml"
if (-not (Test-Path $ConfigFile)) { Die "config.toml not found. Run install.ps1 first." }

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

$ContainerPath  = (Read-Toml $ConfigFile "container" "path") -replace '%USERNAME%', $env:USERNAME
$DriveLetter    = Read-Toml $ConfigFile "container" "drive_letter"
$CredTarget     = Read-Toml $ConfigFile "security" "credential_target"
$CredUser       = Read-Toml $ConfigFile "security" "credential_username"
$YkSlot         = Read-Toml $ConfigFile "security" "yubikey_slot"
$SaltPath       = (Read-Toml $ConfigFile "security" "hmac_salt_path") -replace '%USERPROFILE%', $env:USERPROFILE
$BwItem         = Read-Toml $ConfigFile "security" "bitwarden_item_name"
$VeraCryptExe   = Read-Toml $ConfigFile "security" "veracrypt_cli"
$LogFile        = (Read-Toml $ConfigFile "logging" "detach_log") -replace '%USERPROFILE%', $env:USERPROFILE
$MountTsFile    = "$env:USERPROFILE\.config\secure-dev\last_mount"

# ── P/Invoke: read from Windows Credential Manager ───────────────────────────
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WinCredRead {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool CredRead(string target, uint type, uint reservedFlag, out IntPtr credentialPtr);
    [DllImport("advapi32.dll")]
    public static extern void CredFree([In] IntPtr cred);
}
'@ -ErrorAction SilentlyContinue

# ── Preflight ──────────────────────────────────────────────────────────────────
Write-Host "`nSecure Dev — Mount`n" -ForegroundColor White

if (-not (Test-Path $ContainerPath)) { Die "Container not found at $ContainerPath. Run create-container.ps1 first." }

# Idempotent — already mounted?
$mountPoint = "${DriveLetter}:"
if (Test-Path $mountPoint) {
    Success "Volume already mounted at $mountPoint"
    Write-Host "  cd $mountPoint\repos"
    exit 0
}

# ── Read wrapped password from Credential Manager ────────────────────────────
function Get-WrappedFromCredMgr {
    $credPtr = [IntPtr]::Zero
    $ok = [WinCredRead]::CredRead($CredTarget, 1, 0, [ref]$credPtr)
    if (-not $ok) { return $null }
    $cred = [Runtime.InteropServices.Marshal]::PtrToStructure($credPtr,
        [type][WinCredRead+CREDENTIAL])
    $blobBytes = New-Object byte[] $cred.CredentialBlobSize
    [Runtime.InteropServices.Marshal]::Copy($cred.CredentialBlob, $blobBytes, 0, $cred.CredentialBlobSize)
    [WinCredRead]::CredFree($credPtr)
    return [System.Text.Encoding]::Unicode.GetString($blobBytes)
}

# ── Retrieve password via HMAC-unwrap ─────────────────────────────────────────
function Get-PasswordFromCredMgr {
    # 1. Check YubiKey
    $ykInfo = ykman info 2>$null
    if (-not $ykInfo) { return $null }

    # 2. Read HMAC salt
    if (-not (Test-Path $SaltPath)) { return $null }
    $hmacSalt = Get-Content $SaltPath -Raw

    # 3. Derive HMAC from YubiKey (touch required)
    Info "Touch YubiKey to unlock..."
    $hmacOutput = ($hmacSalt | ykman otp calculate $YkSlot - 2>$null)
    if (-not $hmacOutput) { return $null }

    # 4. Read wrapped password from Credential Manager
    $wrappedB64 = Get-WrappedFromCredMgr
    if (-not $wrappedB64) { return $null }

    # 5. XOR-unwrap
    $wrapped  = [Convert]::FromBase64String($wrappedB64)
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($hmacOutput)
    $pwBytes  = New-Object byte[] $wrapped.Length
    for ($i = 0; $i -lt $wrapped.Length; $i++) {
        $pwBytes[$i] = $wrapped[$i] -bxor $keyBytes[$i % $keyBytes.Length]
    }
    return [System.Text.Encoding]::UTF8.GetString($pwBytes)
}

function Get-PasswordFromBitwarden {
    Info "Falling back to Bitwarden..."
    $bwStatus = $null
    try {
        $bwStatus = (bw status 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue).status
    } catch {}

    if ($bwStatus -ne 'unlocked') {
        Info "Unlocking Bitwarden vault (YubiKey FIDO2 will be prompted)..."
        $env:BW_SESSION = (bw unlock --raw)
    }
    return (bw get password $BwItem 2>$null)
}

# ── Attempt Credential Manager path first ─────────────────────────────────────
$VcPassword = $null

try {
    $VcPassword = Get-PasswordFromCredMgr
} catch {
    $VcPassword = $null
}

if (-not $VcPassword) {
    Warn "Credential Manager path failed or YubiKey not present — trying Bitwarden..."
    $VcPassword = Get-PasswordFromBitwarden
    if (-not $VcPassword) { Die "Could not retrieve password from Bitwarden." }

    # Opportunistically re-cache in Credential Manager if YubiKey now available
    $ykNow = ykman info 2>$null
    if ($ykNow -and (Test-Path $SaltPath)) {
        try {
            $hmacSalt2  = Get-Content $SaltPath -Raw
            $hmacOut2   = ($hmacSalt2 | ykman otp calculate $YkSlot - 2>$null)
            if ($hmacOut2) {
                $pwB   = [System.Text.Encoding]::UTF8.GetBytes($VcPassword)
                $keyB  = [System.Text.Encoding]::UTF8.GetBytes($hmacOut2)
                $wrapB = New-Object byte[] $pwB.Length
                for ($i = 0; $i -lt $pwB.Length; $i++) {
                    $wrapB[$i] = $pwB[$i] -bxor $keyB[$i % $keyB.Length]
                }
                $newWrapped = [Convert]::ToBase64String($wrapB)
                # Write back to Credential Manager (reuse P/Invoke from create-container pattern)
                cmdkey /generic:$CredTarget /user:$CredUser /pass:$newWrapped | Out-Null
                Success "Credential Manager cache refreshed"
                $hmacOut2 = $null; $wrapB = $null
            }
        } catch { Warn "Could not refresh Credential Manager cache: $_" }
    }
}

if (-not $VcPassword) { Die "Failed to retrieve container password." }

# ── Mount ──────────────────────────────────────────────────────────────────────
Info "Mounting $ContainerPath as drive ${DriveLetter}:..."

# Gap W6 fix: never pass password as CLI arg — use a temp keyfile, delete immediately
$tmpKeyFile = [System.IO.Path]::GetTempFileName()
try {
    $acl = Get-Acl $tmpKeyFile
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $env:USERNAME, 'FullControl', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl $tmpKeyFile $acl
    [System.IO.File]::WriteAllText($tmpKeyFile, $VcPassword, [System.Text.Encoding]::UTF8)
    $VcPassword = $null
    [System.GC]::Collect()

    & $VeraCryptExe /volume $ContainerPath /letter $DriveLetter /keyfile $tmpKeyFile /silent /mountoption ro:n
} finally {
    if (Test-Path $tmpKeyFile) {
        $zeros = New-Object byte[] ([System.IO.FileInfo]$tmpKeyFile).Length
        [System.IO.File]::WriteAllBytes($tmpKeyFile, $zeros)
        Remove-Item $tmpKeyFile -Force
    }
}

Start-Sleep -Seconds 3
if (-not (Test-Path $mountPoint)) {
    Die "Mount failed — check VeraCrypt logs. Drive letter ${DriveLetter}: may be in use."
}
Success "Mounted at $mountPoint"

# ── Reset idle timestamp ───────────────────────────────────────────────────────
[DateTimeOffset]::UtcNow.ToUnixTimeSeconds() | Set-Content $MountTsFile

# ── Log ───────────────────────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null
"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') MOUNTED  $mountPoint" | Add-Content $LogFile

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Ready. Start your session:" -ForegroundColor Green
Write-Host ""
Write-Host "  cd $mountPoint\repos\<project>"
Write-Host "  .venv\Scripts\Activate.ps1"
Write-Host ""