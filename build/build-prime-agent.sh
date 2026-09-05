#!/usr/bin/env bash
# Builder-stage script for the Prime Agent container image.
#
# Fetches the pinned upstream source by immutable commit, applies the
# version-checked container patch with zero fuzz, runs the relevant upstream
# tests plus the container assertions, builds with the exact lockfile, packs the
# four workspaces with `npm pack`, prunes to production dependencies, and stages
# a self-contained runtime tree under $STAGE_DIR. Nothing here reaches the final
# image except $STAGE_DIR.
#
# Required environment:
#   PRIME_AGENT_VERSION   release token, e.g. 0.9.1 or v0.9.1
#   PRIME_AGENT_REVISION  exactly 40 hexadecimal characters (the release commit)
# Optional:
#   SRC_DIR     (default /src)               where the source is extracted
#   STAGE_DIR   (default /opt/prime-agent)   staged runtime tree
#   TARBALL_DIR (default /tmp/prime-agent-tarballs)
#   PATCH_FILE  (default <script dir>/prime-agent-container.patch,
#                falling back to <script dir>/../prime-agent-container.patch)
#   SKIP_TESTS=1 to skip the test run (never in CI)
set -euo pipefail

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'build-prime-agent: %s\n' "$*" >&2; exit 1; }

script_dir=$(cd "$(dirname "$0")" && pwd)
SRC_DIR=${SRC_DIR:-/src}
STAGE_DIR=${STAGE_DIR:-/opt/prime-agent}
TARBALL_DIR=${TARBALL_DIR:-/tmp/prime-agent-tarballs}
if [ -z "${PATCH_FILE:-}" ]; then
  if [ -f "$script_dir/prime-agent-container.patch" ]; then
    PATCH_FILE="$script_dir/prime-agent-container.patch"
  else
    PATCH_FILE="$script_dir/../prime-agent-container.patch"
  fi
fi
TEST_ASSET_DIR="$script_dir/tests"

# ---------------------------------------------------------------------------
# Inputs are validated before they reach any URL or shell command.
# ---------------------------------------------------------------------------
version=${PRIME_AGENT_VERSION:?PRIME_AGENT_VERSION is required}
version=${version#v}
case "$version" in
  *[!0-9.]*|.*|*.|*..*|"") die "PRIME_AGENT_VERSION must be a plain X.Y.Z release token, got: ${PRIME_AGENT_VERSION}" ;;
esac
[ "$(printf '%s' "$version" | tr -cd '.' | wc -c)" -eq 2 ] || die "PRIME_AGENT_VERSION must be X.Y.Z, got: ${PRIME_AGENT_VERSION}"

revision=${PRIME_AGENT_REVISION:?PRIME_AGENT_REVISION is required}
case "$revision" in
  *[!0-9a-f]*|"") die "PRIME_AGENT_REVISION must be 40 lowercase hexadecimal characters" ;;
esac
[ "${#revision}" -eq 40 ] || die "PRIME_AGENT_REVISION must be exactly 40 characters, got ${#revision}"

arch=$(dpkg --print-architecture)
case "$arch" in
  amd64) ;;
  *) die "unsupported Debian architecture: $arch (only amd64 is built; arm64 is out of scope)" ;;
esac

for tool in node npm curl tar gzip patch; do
  command -v "$tool" >/dev/null 2>&1 || die "missing build tool: $tool"
done
[ -f "$PATCH_FILE" ] || die "patch file not found: $PATCH_FILE"
[ -d "$TEST_ASSET_DIR" ] || die "container test directory not found: $TEST_ASSET_DIR"

log "Prime Agent ${version} @ ${revision} on ${arch}, node $(node --version), npm $(npm --version)"

