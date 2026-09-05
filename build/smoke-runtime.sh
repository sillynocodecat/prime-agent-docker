#!/usr/bin/env bash
# Runtime-image smoke checks (TODO §3). Runs in the throwaway `verify` stage,
# which is built FROM the runtime stage, so everything asserted here holds for
# the published image without leaving this script (or anything it touches)
# inside it. The only output that reaches the final image is the report file
# this script writes to $REPORT.
#
# Expected environment (from the runtime stage): PRIME_AGENT_VERSION,
# PRIME_AGENT_REVISION, UV_VERSION, PODMAN_VERSION plus the image ENV contract.
set -euo pipefail

REPORT=${REPORT:-/verified/report.txt}
mkdir -p "$(dirname "$REPORT")"
: >"$REPORT"
failed=0
ok()   { printf '  ok   %s\n' "$*" | tee -a "$REPORT"; }
fail() { printf '  FAIL %s\n' "$*" | tee -a "$REPORT" >&2; failed=1; }
check() { if [ "$1" -eq 0 ]; then ok "$2"; else fail "$2${3:+: $3}"; fi; }
log() { printf '\n==> %s\n' "$*" | tee -a "$REPORT"; }
expect_env() { # $1 = name, $2 = expected value
  if [ "${!1-__unset__}" = "$2" ]; then ok "$1=$2"; else fail "$1 is '${!1-<unset>}', expected '$2'"; fi
}
expect_unset() { if [ -z "${!1+x}" ]; then ok "$1 unset"; else fail "$1 must be unset (is '${!1}')"; fi; }

version=${PRIME_AGENT_VERSION:?}
revision=${PRIME_AGENT_REVISION:?}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
log "Environment contract"
# ---------------------------------------------------------------------------
expect_env HOME /root
expect_env PATH /usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
expect_env LANG C.UTF-8
expect_env LC_ALL C.UTF-8
expect_env TMPDIR /tmp
expect_env TMP /tmp
expect_env TEMP /tmp
expect_env PRIME_AGENT_CODING_AGENT_DIR /data
expect_env PRIME_AGENT_KERNEL_VENV /opt/prime-agent/kernel-venv
expect_env UV_PYTHON_INSTALL_DIR /opt/prime-agent/python
expect_env PRIME_AGENT_CONTAINER_CONFIG_DIR /etc/prime-agent
expect_env PRIME_AGENT_BUILD_ID "$revision"
expect_env PRIME_AGENT_LAUNCHER_PATH /usr/local/bin/prime-agent
expect_env PI_OAUTH_CALLBACK_HOST 0.0.0.0
expect_env PI_MCP_OAUTH_CALLBACK_PORT 53700
expect_env PI_SKIP_VERSION_CHECK 1
expect_unset DEBIAN_FRONTEND
expect_unset PRIME_AGENT_KERNEL_PYTHON
expect_unset PRIME_AGENT_CONTAINER_CLIENT
[ "$(id -u)" -eq 0 ] && ok "runs as root (uid 0), matching codex-docker" || fail "expected uid 0"
[ "$(pwd)" = /work ] && ok "WORKDIR is /work" || fail "cwd is $(pwd), expected /work"
for d in /work /data; do
  if [ -d "$d" ] && [ -z "$(ls -A "$d")" ]; then ok "$d exists and is empty"; else fail "$d missing or not empty"; fi
done
[ "$(dpkg --print-architecture)" = amd64 ] && ok "dpkg architecture amd64" || fail "not amd64"

# ---------------------------------------------------------------------------
log "Tools execute"
# ---------------------------------------------------------------------------
tool() { # $1 = label, $2.. = command; first output line is recorded
  local label=$1 out; shift
  if out=$("$@" 2>&1); then ok "$label: $(printf '%s\n' "$out" | head -1)"; else fail "$label: $(printf '%s\n' "$out" | head -1)"; fi
}
tool node /usr/local/bin/node --version
tool "node via PATH" node --version
[ "$(command -v node)" = /usr/local/bin/node ] && ok "node resolves to /usr/local/bin/node" || fail "node resolves to $(command -v node)"
tool bash bash --version
tool git git --version
tool ssh ssh -V
[ -x /usr/bin/scp ] && ok "scp present" || fail "scp missing"
tool ripgrep rg --version
tool fd fd --version
tool fdfind fdfind --version
[ "$(readlink -f "$(command -v fd)")" = "$(readlink -f "$(command -v fdfind)")" ] && ok "fd is Debian's fdfind" || fail "fd and fdfind differ"
tool curl curl --version
tool ss ss -V
tool ps ps --version
tool tar tar --version
tool gzip gzip --version
tool uv uv --version
uv --version | grep -q " ${UV_VERSION:?} " && ok "uv is the pinned ${UV_VERSION}" || fail "uv version is not ${UV_VERSION}: $(uv --version)"
[ "$(command -v uv)" = /usr/local/bin/uv ] && ok "uv resolves from PATH first (/usr/local/bin/uv)" || fail "uv resolves to $(command -v uv)"
tool podman-remote podman-remote --version
podman-remote --version | grep -q " ${PODMAN_VERSION:?}\$" && ok "podman-remote is the pinned ${PODMAN_VERSION} and runs without an engine socket" || fail "podman-remote version mismatch"
tool "kernel python" /opt/prime-agent/kernel-venv/bin/python --version
tool "sha256sum" sha256sum --version
tool "patch absent (build-only)" sh -c '! command -v patch'

