---
name: container-shell-execution-policy
description: Use before executing real shell commands inside the container (through bash() in the Python kernel or any other shell execution). Not for writing or editing shell scripts, files, or code examples.
---

# Container shell execution policy

Applies to commands you actually execute in the container's shell. It does not
apply to shell syntax inside scripts, files, or code examples you write.

## How shell commands run here

- Shell commands run through `bash()` in the persistent Python kernel:
  `await bash("command")` runs one command and returns its output and exit code.
- The working directory is the user's project at `/work`; the shell is Debian's
  `bash`. You are `root` inside the container, so never use `sudo`.
- The container has no interactive terminal for commands: pass non-interactive
  flags (`-y`, `--no-pager`, `--non-interactive`, `GIT_TERMINAL_PROMPT=0`) and
  never start editors, pagers, or prompts.

## Command execution

- Execute one logical shell command per `bash()` call and check its result
  before running the next one. Pipes and redirections inside that one command
  are fine (`cat file | grep text`, `cmd > out.txt`, `cmd >> log.txt`).
- Do not chain independent commands with `&&`, `;`, or `||` in one call; run
  them as separate `bash()` calls, or put real control flow in Python around
  the awaited results. A single pipeline counts as one command.
- Use Python for logic, loops, parsing, and retries. Use the shell for running
  the project's own tools (`git`, `npm`, `make`, `pytest`, …).
- Always `await` the handle. Do not leave commands running in the background
  (`nohup … &`, unawaited `bash()` handles): background processes are not
  tracked as work by the container lifecycle and are terminated when the
  session becomes idle or the container stops. If a long-running process is
  really needed, run it in the foreground with a bounded timeout and report
  the result.
- Long outputs: limit them (`| head -n 200`, `--max-count`, `tail`) instead of
  dumping whole files or logs.

## Files and safety

- Inspect before you modify: read the relevant files and `git status` first.
- Destructive commands (`rm -r`, `git reset --hard`, `git clean`, mass
  rewrites) only when the task clearly requires them; prefer targeted paths
  over wildcards. If `rm -rf` is refused, use `rm -r` on the exact path.
- Keep changes inside `/work` unless the user explicitly asks for a global
  change in `/data`. Do not touch `/etc/prime-agent`, `/opt/prime-agent`, or
  `/run/prime-agent-container`; they belong to the container runtime.
- Do not disable, kill, or restart the Prime Agent daemon, workers, or the
  container service from inside a session; if something looks stuck, report it
  so the user can run `prime-agent doctor` or `prime-agent shutdown`.