# ---------------------------------------------------------------------------
# Fetch by immutable commit and prove the archive is the requested release.
# ---------------------------------------------------------------------------
log "Downloading source archive"
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
archive_url="https://github.com/PrimeIntellect-ai/prime-agent/archive/${revision}.tar.gz"
curl -fsSL --retry 3 --retry-delay 2 -o "$SRC_DIR.tar.gz" "$archive_url"
# GitHub names a commit archive's single top-level directory after the full
# SHA; every member must live under it before it is stripped away.
tar -tzf "$SRC_DIR.tar.gz" >"$SRC_DIR.list"
archive_top=$(head -n 1 "$SRC_DIR.list")
[ "$archive_top" = "prime-agent-${revision}/" ] || die "archive top-level directory is '${archive_top}', expected prime-agent-${revision}/"
stray=$(grep -vc "^prime-agent-${revision}/" "$SRC_DIR.list" || true)
[ "$stray" -eq 0 ] || die "archive has ${stray} member(s) outside prime-agent-${revision}/"
rm -f "$SRC_DIR.list"
tar -xzf "$SRC_DIR.tar.gz" -C "$SRC_DIR" --strip-components=1
rm -f "$SRC_DIR.tar.gz"
cd "$SRC_DIR"
[ ! -e .git ] || die "unexpected .git in source archive"

log "Validating package versions"
DEV_PATHS_FILE=${DEV_PATHS_FILE:-/tmp/prime-agent-dev-paths.json}
export DEV_PATHS_FILE
node - "$version" <<'EOF'
const fs = require("node:fs");
const expected = process.argv[2];
const packages = {
	".": "prime-agent",
	"packages/ai": "@earendil-works/pi-ai",
	"packages/agent": "@earendil-works/pi-agent-core",
	"packages/tui": "@earendil-works/pi-tui",
	"packages/coding-agent": "@earendil-works/pi-coding-agent",
};
let failed = false;
for (const [dir, name] of Object.entries(packages)) {
	const pkg = JSON.parse(fs.readFileSync(`${dir}/package.json`, "utf8"));
	const ok = pkg.name === name && pkg.version === expected;
	console.log(`  ${ok ? "ok  " : "FAIL"} ${dir}: ${pkg.name}@${pkg.version}`);
	if (!ok) failed = true;
}
const lock = JSON.parse(fs.readFileSync("package-lock.json", "utf8"));
for (const name of Object.values(packages).filter((n) => n.startsWith("@"))) {
	const entry = lock.packages[`node_modules/${name}`];
	const ok = entry && entry.link === true;
	console.log(`  ${ok ? "ok  " : "FAIL"} lockfile links ${name} to the workspace`);
	if (!ok) failed = true;
}
const gitDeps = Object.entries(lock.packages).filter(([, e]) => typeof e.resolved === "string" && /^git\+|^git:|^github:/.test(e.resolved));
console.log(`  ${gitDeps.length === 0 ? "ok  " : "FAIL"} lockfile has ${gitDeps.length} git dependencies`);
if (gitDeps.length > 0) failed = true;

// Record npm's own dev-only classification from the pristine lockfile, before
// npm ci or npm prune can rewrite it. `dev: true` means "reachable exclusively
// through devDependencies", so this is the authority for the staged-tree leak
// check; names that are also production dependencies (jiti, @types/node) are
// correctly absent from this list.
const devPaths = Object.entries(lock.packages)
	.filter(([key, entry]) => key.includes("node_modules/") && entry.dev === true)
	.map(([key]) => key);
fs.writeFileSync(process.env.DEV_PATHS_FILE, JSON.stringify(devPaths));
console.log(`  ok   recorded ${devPaths.length} dev-only lockfile paths for the staged-tree check`);
if (failed) process.exit(1);
EOF

# ---------------------------------------------------------------------------
# Version-checked patch: zero fuzz, dry-run first, never partially applied.
# ---------------------------------------------------------------------------
log "Applying container patch $(basename "$PATCH_FILE")"
patch -p1 --fuzz=0 --forward --dry-run --batch <"$PATCH_FILE" >/dev/null \
  || die "container patch does not apply cleanly to Prime Agent ${version} @ ${revision}; refusing to build a mismatched patch"
patch -p1 --fuzz=0 --forward --batch --no-backup-if-mismatch <"$PATCH_FILE"
grep -q 'DEFAULT_IDLE_EVICTION_MINUTES = 0.1;' packages/coding-agent/src/core/settings-manager.ts \
  || die "patched idle eviction default not found"
grep -q 'withContainerAppendSystemPrompt(parsed.appendSystemPrompt)' packages/coding-agent/src/main.ts \
  || die "patched container config injection not found in runtimeConfigFromArgs"
