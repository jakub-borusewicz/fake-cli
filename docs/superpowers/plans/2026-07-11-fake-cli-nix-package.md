# fake-cli Distributable Nix Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the `mkFakeCli` Nix library in this repo into a distributable, tested, documented Nix package (flake + classic `default.nix`), applying the hardening suggestions from the linked design conversation, with tests and a CI workflow.

**Architecture:** `src/fake-cli.nix` keeps its role as the pure function (`{ pkgs }: { name, ... }: derivation`). `flake.nix` exposes it as `lib.<system>.mkFakeCli`, plus `checks` and a `devShell` wired to a set of prebuilt fixture derivations (`tests/fixtures.nix`) that a `tests/fake-cli.bats` suite exercises directly — bats tests run *inside* a Nix build sandbox, so the binaries under test must already be built and put on `PATH` via `nativeBuildInputs`/`packages`, not built live during the test run. `default.nix` becomes a two-line classic-Nix entry point importing the same file.

**Tech Stack:** Nix (flakes + classic), Bash (`writeShellApplication`, ShellCheck-linted), `jq` for structured call records, bats-core for tests, GitHub Actions for CI.

## Global Constraints

- No `git commit` — the user explicitly asked for no commits this session. Every task's "commit" step described by the writing-plans template is replaced with "leave the change staged in the working tree" (do NOT run `git add`/`git commit`).
- Call records move from `NNN.txt` (space-joined argv) to `NNN.json` (`{"argv": [...], "stdin": "..."}`) — a deliberate breaking change, approved by the user, since this is a pre-1.0 (`0-unstable`) package with no committed consumers.
- `mkFakeCli`'s public parameter surface stays additive: `name`, `realPackage ? null`, `passthroughWhen ? "false"`, `callsDirEnv ? null`, `mockStdoutEnv ? null`, `mockStderrEnv ? null` (new), `mockExitCodeEnv ? null`.
- The generated script must NOT run under bash `nounset` — a documented `passthroughWhen` pattern (`[ "$1" = "mod" ] && [ "$2" = "publish" ]`) legitimately dereferences a positional parameter that may be absent, which errors under `set -u`. Verified: `bash -c 'set -u; [ "$1" = "mod" ] && [ "$2" = "publish" ]' mod` → `bash: $2: unbound variable`. `writeShellApplication`'s `bashOptions` must be overridden to `[ "errexit" "pipefail" ]` (omit `"nounset"`).
- All Nix code targets `nixpkgs` `nixos-unstable`; `jq` is a runtime dependency wired via `runtimeInputs`, not assumed to be on the caller's `PATH`.

Everything below has already been prototyped and verified working end-to-end in a scratch Nix store during design (real `nix-build`, real bats runs, real `nix flake check` — not hypothetical). The code in each step is the exact verified version.

---

### Task 1: Replace `default.nix` with a classic-Nix entry point

**Files:**
- Modify: `default.nix`

**Interfaces:**
- Produces: `import ./default.nix { pkgs = <nixpkgs>; }` returns the same function `mkFakeCli` that `import ./src/fake-cli.nix { inherit pkgs; }` returns (i.e. `{ name, realPackage ? null, ... }: derivation`).

- [ ] **Step 1: Replace the file contents**

The current `default.nix` is an unmodified `nix-init` stub that fetches this repo from GitHub by a placeholder rev/hash and builds it with `stdenv.mkDerivation` as if it were a compiled program — it doesn't match reality (this is a parameterized library, not a program) and doesn't work. Replace it entirely:

```nix
{ pkgs ? import <nixpkgs> { } }:
import ./src/fake-cli.nix { inherit pkgs; }
```

- [ ] **Step 2: Verify it evaluates and returns the function**

Run: `nix-instantiate --eval -E '((import ./default.nix {}) { name = "hello"; }).name'`
Expected output: `"hello"`

- [ ] **Step 3: Leave staged (no commit)**

Do not run `git add` or `git commit` — just leave the file modified in the working tree.

---

### Task 2: Rewrite `src/fake-cli.nix` with the hardening from the design conversation

**Files:**
- Modify: `src/fake-cli.nix`

