{
  description = "";
  inputs = {
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-23.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/master";
  };

  outputs = inputs: with inputs;
    let
      inherit (builtins) concatStringsSep concatMap deepSeq filter hashString substring tryEval;
      inherit (nixpkgs-stable.lib) attrsets isAttrs isDerivation strings;
      hostPkgs = nixpkgs-stable.legacyPackages.aarch64-linux;
      # isDerivation, but returns false on eval failure
      # NB: value attribute is just 'false' if tryEval encounters an exception
      isWellBehavedDerivationOrAttrs = x:
        let x' = (tryEval (deepSeq x x)).value;
         in isDerivation x' || isAttrs x';

      # Hydra jobs for all of nixpkgs
      hydraReleaseJobsFor = system:
        import "${inputs.nixpkgs-stable}/pkgs/top-level/release.nix" {
          supportedSystems = [system];
          scrubJobs = false;
          nixpkgsArgs = {
            config.inHydra = false; # ???
            config.allowUnfree = true;
          };
        };

      # HACK: The rpi is memory-constrained. Don't try to build everything at once.
      # Instead, hash-bucket packages by attr names and operate on each hash bucket
      # independently to reduce peak memory usage.
      hashBucket = name: substring 0 2 (hashString "sha256" name);
      buckets =
        let
          alphabet =
            filter
              (str: str != "")
              (strings.splitString "" "0123456789abcdef");
        in
          concatMap
            (c1:
              (map (c2: "${c1}${c2}") alphabet))
              alphabet;

      # Everything that hydra would build, except that we exclude any packages that
      # we can't evaluate on the system in question
      # TODO: Name this better; it includes a .${system} attribute afterwards and that's
      # a little weird, dude
      allNixpkgsFor = {target, host ? target, bucket}:
        attrsets.filterAttrsRecursive
          (name: value:
            (hashBucket name == bucket) &&
            (isWellBehavedDerivationOrAttrs value))
          (hydraReleaseJobsFor target);

      # Produces a derivation that has a runtime dependency on every package for a given
      # system.
      giganticHideousSuperDerivationFor = {target, host ? target, bucket}@args:
        nixpkgs-stable.legacyPackages.aarch64-linux.writeTextFile {
          name = "everything-for-${target}";
          text =
            concatStringsSep
              "\n"
              (map
                #(pkg: toString (pkg.${target})) # FIXME HERE
                #(pkg: hostPkgs.lib.trace (attrsets.attrNames pkg) (toString (pkg.${target}))) # FIXME HERE
                (pkg: hostPkgs.lib.trace pkg (toString (pkg.${target}))) # FIXME HERE
                (attrsets.attrValues (allNixpkgsFor args)));
          allowSubstitutes = true;
        };
    in {
      # This checks out
      passthru = allNixpkgsFor { target = "aarch64-linux"; bucket = "00"; };

      packages.aarch64-linux =
        attrsets.genAttrs
          buckets
          (bucket: giganticHideousSuperDerivationFor {
            inherit bucket;
            target = "aarch64-linux";
          });

      # Auto-builds all arm package buckets and creates gcroots for them in current dir
      apps.aarch64-linux.cacheArmPkgs = {
        type = "app";
        program = hostPkgs.writeShellApplication {
          name = "cacheArmPkgs";
          text = ''
          echo "RIP your cellular plan"
          ${concatStringsSep
            "\n"
            (map
              (bucket: "nix build '${toString self}#${bucket}' --out-link 'aarch64-linux-${bucket}' --system aarch64-linux")
              buckets)}
        '';
          runtimeInputs = [hostPkgs.nix];
        };
      };

  };
}
