# fake-cli: distributable Nix package — design

Date: 2026-07-11

## Context

`src/fake-cli.nix` provides `mkFakeCli`, a Nix function that builds a fake CLI
binary for use in tests (originally bats, but framework-agnostic by design:
env vars in, files out). It intercepts every invocation, logs the call, and
can optionally pass through to a real binary or emit a canned stdout/exit
code.

The repo's `default.nix` is an unmodified `nix-init` stub: it fetches this
repo from GitHub by rev/hash and builds it with `stdenv.mkDerivation` as if
it were a compiled program producing a single `fake-cli` binary. That doesn't
match reality — this is a parameterized library, not a program — so it
doesn't actually work and needs to be replaced.

A prior conversation (linked by the user) confirmed there's no mature,
Nix-native package for this in the ecosystem — existing mocking libraries
(shellmock, bats-mock, bash_shell_mock) are all bash/bats-bound and build
PATH-shadowing stubs at test runtime rather than first-class Nix store paths.
That conversation ended with concrete suggestions for hardening the design
before publishing it, which this spec incorporates.

## Goals

1. Make `mkFakeCli` consumable as a real, distributable Nix package (flake +
   classic `default.nix`).
2. Apply the four functional improvements identified in the linked
   conversation.
3. Add tests for the package's behavior.
4. Add `README.md`, `CONTRIBUTING.md` (with a release procedure), and a
   GitHub Actions CI workflow.
5. Review the resulting package as a whole.

## Non-goals

- Publishing to nixpkgs proper.
- Multi-call assertion helpers, call-count matching, or an expectation DSL
  (the mature bash libraries' territory) — out of scope, YAGNI for now.
- Preserving the old `.txt` call-record format. This is a pre-1.0
  (`0-unstable`) package with no in-repo consumers, so the format change is
  a clean break, not a migration.

## Design

### 1. Package shape

- **`flake.nix`**: inputs `nixpkgs` (nixos-unstable) and `flake-utils`.
  Exposes, per system:
  - `lib.mkFakeCli` — the function itself.
  - `checks.default` — a derivation that runs the bats suite under
    `nix flake check`.
  - `devShells.default` — `bats` + `jq` for local iteration.
- **`default.nix`**: replaced with a thin classic-Nix entry point:
  ```nix
  { pkgs ? import <nixpkgs> { } }:
  import ./src/fake-cli.nix { inherit pkgs; }
  ```
  This mirrors the usage already documented in `src/fake-cli.nix`'s header
  comment and drops the broken self-fetch-from-GitHub stub.
- `src/fake-cli.nix` stays at its current path — no reason to move it.

### 2. Functional changes to `mkFakeCli`

- **Structured call records.** Replace `echo "$@" > NNN.txt` with
  `NNN.json` containing `{"argv": [...], "stdin": "..."}`, built via `jq` so
  argument boundaries and special characters survive (the old format lost
  boundaries on args containing spaces).
- **Stdin capture.** When stdin is not a tty (`[ -t 0 ]` guards against a
  manual interactive run hanging on `cat`), read it and include it in the
  call record.
- **Stderr mocking.** New `mockStderrEnv` parameter, mirroring
  `mockStdoutEnv`, defaulting to `${envPrefix}_MOCK_STDERR`.
- **Per-call overrides.** For stdout, stderr, and exit code, an env var
  suffixed with the 1-based call number (e.g. `CUE_MOCK_STDOUT_2`) overrides
  the global (unsuffixed) var for that specific call only. Resolution order
  per call: per-call var → global var → built-in default (empty output,
  exit 0).
- **Derivation builder.** Switch from `writeShellScriptBin` to
  `writeShellApplication` (adds `runtimeInputs = [ jq ]` wiring and
  shellcheck linting).

The public interface (`mkFakeCli { name, realPackage, passthroughWhen,
callsDirEnv, mockStdoutEnv, mockExitCodeEnv, mockStderrEnv }`) stays additive
— only the on-disk call-record format is a breaking change.

### 3. Tests

`tests/fake-cli.bats`, run via `nix flake check` and locally via
`nix develop -c bats tests/`. Coverage:

- Intercepting: call is logged as JSON with correct `argv`, including an arg
  containing a space (regression test for the old bug).
- Multiple calls: sequential `NNN.json` files, correctly zero-padded and
  numbered.
- Stdin capture: piped stdin appears in the call record; no stdin does not
  hang the test.
- Passthrough: `passthroughWhen` true routes to `realPackage`; false
  intercepts.
- No `realPackage` configured: refuses with exit 127 and a stderr message.
- Mock stdout / stderr / exit code: global vars apply to all calls.
- Per-call overrides: `_2`-suffixed var overrides the global for call 2
  only; call 1 and call 3 still see the global.
- Custom env var names via `callsDirEnv` / `mockStdoutEnv` /
  `mockExitCodeEnv` / `mockStderrEnv`.

### 4. Docs

- **`README.md`**: what/why (including the ecosystem-gap context), install
  (flake input or classic `default.nix`/`fetchTarball`), full API reference,
  env var contract, JSON call-record schema, a worked example (mirroring the
  existing header comment's `fake-git`/`fake-cue` examples), and a short
  note on the Nushell use case that motivated the framework-agnostic design.
- **`CONTRIBUTING.md`**: dev workflow (`nix develop`, `nix flake check`,
  `nixfmt`), PR expectations, and a release procedure — verify `nix flake
  check` is green, tag `vX.Y.Z`, push the tag, note how downstream flakes
  (`github:jakub-borusewicz/fake-cli/vX.Y.Z`) and classic Nix
  (`fetchTarball`/`fetchFromGitHub` pinned to the tag's rev+hash) consume a
  release.

### 5. CI

`.github/workflows/ci.yml`: on push and PR, install Nix (DeterminateSystems
nix-installer-action), run `nix flake check`.

### 6. Review

After implementation, review the package as a whole (structure, docs
accuracy, test coverage, and the flake/default.nix split) before handing
back.

## Testing/verification plan

Everything is verified for real, not just written: build the flake
(`nix flake check`), run the bats suite locally, and exercise `mkFakeCli`
manually for a couple of scenarios (space-containing args, per-call
override) to confirm the JSON output matches the schema documented in the
README.
