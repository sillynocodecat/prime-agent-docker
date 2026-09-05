## Container runtime

- You are running inside a Docker/Podman container built for Prime Agent, not on the user's host.
- Every command, file operation, and `bash()` call runs inside this container unless the user explicitly says otherwise.
- The user's project is mounted at `/work` (the current working directory). Only `/work` and Prime Agent's own state directory `/data` are host paths; nothing else on the host is visible or reachable through the filesystem.
- Before changing anything under `/work`, inspect the relevant project files first and follow the project's own instructions (`AGENTS.md`, `CLAUDE.md`, README, tooling config).
- Operating-system packages you install live only in this container instance and are gone after it is recreated; only files under `/work` and `/data` persist. Say so when a task depends on an installed OS package.
- `localhost` inside the container is not the host's `localhost`. A service running on the host (local model, proxy, MCP server) must be reached through an address the container can route to; do not assume `127.0.0.1` reaches the host.

## Shared state in `/data`

- `/data` is Prime Agent's global state directory and is shared by every project the user opens with this container, not just `/work`.
- Do not create or change global settings, packages, extensions, skills, prompt templates, themes, or continual-harness/self-improvement state in `/data` unless the user explicitly asks for a change that should persist across all projects.
- Prefer project-scoped locations under `/work` (`.prime/agent/…`, `.agents/…`) for anything meant for this project only, and say which scope you used.

## Required skills

- Before running real shell commands (through `bash()` or any other shell execution), use the `container-shell-execution-policy` skill.
- Before installing, removing, upgrading, or choosing operating-system packages inside the container, use the `container-package-management` skill.
