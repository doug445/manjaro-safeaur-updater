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
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$WORK/srcinfo" "$WORK/rpc" "$WORK/shim" "$WORK/git"

# --- the environment every invocation below runs under -----------------------
# Endpoints point at local files; the allowlist points at a fixture we rewrite
# between cases. PATH is prefixed with stubs so nothing reaches the real system.
export AUR_SRCINFO_URL="file://$WORK/srcinfo/%s.SRCINFO"
export AUR_RPC_URL="file://$WORK/rpc/%s.json"
export AUR_PIN_ALLOWLIST="$WORK/allowlist.conf"
export PATH="$WORK/shim:$BIN:$PATH"
: > "$WORK/allowlist.conf"

# pacman stub. aur-pin-check asks two questions of it and nothing else:
#   -Si <pkg>  → is this package in a binary repo? (then it is not our problem)
#   -Qq / -Qdtq → is it installed, and is it an orphan? (triage hints only)
# $WORK/repo-pkgs and $WORK/orphan-pkgs drive the answers.
cat > "$WORK/shim/pacman" <<'SHIM'
#!/bin/bash
case "$1" in
  -Si)   grep -qxF -- "$2" "$WORK_REPO_PKGS" 2>/dev/null && { echo "Repository : extra"; exit 0; }; exit 1 ;;
  -Qq)   grep -qxF -- "$2" "$WORK_INSTALLED" 2>/dev/null && { echo "$2"; exit 0; }; exit 1 ;;
  -Qdtq) cat "$WORK_ORPHANS" 2>/dev/null; exit 0 ;;
  *)     exit 1 ;;
esac
SHIM
chmod +x "$WORK/shim/pacman"
export WORK_REPO_PKGS="$WORK/repo-pkgs" WORK_INSTALLED="$WORK/installed" WORK_ORPHANS="$WORK/orphans"
: > "$WORK_REPO_PKGS"; : > "$WORK_INSTALLED"; : > "$WORK_ORPHANS"

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

# Write a .SRCINFO fixture: srcinfo <pkg> <source-line>...
srcinfo() {
    local pkg="$1"; shift
    { printf 'pkgbase = %s\n\tpkgver = 1.0\n\tpkgrel = 1\n' "$pkg"
      for s in "$@"; do printf '\tsource = %s\n' "$s"; done
      printf '\npkgname = %s\n' "$pkg"
    } > "$WORK/srcinfo/$pkg.SRCINFO"
}

# Write an AUR RPC fixture: rpc <pkg> <resultcount>
rpc() { printf '{"resultcount":%s,"results":[]}' "$2" > "$WORK/rpc/$1.json"; }

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
aurinstall pinned >/dev/null 2>&1
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

echo ""
echo "==================================================="
echo "  $PASS passed, $FAIL failed"
echo "==================================================="
[ "$FAIL" -eq 0 ]
