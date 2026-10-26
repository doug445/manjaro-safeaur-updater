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
# pin-fixture-test.sh — exercise the supply-chain gate (aur-pin-check, and the
# two wrappers that call it) against synthetic .SRCINFO fixtures and REAL local
# git repositories.
#
# No root. No disk. No network. Nothing outside $TMPDIR is read or written.
#
# What it proves:
#   1.  a commit-pinned VCS source (#commit=<40-hex>) is ACCEPTED
#   2.  a bare VCS source with no fragment is REJECTED
#   3.  a #tag= source is REJECTED — tags are mutable, that is the whole point
#   4.  a #branch= source is REJECTED (a branch moves every push)
#   5.  a short (<40 hex) commit fragment is REJECTED, not silently accepted
#   6.  non-VCS sources (tarballs) are ACCEPTED — sha256sums already cover them
#   7.  a "name::git+..." prefixed source is still recognised as VCS
#   8.  multi-source packages reject if ANY one source is unpinned
#   9.  every rejection is reported, not just the first (multi-package runs)
#   10. the allowlist accepts a tag-pinned source whose tag STILL resolves to
#       the recorded SHA        — against a real git repo via `git ls-remote`
#   11. the allowlist REJECTS the same source once upstream moves the tag
#       — the TOFU property, exercised by actually re-pointing the tag
#   12. an allowlist row whose tag no longer exists is REJECTED, not skipped
#   13. an allowlist row for a DIFFERENT source spec does not launder the pkg
#   14. a package already in a pacman repo is skipped (not an AUR concern)
#   15. an unfetchable .SRCINFO is an ERROR (exit 2 class), never a silent pass
#   16. the deleted-from-AUR triage hint fires on resultcount:0
#   17. aurinstall refuses to exec yay when the gate fails, and passes when it
#       succeeds — the gate is load-bearing, not decorative
#   18. aurupdate pin-checks the pending set and aborts on a failure
#   19. --chroot still runs the pin-check gate first, and an unpinned package
#       never reaches chrootbuild
#   20. a dependency in no repo and not in the AUR is refused by the gate
#       itself, before any chroot build or yay run is spent on it
#   21. --chroot always passes an explicit -b <branch>; chrootbuild's default
#       is 'unstable', and building against the wrong branch still exits 0
#       while producing exactly the soname mismatch this suite exists to stop
#   22. --chroot builds the package it was asked for
#   23. auto mode (no flag) uses the chroot when the package is eligible
#   24. auto mode falls back to yay on a chain the chroot will not build
#       (deeper than AURINSTALL_MAX_CHAIN), REPORTING why
#   25. auto mode sends *-bin to yay: nothing is compiled, so a chroot cannot
#       change the shipped ELF and would only cost a chroot sync
#   26. an explicit --chroot on an ineligible package is an ERROR -- forcing a
#       mode and then silently getting another one is the failure this suite
#       exists to prevent
#   27. --no-chroot forces yay even when the chroot would have worked
#   28. a resolvable AUR dependency chain is BUILT, deps first, as one
#       chrootbuild invocation chained with -n (-p dep2 -n -p dep1 -n -p tgt)
#   29. a chained dependency is pin-checked exactly like a named target --
#       an unvetted dep is the same supply-chain hole as an unvetted target
#   30. a dependency cycle is detected and falls back to yay, naming it
#   31. `#commit=<40-hex>?signed` is ACCEPTED — the `?signed` query is makepkg's
#       strongest form, and refusing it penalised the most careful maintainers
#   32. an unpinned VCS source under `source_x86_64 =` is REJECTED — arch-specific
#       source arrays are sources too, and skipping them was a silent pass
#   33. hg `#revision=<40-hex>` is ACCEPTED, bare hg REJECTED — hg has no
#       `#commit=`; its changeset hash is the content-addressed pin
#   34. svn `#revision=N` is ACCEPTED, bare `svn://` REJECTED
#   35. a bare `fossil+` source is REJECTED — it is a VCS makepkg supports, and
#       not recognising it meant accepting it
#   36. a SPLIT package (its own name has no cgit branch) is resolved to its
#       pkgbase through the RPC and judged on the pkgbase's sources, in both
#       directions — instead of an ERROR that blocked the whole upgrade set
#   37. aurinstall builds a split package's PKGBASE in the chroot, once
#   38. with PKGDEST unset, the built package SURVIVES in the invoking
#       directory after a no-install run — it used to be deleted with the
#       temp dir before the "install later" message could even be read
#   39. --install installs the artifact without a prompt; --no-install never
#       touches pacman -U
#   40. a name a binary repo also carries (chaotic-aur carries AUR names) is
#       skipped for yay but checked with --from-aur — and the chroot, which
#       builds the AUR copy regardless, refuses it when it is unpinned
#   41. a source pushed after the check but before the clone is caught: the
#       chroot pin-checks the clone it is about to build
#   42. on the yay path, an unpinned AUR DEPENDENCY is refused; yay never runs
#   43. aurupdate refuses a pending upgrade whose new AUR dependency is unpinned
#   44. a dependency met by an installed package is not walked by --deps
#   45. ...nor one met by a binary repo — yay builds neither
#   46. a name containing '+' is requested URL-encoded; sent raw, the AUR read
#       '+' as a space and the package could never pass
#   47. a .SRCINFO that shows a pin over a PKGBUILD that has none is REJECTED
#   48. a VCS source in the PKGBUILD that the .SRCINFO omits entirely is REJECTED
#   49. variables in a pin, a VCS-looking pkgdesc, comments and build() do not
#       trip the tripwire
#   50. a PKGBUILD that cannot be fetched is an ERROR, never a pass
#
# Run:  bash tests/pin-fixture-test.sh
# Requires: bash >= 4, git, curl (with file:// support), awk, coreutils.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$HERE/.." && pwd)/bin"

for c in git curl awk sed grep; do
    command -v "$c" >/dev/null || { echo "missing tool: $c"; exit 1; }
