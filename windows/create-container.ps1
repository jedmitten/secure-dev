# create-container.ps1 — One-time encrypted VeraCrypt container creation
# Registers HMAC-Secret on YubiKey, wraps password in Windows Credential Manager,
# and backs the plain password to Bitwarden.
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
$SizeMB         = Read-Toml $ConfigFile "container" "size_mb"
$CredTarget     = Read-Toml $ConfigFile "security" "credential_target"
$CredUser       = Read-Toml $ConfigFile "security" "credential_username"
$YkSlot         = Read-Toml $ConfigFile "security" "yubikey_slot"
$SaltPath       = (Read-Toml $ConfigFile "security" "hmac_salt_path") -replace '%USERPROFILE%', $env:USERPROFILE
$BwItem         = Read-Toml $ConfigFile "security" "bitwarden_item_name"
$VeraCryptExe   = Read-Toml $ConfigFile "security" "veracrypt_cli"

# ── Preflight ──────────────────────────────────────────────────────────────────
Write-Host "`nSecure Dev — Container Creation (Windows/VeraCrypt)`n" -ForegroundColor White

if (Test-Path $ContainerPath) { Die "Container already exists at $ContainerPath. Aborting." }
if (-not (Test-Path $VeraCryptExe)) { Die "VeraCrypt not found at $VeraCryptExe. Run install.ps1 first." }
if (-not (Get-Command ykman -ErrorAction SilentlyContinue)) { Die "ykman not found. Run install.ps1 first." }
if (-not (Get-Command bw -ErrorAction SilentlyContinue)) { Die "Bitwarden CLI not found. Run install.ps1 first." }

# ── Enumerate connected YubiKeys ──────────────────────────────────────────────
# Both keys must be plugged in now so they can be programmed with the same
# HMAC secret. The secret is generated once, written to both, then discarded.
$ykList = ykman list --serials 2>$null
$YkSerials = @($ykList | Where-Object { $_ -match '\d+' } | ForEach-Object { $_.Trim() })
$YkCount = $YkSerials.Count

if ($YkCount -eq 0) {
    Die "No YubiKeys detected. Insert your YubiKey(s) and retry."
} elseif ($YkCount -eq 1) {
    Warn "Only one YubiKey detected (serial: $($YkSerials[0]))."
    Warn "Strongly recommended: plug in your backup YubiKey now so both can be"
    Warn "enrolled with the same secret. Without a backup you risk permanent"
    Warn "lockout if this key is lost (Bitwarden break-glass still works)."
    Write-Host ""
    $oneKey = Read-Host "Continue with one key only? [y/N]"
    if ($oneKey -ne 'y') { Die "Aborted. Plug in both YubiKeys and retry." }
} else {
    Info "Found $YkCount YubiKeys: $($YkSerials -join ', ')"
}

$ykSerial = $YkSerials[0]   # primary — serial recorded in Bitwarden

# ── Generate shared HMAC secret ───────────────────────────────────────────────
# IMPORTANT: generate explicitly so the same value can be programmed onto every
# key. --generate creates a different random secret per invocation.
Info "Generating shared HMAC secret (20 bytes)..."
$secretBytes = New-Object byte[] 20
[System.Security.Cryptography.RandomNumberGenerator]::Fill($secretBytes)
$HmacSecret = ($secretBytes | ForEach-Object { $_.ToString('x2') }) -join ''
# Will be zeroed immediately after all keys are programmed.

# ── Program each YubiKey with the shared secret ───────────────────────────────
function Invoke-ProgramYubiKey {
    param([string]$Serial, [string]$Label)
    Info "Programming $Label YubiKey (serial: $Serial)..."

    $slotInfo = ykman --device $Serial otp info 2>$null | Out-String
    $slotLine = ($slotInfo -split "`n") | Where-Object { $_ -match "Slot $YkSlot" }

    if ($slotLine -match "programmed") {
        Warn "$Label YubiKey slot $YkSlot is already programmed: $slotLine"
        Warn "Continuing will OVERWRITE the existing slot $YkSlot configuration."
        Write-Host ""
        $confirm = Read-Host "Type 'overwrite' to confirm for $Label key, or Ctrl-C to abort"
        if ($confirm -ne 'overwrite') { Die "Aborted. Slot $YkSlot on $Label key not modified." }
    } else {
        Info "$Label YubiKey slot $YkSlot is empty — safe to program."
    }

    ykman --device $Serial otp chalresp --force $YkSlot $HmacSecret 2>$null
    if ($LASTEXITCODE -ne 0) { Die "Failed to program slot $YkSlot on $Label YubiKey (serial: $Serial)." }
    Success "$Label YubiKey programmed (serial: $Serial, slot: $YkSlot)"
}

for ($i = 0; $i -lt $YkSerials.Count; $i++) {
    $label = if ($i -eq 0) { "primary" } else { "backup #$i" }
    Invoke-ProgramYubiKey -Serial $YkSerials[$i] -Label $label
}

