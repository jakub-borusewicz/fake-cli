# fake-cli

A tiny Nix library for building fake CLI binaries to use in tests. Point a
test at a `mkFakeCli`-built binary instead of the real `git`/`cue`/whatever:
every invocation gets logged (argv + stdin, as JSON) to a directory you
choose, and you can make it emit canned stdout, stderr, and an exit code —
globally or for one specific call.

## Disclaimer
This is low effort, vibecoded library. Use at your own risk.

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
