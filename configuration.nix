{ config, pkgs, lib, ... }:

let
  kde = {
    services.desktopManager.plasma6.enable = true;
    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
    };
    networking.networkmanager.enable = true;
    hardware.bluetooth.enable = true;

    # alsa-lib's built-in UCM path is alsa-ucm-conf; overriding that package
    # would rebuild everything linked against alsa-lib.
    environment.sessionVariables.ALSA_CONFIG_UCM2 = "${ucm2}";
    systemd.user.services.pipewire.environment.ALSA_CONFIG_UCM2 = "${ucm2}";
    systemd.user.services.wireplumber.environment.ALSA_CONFIG_UCM2 = "${ucm2}";

    # The 4-channel speaker sink is FL FR RL RR (woofers + tweeters); the
    # default psd upmix only sends the stereo difference to the rear pair.
    services.pipewire.extraConfig = lib.genAttrs [ "client" "pipewire-pulse" ] (_: {
      "99-omnibook-upmix"."stream.properties" = {
        "channelmix.upmix" = true;
        "channelmix.upmix-method" = "simple";
      };
    });

    # Mesa 26.2 lacks Mahua's Adreno X2-85 (kernel reports 0x165_44060030) and
    # falls back to llvmpipe; reuse Glymur's X2-85 entry (same registers, 3
    # slices). 0xffff....ff = any fuse id, any patch level.
    hardware.graphics.package = pkgs.mesa.overrideAttrs (old: {
      postPatch = (old.postPatch or "") + ''
        substituteInPlace src/freedreno/common/freedreno_devices.py \
          --replace-fail 'GPUId(chip_id=0xffff44070031, name="Adreno (TM) X2-85"),' \
            'GPUId(chip_id=0xffff44070031, name="Adreno (TM) X2-85"), GPUId(chip_id=0xffff440600ff, name="Adreno (TM) X2-85 (Mahua)"),'
      '';
    });

    environment.systemPackages = [ pkgs.easyeffects ];

    # SDDM refuses root logins.
    users.users.nixos = {
      isNormalUser = true;
      extraGroups = [ "wheel" "video" "networkmanager" ];
      initialPassword = "nixos";
    };
  };

  dspFw = "qcom/glymur/hp/omnibook-ultra-14-kg0xxx";

  # UCM looks up conf.d/<driver>/<card long name>.conf; alsa-ucm-conf only has
  # GLYMUR-CRD.conf (same four WSA8845 + VA DMIC layout and control names).
  ucm2 = pkgs.runCommand "alsa-ucm2-omnibook" { } ''
    cp -rs ${pkgs.alsa-ucm-conf}/share/alsa/ucm2 $out
    chmod -R u+w $out
    ln -s ../../Qualcomm/glymur/GLYMUR-CRD.conf \
      "$out/conf.d/glymur/HP-HPOmniBookUltraLaptop14_kg0xxx-ConfigID-8F03.conf"
  '';