# ---------------------------------------------------------------------------
log "Prime Agent CLI through the wrapper"
# ---------------------------------------------------------------------------
# stdin is not a TTY here, so upstream prints --version on stderr (main.ts:1093).
wrapper_version=$(prime-agent --version 2>&1 </dev/null | tr -d '\r' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)
[ "$wrapper_version" = "$version" ] && ok "prime-agent --version -> $wrapper_version" || fail "prime-agent --version -> '$wrapper_version', expected $version"
smoke_agent_dir="$WORK/agent"
mkdir -p "$smoke_agent_dir"
# Public commands print JSON on stdout; keep /data untouched by pointing the
# agent dir elsewhere for this probe.
st=$(PRIME_AGENT_CODING_AGENT_DIR="$smoke_agent_dir" prime-agent status --json 2>/dev/null </dev/null)
[ "$st" = "[]" ] && ok "prime-agent status --json -> []" || fail "status --json -> '$st'"
# `list` needs a daemon and public commands never auto-spawn one
# (shouldStartDaemonEarly is false for them): expect a clean connect failure
# and no daemon afterwards.
if PRIME_AGENT_CODING_AGENT_DIR="$smoke_agent_dir" prime-agent list --json >"$WORK/list-out" 2>"$WORK/list-err" </dev/null; then
  fail "list --json succeeded without a daemon: $(head -c 200 "$WORK/list-out")"
else
  grep -q 'Failed to connect to the Prime Agent daemon' "$WORK/list-err" && ok "list --json without a daemon fails cleanly (no auto-spawn)" || fail "list --json error: $(head -c 300 "$WORK/list-err")"