grep -q 'withContainerSkills(resolveCliPaths(cwd, parsed.skills))' packages/coding-agent/src/main.ts \
  || die "patched container skill injection not found in runtimeConfigFromArgs"
grep -q 'default 90' packages/coding-agent/CHANGELOG.md \
  || die "upstream CHANGELOG must be preserved untouched"

log "Installing container test assertions"
cp "$TEST_ASSET_DIR"/*.test.ts packages/coding-agent/test/

# ---------------------------------------------------------------------------
# Install from the exact lockfile. HUSKY=0 only disables the git-hook prepare
# step; dependency install scripts (esbuild, koffi, ...) still run.
# ---------------------------------------------------------------------------
log "npm ci (lockfile, dev dependencies included for build and test)"
HUSKY=0 npm ci --no-audit --no-fund

log "Building the workspaces"
npm run build
bundle="packages/coding-agent/dist/bundle/cli.js"
[ -x "$bundle" ] || die "bundled CLI missing: $bundle"
[ -f packages/coding-agent/dist/prime-agent-runtime/pyproject.toml ] || die "dist/prime-agent-runtime missing"
[ -d packages/coding-agent/dist/skills ] || die "dist/skills missing"
# `--version` and `--help` are printed after upstream's stdout takeover, which
# redirects console output to stderr whenever stdin is not a TTY (main.ts:1082-1100
# resolves appMode to "print"). Public commands such as `status --json` dispatch
# before the takeover and keep writing to stdout. Merge both streams here.
built_version=$(node "$bundle" --version 2>&1 | tr -d '\r' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)
[ "$built_version" = "$version" ] || die "built CLI reports '${built_version}', expected ${version}"
# The patched helper must have been compiled into the shipped bundle, not only
# into src/ where the tests run.
grep -lq 'PRIME_AGENT_CONTAINER_CONFIG_DIR' packages/coding-agent/dist/bundle/*.js \
  || die "container config injection missing from dist/bundle"

# ---------------------------------------------------------------------------
# Relevant upstream tests plus the container assertions. This subset covers the
# settings default, idle-eviction sweep, argument parsing, runtime config
# merging, resource loading and system-prompt assembly; it needs no uv, network
# or Python kernel. Deliberately absent: test/settings-selector.test.ts (a TUI
# widget test that only uses idleEvictionMinutes as fixture data and races a
# lazy cli-highlight import against vitest's environment teardown) and
# test/agent-session-recursion.test.ts (boots the Python kernel). No retry is
# configured: a failure here must stop the image build.
# ---------------------------------------------------------------------------
if [ "${SKIP_TESTS:-0}" != "1" ]; then
  log "Running upstream and container tests"
  (
    cd packages/coding-agent
    npx vitest --run \
      test/settings-manager.test.ts \
      test/daemon-supervisor-eviction.test.ts \
      test/daemon-supervisor-admission.test.ts \
      test/args.test.ts \
      test/agent-session-config.test.ts \
      test/resource-loader.test.ts \
      test/system-prompt.test.ts \
      test/container-config.test.ts
  )
else
  log "SKIP_TESTS=1: tests skipped"
fi

# ---------------------------------------------------------------------------
# Pack the four built workspaces. Their upstream `files` declarations decide
# what ships; nothing is re-resolved from npm.
# ---------------------------------------------------------------------------
log "Restricting the root workspace list to the four production packages"
node - <<'EOF'
const fs = require("node:fs");
const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
pkg.workspaces = ["packages/ai", "packages/agent", "packages/tui", "packages/coding-agent"];
fs.writeFileSync("package.json", `${JSON.stringify(pkg, null, "\t")}\n`);
console.log(`  workspaces: ${pkg.workspaces.join(", ")}`);
EOF

log "npm pack"
rm -rf "$TARBALL_DIR"
mkdir -p "$TARBALL_DIR"
declare -A tarball_for
for dir in ai agent tui coding-agent; do
  name=$(node -p "require('./packages/$dir/package.json').name")
  expected="$TARBALL_DIR/$(printf '%s' "$name" | sed 's/^@//; s#/#-#')-${version}.tgz"
  npm pack "./packages/$dir" --pack-destination "$TARBALL_DIR" --silent >/dev/null
  [ -f "$expected" ] || die "npm pack did not produce $expected"
  tarball_for[$dir]=$expected
  printf '  %-13s %s (%s bytes)\n' "$dir" "$(basename "$expected")" "$(stat -c %s "$expected")"
done

log "npm prune --omit=dev"
npm prune --omit=dev --no-audit --no-fund
for link in node_modules/@earendil-works/*; do
  [ -L "$link" ] || die "expected workspace symlink, found: $link"
  printf '  %s -> %s\n' "$link" "$(readlink "$link")"
done
[ "$(ls node_modules/@earendil-works | wc -l)" -eq 4 ] || die "expected exactly four workspace links"

# npm's own view of the pruned tree is the authority for "nothing extraneous":
# packages that were only reachable through the dropped example workspaces
# (e.g. @anthropic-ai/sandbox-runtime) must be gone, and nothing may be missing.
log "npm ls --omit=dev (no extraneous or missing production packages)"
npm ls --all --omit=dev --json >/tmp/prime-agent-npm-ls.json 2>/dev/null || true
node - <<'EOF'
const fs = require("node:fs");
const tree = JSON.parse(fs.readFileSync("/tmp/prime-agent-npm-ls.json", "utf8"));
const problems = tree.problems ?? [];
let fatal = 0;
for (const problem of problems) {
	const isFatal = /^(extraneous|missing|invalid):/.test(problem);
	if (isFatal) fatal += 1;
	console.log(`  ${isFatal ? "FAIL" : "warn"} ${problem}`);
}
if (fatal > 0) process.exit(1);
console.log(`  ok   ${Object.keys(tree.dependencies ?? {}).length} top-level production packages, no extraneous/missing/invalid entries`);
EOF
rm -f /tmp/prime-agent-npm-ls.json

# ---------------------------------------------------------------------------
# Stage: production node_modules + the packed workspaces, linked exactly as npm
# linked them in the source tree.
# ---------------------------------------------------------------------------
log "Staging into $STAGE_DIR"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/packages"
cp -a node_modules "$STAGE_DIR/node_modules"
rm -rf "$STAGE_DIR/node_modules/@earendil-works"
mkdir -p "$STAGE_DIR/node_modules/@earendil-works"
for dir in ai agent tui coding-agent; do
  mkdir -p "$STAGE_DIR/packages/$dir"
  tar -xzf "${tarball_for[$dir]}" -C "$STAGE_DIR/packages/$dir" --strip-components=1
  # Production dependencies that npm could not hoist live next to the workspace
  # and are not part of the tarball; carry them over verbatim. Everything else
  # that accumulates there (vitest's .vite caches, scope directories emptied by
  # prune, an empty .bin) is build residue and must not be staged.
  nested="packages/$dir/node_modules"
  if [ -d "$nested" ]; then
    rm -rf "$nested"/.vite "$nested"/.vite-temp "$nested"/.vitest
    find "$nested" -mindepth 1 -type d -empty -delete
    if [ -n "$(ls -A "$nested" 2>/dev/null)" ]; then
      cp -a "$nested" "$STAGE_DIR/packages/$dir/node_modules"
      printf '  %s: kept nested node_modules: %s\n' "$dir" "$(ls -A "$nested" | tr '\n' ' ')"
    fi
  fi
  name=$(node -p "require('./packages/$dir/package.json').name")
  case "$name" in
    @earendil-works/*) ;;
    *) die "unexpected workspace package name: $name" ;;
  esac
  ln -s "../../packages/$dir" "$STAGE_DIR/node_modules/${name}"
done
rm -rf "$TARBALL_DIR"

# Upstream keeps its MIT license at the repository root only; no workspace
# tarball carries it. Ship it with the staged tree so the runtime image can
# install it under /usr/share/licenses without reaching back into the source.
grep -q '^MIT License' "$SRC_DIR/LICENSE" || die "upstream LICENSE is not the expected MIT text"
install -m 0644 "$SRC_DIR/LICENSE" "$STAGE_DIR/LICENSE"

# npm leaves the scope directory behind when it prunes the last package inside
# it (e.g. @biomejs after its dev-only CLI is removed). An empty scope directory
# is harmless but makes "no dev dependencies staged" ambiguous, so drop them.
empty_scopes=$(find "$STAGE_DIR" -type d -name '@*' -empty -print -delete | wc -l)
[ "$empty_scopes" -eq 0 ] || printf '  removed %s empty scope director%s left by npm prune\n' "$empty_scopes" "$([ "$empty_scopes" -eq 1 ] && echo y || echo ies)"

# ---------------------------------------------------------------------------
# Prove the staged tree is complete and self-contained.
# ---------------------------------------------------------------------------
log "Verifying staged tree"
# Residue from our own build/test steps must not ship. Third-party packages may
# legitimately publish files with such names (gaxios ships tsbuildinfo), so the
# tsbuildinfo/coverage rule applies only to the packed workspaces themselves,
# outside their node_modules; vitest caches are never legitimate anywhere.
residue=$( {
  find "$STAGE_DIR" \( -name '.vite' -o -name '.vite-temp' -o -name '.vitest' \) -print
  find "$STAGE_DIR/packages" -path '*/node_modules' -prune -o \( -name 'coverage' -o -name '*.tsbuildinfo' \) -print
} | head -10 || true)
[ -z "$residue" ] || die "build/test residue in staged tree:
$residue"
dangling=$(find "$STAGE_DIR" -xtype l | head -20 || true)
[ -z "$dangling" ] || die "dangling symlinks in staged tree:
$dangling"
for link in "$STAGE_DIR"/node_modules/@earendil-works/*; do
  target=$(readlink -f "$link")
  case "$target" in
    "$STAGE_DIR"/packages/*) printf '  ok   %s -> %s\n' "${link#"$STAGE_DIR"/}" "${target#"$STAGE_DIR"/}" ;;
    *) die "workspace link escapes the staged tree: $link -> $target" ;;
  esac
done

STAGE_DIR="$STAGE_DIR" SRC_DIR="$SRC_DIR" DEV_PATHS_FILE="$DEV_PATHS_FILE" node - <<'EOF'
const fs = require("node:fs");
const path = require("node:path");
const { createRequire } = require("node:module");
const stage = process.env.STAGE_DIR;
const src = process.env.SRC_DIR;
const coding = path.join(stage, "packages", "coding-agent");
let failed = false;
const check = (ok, message) => {
	console.log(`  ${ok ? "ok  " : "FAIL"} ${message}`);
	if (!ok) failed = true;
};

// Asset list: the entries upstream's release packer copies, plus package.json.
const packer = fs.readFileSync(path.join(src, "scripts", "pack-prime-agent-release.mjs"), "utf8");
const match = packer.match(/for \(const entry of \[([^\]]+)\]\)/);
if (!match) throw new Error("could not find the asset list in pack-prime-agent-release.mjs");
const assets = [...match[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
for (const entry of [...assets, "package.json", "dist/bundle/cli.js", "dist/index.js", "dist/prime-agent-runtime/pyproject.toml", "dist/skills"]) {
	check(fs.existsSync(path.join(coding, entry)), `staged coding-agent has ${entry}`);
}
for (const dir of ["ai", "agent", "tui"]) {
	check(fs.existsSync(path.join(stage, "packages", dir, "dist", "index.js")), `staged ${dir} has dist/index.js`);
}

// Metadata upstream's packer rewrites for the public release; the source
// package already carries the branding, only the bin key differs.
const pkg = JSON.parse(fs.readFileSync(path.join(coding, "package.json"), "utf8"));
check(pkg.piConfig?.name === "prime-agent", `piConfig.name is ${JSON.stringify(pkg.piConfig?.name)}`);
check(pkg.piConfig?.configDir === ".prime/agent", `piConfig.configDir is ${JSON.stringify(pkg.piConfig?.configDir)}`);
check(pkg.bin && pkg.bin.pi === "dist/bundle/cli.js" && !pkg.bin["prime-agent"], `bin exposes only "pi" (${JSON.stringify(pkg.bin)}); the container installs /usr/local/bin/prime-agent explicitly`);
check(pkg.scripts?.postinstall === "node postinstall.cjs", "postinstall script retained");
check(!JSON.stringify(pkg).includes("PRIME_AGENT_DOWNLOAD_BASE_URL") && !/https?:\/\/[^"]*\/releases\/v/.test(JSON.stringify(pkg.dependencies ?? {})), "no public-R2 dependency URLs");
check(!fs.existsSync(path.join(coding, "src")), "no source tree staged");

// Dev-dependency leak scan against npm's own classification. The lockfile marks
// an entry `dev: true` only when it is reachable exclusively through
// devDependencies, so it is the right authority: names like `jiti` (a direct
// production dependency of coding-agent) and `@types/node` (a production
// dependency of protobufjs) are dev dependencies of the root too, yet must stay.
const devPaths = JSON.parse(fs.readFileSync(process.env.DEV_PATHS_FILE, "utf8"));
const leaked = devPaths.filter((key) => fs.existsSync(path.join(stage, key)));
check(
	leaked.length === 0,
	`no dev-only dependencies staged (${devPaths.length} checked)${leaked.length ? `: ${leaked.slice(0, 10).join(", ")}` : ""}`,
);

// Externals: whatever bundle.mjs currently keeps out of the bundle.
const bundleScript = fs.readFileSync(path.join(src, "packages", "coding-agent", "scripts", "bundle.mjs"), "utf8");
const externalMatch = bundleScript.match(/external:\s*\[([^\]]+)\]/);
if (!externalMatch) throw new Error("could not find the external list in bundle.mjs");
const externals = [...externalMatch[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
const optional = new Set(Object.keys(pkg.optionalDependencies ?? {}));
const req = createRequire(path.join(coding, "dist", "bundle", "cli.js"));
for (const name of externals) {
	let resolved;
	try {
		resolved = req.resolve(`${name}/package.json`);
	} catch {
		resolved = undefined;
	}
	const inside = resolved !== undefined && resolved.startsWith(`${stage}${path.sep}`);
	if (inside) {
		check(true, `external ${name} resolves inside the staged tree`);
	} else if (optional.has(name) || !(name in (pkg.dependencies ?? {}))) {
		console.log(`  warn ${name} (optional/transitive external) not resolvable on this platform`);
	} else {
		check(false, `external ${name} must resolve inside the staged tree`);
	}
}
if (failed) process.exit(1);
EOF

log "Running the staged CLI with the source tree hidden"
mv "$SRC_DIR" "$SRC_DIR.hidden"
trap 'mv "$SRC_DIR.hidden" "$SRC_DIR" 2>/dev/null || true' EXIT
staged_cli="$STAGE_DIR/packages/coding-agent/dist/bundle/cli.js"
staged_version=$(cd / && PRIME_AGENT_BUILD_ID="$revision" node "$staged_cli" --version 2>&1 | tr -d '\r' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)
[ "$staged_version" = "$version" ] || die "staged CLI reports '${staged_version}', expected ${version}"
# A public command: its JSON must arrive on stdout, so capture stdout only.
staged_status=$(cd / && HOME=/tmp/prime-agent-build-home PRIME_AGENT_CODING_AGENT_DIR=/tmp/prime-agent-build-home/agent node "$staged_cli" status --json 2>/dev/null)
[ "$staged_status" = "[]" ] || die "staged CLI status --json returned on stdout: '$staged_status'"
rm -rf /tmp/prime-agent-build-home
mv "$SRC_DIR.hidden" "$SRC_DIR"
trap - EXIT
echo "  ok   --version -> $staged_version; status --json -> $staged_status"

log "Staged size"
du -sh "$STAGE_DIR" "$STAGE_DIR/node_modules" "$STAGE_DIR/packages" | sed 's/^/  /'
du -sh "$STAGE_DIR"/node_modules/* "$STAGE_DIR"/node_modules/@*/* 2>/dev/null | sort -rh | head -12 | sed 's/^/  /'
total_of() { find "$STAGE_DIR/packages" -name "$1" -print0 2>/dev/null | du -ch --files0-from=- 2>/dev/null | tail -1 | cut -f1; }
printf '  %s\tdeclaration files (*.d.ts) — kept: upstream ships them via `files: ["dist"]`\n' "$(total_of '*.d.ts')"
printf '  %s\tsource maps (*.map)\n' "$(total_of '*.map')"

log "Prime Agent ${version} staged at ${STAGE_DIR}"
