# secure-dev

Encrypted Python development environment for macOS.  
Sensitive project code lives inside an AES-256 APFS sparsebundle that mounts on demand and locks automatically on screen lock, sleep, or idle timeout.

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

- macOS 13+ (Ventura or later)
- YubiKey 5 series with HMAC-SHA1 configured on slot 2
- Bitwarden account + Bitwarden CLI
- Homebrew
- `pyobjc-framework-Cocoa` — required by the screen lock watcher (`install.sh` installs automatically)
- `sleepwatcher` — required for sleep/lid-close trigger (`install.sh` installs via Homebrew)

> **Note:** `age-plugin-yubikey` was listed as a dependency in earlier versions but is not used by the XOR-HMAC credential flow. It has been removed from `install.sh`.

---

## First-time setup

### 1. Configure YubiKey HMAC slot

```bash
ykman otp hmac-sha1 2
```

> **Warning:** This overwrites any existing configuration on slot 2. If slot 2 already has a credential (e.g. Yubico OTP), back it up before running this command. `create-container.sh` will detect a programmed slot and prompt for confirmation before overwriting.

If you have a backup YubiKey, enrol it now with the same command.  
The HMAC key on each YubiKey is independent — both need to be set up at creation time.

### 2. Clone this repo

```bash
git clone <this-repo> ~/bin/secure-dev
cd ~/bin/secure-dev
```

### 3. Edit config

```bash
cp config.toml ~/.config/secure-dev/config.toml   # install.sh does this automatically
$EDITOR ~/.config/secure-dev/config.toml
```

Key fields:

| Field | Default | Notes |
|---|---|---|
| `container.path` | `~/Secure/secure-project.sparsebundle` | Where the container file lives |
| `container.size` | `50g` | Maximum sparse size |
| `security.yubikey_slot` | `2` | HMAC-SHA1 slot on YubiKey |
| `security.bitwarden_item_name` | `SecureProject APFS` | Bitwarden item holding break-glass password |
| `idle.timeout_minutes` | `15` | Auto-detach after N minutes of HID inactivity |

### 4. Bootstrap

```bash
chmod +x install.sh
./install.sh
```

This installs dependencies, scripts, launchd agents, and prints the Automator manual step.

### 5. Create the container

```bash
create-container.sh
```

This generates the APFS password, wraps it with your YubiKey HMAC, stores it in Keychain, backs it up to Bitwarden, and creates the sparsebundle.

### 6. Automator Quick Action (manual — required for keyboard shortcut)

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
uv venv
source .venv/bin/activate
uv add fastapi numpy
```

---

## Auto-detach triggers

| Trigger | Mechanism |
|---|---|
| Screen lock | `screenlock-watcher.sh` (launchd KeepAlive, Darwin notification centre via PyObjC) |
| Sleep / lid close | `sleepwatcher` daemon → `~/.sleep` hook → `detach.sh --trigger sleep` |
| Idle timeout | `com.securedev.idle.plist` polling HID idle time via `ioreg` |
| Manual shortcut | Automator Quick Action → `detach.sh --trigger manual` |

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

## Moving to a new laptop

1. Copy `~/Secure/secure-project.sparsebundle` to the new machine
2. Copy `~/.config/secure-dev/hmac.salt` to the same path on the new machine
3. Run `install.sh` on the new machine
4. Skip `create-container.sh` — the container already exists
5. Run `mount-secure.sh` — it will fall back to Bitwarden on first use, then re-cache in Keychain

The same physical YubiKey works on any machine. The sparsebundle is just an encrypted file.

---

## YubiKey loss / recovery

| Scenario | Recovery path |
|---|---|
| YubiKey forgotten at home | Use Bitwarden break-glass password via `bw get password "SecureProject APFS"` |
| YubiKey lost permanently | Retrieve password from Bitwarden, create new container or re-enrol with new key |
| Bitwarden + YubiKey both unavailable | Permanently locked out — no recovery path |

This is intentional. Enrol a backup YubiKey when you set up the primary.

---

## Security model

Protects against:
- Laptop theft (container is encrypted at rest)
- Disk removal and forensic analysis
- Unattended workstation (auto-detach removes key material from memory)

Does not protect against:
- Malware or root access while container is mounted
- Memory extraction attacks during an active session
- Compromise of your Bitwarden account (use a strong master password + FIDO2)

---

## File layout

```
~/
├── bin/
│   ├── mount-secure.sh
│   ├── detach.sh
│   ├── create-container.sh
│   ├── screenlock-watcher.sh
│   └── github-init.sh
│
├── Secure/
│   └── secure-project.sparsebundle
│
└── .config/
    └── secure-dev/
        ├── config.toml
        ├── hmac.salt
        ├── last_mount
        └── detach.log

~/Library/LaunchAgents/
├── com.securedev.screenlock.plist
├── de.bernhard-baehr.sleepwatcher.plist
└── com.securedev.idle.plist
```