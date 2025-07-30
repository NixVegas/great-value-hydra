{
  description = "we have hydra at home :3";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    nixpkgs-master.url = "github:nixos/nixpkgs/master";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = inputs: with inputs;
    flake-utils.lib.eachDefaultSystem (system: 
    let
      inherit (builtins) concatStringsSep concatMap filter seq tryEval;
      inherit (nixpkgs.lib) attrsets isAttrs isDerivation strings;
      hostPkgs = nixpkgs.legacyPackages.${system};
      runNixJob = hostPkgs.writeShellScript "run-nix-job"
        ''
        JSON_LINE="$@"
        JOB_ATTR=$(jq -r '.attr' <<< "$JSON_LINE")
        JOB_DRV=$(jq -r '.drvPath' <<< "$JSON_LINE")

        nix-build \
          "''${JOB_DRV}^*" \
          --out-link "$JOB_ATTR" \
          --max-jobs 0 \
          --impure \
          --use-sqlite-wal \
          --quiet || true
        '';

      cacheDownloadScriptFor = system: nixpkgs:
        hostPkgs.writeShellScript
          "cache-pkgs"
          ''
           CACHE_GCROOTS_DIR=$1
           if [[ -z "$CACHE_GCROOTS_DIR" ]]; then
             CACHE_GCROOTS_DIR=$(pwd)
           fi
           SHORT_NIX_VSN="${builtins.substring 0 5 hostPkgs.lib.version}"
           set -euo pipefail

           echo "Caching to $CACHE_GCROOTS_DIR/$SHORT_NIX_VSN/${system}/..."
           BUILT_GCROOTS_DIR="$CACHE_GCROOTS_DIR/$SHORT_NIX_VSN/${system}/built"
           DRV_GCROOTS_DIR="$CACHE_GCROOTS_DIR/$SHORT_NIX_VSN/${system}/drvs"

           mkdir -p "$BUILT_GCROOTS_DIR" "$DRV_GCROOTS_DIR"

           DRVINFO=$(mktemp)
           echo "Evaluating package set and dumping info to $DRVINFO"

           ${hostPkgs.nix-eval-jobs}/bin/nix-eval-jobs \
             --flake '${nixpkgs}#legacyPackages.${system}' \
             --impure \
             --gc-roots-dir "$DRV_GCROOTS_DIR" \
             --max-memory-size 2304 \
             --workers 32 \
           | jq -rc 'select(.error == null)' \
             >"$DRVINFO" 2>/dev/null || true

           pushd .
           cd "$BUILT_GCROOTS_DIR"

           <$DRVINFO \
           nice -n 20 ${hostPkgs.parallel}/bin/parallel \
             --bar --eta \
             -j3 \
             ${runNixJob} '{}'

           popd
           rm $DRVINFO
           '';

    in {
      # legacyPackages exposed to give the cache download scripts an easy way to use the package
      # sets that they were built from
      legacyPackages = import nixpkgs {
        system = system;
        config.allowUnfree = true;
      };

      # Scripts to download everything, make GC roots
      packages = {
        cacheArmPkgs = cacheDownloadScriptFor "aarch64-linux" nixpkgs;
        cacheX86Pkgs = cacheDownloadScriptFor "x86_64-linux" nixpkgs;
        cacheSpicyArmPkgs = cacheDownloadScriptFor "aarch64-linux" nixpkgs-master;
        cacheSpicyX86Pkgs = cacheDownloadScriptFor "x86_64-linux" nixpkgs-master;
      };

      apps =
        let mkApp = program: { inherit program; type = "app"; };
        in with self.packages.${system}; {
          cacheArmPkgs = mkApp cacheArmPkgs;
          cacheX86Pkgs = mkApp cacheX86Pkgs;
          cacheSpicyArmPkgs = mkApp cacheSpicyArmPkgs;
          cacheSpicyX86Pkgs = mkApp cacheSpicyX86Pkgs;
        };
  });
}
