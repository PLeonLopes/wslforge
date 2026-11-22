# Changelog

All notable changes to wslforge. Versions follow [Semantic Versioning](https://semver.org).

## [1.0.1] - 2026-11-22

### Changed

- Plain Linux (outside WSL) is now officially supported. The same `curl | bash` command sets up a laptop, a VM or a server running a supported distro.
- Outside WSL, the start-up message now just says that the WSL-specific steps are skipped, instead of warning that it "does not look like WSL".

### Docs

- The README covers the plain Linux case.
- The social preview image is kept in `docs/media/`. `CONTRIBUTING.md` explains how to render it again.

## [1.0.0] - 2026-11-21

The first release: one command from a Windows PC without WSL to a ready development terminal.

### Windows (`install.ps1`)

- A short questionnaire with a default for every answer:
  - distro, name and install folder;
  - Linux user;
  - WSL memory and CPU cores;
  - profile;
  - git identity.
- Enables or updates WSL when needed, asking for administrator rights only then, and continues by itself after a restart.
- Creates the distro and your Linux user with `sudo`, sets the limits in `~\.wslconfig` (keeping a backup) and runs `install.sh` inside.
- `-Yes`, `-Resume`, `-ConfigOnly`, `-Config`, `-Ref` and `-Ui`.

### Linux (`install.sh`)

- Ubuntu, Debian, Kali, Fedora, AlmaLinux and Arch Linux (apt, dnf and pacman).
- 12 modules in 6 groups:
  - **in the `dev` profile:** `base`, `cli`, `git`, `python`, `node`, `docker`, `claude`;
  - **optional:** `go`, `rust`, `cloud`, `db-clients`, `shell`.
- Profiles `minimal`, `dev` and `full`, or pick modules and single tools in an interactive menu (gum, whiptail or plain text).
- `--list [module]`, `--only`, `--skip`, `--config`, `--dry-run`, `--yes`.
- Safe to run again: only missing tools are installed. A failing tool never stops the others, and the summary says what happened.
- Works through `curl | bash`, asks for `sudo` only when needed, and logs each run to `~/.wslforge/install.log`.

[1.0.1]: https://github.com/PLeonLopes/wslforge/releases/tag/v1.0.1
[1.0.0]: https://github.com/PLeonLopes/wslforge/releases/tag/v1.0.0