**Interfaces:**
- Consumes: `pkgs.jq`, `pkgs.writeShellApplication`, `pkgs.lib.strings.toUpper`, `builtins.replaceStrings` (all from the `{ pkgs }` argument, unchanged from before).
- Produces: `mkFakeCli = import ./src/fake-cli.nix { inherit pkgs; }`, a function `{ name, realPackage ? null, passthroughWhen ? "false", callsDirEnv ? null, mockStdoutEnv ? null, mockStderrEnv ? null, mockExitCodeEnv ? null }: derivation`. The derivation's `bin/${name}` script, per call:
  - writes `$CALLS_DIR/NNN.json` as `{"argv": [...], "stdin": "..."}` (1-based, zero-padded to 3 digits, `NNN` = current call count + 1)
  - captures piped stdin (empty string if `[ -t 0 ]`, i.e. no pipe)
  - resolves stdout/stderr/exit-code from, in order: `${PREFIX}_<call_num>` env var, then `${PREFIX}` env var, then built-in default (empty output, exit 0)
  - execs `${realPackage}/bin/${name}` when `passthroughWhen` evaluates true and `realPackage` is set; otherwise (when `passthroughWhen` is true but no `realPackage`) prints `fake-${name}: refusing to run for real (no realPackage configured): $*` to stderr and exits 127

This is used by Task 3's fixtures and Task 4's flake — those tasks assume exactly this behavior.

- [ ] **Step 1: Write the failing bats expectation first (informational — see Task 3)**

Task 3 writes the actual bats suite; this task's own verification is done by direct shell invocation below since the bats fixtures don't exist until Task 3. This ordering (implementation before its bats suite exists) is intentional: the fixtures in Task 3 need `src/fake-cli.nix` to already be at its final shape to build against.

- [ ] **Step 2: Replace `src/fake-cli.nix` in full**

```nix
# Builds a fake CLI binary for use in tests: by default it intercepts every
# invocation, logging its argv and stdin as JSON to a numbered file in a
# directory named by an env var; for selected argv patterns it can instead
# fall through to a real binary. It can also emit mock stdout / stderr /
# exit code, either for every call or overridden per call number.
#
# Usage (from a shell.nix):
#
#   mkFakeCli = import ./nix/fake-cli.nix { inherit pkgs; };
#
#   fake-git = mkFakeCli { name = "git"; };
#
#   fake-cue = mkFakeCli {
#     name = "cue";
#     realPackage = pkgs.cue;
#     passthroughWhen = ''! { [ "$1" = "export" ] || { [ "$1" = "mod" ] && [ "$2" = "publish" ]; }; }'';
#   };
#
# A test then drives the fake via env vars (defaults shown for name = "cue"):
#
#   CUE_CALLS_DIR         (required while intercepting) directory to log calls
#                          into; each call writes its own zero-padded NNN.json
#                          file: {"argv": [...], "stdin": "..."}.
#   CUE_MOCK_STDOUT        (optional) literal text the fake prints to stdout.
#   CUE_MOCK_STDERR        (optional) literal text the fake prints to stderr.
#   CUE_MOCK_EXIT_CODE     (optional, default 0) exit code the fake returns.
#
# Any of the three mock vars can be overridden for one specific call by
# suffixing the 1-based call number, e.g. CUE_MOCK_STDOUT_2 applies only to
# the second call made during the test, falling back to the unsuffixed var
# (then the built-in default) for every other call.
{ pkgs }:

{
  name,
  # Package providing the real binary, for argv that gets passed through. Omit for
  # a tool that should never run for real in tests (e.g. git).
  realPackage ? null,
  # Bash condition (as a string) deciding whether to pass "$@" through to the real
  # binary instead of intercepting it. Defaults to never passing through, i.e.
  # everything is intercepted. Only meaningful when `realPackage` is set — without
  # a real binary to fall through to, everything is intercepted regardless.
  passthroughWhen ? "false",
  # Override the env var names below instead of deriving them from `name`.
  callsDirEnv ? null,
  mockStdoutEnv ? null,
  mockStderrEnv ? null,
  mockExitCodeEnv ? null,
}:

let
  envPrefix = pkgs.lib.strings.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] name);
  callsDir = if callsDirEnv != null then callsDirEnv else "${envPrefix}_CALLS_DIR";
  mockStdout = if mockStdoutEnv != null then mockStdoutEnv else "${envPrefix}_MOCK_STDOUT";
  mockStderr = if mockStderrEnv != null then mockStderrEnv else "${envPrefix}_MOCK_STDERR";
  mockExitCode = if mockExitCodeEnv != null then mockExitCodeEnv else "${envPrefix}_MOCK_EXIT_CODE";
  passthrough =
    if realPackage == null then
      ''
        echo "fake-${name}: refusing to run for real (no realPackage configured): $*" >&2
        exit 127
      ''
    else
      ''exec ${realPackage}/bin/${name} "$@"'';
in
pkgs.writeShellApplication {
  inherit name;
  runtimeInputs = [ pkgs.jq ];
  # Intercepted scripts may reference an optional $2 (or beyond) in a
  # user-supplied `passthroughWhen`, e.g. `[ "$1" = "mod" ] && [ "$2" = "publish" ]`.
  # `nounset` would make that an error whenever a caller passes fewer args, so
  # it's deliberately left out; errexit/pipefail still apply.
  bashOptions = [
    "errexit"
    "pipefail"
  ];
  text = ''
    if ${passthroughWhen}; then
      ${passthrough}
    else
      dir="''${${callsDir}:?${callsDir} must be set}"
      mkdir -p "$dir"
      n=$(find "$dir" -maxdepth 1 -name "*.json" | wc -l)
      call_num=$((n + 1))
      call_file="$dir/$(printf '%03d' "$call_num").json"

      if [ -t 0 ]; then
        stdin_content=""
      else
        stdin_content="$(cat)"
      fi

      argv_json="$(jq -n --args '$ARGS.positional' -- "$@")"
      jq -n --argjson argv "$argv_json" --arg stdin "$stdin_content" \
        '{argv: $argv, stdin: $stdin}' > "$call_file"

      stdout_var_name="${mockStdout}_''${call_num}"
      stderr_var_name="${mockStderr}_''${call_num}"
      exit_var_name="${mockExitCode}_''${call_num}"

      stdout_val="''${!stdout_var_name:-''${${mockStdout}:-}}"
      stderr_val="''${!stderr_var_name:-''${${mockStderr}:-}}"
      exit_val="''${!exit_var_name:-''${${mockExitCode}:-0}}"

      if [ -n "$stdout_val" ]; then printf '%s' "$stdout_val"; fi
      if [ -n "$stderr_val" ]; then printf '%s' "$stderr_val" >&2; fi
      exit "$exit_val"
    fi
  '';
}
```