in
{
  # UEFI bootloader setup
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Custom Linux Kernel + Lore Patch Series
  boot.kernelPackages = pkgs.linuxPackagesFor (pkgs.buildLinux {
    version = "7.3.0-rc6-next-20261009";
    modDirVersion = "7.3.0-rc6-next-20261009";

    src = pkgs.fetchgit {
      url = "https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git";
      rev = "next-20261009";
      hash = "sha256-z+dBVs06zR5Ll8kqEILmLz2DozLZF+DIWgbNHRSL1U4=";
    };

    kernelPatches = [
      {
        # 2/5 (glymur GMU compatible) and 5/5 (mahua.dtsi GPU/GMU) of
        # mahua-gpu-v1; 1/5, 3/5 and the bindings are in next-20261009.
        name = "mahua-gpu-v1-dt";
        patch = ./patches/mahua-gpu-v1-dt.patch;
      }
      {
        name = "glymur-mahua-hp-omnibook-ultra-kg0xxx";
        patch = ./patches/glymur-mahua-hp-omnibook-ultra-kg0xxx.patch;
      }
      {
        # Fixes on top of the board patch above; order matters.
        name = "glymur-mahua-hp-omnibook-ultra-kg0xxx-2";
        patch = ./patches/glymur-mahua-hp-omnibook-ultra-kg0xxx_2.patch;
      }
      {
        # Glymur DP PHY PLL programming (USB-C DisplayPort), v5 (11 patches).
        name = "glymur-dp-phy-pll-v5";
        patch = ./patches/glymur-dp-phy-pll-v5.patch;
      }
      {
        name = "dispcc-glymur-no-init-park";
        patch = ./patches/dispcc-glymur-no-init-park.patch;
      }
      {
        # Bjorn Andersson, 20260622-glymur-edp-phy-v1 (2 patches): eDP panel PHY.
        name = "phy-qcom-edp-v8";
        patch = ./patches/phy-qcom-edp-v8.patch;
      }
      {
        # Oleg Keri v3: fixes the Type-C orientation/mux reconfigure path.
        name = "qmp-combo-typec-callbacks-v3";
        patch = ./patches/qmp-combo-typec-callbacks-v3.patch;
      }
      {
        # Rahul Pon, from the Mahua OmniBook 5: unacked port notifications stop UCSI.
        name = "pmic-glink-altmode-ack-undescribed-ports";
        patch = ./patches/pmic-glink-altmode-ack-undescribed-ports.patch;
      }
      {
        # Bus clash / parity errors / detached speaker after SoundWire clock stop.
        name = "soundwire-qcom-irq-before-clock-gate-v2";
        patch = ./patches/soundwire-qcom-irq-before-clock-gate-v2.patch;
      }
      {
        # Report GMEM of the active slices only (Mahua has fused-off slices).
        name = "a8xx-gmem-active-slices-v2";
        patch = ./patches/a8xx-gmem-active-slices-v2.patch;
      }
      {
        # Extra DTB for the "KDE (msm, USB-C DP test)" boot entry.
        name = "mahua-bringup-usbc-dp";
        patch = ./patches/mahua-bringup-usbc-dp.patch;
      }
    ];

    defconfig = "defconfig";

    autoModules = false;
    ignoreConfigErrors = true;

    structuredExtraConfig = with lib.kernel; {
      EFI = yes;
      EFI_STUB = yes;         # Impératif pour que l'UEFI charge le binaire
      DRM_MSM = module;
      ARCH_QCOM = yes;
      OF = yes;
      STAGING = yes;

      # Everything below is built in on purpose: arm64 defconfig leaves most of
      # these at "m" (they are "default ARCH_QCOM" tristates), and every one of
      # them sits between reset and the NVMe showing up. Built in, stage 1 does
      # not have to carry them and cannot get the load order wrong.

      # TLMM, PDC, SPMI/PMIC, RPMh, clocks
      PINCTRL_MSM = yes;
      PINCTRL_GLYMUR = yes;
      QCOM_PDC = yes;
      SPMI = yes;
      SPMI_MSM_PMIC_ARB = yes;
      QCOM_SMEM = yes;
      QCOM_COMMAND_DB = yes;
      QCOM_RPMH = yes;
      REGULATOR_QCOM_RPMH = yes;
      COMMON_CLK_QCOM = yes;
      CLK_GLYMUR_GCC = yes;
      CLK_GLYMUR_TCSRCC = yes;

      # Interconnect: PCIe and USB refuse to probe without their NoC paths
      INTERCONNECT = yes;
      INTERCONNECT_QCOM = yes;
      INTERCONNECT_QCOM_RPMH = yes;
      INTERCONNECT_QCOM_BCM_VOTER = yes;
      INTERCONNECT_QCOM_GLYMUR = yes;

      # PCIe root complex + QMP PHYs (pcie3b_phy feeds the NVMe)
      PCI = yes;
      PCIEPORTBUS = yes;
      PCIE_QCOM = yes;
      PHY_QCOM_QMP = yes;
      PHY_QCOM_QMP_PCIE = yes;
      PHY_QCOM_QMP_PCIE_MULTIPHY = yes;
      # Cannot be built in: it "depends on DRM || DRM=n" and DRM is =m here,
      # and it selects DRM_AUX_BRIDGE. Not on the path to the root anyway.
      PHY_QCOM_QMP_COMBO = module;
      ARM_SMMU = yes;

      # Root filesystem (ext4, see fileSystems."/" below) and the ESP
      BLK_DEV_NVME = yes;
      EXT4_FS = yes;
      VFAT_FS = yes;

      # EFI variables go through uefisecapp, which needs the SCM allowlist
      # entry added by the board patch.
      QCOM_SCM = yes;
      QCOM_QSEECOM = yes;
      QCOM_QSEECOM_UEFISECAPP = yes;

      # Early console on the EFI framebuffer, for "earlycon" below
      SERIAL_EARLYCON = yes;

      # ath12k_dbg() output (modprobe ath12k debug_mask=...), for Wi-Fi bring-up
      ATH12K_DEBUG = yes;

      # arm64 defconfig leaves these off: BlueZ then has no RFCOMM (headset
      # HFP/HSP), no BNEP (PAN) and no LE-only features.
      BT_LE = yes;
      BT_RFCOMM = module;
      BT_RFCOMM_TTY = yes;
      BT_BNEP = module;
    };
  });

  # Bring-up variant of the HP OmniBook Ultra (Mahua) device tree: firmware-
  # configured eUSB2 repeaters and no USB-C DP (see the _2 patch, item 6).
  hardware.deviceTree = {
    enable = true;
    name = "qcom/mahua-hp-omnibook-ultra-kg0xxx-bringup.dtb";
  };

  boot.kernelParams = [
    # Bring-up console: earlycon=efifb prints before any DRM driver is up,
    # console=tty0 takes over once efifb/simpledrm or msm/kms is bound.
    "earlycon=efifb"
    "console=tty0"
    "ignore_loglevel"

    # Keep the console on the firmware framebuffer (the image's msm entries
    # drop this). pmic_glink_altmode/ucsi_glink are not blacklisted any more:
    # they load in the initrd (see boot.initrd below).
    "module_blacklist=msm"

    # The initrd boots the ADSP/CDSP from /fw; /lib there is the read-only
    # modules tree. Stage 2 resets the path to hardware.firmware (udev.nix).
    "firmware_class.path=/fw"

    # With msm off nothing consumes the panel/eDP PHY rails, and late
    # regulator cleanup would switch them off ~30 s into boot.
    "regulator_ignore_unused"

    # Qualcomm laptops still need these: without them the clock and power
    # domain frameworks turn off resources that firmware left on and that no
    # driver claims yet (PCIe and the panel among them).
    "clk_ignore_unused"
    "pd_ignore_unused"

    "panic=10"

    # The firmware offers PSCI SYSTEM_SUSPEND ("deep"); the last sleep attempt
    # never came back from it. Snapdragon laptops suspend with s2idle.
    "mem_sleep_default=s2idle"
  ];

  networking.hostName = "omnibook-x2e";
  services.getty.autologinUser = "root";
  hardware.enableRedistributableFirmware = true;

  # Device-specific, HP-signed firmware that linux-firmware doesn't ship
  # (ADSP/CDSP for audio, ath12k board file for Wi-Fi). Put the files in
  # nix/firmware/ using the /lib/firmware layout, e.g.
  # firmware/qcom/glymur/hp/omnibook-ultra-14-kg0xxx/qcadsp8480.mbn.
  hardware.firmware = lib.optional (builtins.pathExists ./firmware)
    (pkgs.runCommand "omnibook-firmware" { } ''
      mkdir -p $out/lib
      cp -r ${./firmware} $out/lib/firmware
    '');

  # Other Windows Wi-Fi board files, to swap in at runtime (see README).
  environment.etc = lib.mkIf (builtins.pathExists ./wlan-bdf) {
    "omnibook/wlan-bdf".source = ./wlan-bdf;
  };

  # No TPM node in glymur.dtsi/mahua.dtsi: without this both stages wait 90 s
  # for /dev/tpmrm0 (the systemd.mask= kernel args never reached the initrd).
  systemd.tpm2.enable = false;

  # s2idle resume hangs (white lock screen, dead tty): no suspend until fixed;
  # closing the lid only locks.
  # systemd.sleep.settings.Sleep = {
  #   AllowSuspend = "no";
  #   AllowHibernation = "no";
  #   AllowHybridSleep = "no";
  #   AllowSuspendThenHibernate = "no";
  # };
  # services.logind.settings.Login = {
  #   HandleLidSwitch = "lock";
  #   HandleLidSwitchExternalPower = "lock";
  #   HandleSuspendKey = "ignore";
  # };

  # French AZERTY; earlySetup also puts it in the initrd emergency shell.
  console.keyMap = "fr";
  console.earlySetup = true;
  services.xserver.xkb.layout = "fr";

  # KDE Plasma 6 (Wayland) as an opt-in specialisation with its own boot
  # entries; the base system stays a plain console to fall back to.
  specialisation.kde.configuration = kde;
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    google-chrome
    fastfetch
    btop
    (writeShellScriptBin "omnibook-diag" ''
      export PATH=${lib.makeBinPath [ coreutils util-linux gnugrep findutils systemd kmod alsa-utils mesa-demos pipewire wireplumber pulseaudio usbutils bluez edid-decode ]}:$PATH
      export ALSA_CONFIG_UCM2=${ucm2}
      ${builtins.readFile ./omnibook-diag.sh}
    '')
    powertop
    stress-ng
    vulkan-tools
  ];

  # Bring-up: root has no password, so sulogin refuses emergency/rescue mode
  # ("root account is locked"). Let it open a shell anyway.
  users.users.root.initialPassword = "nixos";
  systemd.services.emergency.environment.SYSTEMD_SULOGIN_FORCE = "1";
  systemd.services.rescue.environment.SYSTEMD_SULOGIN_FORCE = "1";

  system.stateVersion = "26.05";

  # GPT partition labels set by image.nix (systemd-repart).
  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/ESP";
    fsType = "vfat";
    # Bring-up: a failing ESP mount must not drop the whole boot to emergency.
    options = [ "nofail" "x-systemd.device-timeout=10s" ];
  };

  boot.initrd = {
    # Stage 1 is the systemd initrd; without this its emergency shell refuses
    # to open ("root account is locked"). Bring-up only.
    systemd.emergencyAccess = true;
    systemd.tpm2.enable = false;
    systemd.extraBin.dmesg = "${pkgs.util-linux}/bin/dmesg";
    systemd.extraBin.grep = "${pkgs.gnugrep}/bin/grep";

    # The whole PCIe/NVMe chain is built into the kernel above, so stage 1 has
    # nothing Qualcomm-specific left to load. Keeping the default module set
    # means a USB keyboard still works at the stage-1 rescue shell.
    availableKernelModules = [ "nvme" "uas" ];
    # Internal keyboard (HID-over-I2C on i2c0) for the initrd emergency shell;
    # i2c_hid_of cannot be built in while DRM=m.
    # USB PHYs: dwc3/xhci/usb-storage are built in but defer on these, so a
    # root on a USB stick never appears without them.
    kernelModules = [
      "i2c_qcom_geni"
      "i2c_hid_of"
      "phy_qcom_m31_eusb2"
      "phy_qcom_eusb2_repeater"
      "phy_qcom_qmp_combo"
      # USB-C orientation: pmic_glink_altmode tells the combo PHY which way the
      # plug is in. In the initrd its PHY re-init happens before root is
      # mounted; in stage 2 it stalled the live root stick.
      "qrtr"
      "qrtr_smd"
      "qcom_pd_mapper"
      "qcom_q6v5_pas"
      "pmic_glink"
      "pmic_glink_altmode"
      "ucsi_glink"
    ];
    # qcom_q6v5_pas also boots the ADSP/CDSP from the initrd.
    systemd.contents = lib.genAttrs
      (map (f: "/fw/${dspFw}/${f}")
        [ "qcadsp8480.mbn" "adsp_dtbs.elf" "qccdsp8480.mbn" "cdsp_dtbs.elf" ])
      (p: { source = ./firmware + lib.removePrefix "/fw" p; });
    allowMissingModules = true;
  };
}