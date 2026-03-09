# secure-dev (Windows / VeraCrypt)

Encrypted Python development environment for Windows.  
Sensitive project code lives inside an AES-256 VeraCrypt container that mounts as a drive letter on demand and locks automatically on screen lock, sleep, or idle timeout.

---

## Credential flow

```
YubiKey (FIDO2 + HMAC-Secret slot 2)
    │
    ├─► gates Bitwarden vault               (break-glass: plain VeraCrypt password)
    │
    └─► HMAC-unwraps Credential Manager     (daily use: wrapped password cache)
              │
              └─► VeraCrypt /volume mount    (never written to disk unwrapped)
```

Daily mounts use the local Windows Credential Manager cache — no network call, one YubiKey touch.  
If the cache is stale or the YubiKey is absent, the script falls back to Bitwarden.

---

## macOS README gaps (fixed here)

The macOS README is missing the following — these are addressed in this Windows port and should be backported to the macOS scripts:

| Gap | Detail |
|---|---|
| PyObjC not listed as prerequisite | `screenlock-watcher.sh` requires `pip install pyobjc-framework-Cocoa` |
| SleepWatcher not installed | `brew install sleepwatcher` required; `/etc/pm/sleep.d/` doesn't exist on macOS |
| YubiKey slot overwrite warning missing | `ykman otp hmac-sha1 2` silently overwrites existing slot 2 config |
| `age-plugin-yubikey` listed but unused | Install step includes it but the XOR-wrap flow doesn't use it |
| `github-init.sh` not committed | Generated but not pushed to the repo |

---

## Prerequisites

- Windows 10 22H2+ or Windows 11
- PowerShell 7+ (`winget install Microsoft.PowerShell`)
- YubiKey 5 series with HMAC-SHA1 configured on slot 2
- Bitwarden account + Bitwarden CLI
- VeraCrypt (installed by `install.ps1`)
- winget (ships with Windows 11; install App Installer on Windows 10)

---

## First-time setup

### 1. Allow script execution

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 2. Configure YubiKey HMAC slot

```powershell
ykman otp hmac-sha1 2
```

**Warning:** this overwrites any existing configuration on slot 2. If slot 2 already has a config (e.g. Yubico OTP), back it up first.  
If you have a backup YubiKey, enrol it now with the same command.

### 3. Clone this repo

```powershell
git clone https://github.com/jedmitten/secure-dev "$env:USERPROFILE\bin\secure-dev-windows"
cd "$env:USERPROFILE\bin\secure-dev-windows"
```

### 4. Edit config

```powershell
Copy-Item config.toml "$env:USERPROFILE\.config\secure-dev\config.toml"
notepad "$env:USERPROFILE\.config\secure-dev\config.toml"
```

Key fields:

| Field | Default | Notes |
|---|---|---|
| `container.path` | `C:\Users\%USERNAME%\Secure\secure-project.vc` | Where the container file lives |
| `container.drive_letter` | `S` | Drive letter VeraCrypt mounts at |
| `container.size_mb` | `51200` | 50 GB |
| `security.yubikey_slot` | `2` | HMAC-SHA1 slot on YubiKey |
| `security.bitwarden_item_name` | `SecureProject VeraCrypt` | Bitwarden break-glass item |
| `idle.timeout_minutes` | `15` | Auto-detach after N minutes of inactivity |

### 5. Bootstrap

```powershell
.\install.ps1
```

Installs dependencies, scripts, Task Scheduler tasks, and prints the keyboard shortcut step.

### 6. Create the container

```powershell
create-container.ps1
```

### 7. Keyboard shortcut

`install.ps1` handles this automatically — it installs AutoHotkey v2, writes `%USERPROFILE%\Documents\SecureDev.ahk`, and adds a startup shortcut. `Ctrl+Shift+L` is active immediately after `install.ps1` completes and at every subsequent login.

If you need to recreate the script manually:

```autohotkey
; %USERPROFILE%\Documents\SecureDev.ahk
#Requires AutoHotkey v2.0
^+l::Run('pwsh.exe -NonInteractive -WindowStyle Hidden -File "' . A_UserProfile . '\bin\secure-dev-windows\detach.ps1" --trigger manual')
```

Launch it with a double-click, or place a shortcut in `shell:startup`.

---

## Daily workflow

### Start session

```powershell
mount-secure.ps1
cd S:\repos\myproject
.venv\Scripts\Activate.ps1
```

### End session

