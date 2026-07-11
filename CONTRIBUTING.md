# Contributing

## Development environment

This repo is a Nix flake. `nix develop` drops you into a shell with `bats`,
`jq`, `nixfmt`, and the test fixtures (from `tests/fixtures.nix`) all on
`PATH`.

## Running tests

```bash
nix flake check                                  # the authoritative pass/fail signal (matches CI)
nix log .#checks.<system>.default                # see the bats output from that run
# or, for faster local iteration on the bats file itself:
nix develop -c bats tests/
```

`nix flake check` doesn't print the bats output to your terminal even
with `-L`/`--print-build-logs`: in an interactive terminal Nix's progress
UI clears a build's log lines once that build finishes successfully (only
a *failing* build's log is kept on screen). This is normal Nix behavior,
not a bug in the setup — `nix log` sidesteps it by fetching the log
straight from Nix's build-log store after the fact, which works whether
the check just built fresh or was served from cache. Replace `<system>`
with your platform, e.g. `aarch64-darwin` or `x86_64-linux`
(`nix eval --impure --expr builtins.currentSystem` prints yours). For
everyday iteration, `nix develop -c bats tests/` is simplest — it runs
bats directly in your shell instead of inside a Nix build sandbox, so you
always see live output.

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