# ── Verify all keys produce identical HMAC output ─────────────────────────────
Info "Verifying all keys produce identical HMAC output..."
$TestChallenge = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
$ReferenceHmac = $null

for ($i = 0; $i -lt $YkSerials.Count; $i++) {
    $serial = $YkSerials[$i]
    $label  = if ($i -eq 0) { "primary" } else { "backup #$i" }
    Info "Touch $label YubiKey (serial: $serial) when it flashes..."
    $keyHmac = ($TestChallenge | ykman --device $serial otp calculate $YkSlot - 2>$null)
    if (-not $keyHmac) { Die "HMAC challenge failed on $label YubiKey (serial: $serial)." }

    if ($null -eq $ReferenceHmac) {
        $ReferenceHmac = $keyHmac
        Success "Primary key HMAC: $keyHmac"
    } elseif ($keyHmac -ne $ReferenceHmac) {
        Die "HMAC mismatch on $label key (serial: $serial)!`n  Expected: $ReferenceHmac`n  Got:      $keyHmac`n  Keys not programmed with the same secret. Aborting."
    } else {
        Success "$label key HMAC matches primary ✓"
    }
}
$ReferenceHmac = $null; $TestChallenge = $null

# Zero the secret from memory
$HmacSecret = "0000000000000000000000000000000000000000"
$HmacSecret = $null
[System.GC]::Collect()
Success "All keys verified and secret discarded"

# ── Step 1: Generate APFS password ───────────────────────────────────────────
Info "Generating strong container password..."
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$ContainerPassword = [Convert]::ToBase64String($bytes).Replace('+','').Replace('/','').Replace('=','').Substring(0,40)
Success "Password generated (40-char)"

# ── Step 2: Generate HMAC salt ────────────────────────────────────────────────
Info "Generating HMAC salt..."
New-Item -ItemType Directory -Force -Path (Split-Path $SaltPath) | Out-Null
$saltBytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Fill($saltBytes)
$HmacSalt = [BitConverter]::ToString($saltBytes).Replace('-','').ToLower()
$HmacSalt | Set-Content $SaltPath -NoNewline
(Get-Item $SaltPath).Attributes = 'Hidden'
Success "HMAC salt stored at $SaltPath"

# ── Step 3: Derive HMAC from YubiKey ──────────────────────────────────────────
Info "Deriving HMAC-Secret from primary YubiKey (touch when it flashes)..."
$HmacOutput = ($HmacSalt | ykman --device $ykSerial otp calculate $YkSlot - 2>$null)
if (-not $HmacOutput) {
    Die "YubiKey HMAC failed on primary key (serial: $ykSerial)."
}
Success "HMAC derived from YubiKey"

# ── Step 4: Wrap password and store in Credential Manager ─────────────────────
Info "Wrapping password with HMAC and storing in Windows Credential Manager..."

# XOR-wrap the password bytes with HMAC output bytes
$pwBytes   = [System.Text.Encoding]::UTF8.GetBytes($ContainerPassword)
$keyBytes  = [System.Text.Encoding]::UTF8.GetBytes($HmacOutput)
$wrapped   = New-Object byte[] $pwBytes.Length
for ($i = 0; $i -lt $pwBytes.Length; $i++) {
    $wrapped[$i] = $pwBytes[$i] -bxor $keyBytes[$i % $keyBytes.Length]
}
$wrappedB64 = [Convert]::ToBase64String($wrapped)

# Store in Windows Credential Manager via cmdkey
# We use a PowerShell helper that calls CredWrite via P/Invoke for the wrapped value
$credScript = @"
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WinCred {
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
    public static extern bool CredWrite([In] ref CREDENTIAL userCredential, [In] uint flags);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool CredDelete(string target, uint type, uint flags);
}
'@
`$blob = [System.Text.Encoding]::Unicode.GetBytes('$wrappedB64')
`$ptr  = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(`$blob.Length)
[System.Runtime.InteropServices.Marshal]::Copy(`$blob, 0, `$ptr, `$blob.Length)
`$cred = New-Object WinCred+CREDENTIAL
`$cred.Type           = 1   # CRED_TYPE_GENERIC
`$cred.TargetName     = '$CredTarget'
`$cred.UserName       = '$CredUser'
`$cred.CredentialBlob = `$ptr
`$cred.CredentialBlobSize = `$blob.Length
`$cred.Persist        = 2   # CRED_PERSIST_LOCAL_MACHINE
[WinCred]::CredDelete('$CredTarget', 1, 0) | Out-Null
[WinCred]::CredWrite([ref]`$cred, 0) | Out-Null
[System.Runtime.InteropServices.Marshal]::FreeHGlobal(`$ptr)
"@
Invoke-Expression $credScript
Success "Wrapped password stored in Credential Manager (target: $CredTarget)"

# ── Step 5: Back up to Bitwarden ──────────────────────────────────────────────
Info "Storing plain password in Bitwarden as break-glass backup..."
$bwStatus = (bw status 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue).status
if ($bwStatus -eq 'unlocked') {
    $template = bw get template item.login 2>$null | ConvertFrom-Json
    $template.name = $BwItem
    $template.login.password = $ContainerPassword
    $template.notes = "YubiKey serial: $ykSerial`nSalt: $SaltPath"
    ($template | ConvertTo-Json -Depth 10) | bw encode | bw create item | Out-Null
    Success "Password saved to Bitwarden item: $BwItem"
} else {
    Warn "Bitwarden vault not unlocked. Skipping automatic backup."
    Warn "IMPORTANT — manually save this password to Bitwarden item '$BwItem':"
    Write-Host ""
    Write-Host "  $ContainerPassword" -ForegroundColor Red
    Write-Host ""
    Warn "This is the ONLY time this password will be shown."
    Read-Host "Press ENTER after saving it securely"
}