Press `Ctrl+Shift+L`, or:

```powershell
deactivate
detach.ps1 --trigger manual
```

### Create a new project inside the volume

```powershell
cd S:\repos
mkdir myproject; cd myproject
uv init
pyenv local 3.12.8
uv venv
.venv\Scripts\Activate.ps1
uv add fastapi numpy
```

---

## Auto-detach triggers

| Trigger | Mechanism |
|---|---|
| Screen lock | Task Scheduler — Security event ID 4800 (workstation locked) |
| Sleep / lid close | Task Scheduler — Kernel-Power event ID 42 |
| Idle timeout | Task Scheduler — repeating interval, `GetLastInputInfo` validates actual idle |
| Manual shortcut | AutoHotkey `Ctrl+Shift+L` → `detach.ps1 --trigger manual` |

All triggers converge on `detach.ps1` with a `--trigger` label written to the detach log.

**Note on screen lock trigger reliability:** Event ID 4800 requires the "Other Logon/Logoff Events" audit subcategory to be enabled. `install.ps1` enables this automatically if run as Administrator. If the screen lock trigger isn't firing, run:

```powershell
auditpol /set /subcategory:"Other Logon/Logoff Events" /success:enable /failure:enable
```

---

## Detach log

```powershell
Get-Content "$env:USERPROFILE\.config\secure-dev\detach.log"
```

```
2025-03-08 09:14:22 MOUNTED  S:
2025-03-08 11:02:45 DETACHED S: trigger=screenlock
2025-03-08 13:30:01 MOUNTED  S:
2025-03-08 14:45:10 DETACHED S: trigger=idle
```

---

## Moving to a new machine

1. Copy `%USERPROFILE%\Secure\secure-project.vc` to the new machine
2. Copy `%USERPROFILE%\.config\secure-dev\hmac.salt` to the same path
3. Run `install.ps1` on the new machine
4. Skip `create-container.ps1` — container already exists
5. Run `mount-secure.ps1` — falls back to Bitwarden on first use, re-caches in Credential Manager

---

## YubiKey loss / recovery

| Scenario | Recovery path |
|---|---|
| YubiKey forgotten | Use Bitwarden break-glass: `bw get password "SecureProject VeraCrypt"` |
| YubiKey lost permanently | Retrieve from Bitwarden, create new container or re-enrol new key |
| Bitwarden + YubiKey both unavailable | Permanently locked out — no recovery path |

Enrol a backup YubiKey at setup time.

---

## Security model

Protects against:
- Laptop theft (container encrypted at rest)
- Disk removal and forensic analysis
- Unattended workstation (auto-detach on lock/sleep/idle)

Does not protect against:
- Malware or admin-level access while container is mounted
- Memory extraction during active session
- Compromise of Bitwarden account

**Windows-specific note:** VeraCrypt containers on Windows are more exposed to hibernation (`hiberfil.sys`) than APFS sparsebundles on macOS. Consider disabling hibernation (`powercfg /h off`) or ensuring your system drive is also encrypted with BitLocker.

---

## File layout

```
%USERPROFILE%\
├── bin\
│   └── secure-dev-windows\
│       ├── mount-secure.ps1
│       ├── detach.ps1
│       ├── create-container.ps1
│       └── install.ps1
│
├── Secure\
│   └── secure-project.vc
│
└── .config\
    └── secure-dev\
        ├── config.toml
        ├── hmac.salt
        ├── last_mount
        └── detach.log

Task Scheduler\
└── SecureDev\
    ├── ScreenLock
    ├── Sleep
    └── IdleCheck
```

---

## Differences from macOS version

| Area | macOS | Windows |
|---|---|---|
| Container format | APFS sparsebundle | VeraCrypt `.vc` file |
| Mount tool | `hdiutil` | VeraCrypt CLI |
| Secret store | macOS Keychain | Windows Credential Manager |
| Screen lock trigger | Darwin notification centre (persistent watcher) | Task Scheduler + Event ID 4800 |
| Sleep trigger | IOKit / launchd | Task Scheduler + Event ID 42 |
| Idle detection | `ioreg HIDIdleTime` | `user32.GetLastInputInfo` |
| Shell | bash | PowerShell 7 |
| Keyboard shortcut | Automator Quick Action | AutoHotkey v2 |
| Notification | `osascript` | BurntToast / WScript balloon |
| Hibernation risk | Low (APFS handles it) | Higher — consider `powercfg /h off` |