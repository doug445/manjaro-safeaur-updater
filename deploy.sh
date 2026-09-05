#!/bin/bash
# deploy.sh — install the Manjaro SafeAUR Updater from this source-of-record.
#
# Installs any missing dependency, then mirrors files from ./bin, ./etc,
# ./config and ./systemd into their deployed locations.
#
# Idempotent: a file that already matches is left completely alone, and a file
# that does not is backed up to <dst>.bak-YYYYmmdd-HHMMSS before it is replaced.
# The timestamp matters -- with a plain .bak, the second run that changed
# something would overwrite the copy the first run saved.
#
# Usage:
#   ./deploy.sh                  # install deps (asking first), then deploy
#   ./deploy.sh --yes            # never ask; assume yes to every prompt
#   ./deploy.sh --skip-deps      # deploy only, install nothing
#   ./deploy.sh --deps-only      # install dependencies and stop
#   ./deploy.sh --with-test-deps # also install what tests/ needs
#
# Everything here is idempotent: re-running it is the supported way to
# redeploy after editing a script in this checkout.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

ASSUME_YES=0
SKIP_DEPS=0
DEPS_ONLY=0
TEST_DEPS=0
for a in "$@"; do
    case "$a" in
        --yes|-y)        ASSUME_YES=1 ;;
        --skip-deps)     SKIP_DEPS=1 ;;
        --deps-only)     DEPS_ONLY=1 ;;
        --with-test-deps) TEST_DEPS=1 ;;
        -h|--help)       sed -n '2,18p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
    esac
done

