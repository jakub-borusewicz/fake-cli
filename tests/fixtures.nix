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