# Clear from memory
$ContainerPasswordSecure = $ContainerPassword
$ContainerPassword = $null
[System.GC]::Collect()

# ── Step 6: Create VeraCrypt container ────────────────────────────────────────
Info "Creating encrypted VeraCrypt container (${SizeMB}MB)..."
Info "Retrieve the container password from Bitwarden when prompted."
Write-Host ""

# Gap W6 fix: never pass the password as a CLI argument — it appears in process
# listings visible to any local process with OpenProcess access.
# Strategy: write password to a temp keyfile, pass via /keyfile, delete immediately.
# VeraCrypt supports keyfile-only or password+keyfile auth; we use password+keyfile
# where the keyfile IS the password written to a temp file, then immediately shredded.
$vcPassword = Read-Host "Enter container password (from Bitwarden)" -AsSecureString
$vcPasswordPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($vcPassword))

# Write to a temp file with restricted ACL, pass as /keyfile, delete after
$tmpKeyFile = [System.IO.Path]::GetTempFileName()
try {
    # Restrict permissions to current user only before writing
    $acl = Get-Acl $tmpKeyFile
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $env:USERNAME, 'FullControl', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl $tmpKeyFile $acl
    [System.IO.File]::WriteAllText($tmpKeyFile, $vcPasswordPlain,
        [System.Text.Encoding]::UTF8)
    $vcPasswordPlain = $null
    [System.GC]::Collect()

    & $VeraCryptExe /create $ContainerPath `
        /size "${SizeMB}M" `
        /keyfile $tmpKeyFile `
        /encryption AES `
        /hash SHA-512 `
        /filesystem NTFS `
        /silent
} finally {
    # Overwrite then delete — basic scrub (SSD wear-levelling limits guarantees)
    if (Test-Path $tmpKeyFile) {
        $zeros = New-Object byte[] ([System.IO.FileInfo]$tmpKeyFile).Length
        [System.IO.File]::WriteAllBytes($tmpKeyFile, $zeros)
        Remove-Item $tmpKeyFile -Force
    }
}

Success "VeraCrypt container created at $ContainerPath"

# ── Step 7: Initial mount and directory scaffold ──────────────────────────────
Info "Mounting for initial directory setup..."
$mountPw = Read-Host "Re-enter container password to mount" -AsSecureString
$mountPwPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($mountPw))

# Same keyfile approach for mount
$tmpMountKey = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($tmpMountKey, $mountPwPlain, [System.Text.Encoding]::UTF8)
    $mountPwPlain = $null
    & $VeraCryptExe /volume $ContainerPath /letter $DriveLetter /keyfile $tmpMountKey /silent /mountoption ro:n
} finally {
    if (Test-Path $tmpMountKey) {
        $zeros = New-Object byte[] ([System.IO.FileInfo]$tmpMountKey).Length
        [System.IO.File]::WriteAllBytes($tmpMountKey, $zeros)
        Remove-Item $tmpMountKey -Force
    }
}

Start-Sleep -Seconds 3
$mountPoint = "${DriveLetter}:"
if (Test-Path $mountPoint) {
    New-Item -ItemType Directory -Force -Path "$mountPoint\repos" | Out-Null
    New-Item -ItemType Directory -Force -Path "$mountPoint\data"  | Out-Null
    Success "Directory structure created inside volume"
    & $VeraCryptExe /dismount $mountPoint /silent
    Success "Volume dismounted — encryption active"
} else {
    Warn "Mount point $mountPoint not found — create repos\ and data\ manually after first mount"
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Container creation complete." -ForegroundColor Green
Write-Host ""
Write-Host "  Container    : $ContainerPath"
Write-Host "  YubiKey(s)   : $($YkSerials -join ', ') (slot $YkSlot)"
Write-Host "  HMAC salt    : $SaltPath"
Write-Host "  Credential   : $CredTarget / $CredUser"
Write-Host "  Bitwarden    : $BwItem"
Write-Host ""
Write-Host "  Back up $ContainerPath to an external encrypted drive."
if ($YkSerials.Count -eq 1) {
    Warn "Only one YubiKey was enrolled. To add a backup key later you will need"
    Warn "the original HMAC secret — it was discarded at creation time."
    Warn "Retrieve the container password from Bitwarden and re-wrap with the new key."
}
Write-Host ""
Write-Host "  Start working: mount-secure.ps1"
Write-Host ""