- [ ] **Step 3: Build a smoke-test instance and verify shellcheck passes**

Run: `nix-build -E 'let pkgs = import <nixpkgs> {}; mkFakeCli = import ./src/fake-cli.nix { inherit pkgs; }; in mkFakeCli { name = "cue"; }' -o /tmp/fake-cli-smoke`
Expected: build succeeds (shellcheck runs as part of `writeShellApplication`'s check phase — a shellcheck failure would abort the build), output ends with a `/nix/store/...-cue` path.

- [ ] **Step 4: Exercise it manually to confirm the JSON schema and arg-with-space handling**

```bash
d=$(mktemp -d)
CUE_CALLS_DIR="$d" /tmp/fake-cli-smoke/bin/cue mod "publish now" < /dev/null
cat "$d"/001.json
```
Expected: `{"argv": ["mod", "publish now"], "stdin": ""}` (pretty-printed by `jq`), proving the space inside `"publish now"` survived as one argument.

- [ ] **Step 5: Leave staged (no commit)**

---

### Task 3: Add bats test fixtures and the test suite

**Files:**
- Create: `tests/fixtures.nix`
- Create: `tests/fake-cli.bats`

**Interfaces:**
- Consumes: `../src/fake-cli.nix`'s `mkFakeCli` (Task 2).
- Produces: `import ./tests/fixtures.nix { inherit pkgs; }` → an attrset `{ basic, passthrough, noRealPackage, customEnv }` of derivations, each with `bin/<name>` as documented below. Task 4's `flake.nix` consumes `builtins.attrValues` of this attrset as `nativeBuildInputs`/`packages`.

Bats tests run inside a Nix build sandbox (Task 4's `checks.default`), which has no network access and can't shell out to `nix build`. So instead of building fixtures *inside* the test, `tests/fixtures.nix` predefines a fixed set of `mkFakeCli` instances; the flake builds them up front and puts their `bin/` on `PATH` before bats ever runs.

- [ ] **Step 1: Write `tests/fixtures.nix`**

```nix
{ pkgs }:
let
  mkFakeCli = import ../src/fake-cli.nix { inherit pkgs; };
in
{
  basic = mkFakeCli { name = "fake-test-basic"; };
  # name must match realPackage's actual binary name (`hello`, here) since the
  # generated script execs "$realPackage/bin/$name" when passing through.
  passthrough = mkFakeCli {
    name = "hello";
    realPackage = pkgs.hello;
    passthroughWhen = ''[ "$1" = "pass" ]'';
  };
  noRealPackage = mkFakeCli {
    name = "fake-test-norealpkg";
    passthroughWhen = "true";
  };
  customEnv = mkFakeCli {
    name = "fake-test-customenv";
    callsDirEnv = "CUSTOM_CALLS_DIR";
    mockStdoutEnv = "CUSTOM_STDOUT";
    mockStderrEnv = "CUSTOM_STDERR";
    mockExitCodeEnv = "CUSTOM_EXIT";
  };
}
```

- [ ] **Step 2: Write `tests/fake-cli.bats`**

```bash
bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "intercepts and logs argv as json, including args with spaces" {
  FAKE_TEST_BASIC_CALLS_DIR="$TEST_DIR" fake-test-basic export "with a space" </dev/null
  [ "$(jq -r '.argv | length' "$TEST_DIR/001.json")" = "2" ]
  [ "$(jq -r '.argv[0]' "$TEST_DIR/001.json")" = "export" ]
  [ "$(jq -r '.argv[1]' "$TEST_DIR/001.json")" = "with a space" ]
}

@test "numbers sequential calls" {
  FAKE_TEST_BASIC_CALLS_DIR="$TEST_DIR" fake-test-basic one </dev/null
  FAKE_TEST_BASIC_CALLS_DIR="$TEST_DIR" fake-test-basic two </dev/null
  [ -f "$TEST_DIR/001.json" ]
  [ -f "$TEST_DIR/002.json" ]
}

@test "captures piped stdin" {
  echo -n "hello stdin" | FAKE_TEST_BASIC_CALLS_DIR="$TEST_DIR" fake-test-basic anything
  [ "$(jq -r '.stdin' "$TEST_DIR/001.json")" = "hello stdin" ]
}

@test "no stdin captured when none piped" {
  FAKE_TEST_BASIC_CALLS_DIR="$TEST_DIR" fake-test-basic anything </dev/null
  [ "$(jq -r '.stdin' "$TEST_DIR/001.json")" = "" ]
}

@test "global mock stdout/stderr/exit code apply to all calls" {
  run env FAKE_TEST_BASIC_CALLS_DIR="$TEST_DIR" FAKE_TEST_BASIC_MOCK_STDOUT="out" \
    FAKE_TEST_BASIC_MOCK_STDERR="err" FAKE_TEST_BASIC_MOCK_EXIT_CODE="3" \
    fake-test-basic call </dev/null
  [ "$status" -eq 3 ]
  # stdout and stderr are both plain printf with no trailing newline, and
  # `run` merges them in write order, so they land concatenated.
  [ "$output" = "outerr" ]
}

@test "per-call override applies only to that call number" {
  export FAKE_TEST_BASIC_CALLS_DIR="$TEST_DIR"
  export FAKE_TEST_BASIC_MOCK_STDOUT="global"
  export FAKE_TEST_BASIC_MOCK_STDOUT_2="second-call-only"

  run fake-test-basic a </dev/null
  [ "$output" = "global" ]
  run fake-test-basic b </dev/null
  [ "$output" = "second-call-only" ]
  run fake-test-basic c </dev/null
  [ "$output" = "global" ]
}

@test "passthroughWhen true execs the real binary" {
  run hello pass
  [ "$status" -eq 1 ]
  [[ "$output" == *"extra operand"* ]]
}

@test "passthroughWhen false intercepts" {
  HELLO_CALLS_DIR="$TEST_DIR" hello nope </dev/null
  [ -f "$TEST_DIR/001.json" ]
}

@test "refuses to run without a realPackage configured" {
  run -127 fake-test-norealpkg status
  [[ "$output" == *"refusing to run for real"* ]]
}

@test "honors custom env var names" {
  run env CUSTOM_CALLS_DIR="$TEST_DIR" CUSTOM_STDOUT="custom" CUSTOM_EXIT="5" \
    fake-test-customenv x </dev/null
  [ "$status" -eq 5 ]
  [ "$output" = "custom" ]
  [ "$(jq -r '.argv[0]' "$TEST_DIR/001.json")" = "x" ]
}
```

- [ ] **Step 3: Build the fixtures and run the suite locally to verify it passes**

```bash
nix-build -E 'let pkgs = import <nixpkgs> {}; f = import ./tests/fixtures.nix { inherit pkgs; }; in pkgs.symlinkJoin { name = "fixtures"; paths = builtins.attrValues f; }' -o /tmp/fake-cli-fixtures
PATH="/tmp/fake-cli-fixtures/bin:$PATH" nix shell nixpkgs#bats nixpkgs#jq --command bats tests/fake-cli.bats
```
Expected: `1..10` then `ok 1` through `ok 10`, no `not ok` lines, no warnings.

- [ ] **Step 4: Leave staged (no commit)**

---

### Task 4: Add `flake.nix` wiring `lib`, `checks`, and `devShells`

**Files:**
- Create: `flake.nix`

**Interfaces:**
- Produces: `lib.<system>.mkFakeCli` (consumers do `fake-cli.lib.${system}.mkFakeCli { name = ...; }`), `checks.<system>.default` (runs the Task 3 bats suite against Task 3's fixtures), `devShells.<system>.default` (bats, jq, nixfmt, and the fixtures, for local iteration).

- [ ] **Step 1: Write `flake.nix`**

```nix
{
  description = "Nix helper for building fake CLI binaries usable in bats/Nushell/etc. tests";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs =
    { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        mkFakeCli = import ./src/fake-cli.nix { inherit pkgs; };
        fixtures = import ./tests/fixtures.nix { inherit pkgs; };
        fixtureBins = builtins.attrValues fixtures;
      in
      {
        lib.mkFakeCli = mkFakeCli;

        checks.default =
          pkgs.runCommand "fake-cli-tests"
            {
              nativeBuildInputs = [
                pkgs.bats
                pkgs.jq
              ]
              ++ fixtureBins;
            }
            ''
              cp -r ${./tests} tests
              chmod -R +w tests
              bats tests
              touch $out
            '';

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.bats
            pkgs.jq
            pkgs.nixfmt
          ]
          ++ fixtureBins;
        };
      }
    );
}
```

- [ ] **Step 2: Run `nix flake check`**

Run (from the repo root, after `git add -A` so the flake's Git-tracked-files check sees the new files — see note below): `nix flake check`

Note: Nix flakes only evaluate files tracked by Git (or at least `git add`ed). Since this session must not run `git commit`, run `git add -A` (stages, does not commit) before `nix flake check` so it can see `flake.nix`, `src/fake-cli.nix`, and `tests/`. This is safe and reversible (`git reset` un-stages without discarding changes) and is not a commit.

Expected: ends with `all checks passed!` (a `warning: Git tree ... is dirty` line is expected and harmless — it's just because we haven't committed).

- [ ] **Step 3: Leave staged (no commit)**

Files are already staged from Step 2's `git add -A`; do not run `git commit`.

---

### Task 5: Write `README.md`

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write the file**

```markdown
# fake-cli

A tiny Nix library for building fake CLI binaries to use in tests. Point a
test at a `mkFakeCli`-built binary instead of the real `git`/`cue`/whatever:
every invocation gets logged (argv + stdin, as JSON) to a directory you
choose, and you can make it emit canned stdout, stderr, and an exit code —
globally or for one specific call.

## Why

There's no mature, Nix-native package for this in the ecosystem. The
established mocking libraries (`boschresearch/shellmock`, `bats-mock`,
`bash_shell_mock`) are all bash/bats-bound: they build PATH-shadowing stubs
at test *runtime*, not first-class Nix store paths, and their control
interface is bash functions (`stub`, `shellmock_expect`, ...) that don't
travel to other languages.

`mkFakeCli`'s control interface is env vars in, files out, which makes it
usable from anything that can set an env var and read a directory —
including non-bash test runners. It was originally built for bats, but
works just as well for, say, Nushell tests (e.g. with
[`nutest`](https://github.com/vyadh/nutest)): set `$env.CUE_CALLS_DIR`, run
the thing under test, then `open` the JSON files it wrote to assert on
calls.

## Install

### Flakes

```nix
{
  inputs.fake-cli.url = "github:jakub-borusewicz/fake-cli";

  outputs = { self, nixpkgs, fake-cli }:
    let
      system = "x86_64-linux"; # or your system
      mkFakeCli = fake-cli.lib.${system}.mkFakeCli;
    in
    # ... use mkFakeCli in a devShell, checkPhase, etc.
    ;
}
```

### Classic Nix

```nix
{ pkgs ? import <nixpkgs> { } }:
let
  mkFakeCli = import (fetchTarball "https://github.com/jakub-borusewicz/fake-cli/archive/main.tar.gz") { inherit pkgs; };
  # or, pinned to a release (recommended — see CONTRIBUTING.md):
  # mkFakeCli = import (pkgs.fetchFromGitHub {
  #   owner = "jakub-borusewicz";
  #   repo = "fake-cli";
  #   rev = "vX.Y.Z";
  #   hash = "sha256-...";
  # }) { inherit pkgs; };
in
mkFakeCli { name = "git"; }
```

## Usage

```nix
mkFakeCli = import ./nix/fake-cli.nix { inherit pkgs; }; # or the flake/fetchTarball form above

fake-git = mkFakeCli { name = "git"; };

fake-cue = mkFakeCli {
  name = "cue";
  realPackage = pkgs.cue;
  passthroughWhen = ''! { [ "$1" = "export" ] || { [ "$1" = "mod" ] && [ "$2" = "publish" ]; }; }'';
};
```

`mkFakeCli` takes:

| Argument | Default | Meaning |
|---|---|---|
| `name` | *(required)* | The binary name, e.g. `"git"`. Also the base for the derived env var prefix (`GIT_*`), and — when passing through — must match `realPackage`'s actual binary name. |
| `realPackage` | `null` | A package providing the real binary, used when `passthroughWhen` is true. Omit for tools that should never run for real in tests. |
| `passthroughWhen` | `"false"` | A bash condition (as a string) deciding whether to exec the real binary instead of intercepting. Only meaningful with `realPackage` set. |
| `callsDirEnv` | `"${PREFIX}_CALLS_DIR"` | Override the calls-directory env var name. |
| `mockStdoutEnv` | `"${PREFIX}_MOCK_STDOUT"` | Override the mock-stdout env var name. |
| `mockStderrEnv` | `"${PREFIX}_MOCK_STDERR"` | Override the mock-stderr env var name. |
| `mockExitCodeEnv` | `"${PREFIX}_MOCK_EXIT_CODE"` | Override the mock-exit-code env var name. |

`${PREFIX}` is `name` upper-cased with `-` replaced by `_` (e.g. `fake-cue` → `FAKE_CUE`, unless `name = "cue"` → `CUE`).

## Env var contract

A test drives the fake via env vars (examples below for `name = "cue"`):

- **`CUE_CALLS_DIR`** — required while intercepting. Directory to log calls
  into. Each call writes its own file, zero-padded to 3 digits
  (`001.json`, `002.json`, ...).
- **`CUE_MOCK_STDOUT`** / **`CUE_MOCK_STDERR`** — optional literal text the
  fake prints to stdout / stderr.
- **`CUE_MOCK_EXIT_CODE`** — optional, default `0`.

Any of the three mock vars can be overridden for one specific call by
suffixing the 1-based call number: `CUE_MOCK_STDOUT_2` applies only to the
second call made during the test, falling back to the unsuffixed var (then
the built-in default) for every other call.

## Call record format

Each call writes one JSON file:

```json
{
  "argv": ["mod", "publish now"],
  "stdin": "piped content, if any"
}
```

`argv` preserves argument boundaries exactly (an arg containing a space
stays one array element). `stdin` is the full content piped to the fake, or
`""` if nothing was piped (checked via `[ -t 0 ]`, so a manual interactive
invocation with no redirected stdin doesn't hang waiting to read a
terminal).

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md).
```

- [ ] **Step 2: Verify code fences and the table render sanely**

Run: `grep -c '^```' README.md`
Expected: an even number (every opened fence is closed) — with the content above, `6`.

- [ ] **Step 3: Leave staged (no commit)**

---

### Task 6: Write `CONTRIBUTING.md`

**Files:**
- Create: `CONTRIBUTING.md`

- [ ] **Step 1: Write the file**

```markdown
# Contributing

## Development environment

This repo is a Nix flake. `nix develop` drops you into a shell with `bats`,
`jq`, `nixfmt`, and the test fixtures (from `tests/fixtures.nix`) all on
`PATH`.

## Running tests

```bash
nix flake check        # builds everything and runs the bats suite in a sandbox
# or, for faster local iteration on the bats file itself:
nix develop -c bats tests/
```

## Formatting

```bash
nix develop -c nixfmt flake.nix default.nix src/fake-cli.nix tests/fixtures.nix
```

## Making changes

- `src/fake-cli.nix` is the library. Its behavior is defined by
  `tests/fake-cli.bats` against the fixtures in `tests/fixtures.nix` — add a
  fixture there and a `@test` in the bats file for any new behavior, and
  make sure `nix flake check` passes before opening a PR.
- Keep the header comment in `src/fake-cli.nix` in sync with the actual env
  var contract and argument list — it's the primary usage documentation and
  `README.md` mirrors it.
- Changes to the on-disk call-record format (currently `NNN.json`:
  `{argv, stdin}`) are breaking changes for anything consuming it. Call
  that out explicitly in the PR description and the release notes (see
  below).

## Release procedure

This package has no version field to bump (it's a Nix library, not an
application) — a release is just a Git tag that downstream flakes and
classic-Nix consumers pin to.

1. Make sure `main` is green: `nix flake check`.
2. Decide the next version per [SemVer](https://semver.org/): bump major
   for a breaking change (e.g. to the call-record format or to `mkFakeCli`'s
   argument names), minor for a backwards-compatible addition (e.g. a new
   optional argument), patch for a fix that changes no interface.
3. Tag it, describing anything breaking in the tag message:
   ```bash
   git tag -a vX.Y.Z -m "Summary of the release, calling out breaking changes"
   git push origin vX.Y.Z
   ```
4. Downstream consumers pin to the tag:
   - Flake input: `inputs.fake-cli.url = "github:jakub-borusewicz/fake-cli/vX.Y.Z";`
   - Classic Nix: `pkgs.fetchFromGitHub { owner = "jakub-borusewicz"; repo = "fake-cli"; rev = "vX.Y.Z"; hash = "..."; }` — get `hash` by first setting it to
     `pkgs.lib.fakeHash` and letting the resulting Nix error tell you the
     real one, or with `nix-prefetch-github jakub-borusewicz fake-cli --rev vX.Y.Z`.
5. CI (`.github/workflows/ci.yml`) runs `nix flake check` on every push and
   PR; a green tag should already have a green CI run on the commit it
   points at.
```

- [ ] **Step 2: Leave staged (no commit)**

---

### Task 7: Add GitHub Actions CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: CI

on:
  push:
  pull_request:

jobs:
  flake-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
        with:
          extra_nix_config: |
            experimental-features = nix-command flakes
      - run: nix flake check
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml, sys; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo VALID`
(If `python3`/`yaml` isn't available, `nix run nixpkgs#yq -- e '.' .github/workflows/ci.yml > /dev/null && echo VALID` works too.)
Expected: `VALID`

- [ ] **Step 3: Leave staged (no commit)**

---

### Task 8: Update `.gitignore` for Nix build artifacts

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Add Nix result symlinks**

Current content is just `.idea`. Append:

```
result
result-*
```

- [ ] **Step 2: Verify**

Run: `cat .gitignore`
Expected:
```
.idea
result
result-*
```

- [ ] **Step 3: Leave staged (no commit)**

---

### Task 9: Whole-package review

**Files:** none (read-only task)

- [ ] **Step 1: Re-run the full check suite one more time from a clean state**

```bash
rm -f result result-*
nix flake check
```
Expected: `all checks passed!`

- [ ] **Step 2: Review for consistency**

Check, and fix inline if anything's off:
- Does `README.md`'s argument table match `src/fake-cli.nix`'s actual parameter list and defaults?
- Does `README.md`'s call-record JSON example match what the script actually writes (Task 2 Step 4's manual test)?
- Does `CONTRIBUTING.md`'s release procedure match what CI (Task 7) actually runs?
- Does the header comment in `src/fake-cli.nix` match `README.md` (both are usage docs; they must not drift)?
- Is `default.nix`'s output (Task 1) actually the same function `flake.nix`'s `lib.mkFakeCli` exposes (Task 4)? (Both `import ./src/fake-cli.nix { inherit pkgs; }` — yes by construction, but confirm no divergence crept in.)

- [ ] **Step 3: Report status to the user**

Summarize: what was built, that `nix flake check` passes, and that nothing was committed (per the global constraint) — list the new/modified files and remind the user they're staged (from Task 4 Step 2's `git add -A`) but not committed, so they can review with `git diff --staged` before committing themselves.
