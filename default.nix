# Nix expressions to work on podenv
# Build release with: `PODENV_COMMIT=$(git show HEAD --format="format:%H" -q) nix-build --attr podenv --arg static true
{ withHoogle ? false, static ? false }:
let
  # pin the upstream nixpkgs
  nixpkgsPath = fetchTarball {
    url =
      "https://github.com/NixOS/nixpkgs/archive/d00b5a5fa6fe8bdf7005abb06c46ae0245aec8b5.tar.gz";
    sha256 = "08497wbpnf3w5dalcasqzymw3fmcn8qrnbkf8rxxwwvyjdnczxdv";
  };
  nixpkgsSrc = (import nixpkgsPath);

  # use gitignore.nix to filter files from the src and avoid un-necessary rebuild
  gitignoreSrc = pkgs.fetchFromGitHub {
    owner = "hercules-ci";
    repo = "gitignore.nix";
    # put the latest commit sha of gitignore Nix library here:
    rev = "211907489e9f198594c0eb0ca9256a1949c9d412";
    # use what nix suggests in the mismatch message here:
    sha256 = "sha256-qHu3uZ/o9jBHiA3MEKHJ06k7w4heOhA+4HCSIvflRxo=";
  };
  inherit (import gitignoreSrc { inherit (pkgs) lib; }) gitignoreSource;

  # fetch latest language server from easy-hls
  easyHlsSrc = pkgs.fetchFromGitHub {
    owner = "jkachmar";
    repo = "easy-hls-nix";
    rev = "a332d37c59fdcc9e44907bf3f48cf20b6d275ef4";
    sha256 = "1zwgg8qd33411c9rdlz1x7qv65pbw80snlvadifm4bm4avpkjhnk";
  };
  easyHls = pkgs.callPackage easyHlsSrc { ghcVersions = [ "8.10.4" ]; };

  # fetch the DHALL_PRELUDE to compile the podenv/hub without network access
  preludeSrc = pkgs.fetchFromGitHub {
    owner = "dhall-lang";
    repo = "dhall-lang";
    rev = "v17.0.0";
    sha256 = "0jnqw50q26ksxkzs85a2svyhwd2cy858xhncq945bmirpqrhklwf";
  };

  # update haskell dependencies
  compilerVersion = "8104";
  compiler = "ghc" + compilerVersion;
  haskellOverrides = {
    overrides = hpFinal: hpPrev: {
      # relude>1 featuer exposed modules
      relude = pkgs.haskell.lib.overrideCabal hpPrev.relude {
        version = "1.0.0.1";
        sha256 = "0cw9a1gfvias4hr36ywdizhysnzbzxy20fb3jwmqmgjy40lzxp2g";
      };

      podenv =
        (hpPrev.callCabal2nix "podenv" (gitignoreSource ./.) { }).overrideAttrs
        (_: {
          # Set build environment variable to avoid warnings
          LANG = "en_US.UTF-8";
          XDG_CACHE_HOME = "/tmp";
          # Provide a local dhall prelude because build can't access network
          DHALL_PRELUDE = "${preludeSrc}/Prelude/package.dhall";
          HUB_COMMIT = "${builtins.readFile ./.git/modules/hub/HEAD}";
          PODENV_COMMIT = builtins.getEnv "PODENV_COMMIT";
        });
    };
  };

  pkgsBase = nixpkgsSrc { system = "x86_64-linux"; };

  pkgs = (if static then pkgsBase.pkgsMusl else pkgsBase);

  # Borrowed from https://github.com/dhall-lang/dhall-haskell/blob/master/nix/shared.nix
  statify = (if static then
    drv:
    pkgs.haskell.lib.appendConfigureFlags
    (pkgs.haskell.lib.disableLibraryProfiling
      (pkgs.haskell.lib.disableSharedExecutables
        (pkgs.haskell.lib.justStaticExecutables
          (pkgs.haskell.lib.dontCheck drv)))) [
            "--enable-executable-static"
            "--extra-lib-dirs=${
              pkgs.ncurses.override {
                enableStatic = true;
                enableShared = true;
              }
            }/lib"
            "--extra-lib-dirs=${pkgs.gmp6.override { withStatic = true; }}/lib"
            "--extra-lib-dirs=${pkgs.zlib.static}/lib"
            "--extra-lib-dirs=${
              pkgs.pkgsMusl.libsodium.overrideAttrs
              (old: { dontDisableStatic = true; })
            }/lib"
            "--extra-lib-dirs=${
              pkgs.libffi.overrideAttrs (old: { dontDisableStatic = true; })
            }/lib"
          ]
  else
  # TODO: fix test and provides HUB_NIX_BUILDER environment variable
    drv: pkgs.haskell.lib.dontCheck drv);

  hsPkgs = pkgs.haskell.packages.${compiler}.override haskellOverrides;

in {
  podenv = statify hsPkgs.podenv;

  shell = hsPkgs.shellFor {
    packages = p: [ p.podenv ];
    buildInputs = with hsPkgs; [
      cabal-install
      hlint
      ghcid
      doctest
      easyHls.nixosDrv
    ];
    withHoogle = withHoogle;
  };
}
