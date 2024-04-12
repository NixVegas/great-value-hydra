{
  description = "look ma, no hydra :3";
  inputs = {
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-23.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/master";
  };

  outputs = inputs: with inputs;
    let
      inherit (builtins) concatStringsSep concatMap deepSeq filter hashString seq substring tryEval;
      inherit (nixpkgs-stable.lib) attrsets isAttrs isDerivation strings;
      hostPkgs = nixpkgs-stable.legacyPackages.aarch64-linux;

      # isDerivation + isAttrs, but returns false on eval failure
      # NB: value attribute is just 'false' if tryEval encounters an exception
      isWellBehavedDerivationOrAttrs = x:
        let x' = (tryEval (seq (x ? name) x)).value;
         in isDerivation x' || isAttrs x';

      # :: attrset -> attrset
      # Takes a package set, spits out a shallow set mapping derivation attribute paths
      # onto empty sets.
      getPackagePathSet =
        let
          shouldDescend = attrs: attrs.recurseForDerivations or false;
          # All attributes of pkgs are either:
          # - derivations (we want these)
          # - attrsets with things we want (we want these)
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
            # Recurse into subsets, prepending name:
            subset = name: subPkgs:
              attrsets.mapAttrs'
                (subName: subValue: { name = "${name}.${subName}"; value = {}; })
                (getPackagePathSet subPkgs);
          };
          tryExtractPackages = name: value:
            handlers.${categorize value} name value;
        in
          attrsets.concatMapAttrs tryExtractPackages;

      # Extracts a list of attr paths to all packages in the provided set
      getPackagePaths = pkgs: attrsets.attrNames (getPackagePathSet pkgs);

    in {
      passthru.packages.aarch64-linux = import nixpkgs-stable {
        system = "aarch64-linux";
        config.allowUnfree = true;
      };

      packages.aarch64-linux.cacheArmPkgs = hostPkgs.writeShellScript
        "cacheArmPkgs"
        (let
           packagePaths = getPackagePaths self.passthru.packages.aarch64-linux;
         in ''
         CACHE_GCROOTS_DIR=$1
         if [[ -z "$CACHE_GCROOTS_DIR" ]]; then
           CACHE_GCROOTS_DIR=$(pwd)
         fi
         set -euo pipefail

         echo "Caching to $CACHE_GCROOTS_DIR"
         mkdir -p "$CACHE_GCROOTS_DIR/aarch64-linux"
         sleep 1
         echo "RIP your cellular plan..."
         ${concatStringsSep
             "\n"
             (map
               (path: "nix build '${self}#passthru.packages.aarch64-linux.${path}' --out-link \"$CACHE_GCROOTS_DIR/aarch64-linux/${path}\" --max-jobs 0 --builders \"\" || true")
               packagePaths)}
         '');

      apps.aarch64-linux.cacheArmPkgs = {
        type = "app";
        program = self.packages.aarch64-linux.cacheArmPkgs;
      };
  };
}
