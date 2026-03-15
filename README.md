# secure-dev

Encrypted Python development environment for **macOS** and **Windows**.

Sensitive project code lives inside an AES-256 encrypted container that mounts on demand and locks automatically on screen lock, sleep, or idle timeout. All secrets are gated by a YubiKey with Bitwarden as a break-glass fallback. No password is ever written to disk unwrapped.

---

## How it works

```
YubiKey (FIDO2 + HMAC-Secret slot 2)
    │
    ├─► gates Bitwarden vault              (break-glass: plain container password)
    │
    └─► HMAC-unwraps local secret store   (daily use: wrapped password cache)
              │
              └─► mount encrypted container
                        │
                        └─► repos/  data/   (normal dev filesystem)
```

Daily mounts require one YubiKey touch and make no network call. If the local cache is stale or the YubiKey is absent, the scripts fall back to Bitwarden automatically.

Once mounted the container behaves like any normal filesystem. When detached — on screen lock, sleep, idle timeout, or keyboard shortcut — it returns to a fully encrypted state immediately.

---

## Platform support

|                         | macOS                                       | Windows                                   |
| ----------------------- | ------------------------------------------- | ----------------------------------------- |
| **Scripts**             | [`macos/`](macos/)                          | [`windows/`](windows/)                    |
| **Container**           | APFS sparsebundle                           | VeraCrypt `.vc` file                      |
| **Encryption**          | AES-256 (native APFS)                       | AES-256 (VeraCrypt)                       |
| **Mount tool**          | `hdiutil`                                   | VeraCrypt CLI                             |
| **Secret store**        | macOS Keychain                              | Windows Credential Manager                |
| **Screen lock trigger** | Darwin notification centre (PyObjC watcher) | Task Scheduler + Security Event 4800      |
| **Sleep trigger**       | `sleepwatcher` → `~/.sleep` hook            | Task Scheduler + Kernel-Power Event 42    |
| **Idle detection**      | `ioreg HIDIdleTime`                         | `user32.GetLastInputInfo`                 |
| **Keyboard shortcut**   | Automator Quick Action (manual)             | AutoHotkey v2 (scripted by `install.ps1`) |
| **Shell**               | bash                                        | PowerShell 7+                             |

---

## Repository layout

```
secure-dev/
├── README.md          ← you are here
│
├── macos/             ← macOS scripts and config
│   ├── README.md
│   ├── install.sh
│   ├── create-container.sh
│   ├── mount-secure.sh
│   ├── detach.sh
│   ├── screenlock-watcher.sh
│   ├── github-init.sh
│   ├── config.toml
│   └── com.securedev.screenlock.plist
│
└── windows/           ← Windows scripts and config
    ├── README.md
    ├── install.ps1
    ├── create-container.ps1
    ├── mount-secure.ps1
    ├── detach.ps1
    └── config.toml
```

---

## Shared prerequisites

- YubiKey 5 series (HMAC-SHA1 on slot 2)
- Bitwarden account + Bitwarden CLI (`bw`)
- `git`

---

## Quick start — macOS

```bash
git clone https://github.com/jedmitten/secure-dev ~/bin/secure-dev
cd ~/bin/secure-dev/macos
chmod +x install.sh
./install.sh           # installs deps, launchd agents, pyobjc, sleepwatcher
./create-container.sh  # one-time: creates sparsebundle, enrols YubiKey
./mount-secure.sh      # daily: mount and start working
```

→ Full macOS documentation: [`macos/README.md`](macos/README.md)

---

## Quick start — Windows

```powershell
git clone https://github.com/jedmitten/secure-dev "$env:USERPROFILE\bin\secure-dev"
cd "$env:USERPROFILE\bin\secure-dev\windows"
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
.\install.ps1           # installs deps, Task Scheduler tasks, AutoHotkey shortcut
.\create-container.ps1  # one-time: creates VeraCrypt container, enrols YubiKey
.\mount-secure.ps1      # daily: mount and start working
```

→ Full Windows documentation: [`windows/README.md`](windows/README.md)

---

## YubiKey loss / recovery

| Scenario                             | Recovery                                                                                |
| ------------------------------------ | --------------------------------------------------------------------------------------- |
| YubiKey forgotten                    | `bw get password "SecureProject APFS"` (macOS) or `"SecureProject VeraCrypt"` (Windows) |
| YubiKey lost permanently             | Retrieve from Bitwarden, re-enrol a new key                                             |
| Bitwarden + YubiKey both unavailable | Permanently locked out — no recovery path                                               |

Enrol a backup YubiKey at setup time. The HMAC secret is per-device and non-exportable.

---

## Security model

**Protects against:**
- Laptop theft — container encrypted at rest on both platforms
- Disk removal and offline forensic analysis
- Unattended workstation — auto-detach on lock, sleep, and idle

**Does not protect against:**
- Malware or root/admin access while the container is mounted
- Memory extraction during an active session
- Compromise of your Bitwarden account

**Windows-specific:** VeraCrypt containers are more exposed to hibernation (`hiberfil.sys`) than APFS sparsebundles. Consider `powercfg /h off` or full-disk BitLocker on the system drive. See [`windows/README.md`](windows/README.md) for details.