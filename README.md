# chagg-github-actions

GitHub Actions for [chagg](https://github.com/codested/chagg) — the release-note workflow tool that collects change entries in `.changes/` and generates changelogs from them.

Two composite actions are provided:

| Action | Path | Purpose |
|--------|------|---------|
| CI     | `codested/chagg-github-actions/ci` | Validate entries, preview on PRs |
| Release | `codested/chagg-github-actions/release` | Generate changelog output for a release tag |

---

## `ci` action

Runs on every push / pull request to keep change entries tidy and visible.

**What it does**

- **On pull requests** — validates only the new `.changes/` files introduced by the PR (so pre-existing issues don't block unrelated work), then posts (or updates) a sticky PR comment showing the full staging changelog preview. If no change entries were added, a warning comment is posted instead.
- **On default-branch pushes** — validates all change entries.

### Inputs

| Name | Required | Default | Description |
|------|----------|---------|-------------|
| `github_token` | no | `github.token` | Token used to post / update PR comments |
| `pr_comment` | no | `true` | Set to `false` to disable the PR comment |

### Permissions

The workflow needs `pull-requests: write` to post PR comments.

### Usage

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: ['**']
  pull_request:
    branches: [main]

permissions:
  contents: read
  pull-requests: write

jobs:
  changes:
    name: Verify change entries
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # required so chagg can walk history

      - uses: codested/chagg-github-actions/ci@v0.1.0
```

---

## `release` action

Runs when a semver tag is pushed. Generates release notes and exposes them (and the clean version number) as outputs.

**What it does**

1. Downloads chagg.
2. Runs `chagg generate -n 1 --no-show-staging` to produce the changelog for the version that was just tagged.
3. Exposes the markdown, the clean version string, and the module directory as outputs.

> **Important:** the calling workflow must check out the repository with `fetch-depth: 0`. chagg needs the full git history to assign change entries to their correct release version.

### Inputs

| Name | Required | Default | Description |
|------|----------|---------|-------------|
| `github_token` | no | `github.token` | Token passed to chagg download step |

### Outputs

| Name | Description |
|------|-------------|
| `changelog` | Changelog markdown for this release (the version section, without the top-level `# Changelog` heading) |
| `version` | Clean semver without any leading `v` or module tag-prefix (e.g. tag `msal-browser-v1.4.0` → `1.4.0`) |
| `module_dir` | Repo-relative directory of the released module (e.g. `lib/msal-browser`). `.` for the root module |

### Usage

```yaml
# .github/workflows/release.yml
name: Release

on:
  push:
    tags:
      - 'v?[0-9]+.[0-9]+.[0-9]+*'          # root module
      - '*-v?[0-9]+.[0-9]+.[0-9]+*'         # named module (e.g. msal-browser-1.4.0)

permissions:
  contents: write

jobs:
  release:
    name: Create GitHub release
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # required

      - name: Generate release notes
        id: notes
        uses: codested/chagg-github-actions/release@v0.1.0

      - name: Create GitHub release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh release create "${{ github.ref_name }}" \
            --title "${{ github.ref_name }}" \
            --notes "${{ steps.notes.outputs.changelog }}"
```

#### Accessing outputs

```yaml
- name: Use version in a build step
  run: echo "Building version ${{ steps.notes.outputs.version }}"

- name: Use module dir
  run: echo "Module lives at ${{ steps.notes.outputs.module_dir }}"
```

---

## Multi-module repositories

Both actions support monorepos automatically via `chagg config modules`. Each module is identified by its `.changes/` directory and `tag-prefix` from `.chagg.yaml`. No extra configuration is required — chagg resolves modules from the repository layout.

For the `release` action, the action determines which module is being released by finding the module whose `tag-prefix` is a prefix of the pushed tag (longest match wins), then strips that prefix (and any leading `v`) to produce the clean `version` output.