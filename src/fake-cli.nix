# Builds a fake CLI binary for bats tests: by default it intercepts every
# invocation, logging its argv to a numbered file in a directory named by an env
# var; for selected argv patterns it can instead fall through to a real binary.
# It can also emit mock stdout / exit code set by the test. See
# .claude/skills/testing-cue for usage.
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
# A test then drives the fake via three env vars (defaults shown for name = "cue"):
#
#   CUE_CALLS_DIR       (required while intercepting) directory to log calls into;
#                        each call appends "$@" to its own zero-padded NNN.txt file.
#   CUE_MOCK_STDOUT      (optional) literal text the fake prints to stdout.
#   CUE_MOCK_EXIT_CODE   (optional, default 0) exit code the fake returns.
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
  mockExitCodeEnv ? null,
}:

let
  envPrefix = pkgs.lib.strings.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] name);
  callsDir = if callsDirEnv != null then callsDirEnv else "${envPrefix}_CALLS_DIR";
  mockStdout = if mockStdoutEnv != null then mockStdoutEnv else "${envPrefix}_MOCK_STDOUT";
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
pkgs.writeShellScriptBin name ''
  if ${passthroughWhen}; then
    ${passthrough}
  else
    dir="''${${callsDir}:?${callsDir} must be set}"
    mkdir -p "$dir"
    n=$(find "$dir" -maxdepth 1 -name "*.txt" | wc -l)
    echo "$@" > "$dir/$(printf '%03d' $((n + 1))).txt"

    if [ -n "''${${mockStdout}:-}" ]; then
      printf '%s' "''${${mockStdout}}"
    fi
    exit "''${${mockExitCode}:-0}"
  fi
''
