# secure-dev — macOS

Encrypted Python development environment for macOS.
Sensitive project code lives inside an AES-256 APFS sparsebundle that mounts on demand and locks automatically on screen lock, sleep, or idle timeout.

← Back to [root README](../README.md) | Windows: [windows/README.md](../windows/README.md)

---

## Credential flow

```
YubiKey (FIDO2 + HMAC-Secret slot 2)
    │
    ├─► gates Bitwarden vault          (break-glass: plain APFS password)
    │
    └─► HMAC-unwraps Keychain entry    (daily use: wrapped APFS password cache)
              │
              └─► hdiutil attach       (never written to disk unwrapped)
```

Daily mounts use the local Keychain cache — no network call, one YubiKey touch.
If the cache is stale or the YubiKey is absent, the script falls back to Bitwarden.

---

## Prerequisites

- macOS 13 Ventura or later
- Homebrew
- YubiKey 5 series with HMAC-SHA1 configured on slot 2
- Bitwarden account + Bitwarden CLI
- `pyobjc-framework-Cocoa` — installed automatically by `install.sh`
- `sleepwatcher` — installed automatically by `install.sh`

---

## First-time setup

### 1. Clone and enter the macOS directory

```bash
git clone https://github.com/jedmitten/secure-dev ~/bin/secure-dev
cd ~/bin/secure-dev/macos
```

### 2. Configure YubiKey HMAC slot

```bash
ykman otp chalresp --generate 2
```

> **Warning:** This overwrites any existing slot 2 configuration. `create-container.sh`
> detects a programmed slot and requires typed confirmation before proceeding.
> If you have a backup YubiKey, enrol it now with the same command.

### 3. Edit config

```bash
cp config.toml ~/.config/secure-dev/config.toml   # install.sh does this automatically
$EDITOR ~/.config/secure-dev/config.toml
```

Key fields:

| Field                          | Default                                | Notes                                         |
| ------------------------------ | -------------------------------------- | --------------------------------------------- |
| `container.path`               | `~/Secure/secure-project.sparsebundle` | Container file location                       |
| `container.volume_path`        | `/Volumes/SecureProject`               | Mount point                                   |
| `container.size`               | `50g`                                  | Maximum sparse size                           |
| `security.yubikey_slot`        | `2`                                    | HMAC-SHA1 slot on YubiKey                     |
| `security.bitwarden_item_name` | `SecureProject APFS`                   | Bitwarden break-glass item                    |
| `idle.timeout_minutes`         | `15`                                   | Auto-detach after N minutes of HID inactivity |

### 4. Bootstrap

```bash
chmod +x install.sh
./install.sh
```

Installs Homebrew dependencies (`ykman`, `bw`, `pyenv`, `uv`, `sleepwatcher`), Python package `pyobjc-framework-Cocoa`, scripts to `~/bin/`, launchd agents, and the HMAC salt.

### 5. Create the container

```bash
./create-container.sh
```

Generates the APFS password, wraps it with your YubiKey HMAC, stores it in Keychain, backs it up to Bitwarden, and creates the sparsebundle.

### 6. Automator Quick Action (manual — required for keyboard shortcut)

This step cannot be scripted on macOS.

1. Open **Automator** → New Document → **Quick Action**
2. Set *Workflow receives* → **no input** in **any application**
3. Add action: **Run Shell Script** → shell: `/bin/bash`
4. Paste:
   ```bash
   ~/bin/detach.sh --trigger manual
   ```
5. Save as: **Lock Secure Volume**
6. Open **System Settings** → Keyboard → Keyboard Shortcuts → Services
7. Find **Lock Secure Volume** under General and assign your shortcut

---

## Daily workflow

### Start session

```bash
mount-secure.sh
cd /Volumes/SecureProject/repos/myproject
source .venv/bin/activate
```

### End session

Press your keyboard shortcut, or:

```bash
deactivate
detach.sh --trigger manual
```

### Create a new project inside the volume

```bash
cd /Volumes/SecureProject/repos
mkdir myproject && cd myproject
uv init
pyenv local 3.12.8
uv venv && source .venv/bin/activate
uv add fastapi numpy
```

---

## Auto-detach triggers

| Trigger           | Mechanism                                                                        |
| ----------------- | -------------------------------------------------------------------------------- |
| Screen lock       | `screenlock-watcher.sh` — launchd KeepAlive, Darwin notification centre (PyObjC) |
| Sleep / lid close | `sleepwatcher` daemon → `~/.sleep` → `detach.sh --trigger sleep`                 |
| Idle timeout      | `com.securedev.idle.plist` — polls `ioreg HIDIdleTime`                           |
| Manual            | Automator Quick Action → `detach.sh --trigger manual`                            |

All triggers converge on `detach.sh` with a `--trigger` label written to the detach log.

---

## Detach log

```bash
cat ~/.config/secure-dev/detach.log
```

```
2025-03-08 09:14:22 MOUNTED  /Volumes/SecureProject
2025-03-08 11:02:45 DETACHED /Volumes/SecureProject trigger=screenlock
2025-03-08 13:30:01 MOUNTED  /Volumes/SecureProject
2025-03-08 14:45:10 DETACHED /Volumes/SecureProject trigger=idle
```

---

## Moving to a new Mac

1. Copy `~/Secure/secure-project.sparsebundle` to the new machine
2. Copy `~/.config/secure-dev/hmac.salt` to the same path
3. Clone the repo and run `install.sh` on the new machine
4. Skip `create-container.sh` — the container already exists
5. Run `mount-secure.sh` — falls back to Bitwarden on first use, re-caches in Keychain

The same physical YubiKey works on any machine. The sparsebundle is just an encrypted file.

---

## YubiKey loss / recovery

| Scenario                             | Recovery path                                                     |
| ------------------------------------ | ----------------------------------------------------------------- |
| YubiKey forgotten                    | `bw get password "SecureProject APFS"`                            |
| YubiKey lost permanently             | Retrieve from Bitwarden, create new container or re-enrol new key |
| Bitwarden + YubiKey both unavailable | Permanently locked out — no recovery path                         |

Enrol a backup YubiKey at setup time.

---

## Security model

**Protects against:**
- Laptop theft — sparsebundle is encrypted at rest
- Disk removal and offline forensic analysis
- Unattended workstation — auto-detach on lock, sleep, and idle

**Does not protect against:**
- Malware or root access while the container is mounted
- Memory extraction during an active session
- Compromise of your Bitwarden account

---

## File layout

```
macos/                                  ← this directory (repo)
├── install.sh
├── create-container.sh
├── mount-secure.sh
├── detach.sh
├── screenlock-watcher.sh
├── github-init.sh
├── config.toml
└── com.securedev.screenlock.plist

~/bin/                                  ← installed by install.sh
├── mount-secure.sh
├── detach.sh
├── create-container.sh
└── screenlock-watcher.sh

~/Secure/
└── secure-project.sparsebundle

~/.config/secure-dev/
├── config.toml
├── hmac.salt
├── last_mount
└── detach.log

~/Library/LaunchAgents/
├── com.securedev.screenlock.plist
├── de.bernhard-baehr.sleepwatcher.plist
└── com.securedev.idle.plist
```