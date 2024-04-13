{
  description = "we have hydra at home :3";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = inputs: with inputs;
    flake-utils.lib.eachDefaultSystem (system: 
    let
      inherit (builtins) concatStringsSep concatMap filter seq tryEval;
      inherit (nixpkgs.lib) attrsets isAttrs isDerivation strings;
      hostPkgs = nixpkgs.legacyPackages.${system};

      # Check a package's meta attribute, throwing an error if it's not compatible with
      # the current system. This is the same check that stdenv.mkDerivation uses to raise
      # broken package / unsupported system / etc. errors.
      assertValidPkg =
        let
          assertValidity = (import "${nixpkgs}/pkgs/stdenv/generic/check-meta.nix" {
            config = hostPkgs.config // {
              # Don't assemble friendly error messages; we're ignoring them
              inHydra = true;
            };
            lib = nixpkgs.lib;
            hostPlatform = hostPkgs.hostPlatform;
          }).assertValidity;
        in pkg:
          assertValidity {
            meta = pkg.meta or {};
            attrs = pkg;
          };

      # isDerivation + isAttrs, but returns false if the derivation is broken, incompatible,
      # insecure, etc., as determined by the same .meta-based criteria used by
      # stdenv.mkDerivation.
      isWellBehavedDerivationOrAttrs = x:
        # NB: .value on tryEval output is 'false' if tryEval encounters an exception
        let x' = (tryEval (seq (assertValidPkg x) x)).value;
         in isDerivation x' || isAttrs x';

      # :: attrset -> attrset
      # Takes a package set, returns a shallow set mapping derivation attribute paths
      # onto empty sets.
      getPackagePathSet =
        let
          shouldDescend = attrs: attrs.recurseForDerivations or false;
          # All attributes of pkgs are either:
          # - derivations (we want these)
          # - attrsets containing things we want (we want these)
          # - crap (everything else, which we don't want)
          categorize = thing:
            if !(isWellBehavedDerivationOrAttrs thing) then "crap" else
            if isAttrs thing && shouldDescend thing    then "subset" else
            if isDerivation thing                      then "drv"
            else                                            "crap";
          handlers = {
            # Throw away:
            crap = _: _: {};
            # Remember derivations' names, throw away contents to save memory:
            drv = name: drv: { ${name} = {}; };
            # Recurse into package subsets, prepending subset's name to attrpath:
            subset = subsetName: subset:
              attrsets.mapAttrs'
                (pkgName: subValue: { name = "${subsetName}.${pkgName}"; value = {}; })
                (getPackagePathSet subset);
          };
          tryExtractPackages = name: value: handlers.${categorize value} name value;
        in
          attrsets.concatMapAttrs tryExtractPackages;

      # Extracts a list of attr paths to all packages in the provided set
      getPackagePaths = pkgs: attrsets.attrNames (getPackagePathSet pkgs);

      # Generate a script to download every well-behaved package for a given system
      # TODO: Add a little concurrency, this is excruciatingly slow
      cacheDownloadScriptFor = system:
        hostPkgs.writeShellScript
          "cache-pkgs"
          (let packagePaths = getPackagePaths self.legacyPackages.${system};
           in ''
           CACHE_GCROOTS_DIR=$1
           if [[ -z "$CACHE_GCROOTS_DIR" ]]; then
             CACHE_GCROOTS_DIR=$(pwd)
           fi
           set -euo pipefail

           echo "Caching to $CACHE_GCROOTS_DIR"
           mkdir -p "$CACHE_GCROOTS_DIR/${system}"
           sleep 1
           echo "RIP your cellular plan..."
           ${concatStringsSep
               "\n"
               (map
                 (path: "nix build '${self}#legacyPackages.${system}.${path}' --out-link \"$CACHE_GCROOTS_DIR/${system}/${path}\" --max-jobs 0 --builders \"\" || true")
                 packagePaths)}
           '');
    in {
      # legacyPackages exposed to give the cache download scripts an easy way to use the package
      # sets that they were built from
      legacyPackages = import nixpkgs {
        system = system;
        config.allowUnfree = true;
      };

      # Scripts to download everything, make GC roots
      packages = {
        cacheArmPkgs = cacheDownloadScriptFor "aarch64-linux";
        cacheX86Pkgs = cacheDownloadScriptFor "x86_64-linux";
      };

      apps =
        let mkApp = program: { inherit program; type = "app"; };
        in with self.packages.${system}; {
          cacheArmPkgs = mkApp cacheArmPkgs;
          cacheX86Pkgs = mkApp cacheX86Pkgs;
        };
  });
}
