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
          JOB_DRV="$(realpath -- "$(${hostPkgs.lib.getExe hostPkgs.jq} -r '.drvPath' <<< "$JSON_LINE")")"

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
            if [ -z "$EVAL_WORKERS" ]; then
             EVAL_WORKERS="$(nproc)"
             EVAL_WORKERS=$((EVAL_WORKERS/4))
            fi
            if [ "$EVAL_WORKERS" -lt 8 ]; then
              EVAL_WORKERS=8
            fi
            if [ -z "$DL_WORKERS" ]; then
             DL_WORKERS="$(nproc)"
             DL_WORKERS=$((DL_WORKERS/4))
            fi
            if [ "$DL_WORKERS" -lt 1 ]; then
              DL_WORKERS=1
            fi
            if [ -z "$MEM_PER_EVAL_WORKER" ]; then
              MEM_PER_EVAL_WORKER=2048
            fi
            if [[ -z "$CACHE_GCROOTS_DIR" ]]; then
              CACHE_GCROOTS_DIR="$(pwd)"
            fi
            SHORT_NIX_VSN="${hostPkgs.lib.version}"

            echo "Great Value Hydra: it's just someone else's Hydra" >&2
            echo "Using $EVAL_WORKERS eval workers, $DL_WORKERS download workers" >&2

            set -euo pipefail

            ROOT_DIR="$CACHE_GCROOTS_DIR/$SHORT_NIX_VSN/${system}"
            echo "Caching to $ROOT_DIR" >&2
            BUILT_GCROOTS_DIR="$ROOT_DIR/built"
            DRV_GCROOTS_DIR="$ROOT_DIR/drvs"
            DRVINFO="$ROOT_DIR/drvinfo.json"

            mkdir -p "$BUILT_GCROOTS_DIR" "$DRV_GCROOTS_DIR"

            if [ ! -f "$DRVINFO" ]; then
              echo "Evaluating package set. This will take a long time and use a lot of memory." >&2

              ${hostPkgs.nix-eval-jobs}/bin/nix-eval-jobs \
                --force-recurse \
                --impure \
                --gc-roots-dir "$DRV_GCROOTS_DIR" \
                --max-memory-size "$MEM_PER_EVAL_WORKER" \
                --workers "$EVAL_WORKERS" ${nixpkgs}/pkgs/top-level/release.nix > "$DRVINFO"

              cat "$DRVINFO" | ${hostPkgs.lib.getExe hostPkgs.jq} -rc 'select(.error == null)' | \
                ${hostPkgs.moreutils}/bin/sponge "$DRVINFO" 2>/dev/null || true
            fi

            echo "About to cache $(cat "$DRVINFO" | wc -l) packages. Godspeed." >&2

            pushd .
            cd "$BUILT_GCROOTS_DIR"

            <"$DRVINFO" \
            nice -n 20 ${hostPkgs.parallel}/bin/parallel \
              --bar --eta \
              -j"$DL_WORKERS" \
              ${runNixJob} '{}'

            popd
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