fi
st=$(PRIME_AGENT_CODING_AGENT_DIR="$smoke_agent_dir" prime-agent status --json 2>/dev/null </dev/null)
[ "$st" = "[]" ] && ok "status --json still [] (public probes spawned no daemon)" || fail "a daemon appeared after public probes: $st"
[ -z "$(ls -A /data)" ] && ok "/data still empty after public probes" || fail "/data was written by public probes"
# The build id must come from the environment, not from the version-only fallback.
grep -lq "PRIME_AGENT_BUILD_ID" /opt/prime-agent/packages/coding-agent/dist/bundle/*.js && ok "bundle reads PRIME_AGENT_BUILD_ID at runtime (daemon-runtime-identity)" || fail "bundle lacks PRIME_AGENT_BUILD_ID"
head -c 200 /usr/local/bin/prime-agent | grep -q '^#!/bin/sh' && ok "wrapper is POSIX sh" || fail "wrapper shebang"
[ -x /usr/local/bin/prime-agent ] && [ -f /usr/local/lib/prime-agent-container/service.mjs ] && ok "wrapper and service present" || fail "rootfs files missing"

# ---------------------------------------------------------------------------
log "Managed instructions in /etc/prime-agent (outside /data, so a mount cannot hide them)"
# ---------------------------------------------------------------------------
[ -s /etc/prime-agent/APPEND_SYSTEM.md ] && ok "APPEND_SYSTEM.md present ($(wc -c </etc/prime-agent/APPEND_SYSTEM.md) bytes)" || fail "APPEND_SYSTEM.md missing"
grep -q 'inside a Docker/Podman container' /etc/prime-agent/APPEND_SYSTEM.md && ok "managed prompt names the container runtime" || fail "managed prompt text"
grep -q 'container-shell-execution-policy' /etc/prime-agent/APPEND_SYSTEM.md && grep -q 'container-package-management' /etc/prime-agent/APPEND_SYSTEM.md && ok "managed prompt requires both skills" || fail "managed prompt skill references"
grep -q -- '--no-install-recommends' /etc/prime-agent/skills/container-package-management/SKILL.md && grep -q 'apt-get update' /etc/prime-agent/skills/container-package-management/SKILL.md && ok "package skill is Debian/apt specific" || fail "package skill content"
[ "$(find /etc/prime-agent -type f | wc -l)" = 3 ] && ok "exactly three managed files" || fail "unexpected files: $(find /etc/prime-agent -type f | tr '\n' ' ')"
# Load the managed skills through upstream's own loader: exact names, no diagnostics.
node --input-type=module -e '
const m = await import("/opt/prime-agent/packages/coding-agent/dist/index.js");
const r = m.loadSkillsFromDir({ dir: "/etc/prime-agent/skills", source: "container" });
const names = r.skills.map((s) => s.name).sort().join(",");
if (r.diagnostics.length) { console.log("  FAIL skill diagnostics: " + JSON.stringify(r.diagnostics)); process.exit(1); }
if (names !== "container-package-management,container-shell-execution-policy") { console.log("  FAIL managed skills loaded: " + names); process.exit(1); }
for (const s of r.skills) if (s.description.length > 1024 || !/^[a-z0-9-]+$/.test(s.name)) { console.log("  FAIL skill " + s.name + " violates the Agent Skills limits"); process.exit(1); }
console.log("  ok   upstream loader accepts both managed skills with no diagnostics (" + r.skills.length + " skills)");
' | tee -a "$REPORT" || failed=1

# ---------------------------------------------------------------------------
log "Service controller self-test"
# ---------------------------------------------------------------------------
if out=$(node /usr/local/lib/prime-agent-container/service.mjs --self-test 2>&1); then
  ok "service --self-test: $(printf '%s\n' "$out" | tail -1)"
else
  fail "service --self-test failed" "$(printf '%s\n' "$out" | tail -5)"
fi

# ---------------------------------------------------------------------------
log "Git safe.directory is exactly /work"
# ---------------------------------------------------------------------------
safe=$(git config --system --get-all safe.directory || true)
[ "$safe" = "/work" ] && ok "system safe.directory = /work (only)" || fail "safe.directory is '$safe'"
[ -z "$(git config --global --get-all safe.directory || true)" ] && ok "no global safe.directory" || fail "unexpected global safe.directory"
# Root inspecting a repository owned by another uid is exactly the rootful-Docker
# bind-mount case. Outside /work git must refuse; inside /work it must work.
other="$WORK/other-owner"; mkdir -p "$other"
git -C "$other" init -q && git -C "$other" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
chown -R 65534:65534 "$other"
if git -C "$other" status >/dev/null 2>"$WORK/git-err"; then fail "git accepted a foreign-owned repo outside /work"; else
  grep -q 'dubious ownership' "$WORK/git-err" && ok "foreign-owned repo outside /work is refused (dubious ownership)" || fail "unexpected git error: $(cat "$WORK/git-err")"; fi
cp -a "$other/." /work/ && chown -R 65534:65534 /work
if git -C /work status >/dev/null 2>&1; then ok "foreign-owned repo at /work is accepted"; else fail "git refused /work despite safe.directory"; fi
rm -rf /work/.git; find /work -mindepth 1 -delete; chown 0:0 /work
[ -z "$(ls -A /work)" ] && ok "/work left empty" || fail "/work not cleaned"

# ---------------------------------------------------------------------------
log "Locale: C.UTF-8 without a generated locale"
# ---------------------------------------------------------------------------
[ ! -d /usr/lib/locale/C.utf8 ] && [ ! -d /usr/lib/locale/C.UTF-8 ] && ok "no generated locale directory (glibc builtin C.UTF-8)" || ok "C.UTF-8 locale directory present"
s='Ünïcödé-файл-日本'
[ "${#s}" -eq 15 ] && ok "bash counts UTF-8 characters (\${#s}=${#s})" || fail "bash \${#s}=${#s}, expected 15 (LANG/LC_ALL not effective)"
: >"$WORK/$s.txt"
[ "$(ls "$WORK" | grep -c 'Ünïcödé-файл-日本.txt')" -eq 1 ] && ok "UTF-8 filename round-trips through ls" || fail "UTF-8 filename mangled"
py=/opt/prime-agent/kernel-venv/bin/python
pyenc=$("$py" -c 'import sys,locale;print(sys.getfilesystemencoding(),locale.getpreferredencoding(False),sys.stdout.encoding)')
[ "$pyenc" = "utf-8 UTF-8 utf-8" ] && ok "python fs/preferred/stdout encodings: $pyenc" || fail "python encodings: $pyenc"
nodeout=$(node -e 'process.stdout.write("Ünïcödé-日本\n")')
[ "$nodeout" = "Ünïcödé-日本" ] && ok "node writes UTF-8 unchanged" || fail "node output '$nodeout'"
[ "$(printf 'ÄÖ' | wc -m)" -eq 2 ] && ok "wc -m counts multibyte characters" || fail "wc -m is not UTF-8 aware"

# ---------------------------------------------------------------------------
log "Timezone: upstream cron follows TZ; tzdata serves Python and coreutils"
# ---------------------------------------------------------------------------
cat >"$WORK/tz.mjs" <<'EOF'
import { parseAgentCronSchedule, nextRunAtForSchedule } from "/opt/prime-agent/packages/coding-agent/dist/core/cron-jobs.js";
const after = new Date("2026-06-15T00:00:00Z");
const { schedule } = parseAgentCronSchedule("0 9 * * *", after);
const next = nextRunAtForSchedule(schedule, after);
process.stdout.write(`${schedule.kind} ${next.toISOString()}\n`);
EOF
tz_case() { # $1 = TZ, $2 = expected ISO
  local out; out=$(TZ="$1" node "$WORK/tz.mjs" 2>&1 || true)
  [ "$out" = "cron $2" ] && ok "TZ=$1: '0 9 * * *' after 2026-06-15T00:00Z -> $2" || fail "TZ=$1: got '$out', expected 'cron $2'"
}
tz_case UTC 2026-06-15T09:00:00.000Z
tz_case Asia/Tokyo 2026-06-16T00:00:00.000Z
tz_case America/New_York 2026-06-15T13:00:00.000Z
tz_case Europe/Berlin 2026-06-15T07:00:00.000Z
[ -f /usr/share/zoneinfo/Europe/Berlin ] && ok "tzdata installed (/usr/share/zoneinfo/Europe/Berlin)" || fail "tzdata missing"
pytz=$(TZ=Asia/Tokyo "$py" -c 'from zoneinfo import ZoneInfo; from datetime import datetime, timezone; print(datetime(2026,6,15,tzinfo=timezone.utc).astimezone(ZoneInfo("Asia/Tokyo")).strftime("%H:%M %Z"))')
[ "$pytz" = "09:00 JST" ] && ok "python zoneinfo via tzdata: $pytz" || fail "python zoneinfo: '$pytz'"
d=$(TZ=Asia/Tokyo date -u -d '2026-06-15T00:00:00Z' +%H 2>/dev/null; TZ=Asia/Tokyo date -d '2026-06-15T00:00:00Z' +%H)
[ "$d" = "$(printf '00\n09')" ] && ok "coreutils date honours TZ via tzdata" || fail "date TZ: '$d'"

# ---------------------------------------------------------------------------
log "Python kernel is baked and importable"
# ---------------------------------------------------------------------------
"$py" -c 'import rlm, dill, requests, httpx, yaml, tomli, dotenv, pandas, numpy, scipy, bs4, lxml, pydantic, tyro' && ok "default kernel imports" || fail "default kernel imports"
"$py" -c 'import edit, goal, compact, websearch, refine' && ok "bundled skill imports" || fail "bundled skill imports"
[ -f /opt/prime-agent/kernel-venv/.bootstrap-version ] && ok ".bootstrap-version present" || fail ".bootstrap-version missing"
[ ! -e /root/.cache/uv ] && ok "no uv cache in the image" || fail "/root/.cache/uv shipped"

# ---------------------------------------------------------------------------
log "Nothing build-only ships"
# ---------------------------------------------------------------------------
for p in /src /build /tmp/prime-agent-tarballs /root/.npm /root/.cache /verified-src; do
  [ ! -e "$p" ] && ok "absent: $p" || fail "present: $p"
done
[ -z "$(ls -A /var/lib/apt/lists 2>/dev/null | grep -v -E '^(lock|partial|auxfiles)$')" ] && ok "apt indexes removed" || fail "apt lists present: $(ls -A /var/lib/apt/lists)"
for m in vitest typescript @biomejs tsx esbuild; do
  [ ! -e "/opt/prime-agent/node_modules/$m" ] && ok "no dev module: $m" || fail "dev module shipped: $m"
done
[ -z "$(find /opt /usr/local/lib/prime-agent-container -name .git -print -quit)" ] && ok "no .git under /opt" || fail ".git under /opt"
[ ! -e /opt/prime-agent/packages/coding-agent/src ] && ok "no TypeScript source staged" || fail "src staged"
for tool in gcc make python3 npm-run-all; do command -v "$tool" >/dev/null 2>&1 && fail "build toolchain present: $tool" || ok "no $tool on PATH"; done

# ---------------------------------------------------------------------------
log "Licenses and notices"
# ---------------------------------------------------------------------------
for f in /usr/share/licenses/prime-agent/LICENSE /usr/share/licenses/podman/LICENSE /usr/share/licenses/uv/LICENSE-MIT \
         /usr/share/licenses/uv/LICENSE-APACHE /usr/share/licenses/prime-agent-docker/THIRD_PARTY_NOTICES.md \
         /usr/local/LICENSE /usr/local/lib/node_modules/npm/LICENSE; do
  [ -s "$f" ] && ok "$f ($(wc -c <"$f") bytes)" || fail "missing: $f"
done
grep -q '^MIT License' /usr/share/licenses/prime-agent/LICENSE && ok "Prime Agent license is MIT" || fail "Prime Agent license text"
cmp -s /usr/share/licenses/prime-agent/LICENSE /opt/prime-agent/LICENSE && ok "Prime Agent license identical to the staged copy" || fail "license copies differ"
for pkg in git openssh-client ripgrep fd-find curl iproute2 procps tzdata bash ca-certificates tar gzip; do
  [ -s "/usr/share/doc/$pkg/copyright" ] && ok "Debian copyright: $pkg" || fail "no Debian copyright for $pkg"
done
pyl=$(find /opt/prime-agent/python -maxdepth 4 -iname 'LICENSE*' | head -1)
[ -n "$pyl" ] && ok "managed CPython license: $pyl" || fail "no license under /opt/prime-agent/python"
# npm packages: every package dir carries package.json (metadata); count those
# that also ship a license file or declare one.
node - <<'EOF' | tee -a "$REPORT"
const fs = require("node:fs"), path = require("node:path");
const root = "/opt/prime-agent/node_modules";
const pkgs = [];
for (const e of fs.readdirSync(root)) {
  if (e.startsWith(".")) continue;
  const p = path.join(root, e);
  if (e.startsWith("@")) { for (const s of fs.readdirSync(p)) pkgs.push(path.join(p, s)); } else pkgs.push(p);
}
let meta = 0, licenseFile = 0, licenseField = 0, neither = [];
for (const p of pkgs) {
  if (!fs.existsSync(path.join(p, "package.json"))) continue;
  meta++;
  const hasFile = fs.readdirSync(p).some((f) => /^(licen[cs]e|copying|notice)/i.test(f));
  const j = JSON.parse(fs.readFileSync(path.join(p, "package.json"), "utf8"));
  const field = typeof j.license === "string" || Array.isArray(j.licenses);
  if (hasFile) licenseFile++;
  if (field) licenseField++;
  if (!hasFile && !field) neither.push(path.relative(root, p));
}
console.log(`  ok   npm packages: ${pkgs.length} dirs, ${meta} with package.json, ${licenseFile} ship a license/notice file, ${licenseField} declare a license field`);
if (neither.length) { console.log(`  FAIL npm packages without any license metadata: ${neither.join(", ")}`); process.exit(1); }
EOF
[ $? -eq 0 ] || failed=1
site=$(ls -d /opt/prime-agent/kernel-venv/lib/python3.*/site-packages)
dist=$(find "$site" -maxdepth 1 -name '*.dist-info' | wc -l)
meta=$(find "$site" -maxdepth 1 -name '*.dist-info' -exec test -f '{}/METADATA' \; -print | wc -l)
[ "$dist" -gt 0 ] && [ "$dist" -eq "$meta" ] && ok "python dists: $dist dist-info dirs, all with METADATA" || fail "python dist-info metadata: $meta/$dist"
lic=$(find "$site" -maxdepth 2 -path '*.dist-info/*' \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -path '*/licenses/*' \) | wc -l)
ok "python dists shipping license files under dist-info: $lic files"

# ---------------------------------------------------------------------------
log "Summary"
# ---------------------------------------------------------------------------
{
  printf 'image: prime-agent %s @ %s\n' "$version" "$revision"
  printf 'node %s, uv %s, podman-remote %s, git %s\n' "$(node --version)" "$UV_VERSION" "$PODMAN_VERSION" "$(git --version | cut -d' ' -f3)"
  printf 'kernel python %s\n' "$("$py" --version | cut -d' ' -f2)"
  printf 'staged /opt/prime-agent: %s\n' "$(du -sh /opt/prime-agent | cut -f1)"
} | tee -a "$REPORT"
if [ "$failed" -ne 0 ]; then echo "smoke-runtime: FAILED" | tee -a "$REPORT" >&2; exit 1; fi
echo "smoke-runtime: all checks passed" | tee -a "$REPORT"
