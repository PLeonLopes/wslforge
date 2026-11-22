# wslforge repository guidance

## Project shape

- `install.ps1` is the Windows side. It asks the questions, enables WSL, creates the distro and the Linux user, then runs `install.sh` inside the distro. It targets Windows PowerShell 5.1.
- `install.sh` is the Linux entry point. It parses options, reads the config, picks modules (menu, profile or flags), shows the plan, runs each module and prints a summary.
- `lib/` holds the shared helpers, all sourced by `install.sh`:
  - `common.sh`: logging, the Forge palette, `run`/`as_root` (dry-run aware), downloads with checksums, the shared `~/.wslforge/env.sh`;
  - `distro.sh`: distro detection;
  - `pkg.sh`: packages for the apt, dnf and pacman families;
  - `ui.sh`: menus through gum, whiptail or plain text.
- `modules/<id>.sh` holds one module per file. `install.sh` finds modules by listing this folder, so adding a file adds a module.
- `.github/workflows/` runs lint on every PR, plus tests that install twice in Ubuntu, Debian, Fedora, AlmaLinux and Arch containers.

## Working rules

- **Write a module** by copying a small one (`modules/go.sh`, `modules/db-clients.sh`). Each module sets:
  - `MODULE_NAME`, `MODULE_ORDER`, `MODULE_GROUP`, `MODULE_DEFAULT` (`on` for the `dev` profile, `off` for optional);
  - `MODULE_FAMILIES` (`apt dnf pacman`);
  - `MODULE_ITEMS` (`'id|description'`, add `|required` for tools that cannot be skipped).

  It defines `is_installed ITEM` (read-only) and `do_install ITEMS...`. Optionally it adds `is_available ITEM`, `configure`, `notes` and `actions`.
- Modules run in a subshell with `set -euo pipefail`. In that context:
  - Never end a function with `cond && action`. Use `if`.
  - Never pipe into `grep -q` (SIGPIPE fails the pipeline). Compare a captured string instead.
  - Never name a function `install`.
- **Second run:** it must install nothing. `is_installed` has to recognize every tool `do_install` sets up, including ones that are not yet on the current `PATH`.
- **Changes to the system** go through `run`, `as_root`, `write_root_file`, `pkg_install` or `run_installer`, so `--dry-run` stays truthful.
- **Package names that differ between families** go in `pkg_map` (`lib/pkg.sh`), not in the modules. A tool a distro does not package gets `is_available`; it never fails the module.
- **Downloads:** prefer the vendor's official source. Check release downloads with `fetch_verified` and a published SHA-256.
- **Shell setup:** user tools go under `~/.local`. PATH changes go through `shell_env_setup`/`~/.wslforge/env.sh`. Never append to `~/.bashrc` or `~/.zshrc` directly.
- **`install.ps1` must stay ASCII-only:** PowerShell 5.1 misreads other characters, and CI checks this. Build symbols with `[char]`. Avoid `$script:` scope (the script also runs through `irm | iex`).
- **Colors** come only from the Forge tokens at the top of `lib/common.sh`, and `NO_COLOR` must keep working.
- **English only:** everything in the repository (code, comments, messages, docs, commits) is in English.
- **Commits:** keep them atomic, with Conventional Commit subjects (`type(scope): summary`). Update `README.md` and `CHANGELOG.md` when modules, options or supported distros change.
- **Releases:** the version lives in `install.sh` (`WSLFORGE_VERSION`) and `install.ps1` (`$WslforgeVersion`), and the two must match. Between releases it ends in `-dev`. To release, set both to the new version and add its `## [x.y.z]` section to `CHANGELOG.md`. On merge, `.github/workflows/release.yml` creates the tag and the GitHub Release. Never tag by hand.
- **CI job names are required checks** (`.github/rulesets/main-required-checks.json`). Renaming a job or changing the distro matrix means updating that file and applying it again (see `.github/rulesets/README.md`).
- **Real systems:** do not run real installs, create WSL distros or change `~\.wslconfig` on someone's machine without their explicit approval. Use containers and `--dry-run`.

## Useful commands

```sh
./install.sh --list                     # modules, tools and what is installed
./install.sh --dry-run --profile full   # the plan, changing nothing

# Lint (the same versions as CI)
docker run --rm -v "$PWD":/mnt -w /mnt koalaman/shellcheck:v0.11.0 --external-sources install.sh lib/*.sh modules/*.sh
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:1.7.7
docker run --rm -v "$PWD":/src -w /src mcr.microsoft.com/powershell:7.5-ubuntu-24.04 pwsh -c \
  "Install-Module PSScriptAnalyzer -Force; Invoke-ScriptAnalyzer -Path ./install.ps1 -Settings ./PSScriptAnalyzerSettings.psd1"

# Install twice in a container: the second run must install nothing
docker run --rm -v "$PWD":/src:ro debian:13 bash -c \
  'cp -r /src /w && cd /w && ./install.sh --yes --profile full && ./install.sh --yes --profile full | grep -c Installing:'
```

Run the container test on a copy (as above), not on the mounted folder: editing `install.sh` while it runs breaks the run. Bash reads scripts as it goes.