done
curl -V 2>/dev/null | grep -q '\bfile\b' || {
    echo "this curl has no file:// protocol support; cannot run offline fixtures"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/safeup-pin-test.XXXXXX")
PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
cleanup() { cd / && rm -rf "$WORK"; }
trap cleanup EXIT
# Run from inside the scratch tree. aurinstall keeps a built package in the
# directory it was invoked from when PKGDEST is unset (case 38), so a suite run
# from the repository root used to leave *.pkg.tar.zst files in the checkout.
cd "$WORK" || exit 1

mkdir -p "$WORK/srcinfo" "$WORK/pkgbuild" "$WORK/rpc" "$WORK/shim" "$WORK/git"

# --- the environment every invocation below runs under -----------------------
# Endpoints point at local files; the allowlist points at a fixture we rewrite
# between cases. PATH is prefixed with stubs so nothing reaches the real system.
export AUR_SRCINFO_URL="file://$WORK/srcinfo/%s.SRCINFO"
export AUR_PKGBUILD_URL="file://$WORK/pkgbuild/%s.PKGBUILD"
export AUR_RPC_URL="file://$WORK/rpc/%s.json"
export AUR_PIN_ALLOWLIST="$WORK/allowlist.conf"
export PATH="$WORK/shim:$BIN:$PATH"
: > "$WORK/allowlist.conf"

# pacman stub. aur-pin-check asks it these questions and nothing else:
#   -Si <pkg>   → is this package in a binary repo? (then it is not our problem)
#   -T / -Sddp  → is a dependency met by an installed / a repo package? (--deps)
#   -Qq / -Qdtq → is it installed, and is it an orphan? (triage hints only)
# $WORK/repo-pkgs, $WORK/installed and $WORK/orphans drive the answers; a
# dependency is judged by its name, version constraint ignored.
cat > "$WORK/shim/pacman" <<'SHIM'
#!/bin/bash
last="${*: -1}"; dname="${last%%[<>=]*}"
case "$1" in
  -Si)   grep -qxF -- "$2" "$WORK_REPO_PKGS" 2>/dev/null && { echo "Repository : extra"; exit 0; }; exit 1 ;;
  -T)    grep -qxF -- "$dname" "$WORK_INSTALLED" 2>/dev/null && exit 0; exit 127 ;;
  -Sddp) grep -qxF -- "$dname" "$WORK_REPO_PKGS" 2>/dev/null && exit 0; exit 1 ;;
  -Qq)   grep -qxF -- "$2" "$WORK_INSTALLED" 2>/dev/null && { echo "$2"; exit 0; }; exit 1 ;;
  -Qdtq) cat "$WORK_ORPHANS" 2>/dev/null; exit 0 ;;
  -U)    printf '%s\n' "$*" >> "$WORK_PACMAN_LOG"; exit 0 ;;
  *)     exit 1 ;;
esac
SHIM
chmod +x "$WORK/shim/pacman"
export WORK_REPO_PKGS="$WORK/repo-pkgs" WORK_INSTALLED="$WORK/installed" WORK_ORPHANS="$WORK/orphans"
export WORK_PACMAN_LOG="$WORK/pacman.log"
: > "$WORK_REPO_PKGS"; : > "$WORK_INSTALLED"; : > "$WORK_ORPHANS"; : > "$WORK_PACMAN_LOG"
# aurinstall reads PKGDEST from makepkg.conf the way chrootbuild does: the
# invoking user's /home/<name>/.makepkg.conf, then the global file. Point the
# global file at nothing, and give `id -un` a name with no home directory, so
# neither of the host's real makepkg.conf files can leak a PKGDEST into the
# fixtures.
export MAKEPKG_CONF=/dev/null
cat > "$WORK/shim/id" <<'SHIM'
#!/bin/bash
[[ "${1:-}" == -un ]] && { echo safeaur-fixture-user; exit 0; }
exec /usr/bin/id "$@"
SHIM
chmod +x "$WORK/shim/id"

# yay stub — records its argv so we can prove whether a gate actually blocked
# the exec, rather than assuming it from an exit code.
cat > "$WORK/shim/yay" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$WORK_YAY_LOG"
# -Qua: emit the pending-upgrade list the aurupdate fixture wants
if [[ "$1" == "-Qua" ]]; then cat "$WORK_YAY_QUA" 2>/dev/null; fi
exit 0
SHIM
chmod +x "$WORK/shim/yay"
export WORK_YAY_LOG="$WORK/yay.log" WORK_YAY_QUA="$WORK/yay-qua"
: > "$WORK_YAY_LOG"; : > "$WORK_YAY_QUA"

# curl wrapper: the real curl, with every URL it was asked for logged. A
# file:// fixture reads '+' literally, where the AUR's web server reads it as a
# space, so only the URL itself shows whether a name was encoded (case 46).
REAL_CURL=$(command -v curl)
cat > "$WORK/shim/curl" <<SHIM
#!/bin/bash
printf '%s\n' "\${*: -1}" >> "\$WORK_CURL_LOG"
exec "$REAL_CURL" "\$@"
SHIM
chmod +x "$WORK/shim/curl"
export WORK_CURL_LOG="$WORK/curl.log"
: > "$WORK_CURL_LOG"

