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
