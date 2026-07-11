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
