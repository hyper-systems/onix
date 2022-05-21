{ pkgs ? import <nixpkgs> { }, ocamlPackages ? pkgs.ocamlPackages }:

let
  onixPackages = import ./nix/onixPackages { inherit pkgs ocamlPackages; };
  api = import ./nix/api.nix { inherit pkgs onix; };
  onix = ocamlPackages.buildDunePackage {
    pname = "onix";
    version = "0.0.1";
    duneVersion = "3";

    passthru = { inherit (api) build lock; };

    src = ./.;

    nativeBuildInputs = [ pkgs.git ];
    propagatedBuildInputs = with onixPackages; [
      bos
      cmdliner
      fpath
      uri
      yojson
      opam-core
      opam-state
      opam-0install
    ];

    meta = {
      description = "Build OCaml projects with Nix.";
      homepage = "https://github.com/odis-labs/onix";
      license = pkgs.lib.licenses.isc;
      maintainers = [ ];
    };
  };
in onix
