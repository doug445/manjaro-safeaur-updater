# Contributing

**Manjaro SafeAUR Updater 1.1.0**

This project gates what gets installed on your machine. Every added code path is
a path that can wave something through, and there is one maintainer to be sure
it does not. **Bug reports only.**

| | |
|---|---|
| **Wanted** | Bugs — especially a gate that passed when it should have failed |
| **Declined** | Features, new options, refactors, style changes — regardless of quality |

Pull requests that are not a fix for a reported bug will be closed. That is not
a comment on their quality; it is the scope.

## What counts as a bug

- `aur-pin-check` accepting an unpinned VCS source, or an allowlisted tag that
  has moved.
- `safeup` holding a package it should not have, or upgrading one it should
  have held.
- A hold that happened but was not reported, on screen or in
  `/var/log/safeup.log`.
- `remove-versioned-kernel` removing the running kernel, the last kernel, or
  corrupting `IgnorePkg`.
- `aur-rebuild-check` flagging a package that is fine, or missing one that is
  broken.
- Anything reporting success on an operation that did not happen.

Not a bug: cosmetic output, a wish for a flag, a preference about defaults, or a
held package staying held because Manjaro has not shipped the dependency yet.

**Security issues do not go here.** Read [SECURITY.md](SECURITY.md) and use the
private address.

## Reporting one

Include:

1. what you ran, verbatim, and what you expected;
2. `pacman-conf --repo-list` — which third-party repos you have enabled;
3. `git -C /path/to/manjaro-safeaur-updater describe --tags --always --dirty`;
4. the relevant lines of `/var/log/safeup.log`, and the terminal output;
5. for a pin-check bug, the package name and the `source =` lines from
   `curl -s "https://aur.archlinux.org/cgit/aur.git/plain/.SRCINFO?h=<pkg>"`.

Read [SECURITY.md § Before you send
diagnostics](SECURITY.md#before-you-send-diagnostics) first — `pacman.conf` and
the allowlist say more about your machine than you may intend.

## If you are sending a fix

Run what CI runs:

```bash
shellcheck -S warning $(git ls-files '*.sh') bin/*
bash tests/pin-fixture-test.sh            # expect 22 passed, 0 failed
sudo bash tests/loopback-core-test.sh     # expect 31 passed, 0 failed
```

Requirements for any patch:

- `bash -n` clean and `shellcheck -S warning` clean. Both are enforced in CI.
- **A test with it.** A behaviour change with no assertion covering it will be
  declined however correct it looks. `tests/pin-fixture-test.sh` needs no root
  and no network; add there if you can.
- No new runtime dependency. This suite repairs a broken package manager, so it
  cannot depend on packages installed by that package manager.
- Comments explain **why**, not what. The existing code is dense with reasons
  for non-obvious choices; match that.
- Anything that can fail must fail loudly. A check that could not run reports an
  error or `SKIP`; it is never silently counted as a pass. That invariant is the
  whole safety model — do not weaken it for tidier output.

## Conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
