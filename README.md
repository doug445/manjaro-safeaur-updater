# Manjaro SafeAUR Updater

[![lint](https://github.com/doug445/manjaro-safeaur-updater/actions/workflows/lint.yml/badge.svg)](https://github.com/doug445/manjaro-safeaur-updater/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell: bash](https://img.shields.io/badge/shell-bash-4EAA25.svg)](#requirements)
[![Tests: 65](https://img.shields.io/badge/tests-65%20passing-brightgreen.svg)](#testing)
[![No runtime deps](https://img.shields.io/badge/runtime%20deps-pacman%20%2B%20coreutils-lightgrey.svg)](#requirements)

**Use the AUR on Manjaro without breaking your system.** A small suite of
`pacman` and `yay` wrappers that closes the three failure modes behind almost
every "Manjaro AUR disaster": the **partial upgrade** caused by Manjaro's
two-week lag behind Arch, the **stale-soname breakage** that hits every AUR
package after Manjaro finally catches up, and the **unpinned VCS source** that
lets an AUR PKGBUILD build something other than what you reviewed.

It is five short bash scripts, no daemon, no runtime dependency beyond pacman
and coreutils, and 65 tests that run real `pacman` transactions on a loop
device.

---

## The problem, in other people's words

This suite exists because of a specific, well-documented property of Manjaro:
its Stable branch trails Arch, while the AUR does not. That gap is the whole
story, and it is worth reading the complaint before the fix.

> "some AUR packages require certain dependencies to run, which they expect to
> install from the official Arch repo. However, on Manjaro, the necessary
> dependency might be running on an older version, which has some compatibility
> issues with the AUR package. […] This can create a fundamental compatibility
> mismatch that can lead to broken installations, missing dependencies, or
> packages that simply refuse to build."
>
> — Dibakar Ghosh, [*3 Reasons I Avoid Manjaro Even Though I Love Arch
> Linux*](https://www.howtogeek.com/why-i-avoid-manjaro-even-though-i-love-arch-linux/),
> How-To Geek, 1 September 2025

Manjaro's own moderators do not dispute the risk. They document it and decline
to fix it:

> "Remember, the AUR is neither officially supported by Arch nor by Manjaro.
> Using it is at your own risk and your own responsibility."
>
> — linux-aarhus, [*Responsible use of
> AUR*](https://forum.manjaro.org/t/responsible-use-of-aur/86392), Manjaro Linux
> Forum, 14 October 2021

> "any CUSTOM package may cease to function without warning OR your system may
> cease to function due to a CUSTOM package"
>
> — linux-aarhus, [*[Need-To-Know] About Manjaro and
> AUR*](https://forum.manjaro.org/t/need-to-know-about-manjaro-and-aur/103617),
> Manjaro Linux Forum, 23 February 2022

That second sentence is an accurate description of the failure mode, and it is
also an accurate description of what this suite exists to detect. Being told
the risk is yours is only useful if you have some way of seeing it.

So: the AUR assumes you are current with Arch. Manjaro's Stable branch
deliberately is not. Nobody supports the gap. **This suite is the gap,
handled.**

---

## What actually goes wrong, and what closes it

Manjaro's lag produces two failures that look unrelated and are really the same
clock running in opposite directions. A third, orthogonal risk comes from the
AUR itself.

| # | Failure | When it bites | What closes it |
|---|---|---|---|
| 1 | **Partial upgrade.** A third-party binary repo (BlackArch, chaotic-aur) rebuilt against Arch's `libfoo 2.0`. Manjaro still ships `1.0`. Installing the new package drags in a dependency Manjaro cannot satisfy. | While Manjaro is behind | `safeup` probes every pending foreign upgrade's version-constrained deps with `pacman -T` and `--ignore`s the ones that cannot be satisfied *yet* |
| 2 | **Stale soname.** Manjaro finally ships `libfoo 2.0`. Every AUR package you built against `1.0` now fails to resolve its `DT_NEEDED` and dies at runtime — often silently, often days later. | When Manjaro catches up | `aur-rebuild-check` walks every AUR-owned ELF with `ldd` and names the packages that need rebuilding |
| 3 | **Unpinned VCS source.** A PKGBUILD's `source=` is `git+https://…` with no commit. What you audited last week is not what builds today. Tags do not help — upstream can move a tag. | Any time you install or upgrade | `aur-pin-check` refuses any VCS source without `#commit=<40-hex>`, and re-verifies allowlisted tags against their recorded SHA on every run |

### How honest is "solves it completely"?

Completely, for the three failures above — that is what the test suite
demonstrates, package by package. Not completely, for Manjaro in general.
Read [What this does not do](#what-this-does-not-do) before you rely on it.

---

## "But this automates `pacman --ignore`"

It does, and that deserves a real answer rather than reassurance. `--ignore` is
listed on the Arch wiki as a way to **cause** partial upgrades, so a tool that
reaches for it automatically is right to be treated with suspicion.

**`--ignore` suppresses an upgrade. It does not suppress dependency
resolution.** pacman still resolves the entire transaction and refuses one that
would leave a dependency unsatisfied. Here is that being tested rather than
asserted — `consumer 1.0` requires `libX=1.0`, both have upgrades pending, and
`libX` is ignored so that `consumer 2.0` would need a `libX 2.0` that will not
be installed:

```console
$ pacman -Syu --noconfirm --ignore libX
warning: ignoring package libX-2.0-1
warning: cannot resolve "libX=2.0", a dependency of "consumer"
error: failed to prepare transaction (could not satisfy dependencies)
:: unable to satisfy dependency 'libX=2.0' required by consumer
                                                            exit 1

$ pacman -Q                       # nothing moved
consumer 1.0-1
libX 1.0-1

$ pacman -Dk                      # pacman's own consistency audit
No database errors have been found!
```

You cannot `--ignore` your way into an unsatisfied dependency. **pacman is the
backstop, not this script** — which is the correct arrangement, because pacman
is the thing that actually knows.

That transcript is section 19 of
[`tests/loopback-core-test.sh`](tests/loopback-core-test.sh) and runs in CI on
every push, against real pacman transactions. It is deliberately a test of
*pacman's* behaviour rather than of this code: the safety argument for the whole
suite rests on that property, nothing here would notice if a future pacman
changed it, and the consequence would be silent. The same section then asserts
that a real `safeup` hold inherits it — `pacman -Dk` still reports a consistent
system afterwards.

Beyond that guarantee, **what** gets held matters:

- It only holds a package whose version-constrained dependency is **already
  unsatisfiable** — one that cannot install correctly at that moment regardless.
- It holds the **new** version back, so the package keeps the dependencies it
  already had and stays in the state it was already working in. The classic
  dangerous pattern is pinning a *library* while upgrading its dependents; this
  is the opposite direction.
- The realistic alternative is not a clean full upgrade. It is a refused
  transaction, or a person reaching for `--ignore` by hand with worse aim.
- Every hold is printed and written to `/var/log/safeup.log`. A silent
  indefinite pin is the real long-term hazard, so a hold is made into a
  *deferred* upgrade you can chase rather than a package that quietly stops
  updating.

**The limitation, stated plainly:** `safeup` does not pre-check whether a
package it holds is itself required by something else in the same transaction.
It relies on pacman refusing, and then isolates the break. The transcript above
is why that is acceptable — but it works that way because pacman is sound, not
because this script is clever, and you should know which of those you are
trusting.

---

## Quick start

```bash
git clone https://github.com/doug445/manjaro-safeaur-updater.git
cd manjaro-safeaur-updater
./deploy.sh
```

`deploy.sh` installs any missing dependency (asking first), copies the five
tools into `/usr/local/bin`, installs the logrotate rule and the monthly
drift-audit timer, and stops. It is idempotent: a file that already matches is
not rewritten, and anything it does replace is backed up to
`<path>.bak-YYYYmmdd-HHMMSS` first.

Then use it:

```bash
safeup                 # pacman -Syu, with the partial-upgrade guard
aurinstall <pkg>       # yay -S, with the pin-check gate
aurupdate              # yay -Sua, with the pin-check gate
aur-rebuild-check      # what needs rebuilding after a library bump
```

Suggested aliases, which `deploy.sh` deliberately does **not** write for you:

```bash
alias pupdate='safeup'
alias yinstall='aurinstall'
alias yupdate='safeup ; aurupdate'
```

---

## The tools

| Tool | Wraps | What it adds |
|---|---|---|
| **`safeup`** | `pacman -Syu` | Auto-detects foreign repos from `pacman.conf` (anything outside `core`/`extra`/`multilib`/`community` and their `-testing` variants). Holds any pending foreign upgrade whose version-constrained dependency fails `pacman -T`. Recovers from `installing X breaks dependency … required by Y` by holding `X` and retrying, so one ABI break does not block the whole upgrade. Chains into `aur-rebuild-check` on success. Logs every hold to `/var/log/safeup.log`. |
| **`aur-rebuild-check`** | — | `ldd`s every ELF owned by every `pacman -Qmq` package and reports `=> not found`. Filters the two false positives that otherwise flag `-bin` packages forever: privately bundled libraries resolved through an `$ORIGIN` RPATH, and optional sonames named in `AUR_REBUILD_IGNORE_SONAMES`. `--fix` offers `yay -S --rebuild`. |
| **`aur-pin-check`** | — | Fetches `.SRCINFO` from AUR cgit and rejects any `git`/`hg`/`svn`/`bzr` source without `#commit=<40-hex>`. `#tag=` and `#branch=` are rejected on principle. Tarballs pass — `sha256sums` already cover them. Has a TOFU allowlist for tag-pinned upstreams. On rejection it tells you whether the package was deleted from the AUR, or is an installed orphan you should simply remove. |
| **`aurinstall`** | `yay -S` | Runs the pin-check gate first; refuses to exec `yay` if it fails. Then builds in Manjaro's own `chrootbuild` when that will work, falling back to `yay` with a stated reason when it will not — see [Building in a chroot](#building-in-a-chroot). |
| **`aurupdate`** | `yay -Sua` | Pin-checks every package with a pending AUR upgrade before any of them build. |
| **`remove-versioned-kernel`** | `pacman -Rns` | Evicts `linuxNN`, `linuxNN-headers` and `linuxNN-nvidia` in one transaction and rewrites `IgnorePkg` to name only the survivors. Refuses to remove the running kernel or the last one you have. |

### Building in a chroot

`aurinstall --chroot` hands the actual build to
[`chrootbuild`](https://gitlab.manjaro.org/tools/development-tools/manjaro-chrootbuild),
from Manjaro's own `manjaro-chrootbuild` package. The suggestion came from
linux-aarhus of the Manjaro team, and the two tools answer different questions:

| | Question it answers |
|---|---|
| `aur-pin-check` | **Which source** am I building? |
| `chrootbuild` | **Against which libraries**, and where? |

The second one matters specifically because of the lag. An AUR PKGBUILD assumes
current Arch; building it against your own installed libraries is what produces
a package linked to a soname Manjaro Stable does not have. `chrootbuild` builds
inside a chroot synced to a chosen Manjaro branch, so the result links against
the libraries you actually run — a **build-time** fix for the breakage
`aur-rebuild-check` can only report after the fact. Build dependencies land in
the chroot and never touch your system.

```bash
aurinstall <pkg>              # auto: chroot when it will work, else yay
aurinstall --chroot <pkg>     # force the chroot; refuse rather than fall back
aurinstall --no-chroot <pkg>  # force plain yay
aurinstall --chroot --clean <pkg>   # recreate the chroot from scratch first
```

**The chroot is the default when it will work.** A gate checks three things
first, and falls back to `yay` — always saying which one tripped — rather than
failing:

- `manjaro-chrootbuild` is not installed.
- The dependency chain cannot be resolved — a member is missing from the AUR
  (a dead source: no build order fixes that), there is a cycle, or the chain is
  deeper than `AURINSTALL_MAX_CHAIN` (10). **Resolvable chains are built**, deps
  first, as one `chrootbuild` run chained with `-n`
  (`-p dep2 -n -p dep1 -n -p target`), and every chained dependency is
  pin-checked exactly like a named target — an unvetted dep is the same
  supply-chain hole as an unvetted target. The `-n` form is due to
  linux-aarhus, whose flightgear experiments also supplied the failure case
  the resolver refuses on.
- The package is a `*-bin`. Nothing is compiled, so a chroot cannot change what
  gets installed. It *would* still isolate the PKGBUILD's own execution — a
  real if smaller benefit — so `--chroot` forces it anyway if you want that.

On a survey of one real system's 49 AUR packages, 42 were chroot-eligible, 7
had AUR dependencies and 1 was a `-bin`. The fallback is never silent: a tool
that quietly does something other than what you assumed is the failure mode
this whole suite exists to prevent. `--chroot` makes it an error instead, and
`AURINSTALL_MODE=auto|chroot|yay` sets the default.

The wrapper also files down two sharp edges:

- **`chrootbuild`'s default branch is `unstable`.** Passing the wrong branch
  still exits 0 and silently produces exactly the mismatch you were avoiding.
  `aurinstall` always passes an explicit `-b`, detected from
  `pacman-mirrors --get-branch` (override with `AURINSTALL_BRANCH`).
- **`chrootbuild` has no AUR dependency resolution.** A package whose
  dependencies are themselves in the AUR fails partway through, after the chroot
  work. `aurinstall` reads `.SRCINFO` first and refuses up front, naming them.

Installing is a separate, explicit step: the build is the part that had to
happen in isolation, and putting the result on your system stays your decision.

`manjaro-chrootbuild` lives in Manjaro's `extra` and `deploy.sh` installs it
along with everything else. If it is missing, the gate says so and falls back to
`yay` rather than failing.

### Why `.SRCINFO` and not `PKGBUILD`

`aur-pin-check` reads `.SRCINFO`, which is the post-evaluation, static form of a
PKGBUILD. Parsing it means vetting an untrusted package name never executes that
package's code. A pin-checker that sourced the `PKGBUILD` to read `source=`
would be running the thing it was asked to decide about.

### Why `#tag=` is rejected

A tag is a mutable pointer. Upstream can move it, or a compromised or careless
maintainer can move it silently. If you genuinely need a tag-pinned package,
the allowlist records the SHA that tag pointed at **when you vetted it**, and
`aur-pin-check` re-resolves the tag with `git ls-remote` on every run. The day
it stops matching, the package is refused. Trust on first use, verified
forever after — never blanket trust.

```
# /etc/aur-pin-check/allowlist.conf
# <pkg>  <exact source spec from .SRCINFO>  <expected 40-hex SHA>
byobu  git+https://github.com/dustinkirkland/byobu#tag=7.17  cd6dfa0e4918573e03d9881c7750640693c2d15f
```

---

## What this does not do

Stating this plainly is the point of the section. This suite is narrow on
purpose, and a tool that oversells itself is worse than no tool.

- **It does not make Manjaro track Arch.** The lag is Manjaro's design choice.
  This handles the consequences; it does not remove the cause. If you want
  Arch's timing, you must run Arch.
- **It does not audit what a PKGBUILD *does*.** Pinning proves you will build
  the same commit you reviewed. It says nothing about whether that commit is
  malicious. Read the PKGBUILD.
- **It does not sandbox builds by default.** `makepkg` runs upstream's build
  system on your machine with your user's privileges. `aurinstall --chroot`
  moves the build into an isolated chroot (see below), which is a real
  improvement in blast radius and in *which libraries you link against* — but a
  chroot is build isolation, not a security boundary, and it does not make a
  hostile PKGBUILD safe.
- **It cannot fix a package that genuinely needs a newer library.** Holding it
  is the correct outcome, not a workaround — you wait for Manjaro, or you
  rebuild from source, or you get it from somewhere else.
- **It does not replace backups or snapshots.** A held package is a deferred
  upgrade, not a rollback.
- **A package deleted from the AUR still serves its old git repo through cgit,
  indefinitely.** `aur-pin-check` warns you when a rejected package is no longer
  in the AUR index, because in that case the "just override it" advice is
  actively dangerous — the PKGBUILD you are about to trust may be years stale.

---

## Requirements

**Manjaro.** This is scoped to Manjaro deliberately: the problem it solves is
created by Manjaro's Stable branch trailing Arch, and `aurinstall --chroot`
wraps `manjaro-chrootbuild`, which is Manjaro's own tool. On Arch itself there
is no lag to guard against.

Runtime dependencies are `pacman`, `curl`, `git`, `awk`, `coreutils` and
`glibc`'s `ldd` — all of which you already have — plus `logrotate` for the log
rotation, `libnotify` for the drift-audit notification, `yay` for `aurinstall`
and `aurupdate`, and **`manjaro-chrootbuild`**, which `aurinstall` uses to build
by default.

`deploy.sh` installs whatever is missing, after asking. `manjaro-chrootbuild` is
24 KiB with no dependencies of its own — the ~1.1 GiB chroot it manages is
created lazily under `/var/lib/chrootbuild` on your first build, not at install
time.

Everything is bash. There is no language runtime to install, which is
deliberate: a tool that repairs a broken package manager cannot depend on
packages installed by that package manager.

---

## Testing

Two suites, 65 assertions, both run in CI on every push.

```bash
bash tests/pin-fixture-test.sh          # 34 assertions — no root, no disk, no network
sudo bash tests/loopback-core-test.sh   # 31 assertions — root; touches no real disk
shellcheck -S warning $(git ls-files '*.sh') bin/*
```

**`tests/loopback-core-test.sh`** builds a 512 MB file-backed loop device,
formats it ext4, and constructs a complete throwaway `pacman` root inside it:
private `RootDir`/`DBPath`/`CacheDir`, private `file://` repositories built with
the real `repo-add`, and real `.pkg.tar.gz` packages. It then drives the real
`pacman` through the actual scenarios — a foreign package with an unsatisfiable
`libfoo>=2.0`, an `installing X breaks dependency … required by Y` transaction,
an unrecoverable failure — and asserts on installed versions afterwards. The
`aur-rebuild-check` cases build genuine shared objects with `cc` that carry a
genuine unresolvable `DT_NEEDED`, so no `ldd` output is faked.

**No real disk and no real package database is touched.** The only thing on
`PATH` is a wrapper that adds `--config <throwaway config>`; dependency
resolution, ABI-break detection and file ownership are all done by the genuine
pacman.

**`tests/pin-fixture-test.sh`** exercises the pinning policy against synthetic
`.SRCINFO` fixtures and the allowlist against **real local git repositories** —
including moving a tag and asserting that the next run refuses the package.

A check that cannot run in a given environment is reported as `SKIP` and is
never counted as a pass. A silent pass is the one outcome these suites exist to
prevent.

---

## Source-of-record layout

```
manjaro-safeaur-updater/
├── bin/                              → /usr/local/bin/ (root:root 0755)
│   ├── safeup                        pacman -Syu with the partial-upgrade guard
│   ├── aur-rebuild-check             post-upgrade soname scan
│   ├── aur-pin-check                 VCS source pinning policy
│   ├── aurinstall                    yay -S + gate
│   ├── aurupdate                     yay -Sua + gate
│   └── remove-versioned-kernel       kernel eviction with guards
├── etc/
│   ├── logrotate.d/safeup            → /etc/logrotate.d/safeup
│   └── aur-pin-check/allowlist.conf  → /etc/aur-pin-check/ (never overwritten)
├── config/yay/config.json            → ~/.config/yay/config.json
├── systemd/user/                     → ~/.config/systemd/user/ (monthly drift audit)
├── tests/                            the two suites above
├── audit-drift.sh                    run in place — never deployed
└── deploy.sh                         idempotent installer
```

`audit-drift.sh` checksums each source file against its deployed copy and
notifies if they diverge, catching the case where someone edits
`/usr/local/bin/safeup` directly and the change is later lost to a redeploy. The
allowlist is deliberately excluded from that audit: it holds *your* vetting
decisions and is supposed to diverge.

---

## Disclaimers

**Not for beginners.** Everything here wraps `pacman` or `yay` and assumes you
can read a PKGBUILD, know what a partial upgrade is, and can recover your own
system if something goes wrong.

**Not affiliated with Manjaro.** This is a personal project. Nothing about it
is endorsed by, or represents, the Manjaro team — it uses Manjaro's own
`manjaro-chrootbuild` as one of its tools, and that is the extent of the
relationship. It does not make the AUR supported, by anyone.

**AI disclosure.** Substantial parts of this code were written with an AI
assistant (Anthropic's Claude), used as a tool under the author's direction:
every line is reviewed and tested, and responsibility for all of it is the
author's. That involvement is recorded openly in the commit history
(`Co-Authored-By` trailers). The CI suite — real pacman transactions against
throwaway loop devices — exists precisely so that correctness never rests on
anyone's word, the author's or a model's.

## Contributing

Serious bugs only — see [CONTRIBUTING.md](CONTRIBUTING.md). Security issues go
to the address in [SECURITY.md](SECURITY.md), not to the issue tracker.

## License

MIT — see [LICENSE](LICENSE).
