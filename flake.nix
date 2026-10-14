{
  description = "NixOS for HP OmniBook Ultra 14-kg0xxx (Snapdragon X2 Elite, Mahua)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-linux";

      omnibook = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./configuration.nix ./image.nix ];
      };
    in
    {
      nixosConfigurations = { inherit omnibook; };

      # Raw GPT image for the USB stick (dd it). Built with systemd-repart
      # rather than make-disk-image, which fills the image inside a QEMU VM.
      packages.${system}.default = omnibook.config.system.build.image;
    };
}