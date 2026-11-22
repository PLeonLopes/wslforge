# Rulesets

The protection of `main` and of the release tags, kept as code. GitHub does not read these files by itself. Apply them with the GitHub API, and apply them again after editing.

| Ruleset | Rules | Bypass |
|---------|-------|--------|
| [`main-required-checks.json`](main-required-checks.json) | Every CI check must pass; no force push; `main` cannot be deleted | Nobody |
| [`main-pull-request-review.json`](main-pull-request-review.json) | Changes only through pull requests; 1 approval; conversations resolved; merge commits only | Repository admins, only when merging a pull request |
| [`release-tags.json`](release-tags.json) | A published `v*` tag cannot be moved or deleted (creating one is allowed, so the Release workflow can tag) | Repository admins, to undo a broken release |

The `main` rules are split on purpose. A bypass skips **every** rule of its ruleset. With the checks in a ruleset that nobody can bypass, the admin bypass can skip the approval but nothing else:
- it skips the approval, which a sole maintainer needs, since GitHub does not let you approve your own pull request;
- it never skips the checks;
- it never allows a direct push to `main`.

`integration_id: 15368` is the GitHub Actions app: only check runs reported by Actions satisfy the rule.

## Apply

```bash
REPO=PLeonLopes/wslforge

# First time: create
for f in main-required-checks main-pull-request-review release-tags; do
  gh api -X POST "repos/$REPO/rulesets" --input ".github/rulesets/$f.json"
done

# After editing a file: update the existing ruleset by id
gh api "repos/$REPO/rulesets" --jq '.[] | "\(.id)  \(.name)"'
gh api -X PUT "repos/$REPO/rulesets/<id>" --input .github/rulesets/<file>.json
```

## Merging as the sole maintainer

With every check green and no approval, merge with the admin bypass:

```bash
gh pr merge --merge --admin --delete-branch
```

In the web UI, this is the **Merge without waiting for requirements to be met (bypass rules)** checkbox. The required checks still apply.

## Renaming a check

Check names are the `name:` of the jobs in `.github/workflows/lint.yml` and `test.yml`. The matrix jobs are named `Install twice (<image>, <profile>)`. If you rename a job or change the distro matrix, update `main-required-checks.json` and apply it again. Otherwise the rule waits for a check that never reports, and every pull request is blocked.
