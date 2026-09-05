#!/bin/bash
#
# Manjaro SafeAUR Updater — safe pacman/AUR updates on Manjaro
# https://github.com/doug445/manjaro-safeaur-updater
#
# Copyright (c) 2026 William MacKinnon <spilled-bowline0j@icloud.com>
# SPDX-License-Identifier: MIT
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# ============================================================================
# loopback-core-test.sh — exercise the upgrade gate against REAL pacman
# transactions inside a throwaway package root on a file-backed loop device.
#
# NO REAL DISK AND NO REAL PACKAGE DATABASE IS TOUCHED. Everything happens on
# a loop-mounted ext4 image under $TMPDIR:
#
#   * a private pacman root  (RootDir/DBPath/CacheDir/LogFile/HookDir/GPGDir)
#   * private file:// repositories built with the real `repo-add`
#   * real .pkg.tar.gz packages, installed and upgraded by the real pacman
#
# The only thing shimmed onto PATH is a two-line `pacman` wrapper that adds
# `--config <the throwaway config>`, a matching `pacman-conf` wrapper, and a
# `sudo` that execs its argument (the suite already runs as root). The wrapper
# also rewrites a bare absolute path passed to `-Qo` into its RootDir-relative
# form, because pacman does not do that itself — see the `-Qo` note below.
# Dependency resolution, ABI-break detection, transaction ordering and file
# ownership are all done by the genuine pacman.
#
# What it proves:
#   1.  foreign repositories are discovered from pacman.conf, and Manjaro's own
#       repos are not mistaken for foreign ones
#   2.  a foreign package whose version-constrained dep is unsatisfiable is
#       HELD, and is still at its old version after the run  ← the whole point
#   3.  the hold is recorded in the log, so it can be chased later
#   4.  the same package is NOT held once the dep becomes satisfiable — the
#       guard is not a blanket refusal to upgrade foreign packages
#   5.  a package with no version constraint at all is never held
#   6.  "installing X breaks dependency ... required by Y" is recovered from by
#       auto-holding X, and the upgrade completes for everything else
#   7.  the auto-hold is logged as auto-skipped, and X keeps its old version
#   8.  an unrecoverable pacman failure exits non-zero — it is never laundered
#       into a success by the retry loop
#   9.  aur-rebuild-check flags a package with a genuinely unresolvable
#       DT_NEEDED (a real ELF built by cc, with a real missing .so)
#   10. it does NOT flag a package that ships the "missing" soname itself —
#       the $ORIGIN/bundled-library false positive that made -bin packages
#       flag forever
#   11. AUR_REBUILD_IGNORE_SONAMES suppresses a named soname
#   12. a package whose links all resolve is reported clean, exit 0
#   13. remove-versioned-kernel rejects a name that is not linuxNN
#   14. it is a no-op (exit 0) for a kernel that is not installed
#   15. it REFUSES to remove the currently-booted kernel
#   16. it REFUSES to remove the last remaining versioned kernel
#   17. a legitimate removal takes the kernel, its headers and its -nvidia
#       sibling, and rewrites IgnorePkg to name only the survivors -- and
#       still exits 0 when this system has no UKI directory at all, because
#       the post-removal probes run after the work is already done and must
#       never turn a completed removal into a failure exit
#   18. ...and still exits 0, and still lists the images, when it does
#   19. --ignore cannot manufacture a partial upgrade: pacman still resolves
#       the whole transaction and REFUSES one that would strand a dependency,
#       changing nothing -- and a real safeup hold inherits that, leaving a
#       system that `pacman -Dk` still calls consistent. This is the property
#       the entire suite's safety argument rests on, and it is an assumption
#       about pacman rather than about this code, so nothing here would notice
#       if it silently changed.
#   24. aur-rebuild-check flags a broken ELF that is neither *.so nor under
#       bin/ — /opt/<app>/<exe> is where a great many AUR packages live
#   25. it flags a pure-Python package stranded in the PREVIOUS interpreter's
#       site-packages after a python bump, and not one under the current dir
#   29. `aur-rebuild-check --fix` runs the pin-check gate before yay, and
#       `--noconfirm` reaches yay's --rebuild
#
# Run as root:  sudo bash tests/loopback-core-test.sh
# Requires: pacman, repo-add, bsdtar (libarchive), losetup, mkfs.ext4, cc.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0"; exit 1; }
for c in pacman pacman-conf repo-add bsdtar losetup mkfs.ext4 cc awk grep; do
    command -v "$c" >/dev/null || { echo "missing tool: $c"; exit 1; }
