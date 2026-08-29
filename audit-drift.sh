#!/bin/bash
# audit-drift.sh — compare deployed files against their source-of-record.
#
# For each (source, deployed) pair in this suite, diff by hash. Any mismatch
# means one side was edited without syncing — exactly the foot-gun that
# feedback_deployed_copy_canonical.md warned about.
#
# Output to stdout (for journalctl), plus notify-send if interactive and
# drift is found. Exits 0 if clean, 1 if drift, 2 on missing files.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
drift=0
missing=0

# Pairs: "<source-relative-to-HERE> <deployed-absolute>"
pairs=(
    "bin/safeup              /usr/local/bin/safeup"
    "bin/aur-rebuild-check   /usr/local/bin/aur-rebuild-check"
    "bin/aur-pin-check       /usr/local/bin/aur-pin-check"
    "bin/aurinstall          /usr/local/bin/aurinstall"
    "bin/aurupdate           /usr/local/bin/aurupdate"
    "bin/remove-versioned-kernel  /usr/local/bin/remove-versioned-kernel"
    "etc/logrotate.d/safeup  /etc/logrotate.d/safeup"
    "config/yay/config.json  $HOME/.config/yay/config.json"
)

# Deliberately NOT audited:
#   etc/aur-pin-check/allowlist.conf — site-local policy. Every row records a
#     package the operator personally vetted, so the deployed copy is SUPPOSED
#     to diverge from the one shipped in the repository. Flagging it would
#     train you to ignore this report.
#   systemd/user/safeup-drift-audit.service — a template. deploy.sh substitutes
#     the checkout path into it, so the installed copy never hashes equal.

mismatches=()
for pair in "${pairs[@]}"; do
    read -r src dst <<<"$pair"
    srcfull="$HERE/$src"
    if [[ ! -f "$srcfull" ]]; then
        echo "MISSING source:   $srcfull"
        missing=1
        continue
    fi
    if [[ ! -f "$dst" ]]; then
        echo "MISSING deployed: $dst"
        missing=1
        continue
    fi
    # md5 by hand — avoids sudo for /etc/ files; readable-by-all is OK here.
    a=$(md5sum "$srcfull" 2>/dev/null | awk '{print $1}')
    b=$(md5sum "$dst"     2>/dev/null | awk '{print $1}')
    if [[ -z "$a" || -z "$b" || "$a" != "$b" ]]; then
        echo "DRIFT:  $src  !=  $dst"
        mismatches+=("$src")
        drift=1
    fi
done

if (( drift == 0 && missing == 0 )); then
    echo "[drift-audit] $(date -Is) — all ${#pairs[@]} pairs match ✓"
    exit 0
fi

echo ""
echo "[drift-audit] $(date -Is) — drift=$drift missing=$missing"

# Desktop notification if we have a graphical session.
if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v notify-send >/dev/null; then
    msg="SafeAUR drift: ${#mismatches[@]} file(s) differ"
    (( missing )) && msg+=" + missing files"
    notify-send -u critical "Manjaro SafeAUR Updater audit" "$msg
Review ~/Projects/manjaro-safeaur-updater/ vs deployed."
fi

(( missing )) && exit 2
exit 1