say()  { printf '[deploy] %s\n' "$*"; }
warn() { printf '[deploy] WARNING: %s\n' "$*" >&2; }
die()  { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

ask() { # ask "<question>" — honours --yes, defaults to no on a closed stdin
    (( ASSUME_YES )) && return 0
    local ans
    read -r -p "[deploy] $1 [y/N] " ans </dev/tty 2>/dev/null || return 1
    [[ "$ans" == [yY]* ]]
}

# ---------------------------------------------------------------------------
# Dependencies
#
# Runtime needs, as "<command> <package>". The command is what is probed; the
# package is what pacman installs when it is missing. Almost all of these are
# already present on any Manjaro install — the check exists for the minimal
# and container cases where they are not.
# ---------------------------------------------------------------------------
RUNTIME_DEPS=(
    "curl        curl"          # aur-pin-check fetches .SRCINFO and the RPC index
    "git         git"           # aur-pin-check resolves allowlisted tags
    "fakeroot    fakeroot"      # safeup --check refreshes a private database copy without root
    "awk         gawk"          # .SRCINFO and pacman -Si parsing throughout
    "logrotate   logrotate"     # /etc/logrotate.d/safeup is inert without it
    "notify-send libnotify"     # audit-drift.sh's desktop notification
    # aurinstall builds in a chroot BY DEFAULT, so this is core, not optional.
    # The package itself is 24 KiB with no dependencies; the ~1.1 GiB chroot it
    # manages is created lazily under /var/lib/chrootbuild on the first build,
    # not at install time.
    "chrootbuild manjaro-chrootbuild"
)
# Needed by tests/ only, never at runtime.
TEST_ONLY_DEPS=(
    "shellcheck  shellcheck"    # both suites are shellcheck-clean; CI enforces it
    "cc          gcc"           # loopback suite builds real ELFs with broken links
    "losetup     util-linux"    # the loop device the loopback suite runs inside
    "mkfs.ext4   e2fsprogs"     # its filesystem
    "repo-add    pacman"        # builds the throwaway file:// repositories
    "bsdtar      libarchive"    # builds the throwaway packages
)

install_deps() {
    local -a want=("${RUNTIME_DEPS[@]}")
    (( TEST_DEPS )) && want+=("${TEST_ONLY_DEPS[@]}")

    local -a missing_pkgs=() missing_desc=()
    local cmd pkg
    for row in "${want[@]}"; do
        read -r cmd pkg _ <<<"$row"
        command -v "$cmd" >/dev/null 2>&1 && continue
        missing_pkgs+=("$pkg")
        missing_desc+=("$cmd (from $pkg)")
    done

    if (( ${#missing_pkgs[@]} > 0 )); then
        say "missing dependencies:"
        printf '           - %s\n' "${missing_desc[@]}"
        # pacman refuses a whole transaction over one unknown target, and
        # manjaro-chrootbuild is unknown to every repository but Manjaro's. A
        # package no configured repo carries is reported and skipped so the
        # rest still installs; the feature that wanted it degrades on its own
        # (aurinstall falls back to yay, and says so).
        local -a can=() cannot=()
        for pkg in "${missing_pkgs[@]}"; do
            if pacman -Si "$pkg" >/dev/null 2>&1; then can+=("$pkg"); else cannot+=("$pkg"); fi
        done
        if (( ${#cannot[@]} > 0 )); then
            warn "not in any configured repository, skipped: ${cannot[*]}"
        fi
        if (( ${#can[@]} > 0 )); then
            # --needed makes this a no-op for anything already installed, so a
            # duplicate package name in the list above costs nothing.
            if ask "install ${can[*]} with pacman?"; then
                sudo pacman -S --needed --noconfirm "${can[@]}" \
                    || die "pacman could not install: ${can[*]}"
                say "dependencies installed"
            else
                warn "continuing without them — the affected features will not work"
            fi
        fi
    else
        say "all dependencies present"
    fi

    install_yay
}

# yay is the AUR helper aurinstall and aurupdate wrap. Manjaro ships it in
# [extra]; plain Arch does not, and there it has to come from the AUR itself.
# Bootstrapping is deliberately a prompt, not a silent action: it clones a
# PKGBUILD and builds it, which is exactly the kind of thing this suite exists
# to make you think about.
install_yay() {
    command -v yay >/dev/null 2>&1 && { say "yay present ($(yay --version 2>/dev/null | head -1))"; return 0; }

    say "yay is not installed — aurinstall and aurupdate need it"
    if pacman -Si yay >/dev/null 2>&1; then
        ask "install yay from your repositories?" || { warn "skipping yay"; return 0; }
        sudo pacman -S --needed --noconfirm yay || die "could not install yay"
        return 0
    fi

    say "yay is not in your configured repositories; it would have to be built from the AUR"
    ask "clone and build yay-bin from the AUR now?" || {
        warn "skipping yay — install it yourself before using aurinstall/aurupdate"
        return 0
    }
    command -v makepkg >/dev/null 2>&1 || sudo pacman -S --needed --noconfirm base-devel
    local tmp; tmp=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin" \
        || die "could not clone yay-bin from the AUR"
    say "review the PKGBUILD before it is built:"
    echo "---------------------------------------------------------------"
    cat "$tmp/yay-bin/PKGBUILD"
    echo "---------------------------------------------------------------"
    ask "build and install this PKGBUILD?" || { warn "skipping yay"; return 0; }
    ( cd "$tmp/yay-bin" && makepkg -si --noconfirm ) || die "yay-bin build failed"
}

# ---------------------------------------------------------------------------
# Deployment
#
# Idempotent by construction. A file whose content already matches is not
# rewritten at all -- not even its mtime -- and no backup is taken for it,
# because there is nothing to lose. Only a genuine difference produces a
# backup, and backups are timestamped: a plain `.bak` would mean the second
# run that changed something destroyed the copy the first one saved.
# ---------------------------------------------------------------------------
CHANGED=0
UNCHANGED=0

# Current mode / owner:group of a file, or empty if it does not exist.
stat_mode()  { stat -c '%a'    "$1" 2>/dev/null; }
stat_owner() { stat -c '%U:%G' "$1" 2>/dev/null; }

backup_of() { # echo a backup path that does not already exist
    printf '%s.bak-%s' "$1" "$(date +%Y%m%d-%H%M%S)"
}

install_file() { # install_file <src> <dst> <mode> <owner:group> [--user]
    local src=$1 dst=$2 mode=$3 owner=$4 user=${5:-}
    local SUDO=(sudo); [[ "$user" == "--user" ]] && SUDO=()

    mkdir -p "$(dirname "$dst")" 2>/dev/null || "${SUDO[@]}" mkdir -p "$(dirname "$dst")"

    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        # Content already correct. Repair mode/ownership if they drifted --
        # that is a metadata fix, not a rewrite, so it still needs no backup.
        local fixed=""
        if [[ "$(stat_mode "$dst")" != "${mode#0}" ]]; then
            "${SUDO[@]}" chmod "$mode" "$dst"; fixed=" (mode fixed)"
        fi
        if [[ -z "$user" && "$(stat_owner "$dst")" != "$owner" ]]; then
            "${SUDO[@]}" chown "$owner" "$dst"; fixed="$fixed (owner fixed)"
        fi
        echo "  unchanged  $dst$fixed"
        UNCHANGED=$((UNCHANGED + 1))
        return 0
    fi

    if [[ -e "$dst" ]]; then
        local bk; bk=$(backup_of "$dst")
        echo "  backup     $dst -> $bk"
        "${SUDO[@]}" cp -p "$dst" "$bk"
    fi
    echo "  install    $src -> $dst"
    if [[ "$user" == "--user" ]]; then
        install -m "$mode" "$src" "$dst"
    else
        sudo install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$dst"
    fi
    CHANGED=$((CHANGED + 1))
}

backup_then_install()      { install_file "$1" "$2" "$3" "$4"; }
backup_then_install_user() { install_file "$1" "$2" 0644 "" --user; }

(( SKIP_DEPS )) || install_deps
(( DEPS_ONLY )) && { say "--deps-only: stopping before deployment"; exit 0; }

say "installing scripts into /usr/local/bin (root-owned, 0755)..."
for s in safeup aur-rebuild-check aur-pin-check aurinstall aurupdate remove-versioned-kernel; do
    backup_then_install "$HERE/bin/$s" "/usr/local/bin/$s" 0755 root:root
done

say "installing logrotate config..."
backup_then_install "$HERE/etc/logrotate.d/safeup" "/etc/logrotate.d/safeup" 0644 root:root

say "installing aur-pin-check allowlist..."
sudo install -d -m 0755 -o root -g root /etc/aur-pin-check
# The allowlist is site-local policy: every row records a package YOU vetted.
# Overwriting an existing one would silently discard those decisions.
if [[ -f /etc/aur-pin-check/allowlist.conf ]]; then
    say "  /etc/aur-pin-check/allowlist.conf exists — left alone (it holds your vetting decisions)"
else
    backup_then_install "$HERE/etc/aur-pin-check/allowlist.conf" \
        "/etc/aur-pin-check/allowlist.conf" 0644 root:root
fi

say "installing yay config (user-scoped)..."
YAY_CONF="$HOME/.config/yay/config.json"
if [[ -f "$YAY_CONF" ]] && ! cmp -s "$HERE/config/yay/config.json" "$YAY_CONF"; then
    # This file changes how yay behaves in EVERY invocation, not just through
    # the wrappers here: it switches off the per-package PKGBUILD diff, edit
    # and clean menus, on the reasoning that aur-pin-check is the gate. That
    # is a choice to make knowingly, so an existing, different config is
    # never replaced without asking (--yes answers for you). A timestamped
    # backup is kept either way.
    say "  $YAY_CONF exists and differs from the suite's:"
    diff -u "$YAY_CONF" "$HERE/config/yay/config.json" | sed 's/^/    /' || true
    if ask "replace it with the suite's yay config?"; then
        backup_then_install_user "$HERE/config/yay/config.json" "$YAY_CONF"
    else
        say "  left alone"
    fi
else
    backup_then_install_user "$HERE/config/yay/config.json" "$YAY_CONF"
fi

say "installing the drift-audit timer (user-scoped)..."
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"
# The service is a template: the checkout can live anywhere, so its real path
# is substituted here rather than hardcoded in the repository. Render it to a
# scratch file first so install_file can compare it like any other source and
# leave an already-correct unit untouched.
RENDERED=$(mktemp)
trap 'rm -f "$RENDERED"' EXIT
sed "s|@@SUITE_DIR@@|$HERE|g" "$HERE/systemd/user/safeup-drift-audit.service" > "$RENDERED"
before=$CHANGED
install_file "$RENDERED" "$UNIT_DIR/safeup-drift-audit.service" 0644 "" --user
install_file "$HERE/systemd/user/safeup-drift-audit.timer" \
             "$UNIT_DIR/safeup-drift-audit.timer" 0644 "" --user
units_changed=$(( CHANGED - before ))

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    # Only reload when a unit file actually moved. Reloading is cheap but not
    # free, and a no-op run should be a genuine no-op.
    (( units_changed > 0 )) && systemctl --user daemon-reload
    if systemctl --user is-enabled safeup-drift-audit.timer >/dev/null 2>&1 \
       && systemctl --user is-active safeup-drift-audit.timer >/dev/null 2>&1; then
        say "  timer already enabled and running"
    elif systemctl --user enable --now safeup-drift-audit.timer >/dev/null 2>&1; then
        say "  timer enabled"
    else
        warn "  could not enable the timer; enable it by hand with:"
        warn "    systemctl --user enable --now safeup-drift-audit.timer"
    fi
    # Read the scheduled time as a property rather than scraping the table:
    # list-timers is a localised, column-aligned human format whose fields
    # shift when a timer has not been scheduled yet.
    next=$(systemctl --user show -p NextElapseUSecRealtime --value safeup-drift-audit.timer 2>/dev/null)
    [[ -n "$next" && "$next" != "0" && "$next" != "n/a" ]] && say "  next run: $next"
else
    warn "  no user systemd session here; units installed but not enabled"
fi

echo ""
if (( CHANGED == 0 )); then
    say "done — nothing changed ($UNCHANGED file(s) already up to date)."
else
    say "done — $CHANGED file(s) updated, $UNCHANGED already up to date."
fi
say "Verify with:"
echo "         ls -la /usr/local/bin/{safeup,aur-*,aurinstall,aurupdate,remove-versioned-kernel}"
echo "         systemctl --user list-timers safeup-drift-audit.timer"
say "reminder: shell aliases live in ~/.zshrc and ~/.bashrc — deploy does NOT touch them."
say "          suggested: alias pupdate='safeup'  yinstall='aurinstall'  yupdate='safeup ; aurupdate'"