done

ARCH=$(uname -m)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/safeup-loopback-test.XXXXXX")
MNT="$WORK/mnt"
LOOP=""
PASS=0; FAIL=0; SKIP=0
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
# A check that cannot run here is reported as SKIP. It is never counted as a
# pass — a silent pass is the one outcome this suite exists to prevent.
skip() { echo "  SKIP: $*"; SKIP=$((SKIP+1)); }

cleanup() {
    set +e
    umount "$MNT" 2>/dev/null
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "== setup: 512M file-backed loop device, ext4, mounted at \$WORK/mnt =="
mkdir -p "$MNT"
truncate -s 512M "$WORK/disk.img"
LOOP=$(losetup --show -f "$WORK/disk.img") || { echo "losetup failed"; exit 1; }
mkfs.ext4 -q -F "$LOOP"
mount "$LOOP" "$MNT" || { echo "mount failed"; exit 1; }
echo "  loop device: $LOOP -> $MNT"

# ---------------------------------------------------------------------------
# Environment construction. Each scenario gets its own package root so that a
# transaction in one cannot colour the next.
# ---------------------------------------------------------------------------
ENV_DIR=""; ROOT=""; CONF=""; REPO_M=""; REPO_F=""; SHIM=""
BASE_PATH="$PATH"

mkenv() { # mkenv <name> [foreign-repo-name]  — builds and selects an env
    local name="$1" foreign="${2:-}"
    ENV_DIR="$MNT/$name"
    ROOT="$ENV_DIR/root"; CONF="$ENV_DIR/pacman.conf"
    REPO_M="$ENV_DIR/repo-manjaro"; REPO_F="$ENV_DIR/repo-foreign"
    SHIM="$ENV_DIR/shim"
    mkdir -p "$ROOT"/{var/lib/pacman,var/cache/pacman/pkg,var/log,usr/lib} \
             "$ROOT"/etc/pacman.d/{hooks,gnupg} \
             "$REPO_M" "$REPO_F" "$SHIM" "$ENV_DIR/build"

    {
        echo "[options]"
        echo "RootDir      = $ROOT"
        echo "DBPath       = $ROOT/var/lib/pacman/"
        echo "CacheDir     = $ROOT/var/cache/pacman/pkg/"
        echo "LogFile      = $ROOT/var/log/pacman.log"
        echo "GPGDir       = $ROOT/etc/pacman.d/gnupg/"
        echo "HookDir      = $ROOT/etc/pacman.d/hooks/"
        echo "Architecture = $ARCH"
        echo "SigLevel     = Never"
        echo "IgnorePkg    ="
        echo ""
        echo "[extra]"
        echo "Server = file://$REPO_M"
        if [ -n "$foreign" ]; then
            echo ""
            echo "[$foreign]"
            echo "Server = file://$REPO_F"
        fi
    } > "$CONF"

    # The shim. `--config` is prepended to every invocation; the -Qo case also
    # needs its path argument moved into the root, which pacman will not do.
    cat > "$SHIM/pacman" <<SHIMEOF
#!/bin/bash
if [ "\${1:-}" = "-Qoq" ] || [ "\${1:-}" = "-Qo" ]; then
    op="\$1"; shift
    args=()
    for a in "\$@"; do
        case "\$a" in /*) args+=("$ROOT\$a") ;; *) args+=("\$a") ;; esac
    done
    exec /usr/bin/pacman --config "$CONF" "\$op" "\${args[@]}"
fi
exec /usr/bin/pacman --config "$CONF" "\$@"
SHIMEOF
    printf '#!/bin/bash\nexec /usr/bin/pacman-conf --config "%s" "$@"\n' "$CONF" > "$SHIM/pacman-conf"
    printf '#!/bin/bash\nexec "$@"\n' > "$SHIM/sudo"
    # yay stub: records its argv so the --fix path can prove what reached it.
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$ENV_DIR/yay.log" > "$SHIM/yay"
    chmod +x "$SHIM"/*
    : > "$ENV_DIR/yay.log"

    export PATH="$SHIM:$BIN:$BASE_PATH"
    export SAFEUP_PACMAN_CONF="$CONF"
    export SAFEUP_LOG="$ENV_DIR/safeup.log"
    : > "$SAFEUP_LOG"
}

# mkpkg <name> <ver-rel> [--at <subdir>] [--files f1,f2] [dep ...]
#   → prints the package path. Files land under usr/lib unless --at says where.
mkpkg() {
    local name="$1" ver="$2"; shift 2
    local files="" at="usr/lib"
    if [ "${1:-}" = "--at" ]; then at="$2"; shift 2; fi
    if [ "${1:-}" = "--files" ]; then files="$2"; shift 2; fi
    local d="$ENV_DIR/build/$name-$ver"
    rm -rf "$d"; mkdir -p "$d/$at"
    {
        echo "pkgname = $name"; echo "pkgbase = $name"; echo "pkgver = $ver"
        echo "pkgdesc = SafeAUR loopback fixture"
        echo "url = https://example.invalid"
        echo "builddate = 1700000000"; echo "packager = safeup-test"
        echo "size = 0"; echo "arch = $ARCH"
        for dep; do echo "depend = $dep"; done
    } > "$d/.PKGINFO"
    if [ -n "$files" ]; then
        local IFS=,
        for f in $files; do install -Dm644 "$f" "$d/$at/$(basename "$f")"; done
    else
        echo "$name $ver" > "$d/$at/$name.marker"
    fi
    # `--` must precede the first file name: bsdtar stops parsing options at
    # the first non-option and would otherwise try to archive a file named "--".
    ( cd "$d" && bsdtar -czf "$ENV_DIR/build/$name-$ver-$ARCH.pkg.tar.gz" -- .PKGINFO * ) \
        || echo "mkpkg: bsdtar failed for $name-$ver" >&2
    echo "$ENV_DIR/build/$name-$ver-$ARCH.pkg.tar.gz"
}

publish() { # publish <repo-dir> <db-name> <pkgfile>...
    local dir="$1" db="$2"; shift 2
    cp "$@" "$dir/"
    local names=()
    for p in "$@"; do names+=("$dir/$(basename "$p")"); done
    repo-add -q "$dir/$db.db.tar.gz" "${names[@]}" >/dev/null 2>&1
}

installed_ver() { pacman -Q "$1" 2>/dev/null | awk '{print $2}'; }

# =============================================================================
echo ""
echo "== 1. foreign-repo discovery =="
# =============================================================================
mkenv detect blackarch
# safeup opens with `pacman -Sy`, which fails outright if a configured repo has
# no database at all — so both repos need one package before it can run.
publish "$REPO_M" extra "$(mkpkg seed-manjaro 1.0-1)"
publish "$REPO_F" blackarch "$(mkpkg seed-foreign 1.0-1)"
if pacman-conf --repo-list | grep -qx blackarch && pacman-conf --repo-list | grep -qx extra; then
    pass "both repos visible to pacman-conf --repo-list"
else
    fail "repo list did not come back as expected"
fi
out=$(safeup --noconfirm 2>&1)
if grep -q 'foreign repos tracked: blackarch' <<<"$out"; then
    pass "blackarch classified as foreign; extra was not"
else
    fail "foreign-repo classification wrong: $(grep 'foreign repos' <<<"$out")"
fi

# =============================================================================
echo ""
echo "== 2-3. the Manjaro-lag hold: unsatisfiable version constraint =="
# =============================================================================
# The exact shape of a "Manjaro AUR disaster": blackarch has rebuilt toolx
# against libfoo 2.0 because Arch shipped it; Manjaro's extra is still on 1.0.
mkenv lag blackarch
publish "$REPO_M" extra "$(mkpkg libfoo 1.0-1)"
FOO1="$ENV_DIR/build/libfoo-1.0-1-$ARCH.pkg.tar.gz"
TOOL1=$(mkpkg toolx 1.0-1 "libfoo>=1.0")
publish "$REPO_F" blackarch "$(mkpkg toolx 2.0-1 "libfoo>=2.0")"
pacman -U --noconfirm "$FOO1" "$TOOL1" >/dev/null 2>&1

out=$(safeup --noconfirm 2>&1); rc=$?
if grep -q 'hold toolx (blackarch) — unsatisfied dep: libfoo>=2.0' <<<"$out"; then
    pass "toolx held on its unsatisfiable libfoo>=2.0 constraint"
else
    fail "toolx was not held: $(grep -i 'hold\|conflict' <<<"$out")"
fi
[ "$(installed_ver toolx)" = "1.0-1" ] \
    && pass "toolx still at 1.0-1 — the partial upgrade did not happen" \
    || fail "toolx was upgraded to $(installed_ver toolx) despite the hold"
[ "$rc" = "0" ] \
    && pass "safeup still exits 0 — a hold is a success, not a failure" \
    || fail "safeup exited $rc after a clean hold"
grep -q 'toolx' "$SAFEUP_LOG" \
    && pass "hold recorded in \$SAFEUP_LOG" \
    || fail "nothing logged for the held package"

# =============================================================================
echo ""
echo "== 4. no false hold once Manjaro catches up =="
# =============================================================================
# Same env: publish libfoo 2.0 and install it, exactly as a later Manjaro sync
# would. toolx must now sail through.
publish "$REPO_M" extra "$(mkpkg libfoo 2.0-1)"
pacman -U --noconfirm "$ENV_DIR/build/libfoo-2.0-1-$ARCH.pkg.tar.gz" >/dev/null 2>&1
: > "$SAFEUP_LOG"
out=$(safeup --noconfirm 2>&1)
if [ "$(installed_ver toolx)" = "2.0-1" ]; then
    pass "toolx upgraded to 2.0-1 once libfoo>=2.0 was satisfiable"
else
    fail "toolx stuck at $(installed_ver toolx) — false hold"
fi
grep -q 'no ABI conflicts' <<<"$out" \
    && pass "run reported no ABI conflicts" \
    || fail "still reporting conflicts with a satisfiable dep set"

# =============================================================================
echo ""
echo "== 5. an unversioned dependency is never a reason to hold =="
# =============================================================================
mkenv unversioned blackarch
publish "$REPO_M" extra "$(mkpkg libbar 1.0-1)"
BAR1="$ENV_DIR/build/libbar-1.0-1-$ARCH.pkg.tar.gz"
TOOLY1=$(mkpkg tooly 1.0-1 "libbar")
publish "$REPO_F" blackarch "$(mkpkg tooly 2.0-1 "libbar")"
pacman -U --noconfirm "$BAR1" "$TOOLY1" >/dev/null 2>&1
out=$(safeup --noconfirm 2>&1)
if ! grep -q 'hold tooly' <<<"$out" && [ "$(installed_ver tooly)" = "2.0-1" ]; then
    pass "package with only unversioned deps upgraded, not held"
else
    fail "unversioned dep triggered a hold"
fi

# =============================================================================
echo ""
echo "== 6-7. recovery from 'installing X breaks dependency required by Y' =="
# =============================================================================
# This break comes from a MANJARO repo, so the pre-flight foreign check cannot
# see it. pacman refuses the whole transaction; safeup must isolate the one
# breaking package and let the rest of the upgrade land.
mkenv abibreak
APPX1=$(mkpkg appx 1.0-1)
CONS1=$(mkpkg consumer 1.0-1 "appx=1.0")
OTHER1=$(mkpkg other 1.0-1)
pacman -U --noconfirm "$APPX1" "$CONS1" "$OTHER1" >/dev/null 2>&1
publish "$REPO_M" extra \
    "$(mkpkg appx 2.0-1)" "$(mkpkg other 2.0-1)" "$CONS1"

out=$(safeup --noconfirm </dev/null 2>&1); rc=$?
if grep -q 'ABI/dep break detected' <<<"$out" && grep -q '  - appx' <<<"$out"; then
    pass "the breaking package was identified from pacman's own message"
else
    fail "ABI break not detected: $(grep -i 'break\|error' <<<"$out" | head -3)"
fi
[ "$rc" = "0" ] \
    && pass "upgrade completed after auto-holding the breaking package" \
    || { fail "safeup exited $rc instead of recovering"; echo "--- output ---"; echo "$out" | tail -30; echo "--- end ---"; }
[ "$(installed_ver appx)" = "1.0-1" ] \
    && pass "appx kept its old version (the hold was real)" \
    || fail "appx moved to $(installed_ver appx) — the break was not held"
[ "$(installed_ver other)" = "2.0-1" ] \
    && pass "unrelated package 'other' still got its upgrade" \
    || fail "other stuck at $(installed_ver other) — one break blocked everything"
grep -q 'auto-skipped' "$SAFEUP_LOG" && grep -q 'appx' "$SAFEUP_LOG" \
    && pass "auto-skip recorded in \$SAFEUP_LOG" \
    || fail "auto-skipped package not logged"

# =============================================================================
echo ""
echo "== 8. an unrecoverable failure is never laundered into success =="
# =============================================================================
mkenv unrecoverable
pacman -U --noconfirm "$(mkpkg widget 1.0-1)" >/dev/null 2>&1
# widget 2.0 needs something that exists nowhere: not a break, not a conflict,
# just unsatisfiable. None of the recovery patterns match it.
publish "$REPO_M" extra "$(mkpkg widget 2.0-1 "no-such-package-anywhere")"
safeup --noconfirm </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" != "0" ] \
    && pass "safeup exited non-zero ($rc) on an unrecoverable transaction" \
    || fail "unrecoverable pacman failure reported as success"
[ "$(installed_ver widget)" = "1.0-1" ] \
    && pass "nothing was upgraded by the failed transaction" \
    || fail "widget changed version during a failed run"

# =============================================================================
echo ""
echo "== 9-12. aur-rebuild-check against real ELF objects =="
# =============================================================================
# Real shared objects, built here by cc. libmain.so carries a genuine DT_NEEDED
# on libdep.so, and libdep.so is not on any library search path, so `ldd` really
# does report "libdep.so => not found". No ldd output is faked.
mkenv elf
ELF="$ENV_DIR/elf"; mkdir -p "$ELF"
echo 'int dep_fn(void){return 42;}'                 > "$ELF/dep.c"
echo 'int dep_fn(void); int main_fn(void){return dep_fn();}' > "$ELF/main.c"
echo 'int lone_fn(void){return 7;}'                 > "$ELF/lone.c"
cc -shared -fPIC -o "$ELF/libdep.so"  "$ELF/dep.c"  2>/dev/null
cc -shared -fPIC -o "$ELF/libmain.so" "$ELF/main.c" -L"$ELF" -l:libdep.so 2>/dev/null
cc -shared -fPIC -o "$ELF/liblone.so" "$ELF/lone.c" 2>/dev/null

if [ ! -f "$ELF/libmain.so" ] || ! ldd "$ELF/libmain.so" 2>/dev/null | grep -q 'libdep.so => not found'; then
    skip "9-11: could not build an ELF with an unresolvable DT_NEEDED on this host"
    skip "(cc/ldd behaviour differs here; the check itself was not exercised)"
else
    # brokenapp ships ONLY the consumer → a genuine break.
    pacman -U --noconfirm "$(mkpkg brokenapp 1.0-1 --files "$ELF/libmain.so")" >/dev/null 2>&1
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "1" ] && grep -q 'brokenapp' <<<"$out"; then
        pass "package with an unresolvable DT_NEEDED flagged for rebuild"
    else
        fail "broken package not flagged (rc=$rc): $out"
    fi

    # Same missing soname, but the package ships it itself → resolved at
    # runtime through an \$ORIGIN RPATH, invisible to a standalone ldd.
    pacman -R --noconfirm brokenapp >/dev/null 2>&1
    pacman -U --noconfirm \
        "$(mkpkg bundledapp 1.0-1 --files "$ELF/libmain.so,$ELF/libdep.so")" >/dev/null 2>&1
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "0" ] && ! grep -q 'bundledapp' <<<"$out"; then
        pass "package that ships the missing soname itself is NOT flagged"
    else
        fail "bundled-library false positive is back (rc=$rc): $out"
    fi

    # The named-soname escape hatch.
    pacman -R --noconfirm bundledapp >/dev/null 2>&1
    pacman -U --noconfirm "$ENV_DIR/build/brokenapp-1.0-1-$ARCH.pkg.tar.gz" >/dev/null 2>&1
    out=$(AUR_REBUILD_IGNORE_SONAMES=libdep.so aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "0" ]; then
        pass "AUR_REBUILD_IGNORE_SONAMES suppresses a named soname"
    else
        fail "ignore-list did not suppress libdep.so (rc=$rc): $out"
    fi
    pacman -R --noconfirm brokenapp >/dev/null 2>&1
fi

pacman -U --noconfirm "$(mkpkg cleanapp 1.0-1 --files "$ELF/liblone.so")" >/dev/null 2>&1
out=$(aur-rebuild-check 2>&1); rc=$?
if [ "$rc" = "0" ] && grep -q 'satisfied library links' <<<"$out"; then
    pass "a package whose links all resolve is reported clean, exit 0"
else
    fail "clean package not reported clean (rc=$rc): $out"
fi

# 24. A broken executable that is neither *.so nor under a bin/ directory.
# /opt/<app>/<exe> is the layout of a large share of AUR packages, and a scan
# keyed on file NAME never opened it. ELF is identified by magic now.
pacman -R --noconfirm cleanapp >/dev/null 2>&1
echo 'int dep_fn(void); int main(void){return dep_fn();}' > "$ELF/app.c"
cc -o "$ELF/app" "$ELF/app.c" -L"$ELF" -l:libdep.so 2>/dev/null
if [ -x "$ELF/app" ] && ldd "$ELF/app" 2>/dev/null | grep -q 'libdep.so => not found'; then
    pacman -U --noconfirm "$(mkpkg optapp 1.0-1 --at opt/optapp --files "$ELF/app")" >/dev/null 2>&1
    out=$(aur-rebuild-check 2>&1); rc=$?
    if [ "$rc" = "1" ] && grep -q 'optapp' <<<"$out"; then
        pass "a broken ELF under /opt/<app>/ (not *.so, not bin/) is flagged"
    else
        fail "ELF outside *.so and bin/ was not scanned (rc=$rc): $out"
    fi
    pacman -R --noconfirm optapp >/dev/null 2>&1
else
    skip "24: could not build a dynamically linked executable with a missing DT_NEEDED here"
fi

# 25. A pure-Python package after a python bump. There is no ELF to scan; the
# files simply sit in a directory the new interpreter never looks at, and to
# pacman nothing is wrong. The current version comes from `pacman -Q python`.
pacman -U --noconfirm "$(mkpkg python 3.13.1-1)" >/dev/null 2>&1
echo 'x = 1' > "$ELF/mod.py"
pacman -U --noconfirm \
    "$(mkpkg oldpy 1.0-1 --at usr/lib/python3.12/site-packages --files "$ELF/mod.py")" \
    "$(mkpkg newpy 1.0-1 --at usr/lib/python3.13/site-packages --files "$ELF/mod.py")" >/dev/null 2>&1
out=$(aur-rebuild-check 2>&1); rc=$?
if [ "$rc" = "1" ] && grep -q 'oldpy' <<<"$out" && grep -q 'python3.12' <<<"$out"; then
    pass "package under the previous interpreter's site-packages is flagged, naming the stale dir"
else
    fail "stale python3.12 site-packages not flagged (rc=$rc): $out"
fi
grep -q 'newpy' <<<"$out" \
    && fail "package under the CURRENT python3.13 dir was flagged" \
    || pass "package under the current interpreter's site-packages is not flagged"
pacman -R --noconfirm oldpy newpy python >/dev/null 2>&1

# 29. --fix must not become a way around the gate: a rebuild goes through
# aur-pin-check first, and only a clean set reaches yay. .SRCINFO comes from a
# local file here, exactly as the fixture suite does it.
if [ -f "$ELF/libmain.so" ] && curl -V 2>/dev/null | grep -q '\bfile\b'; then
    pacman -U --noconfirm "$ENV_DIR/build/brokenapp-1.0-1-$ARCH.pkg.tar.gz" >/dev/null 2>&1
    export AUR_SRCINFO_URL="file://$ENV_DIR/%s.SRCINFO" AUR_RPC_URL="file://$ENV_DIR/%s.json"
    printf 'pkgbase = brokenapp\n\tsource = git+https://example.invalid/b.git\n\npkgname = brokenapp\n' \
        > "$ENV_DIR/brokenapp.SRCINFO"
    : > "$ENV_DIR/yay.log"
    out=$(aur-rebuild-check --fix --noconfirm 2>&1); rc=$?
    if [ "$rc" != "0" ] && grep -q 'REJECT brokenapp' <<<"$out" && [ ! -s "$ENV_DIR/yay.log" ]; then
        pass "--fix refuses to rebuild a package the pin-check rejects; yay never runs"
    else
        fail "--fix bypassed the gate (rc=$rc, yay: $(cat "$ENV_DIR/yay.log"))"
    fi
    printf 'pkgbase = brokenapp\n\tsource = git+https://example.invalid/b.git#commit=0123456789abcdef0123456789abcdef01234567\n\npkgname = brokenapp\n' \
        > "$ENV_DIR/brokenapp.SRCINFO"
    : > "$ENV_DIR/yay.log"
    aur-rebuild-check --fix --noconfirm >/dev/null 2>&1
    if grep -q -- '-S --rebuild --noconfirm brokenapp' "$ENV_DIR/yay.log"; then
        pass "--fix --noconfirm reaches 'yay -S --rebuild --noconfirm' for a pinned package"
    else
        fail "--fix did not rebuild a clean package: $(cat "$ENV_DIR/yay.log")"
    fi
    unset AUR_SRCINFO_URL AUR_RPC_URL
    pacman -R --noconfirm brokenapp >/dev/null 2>&1
else
    skip "29: needs the broken ELF from 9-11 and a curl with file:// support"
fi

# =============================================================================
echo ""
echo "== 13-18. remove-versioned-kernel guards =="
# =============================================================================
mkenv kernels
remove-versioned-kernel --noconfirm not-a-kernel >/dev/null 2>&1
[ "$?" = "2" ] \
    && pass "a name that is not linuxNN is rejected (exit 2)" \
    || fail "non-kernel name was accepted"

remove-versioned-kernel --noconfirm linux77 >/dev/null 2>&1
[ "$?" = "0" ] \
    && pass "a kernel that is not installed is a no-op (exit 0)" \
    || fail "uninstalled kernel did not exit 0"

# Build a linux66 that OWNS the running kernel's module directory, so the
# booted-kernel guard has something real to resolve.
RUNNING=$(uname -r)
K66="$ENV_DIR/build/k66"; mkdir -p "$K66/usr/lib/modules/$RUNNING"
echo placeholder > "$K66/usr/lib/modules/$RUNNING/.keep"
{
    echo "pkgname = linux66"; echo "pkgbase = linux66"; echo "pkgver = 6.6.1-1"
    echo "pkgdesc = SafeAUR loopback fixture"
    echo "url = https://example.invalid"
    echo "builddate = 1700000000"; echo "packager = safeup-test"
    echo "size = 0"; echo "arch = $ARCH"
} > "$K66/.PKGINFO"
( cd "$K66" && bsdtar -czf "$ENV_DIR/build/linux66-booted-$ARCH.pkg.tar.gz" .PKGINFO usr )
pacman -U --noconfirm "$ENV_DIR/build/linux66-booted-$ARCH.pkg.tar.gz" \
    "$(mkpkg linux66-headers 6.6.1-1)" "$(mkpkg linux99 9.9.9-1)" >/dev/null 2>&1

if [ "$(pacman -Qoq "/usr/lib/modules/$RUNNING" 2>/dev/null)" = "linux66" ]; then
    out=$(remove-versioned-kernel --noconfirm linux66 2>&1); rc=$?
    if [ "$rc" = "3" ] && grep -q 'currently booted into it' <<<"$out"; then
        pass "refuses to remove the currently-booted kernel (exit 3)"
    else
        fail "booted-kernel guard did not fire (rc=$rc): $(head -1 <<<"$out")"
    fi
else
    skip "15: pacman -Qo could not resolve the running kernel's module dir here"
fi

# Guard 2 is checked before guard 3, so the last-kernel case needs a state
# where NOTHING owns the running kernel's modules. Clear the board and leave a
# single plain linux99 behind.
pacman -R --noconfirm linux66 linux66-headers linux99 >/dev/null 2>&1
pacman -U --noconfirm "$(mkpkg linux99 9.9.9-2)" >/dev/null 2>&1
out=$(remove-versioned-kernel --noconfirm linux99 2>&1); rc=$?
if [ "$rc" = "3" ] && grep -q 'leave 0 versioned kernels' <<<"$out"; then
    pass "refuses to remove the last remaining versioned kernel (exit 3)"
else
    fail "last-kernel guard did not fire (rc=$rc): $(head -1 <<<"$out")"
fi

# A legitimate removal, with an IgnorePkg line to rewrite.
#
# SAFEUP_UKI_DIR is pointed at a path that does NOT exist, deliberately. The
# verification section's probes run after the removal and the IgnorePkg
# rewrite have already succeeded, so a probe that aborts the script there
# turns a completed job into a non-zero exit -- and the machines where that
# happens are exactly the ones whose ESP is not laid out like the author's.
# Pinning the variable makes this case reproducible on every host instead of
# only on the ones that happen to lack the directory.
install_kernel_set() {
    pacman -U --noconfirm "$(mkpkg linux66 "$1")" "$(mkpkg linux66-headers "$1")" \
        "$(mkpkg linux66-nvidia "$1")" >/dev/null 2>&1
    sed -i 's|^IgnorePkg.*|IgnorePkg = linux66 linux66-headers linux66-nvidia linux99 linux99-headers linux99-nvidia nvidia-utils lib32-nvidia-utils|' "$CONF"
}

install_kernel_set 6.6.1-3
out=$(SAFEUP_UKI_DIR="$ENV_DIR/no-such-uki-dir" \
      remove-versioned-kernel --noconfirm linux66 2>&1); rc=$?
if [ "$rc" = "0" ] && ! pacman -Qq linux66 >/dev/null 2>&1 \
   && ! pacman -Qq linux66-headers >/dev/null 2>&1 \
   && ! pacman -Qq linux66-nvidia >/dev/null 2>&1; then
    pass "kernel, headers and -nvidia sibling removed in one transaction"
else
    fail "removal incomplete (rc=$rc): $(pacman -Qq 2>/dev/null | grep linux66 | tr '\n' ' ')"
fi
ign=$(grep '^IgnorePkg' "$CONF")
if ! grep -q 'linux66' <<<"$ign" && grep -q 'linux99' <<<"$ign" \
   && grep -q 'nvidia-utils' <<<"$ign"; then
    pass "IgnorePkg rewritten to the survivors, nvidia userspace kept"
else
    fail "IgnorePkg rewrite wrong: $ign"
fi

# 18. The same removal on a system that DOES have a UKI directory. Guarding a
# probe is only correct if the guard did not also swallow the working case.
UKI="$ENV_DIR/uki"; mkdir -p "$UKI"
: > "$UKI/manjaro-linux99.efi"
install_kernel_set 6.6.1-4
out=$(SAFEUP_UKI_DIR="$UKI" remove-versioned-kernel --noconfirm linux66 2>&1); rc=$?
if [ "$rc" = "0" ] && grep -q 'manjaro-linux99.efi' <<<"$out"; then
    pass "removal exits 0 and still lists the UKIs when the directory exists"
else
    fail "UKI-present path broken (rc=$rc): $(grep -i 'boot entries' -A2 <<<"$out" | tr '\n' ' ')"
fi

# =============================================================================
echo ""
echo "== 19. --ignore cannot manufacture a partial upgrade =="
# =============================================================================
# The safety argument for this whole suite rests on one property of pacman:
# --ignore suppresses an UPGRADE, it does not suppress DEPENDENCY RESOLUTION.
# If that were not true, safeup's holds would be a partial-upgrade generator
# rather than a partial-upgrade guard, and the tool would be actively harmful.
#
# It is an assumption about pacman rather than about our own code, which is
# exactly why it belongs in a test: nothing in this repository would notice if
# a future pacman changed it, and the consequence would be silent.
mkenv ignoresafety
# consumer 1.0 needs libX=1.0 exactly, and both are installed and consistent.
LIBX1=$(mkpkg libX 1.0-1)
CONS1=$(mkpkg consumer 1.0-1 "libX=1.0")
pacman -U --noconfirm "$LIBX1" "$CONS1" >/dev/null 2>&1
# The repo offers both upgrades; consumer 2.0 requires the NEW libX.
publish "$REPO_M" extra "$(mkpkg libX 2.0-1)" "$(mkpkg consumer 2.0-1 "libX=2.0")"
pacman -Sy >/dev/null 2>&1

# Ignoring libX would strand consumer 2.0 against a libX 2.0 that is not there.
# This is the exact shape of the partial upgrade people fear.
pacman -Syu --noconfirm --ignore libX >/dev/null 2>&1; rc=$?
[ "$rc" != "0" ] \
    && pass "pacman refuses an --ignore transaction that would strand a dependency" \
    || fail "pacman accepted a transaction leaving consumer 2.0 without libX 2.0"

if [ "$(installed_ver libX)" = "1.0-1" ] && [ "$(installed_ver consumer)" = "1.0-1" ]; then
    pass "the refused transaction changed nothing — no half-applied upgrade"
else
    fail "system moved: libX=$(installed_ver libX) consumer=$(installed_ver consumer)"
fi

# pacman's own database consistency check is the impartial judge here.
pacman -Dk >/dev/null 2>&1 \
    && pass "pacman -Dk: every dependency still satisfied after the refusal" \
    || fail "pacman -Dk reports an inconsistent system"

# And the same audit after a REAL safeup hold, which is the case that actually
# ships: proving pacman refuses is only useful if safeup's own holds inherit it.
mkenv holdconsistency blackarch
publish "$REPO_M" extra "$(mkpkg libz 1.0-1)"
LIBZ1="$ENV_DIR/build/libz-1.0-1-$ARCH.pkg.tar.gz"
TOOLZ1=$(mkpkg toolz 1.0-1 "libz>=1.0")
publish "$REPO_F" blackarch "$(mkpkg toolz 2.0-1 "libz>=2.0")"
pacman -U --noconfirm "$LIBZ1" "$TOOLZ1" >/dev/null 2>&1
out=$(safeup --noconfirm </dev/null 2>&1)
if grep -q 'hold toolz' <<<"$out" && pacman -Dk >/dev/null 2>&1; then
    pass "after a real safeup hold, pacman -Dk still reports a consistent system"
else
    fail "safeup's hold left the system inconsistent, or did not hold at all"
fi

echo ""
echo "==================================================="
echo "  $PASS passed, $FAIL failed, $SKIP skipped"
echo "==================================================="
[ "$FAIL" -eq 0 ]
