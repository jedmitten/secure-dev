#!/usr/bin/env bash
# screenlock-watcher.sh — Watches for macOS screen lock distributed notification
# and calls detach.sh. Installed and kept running by launchd.
#
# macOS does not expose com.apple.screenIsLocked as a WatchPaths trigger.
# This script uses a Python event loop to subscribe to the Darwin notification
# centre and fire on the lock event. launchd keeps it alive (KeepAlive: true).

set -euo pipefail

BIN_DIR="$HOME/bin"

# Python 3 is required (ships with macOS or installed via pyenv/Homebrew)
exec python3 - <<'PYEOF'
import subprocess
import signal
import sys

try:
    from Foundation import NSDistributedNotificationCenter, NSRunLoop, NSDate
    from PyObjCTools import AppHelper
except ImportError:
    # PyObjC not available — fall back to polling /private/var/run lock file
    import os, time
    LOCK_FILE = "/private/var/run/com.apple.screensaver.lock"
    DETACH = os.path.expanduser("~/bin/detach.sh")
    last_state = os.path.exists(LOCK_FILE)
    while True:
        state = os.path.exists(LOCK_FILE)
        if state and not last_state:
            subprocess.run([DETACH, "--trigger", "screenlock"], check=False)
        last_state = state
        time.sleep(2)
    sys.exit(0)

import objc

class ScreenLockObserver(object):
    def init(self):
        self = objc.super(ScreenLockObserver, self).init()
        nc = NSDistributedNotificationCenter.defaultCenter()
        nc.addObserver_selector_name_object_(
            self,
            "screenLocked:",
            "com.apple.screenIsLocked",
            None,
        )
        nc.addObserver_selector_name_object_(
            self,
            "screenSaverDidStart:",
            "com.apple.screensaver.didstart",
            None,
        )
        return self

    def screenLocked_(self, notification):
        subprocess.run(
            [os.path.expanduser("~/bin/detach.sh"), "--trigger", "screenlock"],
            check=False,
        )

    def screenSaverDidStart_(self, notification):
        subprocess.run(
            [os.path.expanduser("~/bin/detach.sh"), "--trigger", "screenlock"],
            check=False,
        )

import os
observer = ScreenLockObserver.alloc().init()
AppHelper.runConsoleEventLoop(installInterrupt=True)
PYEOF
