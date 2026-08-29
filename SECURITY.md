# Security Policy

**Manjaro SafeAUR Updater 1.1.0**

## Supported Versions

This project is maintained by one person and carries no backport branches.
Fixes land on `main` and go out in the next tagged release. Only the newest
release is supported; there is no long-term-support line and older tags do not
receive patches.

| Version | Supported |
| ------- | --------- |
| `main` | :white_check_mark: fixes land here first |
| Newest tagged release | :white_check_mark: |
| Any earlier tag | :x: upgrade to the newest release |

The [releases page](https://github.com/doug445/manjaro-safeaur-updater/releases) lists
every tag, newest first, and each release's notes record what changed in it.
This project keeps that history in the release notes rather than in a
`CHANGELOG.md`.

If you are running a checkout you pulled weeks ago, `git pull` and retry before
reporting — the issue may already be fixed. Include what you are running:

```bash
git -C /path/to/manjaro-safeaur-updater describe --tags --always --dirty
```

A `-dirty` suffix means the working tree has local modifications, and a hash
with no tag means the checkout is somewhere between releases. Say so in the
report either way — it changes what I can reproduce.

Say which distribution you are on and which third-party repositories you have
enabled (`pacman-conf --repo-list`). This tooling keys its behaviour off what is
in `pacman.conf`, not off a distro name, so "Manjaro with BlackArch" and
"EndeavourOS with chaotic-aur" are different paths through the same script.

## Reporting a Vulnerability

I take the security of this project seriously. If you discover a security
vulnerability, please do not open a public issue.

Instead, please report it privately by emailing the report to: spilled-bowline0j@icloud.com

**What to expect:**
* **Acknowledgment:** You will receive an initial response to your report within 72 hours.
* **Updates:** I will keep you informed of my progress as I investigate the issue and develop a fix.
* **Resolution:** If the vulnerability is accepted, I will address it promptly in a new release and notify you. If declined, I will provide a clear explanation of my reasoning.

Please include as much detail as possible in your email, including steps to
reproduce.

## What is in scope

This tooling decides **what gets installed on your machine and from where**. It
runs `pacman` under `sudo`, writes to `/etc/pacman.conf`, and gates an AUR
helper that will execute arbitrary upstream build scripts if it is allowed to.
A bug here does not degrade a feature — it installs something you did not agree
to install. That is the interesting surface:

* **A gate that passes when it should fail.** `aur-pin-check` is the only thing
  standing between `aurinstall`/`aurupdate` and an unpinned VCS source. Any
  `source=` line that reaches `yay` without either a `#commit=<40-hex>` fragment
  or a *currently verifying* allowlist row is a vulnerability, not a parsing
  quirk. **A skipped check counted as a pass is the same bug**: a package that
  could not be fetched, parsed or resolved must be reported as an error and must
  never exit 0.
* **The allowlist failing to notice a moved tag.** The allowlist's entire value
  is that it re-resolves each vetted tag with `git ls-remote` on every run and
  refuses the package the moment the SHA stops matching. A tag that has moved
  and is still accepted — because the resolution silently failed, because the
  comparison was case- or whitespace-sensitive in the wrong direction, or
  because an empty result was treated as agreement — is the exact failure this
  design exists to prevent.
* **Allowlist row matching too broadly.** A row is scoped to one package and one
  exact source spec. A row that launders a *different* source in the same
  package, or the same source in a different package, is a finding.
* **Executing what it was asked to inspect.** `aur-pin-check` deliberately reads
  `.SRCINFO` — the post-evaluation static form — precisely so that vetting an
  untrusted package name never runs that package's code. Any change that
  sources, evals, or otherwise executes PKGBUILD content, or that lets
  `.SRCINFO` content reach a shell as code, is in scope. Package names come
  from the command line and from `yay -Qua`; `.SRCINFO` bodies come from the
  network. Neither is trusted input.
* **Argument injection into pacman or yay.** Package names flow into `pacman
  -Si`, `pacman -T`, `--ignore` lists and `yay -S`. A crafted name that becomes
  an *option* rather than an operand — anything that could turn into
  `--noconfirm`, `--overwrite`, `-U`, a second `--config`, or a path — is a
  vulnerability.
* **`safeup`'s auto-hold selecting the wrong packages.** The recovery path
  parses pacman's own output with a regular expression and feeds the result into
  `--ignore`. A pattern that over-matches silently holds back packages you
  needed — including security updates, which is the serious case — and one that
  under-matches strands the upgrade. Both are in scope. So is anything that
  causes the retry loop to report success on a transaction that did not happen.
* **A hold that is not reported.** Every held or auto-skipped package must reach
  both the terminal and `/var/log/safeup.log`. A package held silently is a
  package you will still be running, unpatched, in six months without knowing.
* **`ldd` on attacker-supplied binaries.** `aur-rebuild-check` runs `ldd` over
  every file owned by every foreign package. `ldd` is not unconditionally safe
  on a hostile ELF — on some platforms and for some malformed objects it can
  result in the binary's own interpreter being executed. Anything that widens
  what gets passed to `ldd`, or that runs it as a more privileged user than
  necessary, is worth reporting. `aur-rebuild-check` needs no privileges and
  should never be run as root.
* **`remove-versioned-kernel` removing the wrong thing.** Its three guards — the
  name must match `linuxNN`, it must not be the running kernel, and it must not
  be the last versioned kernel installed — each prevent an unbootable machine.
  Any of them failing to fire on a system that meets its condition is a serious
  bug. `--noconfirm` suppresses the *prompt* only; a change that lets it
  suppress a guard is a vulnerability.
* **The `IgnorePkg` rewrite.** It replaces a line in `/etc/pacman.conf` by line
  number after taking a timestamped backup. Writing outside that line, dropping
  the nvidia userspace entries that must stay held in lockstep, corrupting the
  file, or leaving `pacman.conf` in a state where a subsequent upgrade does
  something unintended, is in scope.
* **`deploy.sh` writing to the wrong place, or trusting the wrong thing.** It
  installs root-owned executables into `/usr/local/bin` and runs `pacman -S`
  under `sudo`. A path that can be influenced from outside the checkout, a
  backup that clobbers the previous backup (so the pre-change state is
  unrecoverable), or an installed file left group- or world-writable, is a
  finding. So is the AUR bootstrap path fetching `yay-bin` without showing the
  PKGBUILD, or building it as root.
* **Anything world-writable, or any secret in a log.** `/var/log/safeup.log` is
  `0644` by design and holds package names only. Anything else appearing in it
  is a finding.
* **A test suite that touches a real system.** `tests/loopback-core-test.sh`
  must confine every write to its own loop device and temporary directory, and
  must never modify the host's package database, `/etc`, or any real disk.
  `tests/pin-fixture-test.sh` must touch no disk beyond `$TMPDIR` and must make
  no network request.

## What is out of scope

* **Malicious content in a PKGBUILD that is correctly pinned.** Pinning proves
  you will build the same commit you reviewed. It is not a claim that the commit
  is safe. Reviewing the PKGBUILD is still your job, and the README says so.
* **`makepkg` not being sandboxed.** Builds run upstream's build system as your
  user. That is how the AUR works; this suite gates *which* commit gets built,
  not what building it is permitted to do.
* **Bugs in the software this drives** — `pacman`, `yay`, `makepkg`,
  `libalpm`, `git`, `curl`, `ldd`. Report those upstream.
* **Manjaro's release lag itself.** The two-week delay behind Arch is Manjaro's
  design decision. This tooling handles its consequences; the decision is not a
  vulnerability in this tooling.
* **A held package staying held.** That is the guard working. If Manjaro never
  ships the dependency, the package stays held forever, and the answer is to
  stop using that package or stop using Manjaro — not to weaken the check.
* **The AUR being unsupported by Manjaro.** Documented by Manjaro, quoted in the
  README, and the reason this project exists.
* **`aurinstall`/`aurupdate` being bypassable by calling `yay` directly.** That
  is deliberate and documented. The gate exists to make the bypass a conscious
  decision, not to prevent it. A gate that could not be bypassed would just get
  uninstalled.

## Before you send diagnostics

Nothing this suite produces is key material, so the stakes are lower here than
in a tool that handles secrets. Two things are still worth a look before you
paste:

* **`/var/log/safeup.log`** lists package names and timestamps. That is a
  reasonable fingerprint of what you run and when you update. Usually fine to
  send; read it first.
* **`/etc/aur-pin-check/allowlist.conf`** names every AUR package you decided to
  trust, with upstream URLs. Same consideration.
* **`pacman.conf`** identifies every repository and mirror you use, including
  private or internal ones. Redact those before posting.
* **`pacman -Qm` output** is a complete inventory of your foreign packages.
  Send the relevant lines, not the whole list.

Send the smallest thing that demonstrates the problem. For a **security**
report, send it to the email address above rather than attaching it to an issue.
