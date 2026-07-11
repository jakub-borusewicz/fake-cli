{ pkgs ? import <nixpkgs> { } }:
import ./src/fake-cli.nix { inherit pkgs; }
