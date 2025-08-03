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

          nix-build -E \
            "(import $JOB_DRV).all" \
            --out-link "$JOB_ATTR" \
            --max-jobs 0 \
            --impure \
            --use-sqlite-wal \
            --quiet || true
        '';

        cacheDownloadScriptFor =
          system: nixpkgs:
          hostPkgs.writeShellApplication {
            name = "great-value-hydra";
            text = ''
              set -euo pipefail

              if [[ ! -v MIN_MEM_PER_WORKER ]]; then
                MIN_MEM_PER_WORKER=2048
              fi

              if [[ ! -v HEADROOM ]]; then
                HEADROOM=2048
              fi
              if [[ ! -v DL_WORKERS ]]; then
                DL_WORKERS=0
              fi
              if [[ ! -v CACHE_GCROOTS_DIR ]]; then
                CACHE_GCROOTS_DIR="$(pwd)"
              fi

              echo "Great Value Hydra: it's just someone else's Hydra" >&2

              echo "Checking parallel" >&2
              if ! parallel --citation &>/dev/null </dev/null; then
                parallel --citation || exit $?
              fi

              echo "Determining optimal eval headroom" >&2

              # Determine the number of eval workers iteratively.
              num_workers="$(nproc)"
              mem_per_worker=0
              while [ "$num_workers" -gt 1 ]; do
                # Compute the memory to use for eval.
                total_mem="$(awk '/MemFree/ { printf "%d\n", int($2/1024) }' /proc/meminfo)"
                total_mem=$((total_mem - HEADROOM))

                # Compute the usable memory per worker.
                mem_per_worker=$((total_mem / num_workers))
                if [ "$mem_per_worker" -lt "$MIN_MEM_PER_WORKER" ]; then
                  # Converge
                  echo "rejected: $total_mem mem, $num_workers workers, $mem_per_worker mem per worker" >&2
                  num_workers=$(((num_workers * 7) / 8))
                else
                  break
                fi
              done

              if [ "$DL_WORKERS" -lt 1 ]; then
                DL_WORKERS="$num_workers"
              fi

              echo "Using $num_workers eval workers at $mem_per_worker MiB/worker ($((num_workers * mem_per_worker)) MiB, $HEADROOM MiB headroom)." >&2
              echo "Using $DL_WORKERS download workers." >&2

              nixpkgs_ver="${hostPkgs.lib.version}"
              root_dir="$CACHE_GCROOTS_DIR/$nixpkgs_ver/${system}"
              echo "Caching to $root_dir" >&2

              built_gcroots_dir="$root_dir/built"
              drv_gcroots_dir="$root_dir/drvs"
              drvinfo="$root_dir/drvinfo.json"

              mkdir -p "$root_dir" "$built_gcroots_dir" "$drv_gcroots_dir"

              if [ ! -f "$drvinfo" ]; then
                echo "Evaluating package set. This will take a long time and use a lot of memory." >&2
                echo "Note that processes dying here will probably cause a lot of problems." >&2
                nix_eval_jobs_log="$root_dir/nix-eval-jobs.log"

                nix-eval-jobs \
                  --force-recurse \
                  --impure \
                  --gc-roots-dir "$drv_gcroots_dir" \
                  --max-memory-size "$mem_per_worker" \
                  --workers "$num_workers" ${nixpkgs}/pkgs/top-level/release.nix > "$drvinfo" 2> >(tee -a "$nix_eval_jobs_log" >&2)
              fi

              filtered_drvinfo="$(mktemp -t great-value-hydra.XXXXXX)"
              jq -rc 'select(.error == null)' < "$drvinfo" | \
                sponge "$filtered_drvinfo" 2>/dev/null || true

              echo "Filtering drvinfo at $drvinfo ($(wc -l < "$filtered_drvinfo") packages)" >&2
              cleanup() {
                rm -f "$filtered_drvinfo"
              }
              trap cleanup EXIT

              echo "About to cache $(wc -l < "$filtered_drvinfo") packages. Godspeed." >&2

              pushd .
              cd "$built_gcroots_dir"

              nice -n 20 parallel \
                --bar --eta \
                -j"$DL_WORKERS" \
                ${runNixJob} '{}' <"$filtered_drvinfo"

              popd
            '';
            runtimeInputs = with hostPkgs; [
              jq
              parallel
              # has its own version of parallel, put it after
              moreutils
              gawk
              nix-eval-jobs
            ];
          };

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
              program = "${hostPkgs.lib.getExe self.packages.${system}.${program}}";
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
