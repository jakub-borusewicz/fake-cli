# Contributing

## Development environment

This repo is a Nix flake. `nix develop` drops you into a shell with `bats`,
`jq`, `nixfmt`, and the test fixtures (from `tests/fixtures.nix`) all on
`PATH`.

## Running tests

```bash
nix flake check -L     # builds everything and runs the bats suite in a sandbox
# or, for faster local iteration on the bats file itself:
nix develop -c bats tests/
```

The `-L` (`--print-build-logs`) flag matters: Nix hides successful build
output by default, so a plain `nix flake check` prints nothing for the bats
run even though it happened — `-L` streams it live. Also note that if
`src/fake-cli.nix` and `tests/` haven't changed since the last check, Nix
serves the cached (already-passing) result and skips the build entirely, so
you'll see no bats output at all even with `-L`. To force a real rerun,
change a test/source file or delete the cached output first:
`nix-store --delete "$(nix path-info .#checks.<system>.default)"`.

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