# chrootbuild + pacman-mirrors stubs, for --chroot mode. chrootbuild records
# its argv so we can assert on the branch flag rather than assume it.
cat > "$WORK/shim/chrootbuild" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$WORK_CB_LOG"
# Like the real thing with PKGDEST unset: every -p <pkg> leaves its artifact in
# the directory chrootbuild was started from.
while (( $# )); do
    [[ "$1" == -p ]] && : > "$PWD/$2-1.0-1-x86_64.pkg.tar.zst"
    shift
done
exit 0
SHIM
cat > "$WORK/shim/pacman-mirrors" <<'SHIM'
#!/bin/bash
[[ "${1:-}" == "--get-branch" ]] && { echo stable; exit 0; }
exit 1
SHIM
# --chroot calls chrootbuild through sudo; run it directly under test.
cat > "$WORK/shim/sudo" <<'SHIM'
#!/bin/bash
exec "$@"
SHIM
chmod +x "$WORK/shim/chrootbuild" "$WORK/shim/pacman-mirrors" "$WORK/shim/sudo"
export WORK_CB_LOG="$WORK/chrootbuild.log"
: > "$WORK_CB_LOG"

# Write a .SRCINFO fixture: srcinfo <pkg> <source-line>... — and the PKGBUILD
# it describes, with the same sources, since the pin check compares the two.
srcinfo() {
    local pkg="$1"; shift
    { printf 'pkgbase = %s\n\tpkgver = 1.0\n\tpkgrel = 1\n' "$pkg"
      for s in "$@"; do printf '\tsource = %s\n' "$s"; done
      printf '\npkgname = %s\n' "$pkg"
    } > "$WORK/srcinfo/$pkg.SRCINFO"
    { printf 'pkgname=%s\npkgver=1.0\npkgrel=1\nsource=(' "$pkg"
      for s in "$@"; do printf '"%s"\n        ' "$s"; done
      printf ')\n'
    } > "$WORK/pkgbuild/$pkg.PKGBUILD"
}

# Replace only the PKGBUILD fixture: pkgbuild <pkg> <file-content>
pkgbuild() { printf '%s\n' "$2" > "$WORK/pkgbuild/$1.PKGBUILD"; }

# Write an AUR RPC fixture: rpc <pkg> <resultcount> [pkgbase]
rpc() {
    if [[ -n "${3:-}" ]]; then
        printf '{"resultcount":%s,"results":[{"Name":"%s","PackageBase":"%s"}]}' "$2" "$1" "$3"
    else
        printf '{"resultcount":%s,"results":[]}' "$2"
    fi > "$WORK/rpc/$1.json"
}

# Run aur-pin-check on one package, capturing combined output.
check() { aur-pin-check "$@" >"$WORK/out" 2>&1; echo $?; }

SHA_A=0123456789abcdef0123456789abcdef01234567

# =============================================================================
echo "== 1-8. pinning policy: what is accepted and what is refused =="
# =============================================================================

srcinfo pinned      "git+https://example.invalid/a.git#commit=$SHA_A"
rpc     pinned 1
[[ $(check pinned) == 0 ]] \
    && pass "commit-pinned git source accepted" \
    || fail "commit-pinned git source rejected: $(cat "$WORK/out")"

srcinfo bare        "git+https://example.invalid/b.git"
rpc     bare 1
[[ $(check bare) == 1 ]] \
    && pass "unfragmented git source rejected" \
    || fail "unfragmented git source was accepted"

srcinfo tagged      "git+https://example.invalid/c.git#tag=v1.2.3"
rpc     tagged 1
rc=$(check tagged)
if [[ $rc == 1 ]] && grep -q 'REJECT tagged' "$WORK/out"; then
    pass "#tag= source rejected (tags are mutable)"
else
    fail "#tag= source not rejected (rc=$rc)"
fi

srcinfo branched    "git+https://example.invalid/d.git#branch=main"
rpc     branched 1
[[ $(check branched) == 1 ]] \
    && pass "#branch= source rejected" \
    || fail "#branch= source was accepted"

# A 12-char SHA is a perfectly valid git ref. It is NOT a valid pin here:
# short hashes can collide, and the policy is 40 hex or nothing.
srcinfo shortsha    "git+https://example.invalid/e.git#commit=0123456789ab"
rpc     shortsha 1
[[ $(check shortsha) == 1 ]] \
    && pass "abbreviated commit fragment rejected (40-hex or nothing)" \
    || fail "abbreviated commit fragment was accepted"

srcinfo tarball     "https://example.invalid/f-1.0.tar.gz"
rpc     tarball 1
[[ $(check tarball) == 0 ]] \
    && pass "non-VCS tarball source accepted (sha256sums cover it)" \
    || fail "tarball source rejected: $(cat "$WORK/out")"

# `name::git+url` is the renamed-source form. Stripping the prefix is what makes
# it recognisable as VCS at all; getting that wrong means silent acceptance.
srcinfo renamed     "myname::git+https://example.invalid/g.git"
rpc     renamed 1
[[ $(check renamed) == 1 ]] \
    && pass "'name::git+...' prefixed source still recognised as VCS" \
    || fail "renamed VCS source slipped past the parser"

srcinfo mixed       "https://example.invalid/h-1.0.tar.gz" \
                    "git+https://example.invalid/h.git#commit=$SHA_A" \
                    "git+https://example.invalid/h-extra.git"
rpc     mixed 1
rc=$(check mixed)
if [[ $rc == 1 ]] && grep -q 'h-extra.git' "$WORK/out"; then
    pass "multi-source package rejected on its ONE unpinned source"
else
    fail "multi-source package: one unpinned source did not reject (rc=$rc)"
fi

# =============================================================================
echo "== 9. every package is reported, not just the first failure =="
# =============================================================================
rc=$(check bare branched pinned)
if [[ $rc == 1 ]] \
   && grep -q 'REJECT bare' "$WORK/out" \
   && grep -q 'REJECT branched' "$WORK/out"; then
    pass "all failing packages reported in a multi-package run"
else
    fail "multi-package run stopped early or lost a rejection (rc=$rc)"
fi

# =============================================================================
echo "== 10-13. allowlist TOFU against a real git repository =="
# =============================================================================
# A real repo, a real tag, resolved with a real `git ls-remote`. The point of
# these four cases is that the allowlist is not blanket trust: it records the
# SHA a tag pointed at when it was vetted, and re-verifies that every run.
REPO="$WORK/git/upstream"
git init -q "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
git -C "$REPO" tag v1.0
SHA_V1=$(git -C "$REPO" rev-parse v1.0)
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
SHA_V2=$(git -C "$REPO" rev-parse HEAD)

SPEC="git+file://$REPO#tag=v1.0"
srcinfo allowed "$SPEC"
rpc     allowed 1

printf '%s  %s  %s\n' allowed "$SPEC" "$SHA_V1" > "$WORK/allowlist.conf"
[[ $(check allowed) == 0 ]] \
    && pass "allowlisted tag accepted while it still resolves to the vetted SHA" \
    || fail "allowlisted tag rejected though unmoved: $(cat "$WORK/out")"

# Move the tag — exactly what a compromised or careless upstream would do.
git -C "$REPO" tag -f v1.0 "$SHA_V2" >/dev/null 2>&1
rc=$(check allowed)
if [[ $rc == 1 ]] && grep -q 'tag moved upstream' "$WORK/out"; then
    pass "allowlisted tag REJECTED once upstream re-pointed it (TOFU holds)"
else
    fail "moved tag was still accepted (rc=$rc) — TOFU is broken"
fi
git -C "$REPO" tag -f v1.0 "$SHA_V1" >/dev/null 2>&1   # restore

# A deleted tag must not read as "nothing to verify, therefore fine".
git -C "$REPO" tag -d v1.0 >/dev/null 2>&1
rc=$(check allowed)
if [[ $rc == 1 ]] && grep -q 'did not resolve' "$WORK/out"; then
    pass "allowlisted tag that no longer exists is rejected, not skipped"
else
    fail "vanished tag did not reject (rc=$rc)"
fi
git -C "$REPO" tag v1.0 "$SHA_V1" >/dev/null 2>&1      # restore

# An allowlist row is scoped to one exact source spec. A row for a different
# URL must not launder an unrelated source in the same package.
printf '%s  %s  %s\n' allowed "git+file://$REPO-other#tag=v1.0" "$SHA_V1" > "$WORK/allowlist.conf"
[[ $(check allowed) == 1 ]] \
    && pass "allowlist row for a different source spec does not launder the package" \
    || fail "allowlist matched a source it was not written for"
: > "$WORK/allowlist.conf"

# =============================================================================
echo "== 14-16. scope, fetch failures, and the deleted-package hint =="
# =============================================================================
echo bare > "$WORK_REPO_PKGS"
[[ $(check bare) == 0 ]] \
    && pass "package present in a pacman repo is skipped (not an AUR concern)" \
    || fail "repo package was pin-checked anyway"
: > "$WORK_REPO_PKGS"

# No fixture file exists for this name → curl fails → must be an ERROR, and
# must NOT be reported as a clean pass.
rc=$(check does-not-exist-anywhere)
if [[ $rc == 1 ]] && grep -q 'ERROR' "$WORK/out"; then
    pass "unfetchable .SRCINFO reported as ERROR, never as a pass"
else
    fail "unfetchable .SRCINFO did not surface as an error (rc=$rc)"
fi

# cgit serves deleted packages' repos forever. resultcount:0 is the only signal
# that the PKGBUILD you just read may be years stale — the hint must fire.
srcinfo ghostpkg "git+https://example.invalid/ghost.git"
rpc     ghostpkg 0
check ghostpkg >/dev/null
if grep -q 'NOT in the AUR index' "$WORK/out"; then
    pass "deleted-from-AUR triage hint fires on resultcount:0"
else
    fail "no deleted-package hint for an unindexed package"
fi

# An orphan is better removed than allowlisted forever.
srcinfo orphanpkg "git+https://example.invalid/orphan.git"
rpc     orphanpkg 1
echo orphanpkg > "$WORK_INSTALLED"; echo orphanpkg > "$WORK_ORPHANS"
check orphanpkg >/dev/null
if grep -q 'is an orphan' "$WORK/out"; then
    pass "orphan triage hint fires (prefer -Rns over an allowlist row)"
else
    fail "no orphan hint for an installed orphan"
fi
: > "$WORK_INSTALLED"; : > "$WORK_ORPHANS"

# =============================================================================
echo "== 17-18. the wrappers: is the gate actually load-bearing? =="
# =============================================================================
# An exit code alone does not prove aurinstall stopped: it could have run yay
# and had yay fail. The stub logs its argv, so we check yay was never reached.
: > "$WORK_YAY_LOG"
aurinstall bare >/dev/null 2>&1; rc=$?
if (( rc == 1 )) && [[ ! -s "$WORK_YAY_LOG" ]]; then
    pass "aurinstall refuses to exec yay when pin-check rejects"
else
    fail "aurinstall reached yay despite a rejection (rc=$rc, log: $(cat "$WORK_YAY_LOG"))"
fi

: > "$WORK_YAY_LOG"
# --no-chroot, because auto mode now prefers the chroot for an eligible package.
aurinstall --no-chroot pinned >/dev/null 2>&1
if grep -q -- '-S pinned' "$WORK_YAY_LOG"; then
    pass "aurinstall execs 'yay -S' when pin-check passes"
else
    fail "aurinstall did not reach yay on a clean package"
fi

printf 'bare 1.0 -> 2.0\npinned 1.0 -> 2.0\n' > "$WORK_YAY_QUA"
: > "$WORK_YAY_LOG"
aurupdate >/dev/null 2>&1; rc=$?
if (( rc == 1 )) && ! grep -q -- '-Sua' "$WORK_YAY_LOG"; then
    pass "aurupdate pin-checks the pending set and aborts before 'yay -Sua'"
else
    fail "aurupdate proceeded to -Sua with an unpinned package pending (rc=$rc)"
fi

printf 'pinned 1.0 -> 2.0\n' > "$WORK_YAY_QUA"
: > "$WORK_YAY_LOG"
aurupdate >/dev/null 2>&1
if grep -q -- '-Sua' "$WORK_YAY_LOG"; then
    pass "aurupdate proceeds to 'yay -Sua' when the pending set is clean"
else
    fail "aurupdate blocked a clean pending set"
fi

# Nothing pending: it still runs `yay -Qua` to find that out, but must exit 0
# without ever reaching the upgrade itself.
: > "$WORK_YAY_QUA"
: > "$WORK_YAY_LOG"
aurupdate >/dev/null 2>&1; rc=$?
if (( rc == 0 )) && ! grep -q -- '-Sua' "$WORK_YAY_LOG"; then
    pass "aurupdate exits 0 without upgrading when nothing is pending"
else
    fail "empty pending set was not handled cleanly (rc=$rc)"
fi

# =============================================================================
echo "== 19-22. aurinstall --chroot =="
# =============================================================================
# --chroot hands the build to Manjaro's own chrootbuild. The gate must still
# run first, the branch must never be left to chrootbuild's default (which is
# 'unstable' and would silently build against the wrong libraries), and a
# package whose dependencies are themselves in the AUR must be refused BEFORE
# a chroot build is spent on it, since chrootbuild cannot resolve those.

# A local "AUR" to clone from, so no network is touched.
AURGIT="$WORK/aurgit"; mkdir -p "$AURGIT"
# Each repo carries the package's current .SRCINFO and PKGBUILD fixtures, as a
# real AUR repo does: aurinstall pin-checks the CLONE, not the fetched copy.
mk_aur_repo() {
    local pkg="$1"
    local d="$AURGIT/$pkg.git"
    rm -rf "$d"; mkdir -p "$d"
    cp "$WORK/srcinfo/$pkg.SRCINFO" "$d/.SRCINFO"
    cp "$WORK/pkgbuild/$pkg.PKGBUILD" "$d/PKGBUILD"
    ( cd "$d" && git init -q . && git add PKGBUILD .SRCINFO \
      && git -c user.email=t@t -c user.name=t commit -q -m init ) >/dev/null 2>&1
}
export AUR_GIT_BASE="file://$AURGIT"

# 19. the pin-check gate still runs, and nothing reaches chrootbuild
: > "$WORK_CB_LOG"
aurinstall --chroot bare >/dev/null 2>&1; rc=$?
if (( rc == 1 )) && [[ ! -s "$WORK_CB_LOG" ]]; then
    pass "--chroot still refuses an unpinned source before reaching chrootbuild"
else
    fail "--chroot bypassed the pin-check gate (rc=$rc)"
fi

# 20. a dependency that is in no repo and not in the AUR is refused up front,
# by the gate, before a chroot build or a yay run is spent on it — it cannot
# be checked, and an unchecked package is never a pass
srcinfo needsaur "https://example.invalid/x.tar.gz"
printf '\tdepends = totally-not-a-real-package-xyz\n' >> "$WORK/srcinfo/needsaur.SRCINFO"
rpc needsaur 1
mk_aur_repo needsaur
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
out=$(aurinstall --chroot needsaur 2>&1); rc=$?
if (( rc == 1 )) && grep -q 'totally-not-a-real-package-xyz (a dependency of needsaur)' <<<"$out" \
   && [[ ! -s "$WORK_CB_LOG" && ! -s "$WORK_YAY_LOG" ]]; then
    pass "an uncheckable dependency is refused by the gate before any build"
else
    fail "uncheckable dependency was not refused up front (rc=$rc): $out"
fi

# 21. a clean package reaches chrootbuild WITH an explicit branch
srcinfo cleanpkg "https://example.invalid/clean.tar.gz"
rpc cleanpkg 1
mk_aur_repo cleanpkg
: > "$WORK_CB_LOG"
aurinstall --chroot --no-install cleanpkg </dev/null >/dev/null 2>&1
if grep -q -- '-b stable' "$WORK_CB_LOG"; then
    pass "--chroot passes an explicit branch, never chrootbuild's 'unstable' default"
else
    fail "chrootbuild was invoked without an explicit branch: $(cat "$WORK_CB_LOG")"
fi

# 22. ...and the package name is what got built
if grep -q -- '-p cleanpkg' "$WORK_CB_LOG"; then
    pass "--chroot builds the requested package"
else
    fail "wrong package passed to chrootbuild: $(cat "$WORK_CB_LOG")"
fi

# --- the gate, in auto mode -------------------------------------------------
# 23. an eligible package goes to the chroot with no flag at all
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
aurinstall --no-install cleanpkg </dev/null >/dev/null 2>&1
if grep -q -- '-p cleanpkg' "$WORK_CB_LOG" && ! grep -q -- '-S ' "$WORK_YAY_LOG"; then
    pass "auto mode uses the chroot for an eligible package, with no flag"
else
    fail "auto mode did not choose the chroot (cb='$(cat "$WORK_CB_LOG")')"
fi

# 24. a chain the chroot will not build (here: deeper than AURINSTALL_MAX_CHAIN)
# falls back to yay, and SAYS SO
srcinfo helperdep "https://example.invalid/hd.tar.gz"
rpc helperdep 1; mk_aur_repo helperdep
srcinfo needsaur2 "https://example.invalid/x.tar.gz"
printf '\tdepends = helperdep\n' >> "$WORK/srcinfo/needsaur2.SRCINFO"
rpc needsaur2 1; mk_aur_repo needsaur2
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
out=$(AURINSTALL_MAX_CHAIN=1 aurinstall needsaur2 </dev/null 2>&1)
if grep -q -- '-S needsaur2' "$WORK_YAY_LOG" && [[ ! -s "$WORK_CB_LOG" ]] \
   && grep -q 'using yay: cannot chain-build' <<<"$out"; then
    pass "auto mode falls back to yay on a chain it will not build, reporting why"
else
    fail "auto fallback wrong (yay='$(cat "$WORK_YAY_LOG")', said: $(grep -c 'using yay' <<<"$out"))"
fi

# 25. a -bin package is not worth a chroot; nothing is compiled
srcinfo thing-bin "https://example.invalid/x.tar.gz"
rpc thing-bin 1; mk_aur_repo thing-bin
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
out=$(aurinstall thing-bin </dev/null 2>&1)
if grep -q -- '-S thing-bin' "$WORK_YAY_LOG" && [[ ! -s "$WORK_CB_LOG" ]] \
   && grep -q 'nothing is compiled' <<<"$out"; then
    pass "auto mode sends a -bin package to yay, saying nothing is compiled"
else
    fail "-bin package was not routed to yay"
fi

# 26. --chroot on an ineligible package is an ERROR, never a silent fallback
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
out=$(AURINSTALL_MAX_CHAIN=1 aurinstall --chroot needsaur2 </dev/null 2>&1); rc=$?
if (( rc == 2 )) && grep -q 'cannot be used here' <<<"$out" \
   && [[ ! -s "$WORK_YAY_LOG" ]]; then
    pass "--chroot refuses an ineligible package instead of quietly using yay"
else
    fail "forced --chroot fell back silently (rc=$rc)"
fi

# 27. --no-chroot forces yay even when the chroot would have worked
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
aurinstall --no-chroot cleanpkg </dev/null >/dev/null 2>&1
if grep -q -- '-S cleanpkg' "$WORK_YAY_LOG" && [[ ! -s "$WORK_CB_LOG" ]]; then
    pass "--no-chroot forces yay even for a chroot-eligible package"
else
    fail "--no-chroot did not force yay"
fi

# --- dependency chains (28-30) -----------------------------------------------
# target -> dep1 -> dep2, none in any repo. The resolver must emit deps first
# and hand chrootbuild ONE invocation: -p dep2 -n -p dep1 -n -p target.
srcinfo chdep2  "https://example.invalid/d2.tar.gz"
srcinfo chdep1  "https://example.invalid/d1.tar.gz"
printf '\tdepends = chdep2\n' >> "$WORK/srcinfo/chdep1.SRCINFO"
srcinfo chtarget "https://example.invalid/t.tar.gz"
printf '\tdepends = chdep1\n' >> "$WORK/srcinfo/chtarget.SRCINFO"
for pkg in chdep2 chdep1 chtarget; do rpc "$pkg" 1; mk_aur_repo "$pkg"; done

# 28. build order computed and chained with -n, in one invocation
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
out=$(aurinstall --no-install chtarget </dev/null 2>&1)
if grep -q -- '-p chdep2 -n -p chdep1 -n -p chtarget' "$WORK_CB_LOG"; then
    pass "chain built deps-first in one run: -p chdep2 -n -p chdep1 -n -p chtarget"
else
    fail "chain order wrong: $(cat "$WORK_CB_LOG")"
fi

# 29. chained deps get pin-checked like named targets: poison the DEEPEST dep
srcinfo chdep2 "git+https://example.invalid/evil.git"
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
out=$(aurinstall chtarget </dev/null 2>&1); rc=$?
if (( rc == 1 )) && grep -q 'REJECT chdep2' <<<"$out" \
   && [[ ! -s "$WORK_CB_LOG" && ! -s "$WORK_YAY_LOG" ]]; then
    pass "an unpinned CHAINED dependency stops the build — deps are gated too"
else
    fail "poisoned chained dep was not caught (rc=$rc)"
fi
srcinfo chdep2 "https://example.invalid/d2.tar.gz"   # restore

# 30. a dependency cycle is refused with a named reason, not an infinite loop
printf '\tdepends = chtarget\n' >> "$WORK/srcinfo/chdep2.SRCINFO"
: > "$WORK_CB_LOG"; : > "$WORK_YAY_LOG"
out=$(timeout 30 aurinstall chtarget </dev/null 2>&1)
if grep -q 'dependency cycle' <<<"$out" && grep -q -- '-S chtarget' "$WORK_YAY_LOG"; then
    pass "a dependency cycle falls back to yay, naming the cycle"
else
    fail "cycle not handled: $(grep 'using yay' <<<"$out")"
fi

# =============================================================================
echo "== 31-35. the corners of makepkg's VCS syntax =="
# =============================================================================
# `?signed` asks makepkg to verify the commit's signature on top of the pin. It
# follows the fragment, so a pin regex anchored on whitespace-or-end refused the
# one form that is stricter than the policy itself.
srcinfo signedpin "git+https://example.invalid/s.git#commit=$SHA_A?signed"
rpc     signedpin 1
[[ $(check signedpin) == 0 ]] \
    && pass "#commit=<40-hex>?signed accepted (the strongest form is not refused)" \
    || fail "commit pin with ?signed was rejected: $(cat "$WORK/out")"

# .SRCINFO carries arch-specific arrays as `source_x86_64 = ...`. A parser that
# only reads `source =` never sees them — and an unseen source is an accepted one.
{ printf 'pkgbase = archsrc\n\tpkgver = 1.0\n\tpkgrel = 1\n'
  printf '\tsource_x86_64 = git+https://example.invalid/arch.git\n'
  printf '\npkgname = archsrc\n'; } > "$WORK/srcinfo/archsrc.SRCINFO"
pkgbuild archsrc 'source_x86_64=("git+https://example.invalid/arch.git")'
rpc archsrc 1
rc=$(check archsrc)
if [[ $rc == 1 ]] && grep -q 'arch.git' "$WORK/out"; then
    pass "unpinned VCS source under source_x86_64 is rejected (arch arrays are sources too)"
else
    fail "source_x86_64 was not inspected (rc=$rc) — a silent pass"
fi

srcinfo hgpinned "hg+https://example.invalid/h#revision=$SHA_A"
rpc     hgpinned 1
[[ $(check hgpinned) == 0 ]] \
    && pass "hg #revision=<40-hex> accepted (the changeset hash is hg's content-addressed pin)" \
    || fail "hg revision pin rejected: $(cat "$WORK/out")"
srcinfo hgbare "hg+https://example.invalid/h"
rpc     hgbare 1
[[ $(check hgbare) == 1 ]] \
    && pass "bare hg source rejected" \
    || fail "bare hg source accepted"

srcinfo svnpinned "svn+https://example.invalid/svn/trunk#revision=1234"
rpc     svnpinned 1
[[ $(check svnpinned) == 0 ]] \
    && pass "svn #revision=N accepted" \
    || fail "svn revision pin rejected: $(cat "$WORK/out")"
srcinfo svnbare "svn://example.invalid/svn/trunk"
rpc     svnbare 1
[[ $(check svnbare) == 1 ]] \
    && pass "bare svn:// source rejected" \
    || fail "bare svn:// source accepted"

srcinfo fossilbare "fossil+https://example.invalid/f"
rpc     fossilbare 1
[[ $(check fossilbare) == 1 ]] \
    && pass "bare fossil+ source rejected (a VCS makepkg supports is a VCS we check)" \
    || fail "fossil+ source was not recognised as VCS — accepted unpinned"

# =============================================================================
echo "== 36. split packages resolve to their pkgbase =="
# =============================================================================
# cgit serves .SRCINFO per pkgBASE branch. A split package's own name 404s, and
# `aurupdate` would then report an ERROR for it on every run — which, because an
# error blocks the whole set, taught people to bypass the gate with `yay -Sua`.
srcinfo basepkg "git+https://example.invalid/base.git#commit=$SHA_A"
rpc     basepkg 1
rpc     splitpkg 1 basepkg          # no splitpkg.SRCINFO exists — only the RPC knows
[[ $(check splitpkg) == 0 ]] \
    && pass "split package resolved to its pkgbase and judged on the pkgbase's (pinned) sources" \
    || fail "split package not resolved: $(cat "$WORK/out")"
srcinfo basepkg "git+https://example.invalid/base.git"        # now unpin the base
rc=$(check splitpkg)
if [[ $rc == 1 ]] && grep -q 'REJECT splitpkg' "$WORK/out"; then
    pass "split package REJECTED when its pkgbase carries an unpinned source"
else
    fail "unpinned pkgbase behind a split package slipped through (rc=$rc)"
fi
srcinfo basepkg "https://example.invalid/base.tar.gz"          # clean, for aurinstall below

# =============================================================================
echo "== 37-39. aurinstall: split pkgbase, artifact survival, --install =="
# =============================================================================
mk_aur_repo basepkg
: > "$WORK_CB_LOG"
aurinstall --no-install splitpkg </dev/null >/dev/null 2>&1
if grep -q -- '-p basepkg' "$WORK_CB_LOG" && ! grep -q -- '-p splitpkg' "$WORK_CB_LOG"; then
    pass "a split package is built by cloning and building its pkgbase, once"
else
    fail "split package chroot build wrong: $(cat "$WORK_CB_LOG")"
fi

# With PKGDEST unset, chrootbuild leaves the artifact where it was started — a
# temp dir aurinstall removes on exit. The artifact has to be moved somewhere
# durable before that, or "install later with pacman -U <path>" names a file
# that no longer exists by the time the line is printed.
INVOKE="$WORK/invoke"; mkdir -p "$INVOKE"
: > "$WORK_PACMAN_LOG"
out=$(cd "$INVOKE" && aurinstall --no-install cleanpkg </dev/null 2>&1); rc=$?
if (( rc == 0 )) && [[ -f "$INVOKE/cleanpkg-1.0-1-x86_64.pkg.tar.zst" ]] \
   && grep -q "$INVOKE/cleanpkg-1.0-1-x86_64.pkg.tar.zst" <<<"$out"; then
    pass "with PKGDEST unset the built package survives in the invoking directory, and is named"
else
    fail "built package lost or not reported (rc=$rc): $(ls "$INVOKE" 2>/dev/null | tr '\n' ' ') :: $out"
fi
[[ ! -s "$WORK_PACMAN_LOG" ]] \
    && pass "--no-install never reaches pacman -U" \
    || fail "--no-install still installed: $(cat "$WORK_PACMAN_LOG")"

: > "$WORK_PACMAN_LOG"
( cd "$INVOKE" && aurinstall --install cleanpkg </dev/null >/dev/null 2>&1 )
if grep -q -- '-U .*cleanpkg-1.0-1-x86_64.pkg.tar.zst' "$WORK_PACMAN_LOG"; then
    pass "--install runs pacman -U on the built artifact without a prompt"
else
    fail "--install did not install: $(cat "$WORK_PACMAN_LOG")"
fi

# =============================================================================
echo "== 40-41. what the chroot BUILDS is what gets checked =="
# =============================================================================
# 40. chaotic-aur carries AUR names. `yay -S` would install that repo copy, so
# a plain check skips the name — but the chroot builds the AUR's copy anyway.
srcinfo chaoticpkg "git+https://example.invalid/chaotic.git"
rpc chaoticpkg 1; mk_aur_repo chaoticpkg
echo chaoticpkg > "$WORK_REPO_PKGS"
if [[ $(check chaoticpkg) == 0 && $(check --from-aur chaoticpkg) == 1 ]]; then
    pass "a repo-carried name is skipped for yay, and checked with --from-aur"
else
    fail "--from-aur did not check a repo-carried name"
fi
: > "$WORK_CB_LOG"
out=$(aurinstall --no-install chaoticpkg </dev/null 2>&1); rc=$?
if (( rc == 2 )) && grep -q 'REJECT chaoticpkg' <<<"$out" && [[ ! -s "$WORK_CB_LOG" ]]; then
    pass "the chroot refuses to build the AUR copy of a repo-carried name with an unpinned source"
else
    fail "chroot built an unchecked repo-carried name (rc=$rc, cb='$(cat "$WORK_CB_LOG")')"
fi
: > "$WORK_REPO_PKGS"

# 41. a push between the gate and the clone: the AUR said one thing when it
# was checked, and the clone that gets built says another
srcinfo racepkg "https://example.invalid/race.tar.gz"
rpc racepkg 1; mk_aur_repo racepkg
printf 'pkgbase = racepkg\n\tsource = git+https://example.invalid/late.git\n\npkgname = racepkg\n' \
    > "$AURGIT/racepkg.git/.SRCINFO"
printf 'pkgname=racepkg\nsource=("git+https://example.invalid/late.git")\n' > "$AURGIT/racepkg.git/PKGBUILD"
git -C "$AURGIT/racepkg.git" -c user.email=t@t -c user.name=t commit -qam late >/dev/null 2>&1
: > "$WORK_CB_LOG"
out=$(aurinstall --no-install racepkg </dev/null 2>&1); rc=$?
if (( rc == 2 )) && grep -q 'cloned build chain failed' <<<"$out" && [[ ! -s "$WORK_CB_LOG" ]]; then
    pass "a source pushed after the check but before the clone is caught in the clone"
else
    fail "the clone was built unchecked (rc=$rc)"
fi

# =============================================================================
echo "== 42-45. --deps: the AUR dependencies yay would build =="
# =============================================================================
srcinfo yaydep "git+https://example.invalid/yaydep.git"
rpc yaydep 1
srcinfo yaytop "https://example.invalid/yaytop.tar.gz"
printf '\tdepends = yaydep>=1.0\n' >> "$WORK/srcinfo/yaytop.SRCINFO"
rpc yaytop 1

# 42. the yay path: before, only the named package was checked
: > "$WORK_YAY_LOG"
out=$(aurinstall --no-chroot yaytop </dev/null 2>&1); rc=$?
if (( rc == 1 )) && grep -q 'REJECT yaydep' <<<"$out" && [[ ! -s "$WORK_YAY_LOG" ]]; then
    pass "aurinstall --no-chroot refuses an unpinned AUR dependency; yay never runs"
else
    fail "an unpinned AUR dependency reached yay (rc=$rc, yay='$(cat "$WORK_YAY_LOG")')"
fi

# 43. aurupdate: an upgrade can bring in a new AUR dependency
printf 'yaytop 1.0 -> 2.0\n' > "$WORK_YAY_QUA"
: > "$WORK_YAY_LOG"
aurupdate >/dev/null 2>&1; rc=$?
if (( rc == 1 )) && ! grep -q -- '-Sua' "$WORK_YAY_LOG"; then
    pass "aurupdate refuses a pending upgrade whose new AUR dependency is unpinned"
else
    fail "aurupdate let an unpinned AUR dependency through (rc=$rc)"
fi
: > "$WORK_YAY_QUA"

# 44-45. a dependency yay will NOT build is not walked: one an installed
# package meets, and one a binary repo meets. Walking those would refuse
# packages over sources nobody is about to build.
srcinfo yaytop2 "https://example.invalid/yaytop2.tar.gz"
printf '\tdepends = instdep\n\tmakedepends = repodep\n' >> "$WORK/srcinfo/yaytop2.SRCINFO"
rpc yaytop2 1
echo instdep > "$WORK_INSTALLED"; echo repodep > "$WORK_REPO_PKGS"
[[ $(check --deps yaytop2) == 0 ]] \
    && pass "a dependency met by an installed package is not walked" \
    || fail "an installed dependency was walked: $(cat "$WORK/out")"
: > "$WORK_INSTALLED"
echo instdep > "$WORK_REPO_PKGS"; echo repodep >> "$WORK_REPO_PKGS"
[[ $(check --deps yaytop2) == 0 ]] \
    && pass "a dependency met by a binary repo is not walked" \
    || fail "a repo dependency was walked: $(cat "$WORK/out")"
: > "$WORK_REPO_PKGS"

# =============================================================================
echo "== 46. package names containing '+' =="
# =============================================================================
# Sent raw, '+' reaches cgit and the RPC as a space: `aewm++` was a 404 and
# could never pass. Encoded, the file:// fixture resolves exactly as cgit does.
srcinfo 'aewm++' "https://example.invalid/aewm.tar.gz"
rpc 'aewm++' 1
: > "$WORK_CURL_LOG"
rc=$(check 'aewm++')
if [[ $rc == 0 ]] && grep -q 'aewm%2B%2B' "$WORK_CURL_LOG" && ! grep -qF 'aewm++' "$WORK_CURL_LOG"; then
    pass "'aewm++' is requested as aewm%2B%2B, fetched and judged"
else
    fail "a '+' name was sent unencoded (rc=$rc): $(cat "$WORK_CURL_LOG")"
fi

# =============================================================================
echo "== 47-50. the PKGBUILD tripwire =="
# =============================================================================
# 47. the spoof: a .SRCINFO showing a pin, over a PKGBUILD that has none
srcinfo spoofed "git+https://example.invalid/s.git#commit=$SHA_A"
rpc spoofed 1
pkgbuild spoofed 'source=("git+https://example.invalid/evil.git")'
rc=$(check spoofed)
if [[ $rc == 1 ]] && grep -q 'does not match its .SRCINFO' "$WORK/out" && grep -q 'evil.git' "$WORK/out"; then
    pass "a .SRCINFO that hides an unpinned PKGBUILD source is REJECTED"
else
    fail "spoofed .SRCINFO accepted (rc=$rc)"
fi

# 48. a PKGBUILD naming a VCS source under a .SRCINFO that names none
srcinfo spoofed2 "https://example.invalid/s.tar.gz"
rpc spoofed2 1
pkgbuild spoofed2 "source=(\"git+https://example.invalid/x.git#commit=$SHA_A\")"
[[ $(check spoofed2) == 1 ]] \
    && pass "a VCS source missing from .SRCINFO entirely is REJECTED" \
    || fail "a VCS source absent from .SRCINFO was accepted"

# 49. no false alarm on what real PKGBUILDs look like: variables in the pin,
# a VCS-looking string in pkgdesc, a commented-out source, a multi-line array
srcinfo realistic "git+https://example.invalid/r.git#commit=$SHA_A" "https://example.invalid/r.patch"
rpc realistic 1
pkgbuild realistic 'pkgname=realistic
pkgdesc="a git+svn bridge"
_commit=0123456789abcdef0123456789abcdef01234567
# source=(git+https://example.invalid/old.git)
source=("git+$url.git#commit=${_commit}"   # git+https://in.a.comment
        "r.patch::https://example.invalid/r.patch")
build() { echo git+https://not.a.source; }'
[[ $(check realistic) == 0 ]] \
    && pass "variables, pkgdesc, comments and build() do not trip the tripwire" \
    || fail "realistic PKGBUILD falsely rejected: $(cat "$WORK/out")"

# 50. a PKGBUILD that cannot be fetched is an ERROR, never a pass
srcinfo nopkgbuild "https://example.invalid/n.tar.gz"
rpc nopkgbuild 1
rm -f "$WORK/pkgbuild/nopkgbuild.PKGBUILD"
rc=$(check nopkgbuild)
if [[ $rc == 1 ]] && grep -q 'cannot fetch the PKGBUILD' "$WORK/out"; then
    pass "an unfetchable PKGBUILD is an ERROR, never a silent pass"
else
    fail "unfetchable PKGBUILD did not surface as an error (rc=$rc)"
fi

echo ""
echo "==================================================="
echo "  $PASS passed, $FAIL failed"
echo "==================================================="
[ "$FAIL" -eq 0 ]
