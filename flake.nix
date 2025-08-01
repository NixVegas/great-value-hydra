{
  description = "we have hydra at home :3";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    inputs:
    with inputs;
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        hostPkgs = nixpkgs.legacyPackages.${system};
        runNixJob = hostPkgs.writeShellScript "run-nix-job" ''
          JSON_LINE="$*"
          JOB_ATTR="$(${hostPkgs.lib.getExe hostPkgs.jq} -r '.attr' <<< "$JSON_LINE")"
          JOB_DRV="$(readlink -- "$(${hostPkgs.lib.getExe hostPkgs.jq} -r '.drvPath' <<< "$JSON_LINE")")"

          exec nix-build -E \
            "(import $JOB_DRV).all" \
            --out-link "$JOB_ATTR" \
            --max-jobs 0 \
            --impure \
            --use-sqlite-wal \
            --quiet || true
        '';

        cacheDownloadScriptFor =
          system: nixpkgs:
          hostPkgs.writeShellScript "cache-pkgs" ''
            if [ -z "$WORKERS" ]; then
             WORKERS="$(nproc)"
             WORKERS=$((WORKERS/4))
            fi
            if [ "$WORKERS" -lt 8 ]; then
              WORKERS=8
            fi
            if [ -z "$MEM_PER_WORKER" ]; then
              MEM_PER_WORKER=2048
            fi
            if [[ -z "$CACHE_GCROOTS_DIR" ]]; then
              CACHE_GCROOTS_DIR=$(pwd)
            fi
            SHORT_NIX_VSN="${hostPkgs.lib.version}"

            set -euo pipefail
            echo "Caching to $CACHE_GCROOTS_DIR/$SHORT_NIX_VSN/${system}/..."
            BUILT_GCROOTS_DIR="$CACHE_GCROOTS_DIR/$SHORT_NIX_VSN/${system}/built"
            DRV_GCROOTS_DIR="$CACHE_GCROOTS_DIR/$SHORT_NIX_VSN/${system}/drvs"

            mkdir -p "$BUILT_GCROOTS_DIR" "$DRV_GCROOTS_DIR"

            DRVINFO="$(mktemp)"
            echo "Evaluating package set"

            ${hostPkgs.nix-eval-jobs}/bin/nix-eval-jobs \
              --force-recurse \
              --impure \
              --gc-roots-dir "$DRV_GCROOTS_DIR" \
              --max-memory-size "$MEM_PER_WORKER" \
              --workers "$WORKERS" ${nixpkgs}/pkgs/top-level/release.nix > "$DRVINFO"

            cat "$DRVINFO" | ${hostPkgs.lib.getExe hostPkgs.jq} -rc 'select(.error == null)' | \
              ${hostPkgs.moreutils}/bin/sponge "$DRVINFO" 2>/dev/null || true

            echo "About to cache $(cat "$DRVINFO" | wc -l) packages"

            pushd .
            cd "$BUILT_GCROOTS_DIR"

            <$DRVINFO \
            nice -n 20 ${hostPkgs.parallel}/bin/parallel \
              --bar --eta \
              -j"$WORKERS" \
              ${runNixJob} '{}'

            popd
            rm $DRVINFO
          '';

      in
      {
        # legacyPackages exposed to give the cache download scripts an easy way to use the package
        # sets that they were built from
        legacyPackages = import nixpkgs {
          system = system;
          config.allowUnfree = true;
        };

        # Scripts to download everything, make GC roots
        packages = {
          cachePkgs = cacheDownloadScriptFor system nixpkgs;
          cacheSpicyPkgs = cacheDownloadScriptFor system nixpkgs-unstable;
        };

        apps =
          let
            mkApp = program: {
              program = "${self.packages.${system}.${program}}";
              type = "app";
            };
          in
          {
            cachePkgs = mkApp "cachePkgs";
            cacheSpicyPkgs = mkApp "cacheSpicyPkgs";
          };
      }
    );
}
