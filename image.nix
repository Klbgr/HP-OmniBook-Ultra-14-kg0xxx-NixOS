{ config, lib, pkgs, modulesPath, ... }:

# Bootable USB image, built with systemd-repart: no VM involved.
let
  build = config.system.build;
  dtbs = config.hardware.deviceTree.package;
  cmdline = init: "init=${init} ${toString config.boot.kernelParams}";
  # Same command line with msm allowed to load.
  withMsm = lib.replaceStrings [ "module_blacklist=msm " ] [ "" ];
  base = cmdline "${build.toplevel}/init";
  kde = cmdline "${build.toplevel}/specialisation/kde/init";

  entry = title: options: entryDtb title "omnibook.dtb" options;
  entryDtb = title: dtb: options: pkgs.writeText "entry.conf" ''
    title      ${title}
    linux      /EFI/nixos/kernel
    initrd     /EFI/nixos/initrd
    devicetree /EFI/nixos/${dtb}
    options    ${options}
  '';
in
{
  imports = [ "${modulesPath}/image/repart.nix" ];

  image.repart = {
    enable = true;
    name = "omnibook-x2e";
    partitions = {
      "10-esp" = {
        contents = {
          "/EFI/BOOT/BOOTAA64.EFI".source = "${config.systemd.package}/lib/systemd/boot/efi/systemd-bootaa64.efi";
          "/EFI/nixos/kernel".source = "${build.kernel}/${config.system.boot.loader.kernelFile}";
          "/EFI/nixos/initrd".source = "${build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
          "/EFI/nixos/omnibook.dtb".source = "${dtbs}/${config.hardware.deviceTree.name}";
          "/EFI/nixos/omnibook-dp.dtb".source = "${dtbs}/qcom/mahua-hp-omnibook-ultra-kg0xxx-bringup-dp.dtb";
          "/loader/loader.conf".source = pkgs.writeText "loader.conf" ''
            timeout 10
            default omnibook-kde-msm.conf
          '';
          "/loader/entries/omnibook.conf".source =
            entry "NixOS tty" base;
          "/loader/entries/omnibook-msm.conf".source =
            entry "NixOS tty (msm)" (withMsm base);
          "/loader/entries/omnibook-kde.conf".source =
            entry "NixOS KDE (software rendering)" kde;
          "/loader/entries/omnibook-kde-msm.conf".source =
            entry "NixOS KDE (msm)" (withMsm kde);
          "/loader/entries/omnibook-kde-msm-dp.conf".source =
            entryDtb "NixOS KDE (msm, USB-C DP test)" "omnibook-dp.dtb" (withMsm kde);
        };
        repartConfig = {
          Type = "esp";
          Format = "vfat";
          Label = "ESP";
          SizeMinBytes = "512M";
        };
      };
      "20-root" = {
        storePaths = [ build.toplevel ];
        repartConfig = {
          Type = "root";
          Format = "ext4";
          Label = "nixos";
          Minimize = "guess";
        };
      };
    };
  };
}
