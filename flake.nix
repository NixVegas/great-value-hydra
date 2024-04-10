{
  description = "";
  inputs = {
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-23.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/master";
  };

  outputs = inputs: with inputs; {
    # hydraJobs.WHAT.SYSTEM = DERIVATION;
    hydraJobs = import "${inputs.nixpkgs-stable}/pkgs/top-level/release.nix" {
      supportedSystems = ["aarch64-linux"];
    };
  };
}
