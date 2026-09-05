---
name: container-package-management
description: Use whenever installing, removing, upgrading, or choosing operating-system packages inside the container. Not for language package managers (npm, pip, uv, cargo) unless an OS package is also required.
---

# Container package management (Debian)

Use this skill for operating-system packages only. Language package managers
(`npm`, `pip`/`uv`, `cargo`, …) are not covered unless a task also needs an OS
package (compilers, system libraries, CLI tools).

## Container environment

- This image is Debian (`trixie`, slim). Treat that as accurate: use `apt`
  only (`apt-get update`, `apt-get install`, `apt-cache search`,
  `apt-cache policy`). Never try other package managers.
- You are `root`; do not use `sudo`. Run apt non-interactively:
  `DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends <pkg>`.
- The image ships without package indexes (they are removed at build time), so
  `apt-get install` and `apt-cache search` fail until the indexes are refreshed.
- Installed packages live only in this container instance. The container is
  recreated after each clean stop, and a recreated container starts from the
  image again: tell the user which packages a task needed so they can decide
  whether to build a derived image. Files written to `/work` persist.

## Required workflow

1. Before the first package-repository search or package installation in the
   current task, refresh the package indexes once:
   `apt-get update`. After one successful refresh in the same task, do not
   refresh again unless apt reports stale or missing indexes. Refreshing is
   about apt's package repositories, not about searching source-code
   repositories or the project.
2. Before installing, verify the package exists and that the name is the
   Debian name: `apt-cache policy <name>` or `apt-cache search --names-only
   <name>`. Debian names often differ from other distributions and from
   upstream project names (for example `fd-find` provides `fdfind`,
   `python3-dev` provides Python headers, `build-essential` provides a
   compiler toolchain).
3. If the exact package is not found, look for the Debian-specific name, a
   replacement package, or a suitable alternative before choosing. Do not
   install packages by guessing names, and do not retry with random names.
4. Install with `--no-install-recommends` unless a recommended package is
   actually needed.
5. Do not ask for conversational permission before installing an OS package
   that the task clearly requires; report what was installed and why.

## Safety and correctness

- If installation fails, report the exact apt error and the detected
  environment instead of switching package managers or sources.
- Do not add third-party apt repositories, keys, or `curl | sh` installers
  unless the user explicitly asks for them; prefer Debian packages.
- Do not upgrade the whole system (`apt-get upgrade`, `dist-upgrade`) unless
  the user explicitly asks; install only what the task needs.
- Prime Agent's own runtime under `/opt/prime-agent` (Node, uv, the kernel
  Python) is not managed by apt; do not install or remove `nodejs`, `npm`, or
  `python3` packages to change it.
