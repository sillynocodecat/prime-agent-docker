# prime-agent-docker

This project builds a **self-managing container image for [Prime Agent](https://github.com/PrimeIntellect-ai/prime-agent)** (the Prime Intellect coding agent) for Docker and Podman on Linux, and ships a small host launcher. The image is built from the pinned upstream source, bakes the Python kernel, and runs a lifecycle service that keeps background agents alive while you are away and stops the container by itself once everything is idle.

You keep the ordinary `prime-agent [args...]` UX. The launcher mounts your current directory as `/work` and Prime Agent's durable state (`~/prime-agent/data`) as `/data`, starts one managed container when needed, and runs the real Prime Agent CLI inside it.

## Use from registry

- Install the launcher (one POSIX shell script, no other host dependency besides Docker or Podman):
    ```bash
    curl -fsSL https://raw.githubusercontent.com/sillynocodecat/prime-agent-docker/main/prime-agent-container -o ~/.local/bin/prime-agent && chmod +x ~/.local/bin/prime-agent
    ```
    Any name works; `prime-agent` keeps the upstream command name. Optional shell wrappers are in [examples/](examples/) (Fish, Bash/Zsh); they only forward arguments and are never required.

- Run it from a project directory:
    ```bash
    cd ~/src/my-project
    prime-agent
    ```
    The first run pulls `ghcr.io/sillynocodecat/prime-agent-docker:latest`, creates `~/prime-agent/data` and `~/prime-agent/control`, starts the container, waits for the service, and opens the normal Prime Agent TUI. Later runs from the same directory attach to the same container; `prime-agent -c`, `prime-agent agents`, `prime-agent attach <agent>`, `prime-agent -p "summarize this repository"` all work the same way.

- Update the image:
    ```bash
    podman pull ghcr.io/sillynocodecat/prime-agent-docker:latest
    ```
    (or `docker pull`). The new image is used by the next container start after the current workspace has stopped cleanly; a running or recovering workspace keeps its recorded image. `prime-agent update` inside the container is intentionally inert: the installation is immutable and source-built. Prime Agent *packages*, extensions, and skills installed through `prime-agent package …` live in `/data` and are updated separately with `prime-agent package update`.

## Build & run locally

- Build with Docker:
    ```bash
    docker build -t prime-agent-docker .
    ```
- Build with Podman:
    ```bash
    podman build -t prime-agent-docker .
    ```
- Use the local image:
    ```bash
    PRIME_AGENT_IMAGE=prime-agent-docker prime-agent
    ```

Both engines build the same `Dockerfile`; the build fetches the pinned Prime Agent source by commit, applies the small container patch, runs upstream tests, builds and stages the runtime, bakes the Python kernel, then verifies the finished image (smoke checks, kernel imports, the lifecycle JSON contract) in a throw-away stage. `amd64` only.

Build arguments: `PRIME_AGENT_VERSION` / `PRIME_AGENT_REVISION` (upstream release and commit), `UV_VERSION`, `PODMAN_VERSION` with pinned SHA-256 digests, `NODE_IMAGE`, and `IMAGE_SOURCE`.

Hand-written `docker run` / `podman run` or `exec` commands are **not** an equivalent way to use the image: they skip the host-side workspace fence that keeps one project per `/data`. Raw engine commands appear below only for inspection and recovery.

## Environment variables (host launcher)

| Variable | Description |
|---|---|
| `PRIME_AGENT_ENGINE` | Engine executable name or path. Default: `podman` if present, else `docker`. |
| `PRIME_AGENT_IMAGE` | Image reference. Default `ghcr.io/sillynocodecat/prime-agent-docker:latest`. Applied at container creation; a running/recovering workspace keeps its recorded image. |
| `PRIME_AGENT_ENV_FILE` | Path of an env-file (`KEY=value` lines, **no quotes** — both engines pass quotes through literally) applied only when the container is created. See *Authentication*. |
| `PRIME_AGENT_TZ` | Container timezone. Precedence: `PRIME_AGENT_TZ`, host `TZ`, the IANA name behind `/etc/localtime` (Fedora-style symlink), a single-line `/etc/timezone`, then `Etc/UTC`. Fixed per container; changing it takes effect after a clean stop and recreation. |
| `PRIME_AGENT_NO_OAUTH_PORTS` | Exactly `1` to publish no OAuth callback ports; any other value is rejected. |

`DOCKER_HOST`, `DOCKER_CONTEXT`, `CONTAINER_HOST`, `CONTAINER_CONNECTION`, and `PODMAN_HOST` are rejected: the launcher needs a local engine whose daemon can bind the same host directory. Alternate Docker contexts or Podman connections configured elsewhere are unsupported for the same reason, even though the launcher cannot detect them.

Inside the container the image fixes `HOME=/root`, `PATH`, `LANG`/`LC_ALL=C.UTF-8`, `TMPDIR=/tmp`, `PRIME_AGENT_CODING_AGENT_DIR=/data`, the kernel and config paths, the OAuth bind host and base port, and the update-check flag. The launcher re-asserts them after any env-file, so an env-file cannot move state out of `/data` or change the runtime identity.

## Volumes

| Container path | Host path | Purpose |
|---|---|---|
| `/work` | current directory (`$PWD`, physical path) | the project; every project appears as `/work` |
| `/data` | `~/prime-agent/data` (mode 0700) | Prime Agent state: `auth.json`, `settings.json`, sessions, logs, packages, skills, daemon metadata |
| — | `~/prime-agent/control` (mode 0700, **never mounted**) | the workspace fence, launcher lock, and clean-release record |

Both binds use private SELinux relabeling (`:Z`). On SELinux hosts this changes the labels of the project tree (time proportional to its size) and means another private-label container using the same directory revokes access; do not launch from broad system trees such as `$HOME` or `/`. The launcher refuses `/`, paths containing `:` or newlines, and any overlap between the project and `~/prime-agent`.

Nested mounts, hard links, Unix sockets, FIFOs, and device nodes already present under the project directory are part of the bind. An IPC endpoint inside the tree exposes its host service to the agent. Linked git worktrees and submodules whose administrative `.git` directory lies outside the project are **not** followed: use a self-contained checkout or start from the broader root deliberately.

`/data` and the mounted project are shared with the agent in full: outbound network is enabled, and the container is not a data-loss-prevention boundary for anything the agent can read.

### File ownership

Rootless Podman maps container `root` to your user, so files created in `/work` and `/data` belong to you. Rootful Docker runs the container as real root and leaves root-owned files behind (for example under `~/prime-agent/data`); removing them needs `sudo` or a container. Prefer rootless Podman.

## OAuth ports

The image listens for the provider callbacks on `1455` (ChatGPT/Codex), `53692` (Anthropic), and `53700`–`53709` (MCP integrations, base port plus fallbacks). The launcher publishes them on `127.0.0.1` only, with the same numbers on the host, so browser-based `/login` works.

If a port is already taken on the host, the engine's error is shown unchanged and the container is not created; nothing is retried with weaker settings. Retry with `PRIME_AGENT_NO_OAUTH_PORTS=1` and use Prime Agent's manual callback/code entry during `/login`. Docker and Podman on one host cannot both publish these ports at the same time; start the second engine's container with `PRIME_AGENT_NO_OAUTH_PORTS=1`.

## Authentication

`/login` inside Prime Agent is the default path; credentials are stored in `/data/auth.json` and persist across containers and projects.

For API keys, provider, cloud, or proxy variables use `PRIME_AGENT_ENV_FILE=~/prime-agent.env` (create the file mode 0600). The file is passed to the engine as `--env-file` when the container is created: the launcher reads only the variable *names* (to reject `NODE_OPTIONS`, `NODE_PATH`, `LD_PRELOAD`, `LD_LIBRARY_PATH`, `PRIME_AGENT_INTERNAL_*`, `PRIME_AGENT_KERNEL_PYTHON`, session-directory overrides, and Docker/Podman endpoint variables) and records only the path plus a checksum for recovery. Values are never printed or copied to the control directory, but they **are** readable by Prime Agent and every command it runs, and they stay in the container configuration visible to anyone who can inspect the engine. This is not a secret store. Changing the file takes effect when the workspace's container is next created after a clean stop; recovery of an unclean stop requires the same file with the same checksum.

`/data/auth.json` is inside the agent's own permission boundary: container isolation separates the agent from your host, not the agent from its own stored credentials.

### Telemetry

Upstream defaults are preserved. Disable with `PRIME_AGENT_TELEMETRY=0` or `DO_NOT_TRACK=1` in the env-file, or `telemetry.enabled=false` in `settings.json`.

## Leaving the UI

- `/quit` and `Ctrl+D` (on an empty editor) detach the TUI cleanly. Agents, subagents, schedules, and tool calls keep running in the container.
- Closing the terminal tab (or losing the SSH connection) is supported: the launcher hangs up its own client inside the container, work continues, and the container can still stop by itself later. If the launcher process itself is killed with `SIGKILL`, the TUI client stays attached until you reconnect and `/quit`.
- One `Ctrl+C` **interrupts the current work** and shows an exit hint; a second `Ctrl+C` exits. Do not use `Ctrl+C` to put work in the background.
- `prime-agent -c` or `prime-agent --resume <id>` from the same project reattaches to the session; `prime-agent agents` shows every agent.

## Lifecycle

The container's entrypoint is a small service that starts Prime Agent's daemon and watches it through the public `status`, `list`, and `schedule list` commands:

- While a client is attached, an agent or subagent is working, a schedule or heartbeat is registered, or a tracked worker exists, the container stays up. An idle session is passivated by Prime Agent's own idle eviction (the container sets a short default) without archiving it; its transcript stays in `/data`.
- When nothing is left, the service shuts the empty daemon down and exits `0`. The stopped container object is kept on purpose as evidence of a clean stop; it uses no CPU and holds no ports. The next `prime-agent` from **any** project removes it and releases the workspace.
- `prime-agent -c` from the same project later restarts everything: passivated sessions are `live` in `prime-agent list --all` and the Agents View and resume normally.
- Stopping the container (`podman stop`/`docker stop`, host shutdown) or running `prime-agent shutdown` while an agent is still resident stops it through Prime Agent's shutdown path, which **archives** that session: the transcript is intact and `--resume <id>` works, but it appears under *archived* in the Agents View. Letting the container quiesce on its own keeps sessions live. A host crash or `SIGKILL` relies on Prime Agent's crash recovery on the next start.
- Sessions resumed from another project: every project is `/work`, so `-c` and project-scoped history cannot tell host projects apart. The launcher only prevents this while the previous project's container is alive; choosing a saved session from the wrong project later is your responsibility.
- If Prime Agent's idle eviction is delayed or a worker is stuck, the container stays alive by design (it never guesses that work is dead). Inspect with `prime-agent list --all`, `prime-agent doctor`, and stop deliberately with `prime-agent shutdown`. An explicit `idleEvictionMinutes` larger than the container default, or `"off"`, in `/data/settings.json` delays or disables the automatic stop.
- Operating-system packages installed with `apt` inside a container are gone when it is recreated; project files under `/work` and everything in `/data` persist. Build a derived image for toolchains you need every time.

### One active workspace

`/data` is shared, so only one project may have a live container at a time. Starting `prime-agent` from another directory while a container for a different project is running (or stopped uncleanly) is refused with:

```
prime-agent-container: another workspace is active in the managed container: /path/to/other/project
prime-agent-container: finish or /quit there and let it stop, then start from this directory
```

followed by inspect/recover hints. Nothing is mounted, changed, or stopped in that case.

### Recovery after OOM, reboot, or an engine crash

The host fence in `~/prime-agent/control/workspace` survives. From the **same directory and engine**:

```bash
cd /path/to/that/project && prime-agent
```

restarts the stopped container (or recreates it from the recorded image, timezone, ports, and env-file when it was removed), Prime Agent recovers its workers, and you can `/quit` and let the service reach a clean exit. Only that path and engine are accepted; the launcher never guesses that recovery state is stale.

Safe reset means exactly that: return to the recorded path, cancel schedules (`prime-agent schedule list --all`, `schedule cancel <id>`), stop agents, and let the container exit `0`. If the path cannot be restored, back up and replace **all** of `~/prime-agent/data` deliberately, then remove `~/prime-agent/control/workspace` by hand; never delete individual descriptors inside `/data`, because a scheduled prompt could later run against a different `/work`. A non-empty `/data` without a fence is refused on purpose.

Inspection commands (not a way to run the appliance):

```bash
podman inspect prime-agent        # or: docker inspect prime-agent
podman logs prime-agent
cat ~/prime-agent/control/workspace/workspace
```

## Managed instructions

`/etc/prime-agent` in the image (outside `/data`, so a mount cannot hide it) holds `APPEND_SYSTEM.md` and two skills, `container-shell-execution-policy` and `container-package-management`, that every session, worker, and subagent receives in addition to your own configuration. They tell the agent that it runs in a container, that the project is `/work`, that `/data` is shared across projects and must not be changed globally unless you ask, how to run shell commands through `bash()`, and how to install Debian packages.

Limitation: because the managed entry is always present, Prime Agent's automatic discovery of `<project>/.prime/agent/APPEND_SYSTEM.md` and `/data/APPEND_SYSTEM.md` is suppressed. Project and global `AGENTS.md` / `CLAUDE.md` load normally, `--system-prompt` and `--append-system-prompt` keep working, and a discovered file can be passed explicitly: `prime-agent --append-system-prompt .prime/agent/APPEND_SYSTEM.md`. `--no-skills` disables discovered skills but keeps the two managed ones.

Managed instructions are guidance, not enforcement: writable global `/data` is an intentional cross-project trust channel for settings, packages, extensions, skills, prompts, and continual-harness state. What the agent changes there in one project affects the next.

The bundled `linear` and `notion` skills are baked into the kernel but hidden until their MCP integration is authenticated; the first kernel start in a new container therefore only rewrites the kernel's bootstrap marker (no install, no network), and enabling one later re-registers it through `uv`, which needs network once.

## Security

The default launcher runs the container with the engine's normal namespaces, seccomp/AppArmor or SELinux policy, bridge networking, `--init`, `--security-opt no-new-privileges`, `--restart=no`, a 30-second stop timeout, private tmpfs mounts for the runtime coordination directory and `/tmp`, and exactly two binds. It never mounts an engine socket, host namespaces, devices, or other host paths, and never uses `--privileged`. The bundled `podman-remote` binary has no socket to talk to and grants no host-engine access; mounting one yourself hands the agent control of the host engine and voids the isolation model, so no such option exists and none is documented.

This is ordinary container isolation, not a formal escape-proof sandbox: its strength depends on the host kernel, the runtime, rootless vs. rootful mode, the MAC policy, and security updates. Model-generated code runs with full permissions inside the container over everything it can see. A kernel or runtime vulnerability can cross the boundary. Patched rootless Podman with SELinux is the recommended default; rootful Docker adds real root on the host side of the bind mounts.

Desktop integrations are conditional or unavailable inside the container: browser auto-open (use the printed login URL), host clipboard and images, desktop notifications, an external editor, the GitHub CLI, cloud CLIs, SSH agents and keys, and devices/GPUs. Local services on the host are not `localhost` from inside the container; expose them on an address the container can route to (the launcher never enables host networking or engine-specific host aliases).

## Features

- **Source-built, pinned upstream**: Prime Agent built from the tagged commit with a five-file, version-checked patch (short idle-eviction default, managed instruction injection).
- **Baked Python kernel**: uv-managed Python 3.11 with `rlm` and all bundled Python-backed skills; no download on first start.
- **Self-stopping service**: keeps background agents and schedules alive, exits only after Prime Agent itself passivated everything.
- **One launcher for both engines**: POSIX `sh`, identical behavior on Docker and Podman, install by copying one file.
- **Licenses**: this repository declares no license and sets no `org.opencontainers.image.licenses` label; upstream license texts are installed under `/usr/share/licenses` and summarized in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
