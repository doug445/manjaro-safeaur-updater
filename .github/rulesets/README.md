# Rulesets

The branch and tag protection for this repository, as JSON rather than as
settings someone clicked once and cannot reproduce.

Apply or re-apply:

```bash
gh api --method POST repos/doug445/manjaro-safeaur-updater/rulesets --input .github/rulesets/branch-main.json
gh api --method POST repos/doug445/manjaro-safeaur-updater/rulesets --input .github/rulesets/tags-release.json
```

List what is live, and read one back:

```bash
gh api repos/doug445/manjaro-safeaur-updater/rulesets --jq '.[] | "\(.id)  \(.name)  [\(.target)]  \(.enforcement)"'
gh api repos/doug445/manjaro-safeaur-updater/rulesets/RULESET_ID --jq '.rules'
```

## What is enforced

**`branch-main.json`** — the default branch:

| Rule | Effect |
|---|---|
| `deletion` | `main` cannot be deleted |
| `non_fast_forward` | no force-pushing `main`; history cannot be rewritten |

**`tags-release.json`** — every tag matching `v*`:

| Rule | Effect |
|---|---|
| `deletion` | a published version tag cannot be removed |
| `update` | a version tag cannot be moved to another commit |
| `non_fast_forward` | no force-pushing a tag over an existing one |

Creating *new* `v*` tags is unaffected — that is the `creation` rule, which is
deliberately not enabled.

Tag immutability matters more here than in most repositories. This suite is
built on the premise that **a moved tag is an attack**: `aur-pin-check` rejects
every `#tag=` source precisely because upstream can re-point one, and its
allowlist re-resolves each vetted tag on every run to catch it happening. A
project that argues that position and then leaves its own release tags mutable
is not making the argument seriously.

## What is deliberately not enforced

This is a small repository with direct pushes to `main`. Rules that assume a
pull-request workflow would break it for no gain:

- **`pull_request`** — would forbid pushing to `main` at all. Add it the moment
  a second contributor appears.
- **`required_status_checks`** — only evaluated when merging a pull request, so
  it does nothing here while also implying `pull_request`. The `lint` workflow
  still runs on every push; you just have to read the result rather than have
  the rule read it for you.
- **`required_signatures`** — commits here are not GPG-signed, so this would
  reject every push, including your own.
- **`required_linear_history`** — would block merge commits, turning an ordinary
  "Merge" click into a confusing failure.

## Bypass, and getting unstuck

`bypass_actors` is empty on purpose. With a bypass entry for repository admin
the rules would not bind you at all, and you are the only one pushing — the
guard exists precisely to catch a bad `--force` from you or from tooling.

Nothing is locked: as an admin you can set a ruleset to `disabled`, do the
thing, and set it back.

Send the **whole** ruleset body, not just the changed field — `PUT` replaces the
ruleset, so a partial update silently drops the rules:

```bash
ID=$(gh api repos/doug445/manjaro-safeaur-updater/rulesets --jq '.[] | select(.name=="release tags") | .id')

jq '.enforcement = "disabled"' .github/rulesets/tags-release.json > /tmp/off.json
gh api --method PUT "repos/doug445/manjaro-safeaur-updater/rulesets/$ID" --input /tmp/off.json

# ... do the thing ...

gh api --method PUT "repos/doug445/manjaro-safeaur-updater/rulesets/$ID" --input .github/rulesets/tags-release.json
```

Confirm the rules survived, every time:

```bash
gh api "repos/doug445/manjaro-safeaur-updater/rulesets/$ID" --jq '.enforcement, (.rules|map(.type))'
```

## Status

**Not yet applied to this repository** — the two `POST` commands above have not
been run here. The rule bodies are the ones in use on the sibling repositories,
where the behaviour was tested on 2026-08-23: pushing a new `v*` tag succeeded,
deleting it was rejected with `GH013: Repository rule violations found`, and an
ordinary fast-forward push to `main` was unaffected. The disable/re-enable cycle
above is how that test tag was then removed.

Apply both before `v1.0.0` is public, and update this section once you have
confirmed them with the `--jq '.enforcement, (.rules|map(.type))'` read-back.
