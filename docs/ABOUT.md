# About the Manjaro SafeAUR Updater

## What it is

Five bash scripts that sit between you and `pacman`/`yay`, and refuse the three
operations that break Manjaro systems.

That is the whole product. There is no daemon, no database, no configuration
file you have to understand, and no runtime dependency beyond the package
manager it is protecting. You keep typing the same commands; they just stop at
the point where the old ones would have wrecked something.

## Why it exists

The AUR is written for Arch. Manjaro is not Arch — deliberately, and by about
two weeks. Nobody owns the space in between.

That sentence is the entire design rationale, so it is worth being precise
about what "two weeks" costs you. Three separate things go wrong, at three
different moments, and most people never connect them:

**While Manjaro is behind.** A third-party binary repository — BlackArch,
chaotic-aur — rebuilds against whatever Arch shipped this morning. Its packages
now declare dependencies Manjaro will not have for a fortnight. Install one and
`pacman` either refuses the whole transaction or, worse, satisfies it with a
mismatched library. This is the classic partial upgrade, and it is the single
most common way a Manjaro system ends up in an unbootable or half-working state.

**When Manjaro catches up.** The lag ends; `libfoo` goes from 1.0 to 2.0. Every
AUR package you built against 1.0 still exists, still shows as installed, and
now cannot resolve its `DT_NEEDED`. Some fail immediately. Some fail the next
time you use a particular feature. Some fail in three weeks, by which time you
have entirely forgotten there was an upgrade. `pacman` will never tell you,
because from `pacman`'s point of view nothing is wrong: the package is
installed, its files are present, its checksums match.

**Independently of both.** An AUR PKGBUILD can point `source=` at a git
repository with no commit fragment. Whatever `HEAD` happens to be when
`makepkg` runs is what you compile and install as root. A `#tag=` is no better
— upstream can move a tag, and a maintainer whose account has been taken over
certainly will.

The first two are Manjaro's release model leaking. The third is the AUR's trust
model leaking. All three are avoidable with mechanical checks, and none of them
are checked by anything you have installed today.

## The position it takes

**A held package is a success, not a failure.** When `safeup` declines to
upgrade something because its dependency is not satisfiable yet, that is the
tool working. It logs it, tells you why, and moves on with the rest of the
upgrade. The alternative — forcing it through — is precisely the mechanism that
produces the disasters.

**A skipped check is never a passed check.** Every gate here either succeeds,
fails, or reports that it could not run. Nothing is silently counted as fine
because it could not be evaluated. This invariant is enforced by the test suite
as strictly as the checks themselves, because a security tool that reports green
when it did not actually look is worse than having no tool at all — you would
at least have been careful.

**Overrides stay possible, and stay conscious.** `aurinstall` refuses; `yay -S`
still works, and the refusal message says so. A gate that cannot be bypassed
gets uninstalled the first time it is inconvenient. The goal is to make the
bypass a decision you make, not a default you never noticed.

**It does not pretend to be more than it is.** Pinning a source proves you will
build the commit you reviewed. It makes no claim about whether that commit is
safe, and the README says so in a section devoted to what the suite does not do.
The three failure modes above are closed completely. Manjaro, in general, is not
"fixed" — the lag is a design decision, and this handles its consequences.

## How it is tested

Both suites run on every push, and neither mocks the thing under test.

The loopback suite builds a 512 MB file-backed loop device, formats it, and
constructs a complete throwaway `pacman` root inside it — private database,
private `file://` repositories built with the real `repo-add`, real
`.pkg.tar.gz` packages. It then drives the genuine `pacman` through the genuine
scenarios and asserts on installed versions afterwards. Dependency resolution,
ABI-break detection and transaction ordering are done by pacman, not by a stub.
The `aur-rebuild-check` cases compile real shared objects with a real
unresolvable `DT_NEEDED`, so no `ldd` output is faked either.

The fixture suite proves the allowlist's trust-on-first-use property by
creating a real git repository, vetting a tag, **moving that tag**, and
asserting that the next run refuses the package.

Writing these found two real bugs in code that had been running on the author's
machine for months: a retry path that silently required a terminal — hanging any
cron or CI invocation — and a `--noconfirm` flag that suppressed the script's own
prompt but not `pacman`'s, so the "unattended" path blocked forever. Both are
fixed, and both now have assertions.

## Who it is for

Anyone running Manjaro — or EndeavourOS, Garuda, Mabox, or any Arch derivative
that trails upstream — who uses the AUR and would like to keep using it. It is
most valuable if you also have BlackArch or chaotic-aur enabled, because those
track Arch directly and therefore feel the lag hardest.

It is not for you if you run Arch itself. Nothing here would hurt, but the
partial-upgrade guard has no lag to guard against, and Arch already gives you
the timing the AUR assumes.

## Relationship to the author's other projects

Same family of problem as [LinuxLocker](https://github.com/doug445/LinuxLocker):
an Arch-adjacent system doing something dangerous by default, closed with plain
bash, a hard invariant that a check which did not run is never reported as
passed, and a test suite that exercises the real tools against throwaway devices
rather than mocking them.
