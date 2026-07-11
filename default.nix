{
  lib,
  stdenv,
  fetchFromGitHub,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "fake-cli";
  version = "0-unstable-2026-07-11";
  __structuredAttrs = true;
  strictDeps = true;

  src = fetchFromGitHub {
    owner = "jakub-borusewicz";
    repo = "fake-cli";
    rev = "ec8984aa8c202f1777bb727f63489c97944df928";
    hash = "sha256-Vt5Q9X+8ZjJRyhH7RqYji104R9giJMWRG8FG2r6ZuMU=";
  };

  meta = {
    description = "";
    homepage = "https://github.com/jakub-borusewicz/fake-cli";
    license = lib.licenses.unfree; # FIXME: nix-init did not find a license
    maintainers = with lib.maintainers; [ ];
    mainProgram = "fake-cli";
    platforms = lib.platforms.all;
  };
})
