# Contributing to wslforge

Thanks for helping improve wslforge. Bug reports, new tools and fixes for a distro you use are all welcome. The project is plain Bash on the Linux side and Windows PowerShell 5.1 on the Windows side, with no build step.

## Report a problem or ask for a tool

[Open an issue](https://github.com/PLeonLopes/wslforge/issues/new/choose) and pick a form:
- **Bug report.** It asks for your distro, your wslforge version and the end of `~/.wslforge/install.log`.
- **Tool request.** It asks what the tool is for and how it is installed.

For a security problem, do not open a public issue. Use [private vulnerability reporting](https://github.com/PLeonLopes/wslforge/security/advisories/new) instead.

## Contribute a change

1. Fork the repository and branch from the latest `main`. Name the branch `type/short-description`, for example `feat/java-module` or `fix/fedora-docker-repo`.
2. Make the change and test it (see below).
3. Open a pull request against `main`. Use a [Conventional Commit](https://www.conventionalcommits.org) title such as `fix(docker): use the Fedora repository on Fedora 45`. In the description, include:
   - what changed;
   - why;
   - the distros you tested on.

   Add a screenshot when the menu or the output changes.

Keep each commit atomic, with a Conventional Commit subject. Use `feat` for new behavior, `fix` for corrections and `docs` for documentation. Use `ci`, `test`, `refactor` or `chore` where they fit. Update `README.md` and `CHANGELOG.md` when you add a module, an option or a supported distro. Contributions are licensed under the repository's [MIT License](LICENSE).

## Add a tool or a module

A module is one file in `modules/`. `install.sh` picks it up automatically.

- **A tool that fits an existing module** (another CLI tool, another database client) is usually one line in that module's `MODULE_ITEMS`. If a family names the package differently, add an entry to `pkg_map` in `lib/pkg.sh`.
- **A new module:** copy a small one, such as `modules/go.sh` (a release download) or `modules/db-clients.sh` (distro packages). Then adjust it. New modules start with `MODULE_DEFAULT=off`, so they only install when someone asks for them.

[AGENTS.md](AGENTS.md) describes the module contract and the rules that keep modules safe to run twice. It is short and written for people and coding agents alike.

## Test your change

You need Docker. Nothing gets installed on your own system.

```sh
# Lint: ShellCheck, workflow lint and PowerShell analysis (the same versions as CI)
docker run --rm -v "$PWD":/mnt -w /mnt koalaman/shellcheck:v0.11.0 --external-sources install.sh lib/*.sh modules/*.sh
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:1.7.7

# Your module, installed twice in a container. The second run must print 0.
docker run --rm -v "$PWD":/src:ro ubuntu:24.04 bash -c \
  'cp -r /src /w && cd /w && ./install.sh --yes --only <module> && ./install.sh --yes --only <module> | grep -c Installing:'
```

Repeat the container test with `debian:13`, `fedora:latest`, `almalinux:9` and `archlinux:latest` when your change touches packages. CI runs the same checks on every pull request. `./install.sh --dry-run` shows the plan and the commands without changing anything.

Releases are published by the maintainer: merging a version bump with its `CHANGELOG.md` section creates the tag and the GitHub Release automatically. Contributors don't need to change the version.

Changes to `install.ps1` must keep the file ASCII-only, because Windows PowerShell 5.1 misreads anything else. CI checks this with PSScriptAnalyzer. To try the questionnaire without setting anything up, run `.\install.ps1 -ConfigOnly` on Windows.

## Project images

The images in [`docs/media/`](docs/media) use the Forge palette (see the top of `lib/common.sh`). `social-preview.png` is the image GitHub shows when the repository link is shared. Its source is `social-preview.svg`. After editing the SVG, render the PNG (the fonts get baked into it) and upload it in **Settings → Social preview**:

```sh
docker run --rm -v "$PWD/docs/media":/m alpine:3.20 sh -c \
  'apk add -q rsvg-convert font-inter font-jetbrains-mono && rsvg-convert -w 1280 -h 640 /m/social-preview.svg -o /m/social-preview.png'
```
