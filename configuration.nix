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

    # The 4-channel speaker sink is FL FR = tweeters, RL RR = woofers; the
    # default psd upmix only sends the stereo difference to the rear pair.
    services.pipewire.extraConfig = lib.genAttrs [ "client" "pipewire-pulse" ] (_: {
      "99-omnibook-upmix"."stream.properties" = {
        "channelmix.upmix" = true;
        "channelmix.upmix-method" = "simple";
      };
    }) // {
      # Stereo "Speakers" sink in front of the 4-channel one: clients that link
      # ports themselves (EasyEffects) only feed FL/FR, leaving the woofers silent.
      pipewire."60-omnibook-speakers"."context.modules" = [{
        name = "libpipewire-module-loopback";
        args = {
          "node.description" = "Speakers";
          "capture.props" = {
            "node.name" = "omnibook_speakers";
            "media.class" = "Audio/Sink";
            "audio.position" = [ "FL" "FR" ];
            "priority.session" = 2000;
          };
          "playback.props" = {
            "node.name" = "omnibook_speakers_output";
            "node.passive" = true;
            "audio.position" = [ "FL" "FR" ];
            "target.object" = "alsa_output.platform-sound.HiFi__Speaker__sink";
            "channelmix.upmix" = true;
            "channelmix.upmix-method" = "simple";
          };
        };
      }];
    };

    # Pro Audio opens the PCM without the UCM enable sequence (speaker paths
    # stay off), so it is silent.
    services.pipewire.wireplumber.extraConfig."51-omnibook-no-pro-audio" = {
      "monitor.alsa.rules" = [
        {
          matches = [{ "device.name" = "alsa_card.platform-sound"; }];
          actions.update-props."api.acp.disable-pro-audio" = true;
        }
        {
          # The raw sink only feeds the "Speakers" loopback; make that obvious.
          matches = [{ "node.name" = "alsa_output.platform-sound.HiFi__Speaker__sink"; }];
          actions.update-props = {
            "node.description" = "Speakers (raw 4-channel, do not use)";
            "priority.session" = 500;
          };
        }
      ];
    };

    # "Speakers" plays into the raw sink, so its volume scales everything: keep
    # it at 100% (the kernel still caps the amplifiers).
    systemd.user.services.omnibook-raw-speaker-volume = {
      description = "Set the raw 4-channel speaker sink to 100%";
      wantedBy = [ "default.target" ];
      after = [ "wireplumber.service" "pipewire-pulse.service" ];
      path = [ pkgs.pulseaudio pkgs.coreutils ];
      serviceConfig.Type = "oneshot";
      script = ''
        for _ in $(seq 30); do
          pactl set-sink-volume alsa_output.platform-sound.HiFi__Speaker__sink 100% && exit 0
          sleep 1
        done
      '';
    };

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

    # libinput treats touches starting in the outer 8 mm of the touchpad as
    # palms. The Apple quirk is the only switch that turns that off; it also
    # defaults to natural scrolling and two-finger right click (KDE can change both).
    environment.etc."libinput/local-overrides.quirks".text = ''
      [HP OmniBook Ultra 14 touchpad]
      MatchUdevType=touchpad
      MatchBus=i2c
      MatchVendor=0x06CB
      MatchProduct=0xD032
      ModelAppleTouchpad=1
    '';

    # SDDM refuses root logins.
    users.users.nixos = {
      isNormalUser = true;
      extraGroups = [ "wheel" "video" "networkmanager" "fastrpc" ];
      initialPassword = "nixos";
    };
  };

  dspFw = "qcom/glymur/hp/omnibook-ultra-14-kg0xxx";
  dspFiles = [ "qcadsp8480.mbn" "adsp_dtbs.elf" "qccdsp8480.mbn" "cdsp_dtbs.elf" ];

  # HP's Qualcomm driver pack (SoftPaq sp174082, public download): HP-signed
  # ADSP/CDSP firmware and the CDSP user libraries. Only unpacked, never run.
  hpDriverPack = pkgs.fetchurl {
    url = "https://ftp.hp.com/pub/softpaq/sp174001-174500/sp174082.exe";
    sha256 = "98fe80a7588e1c3cc4a460726c9907e28a1fd6e5f18669d9187554804002c7dd";
  };
  hpDsp = pkgs.runCommand "omnibook-hp-dsp" { nativeBuildInputs = [ pkgs._7zz ]; } ''
    7zz x -y -osp ${hpDriverPack} 'src/Driver/qcsubsys_ext_adsp8480_fix_listen_WHQL/*' \
      'src/Driver/qcnspmcdm8480/*' > /dev/null
    a=sp/src/Driver/qcsubsys_ext_adsp8480_fix_listen_WHQL c=sp/src/Driver/qcnspmcdm8480
    install -Dm444 -t $out/${dspFw} $a/qcadsp8480.mbn $a/adsp_dtbs.elf $c/qccdsp8480.mbn $c/cdsp_dtbs.elf
    install -Dm444 -t $out/dsp/cdsp $c/CDSP/*
    (cd $out && sha256sum -c --quiet) <<'SUMS'
    0b68b188aac54f7beecb3234c19e794092864a4690aafea20bf379643305bf93  ${dspFw}/qcadsp8480.mbn
    c1a69fe37eaff8759b22738f4d4b8e046e7b07fbccdfdc76554f0fa6b412b981  ${dspFw}/adsp_dtbs.elf
    acf13d29288d283793f418a36650e8a261eed927d30de109a59cb2210f458794  ${dspFw}/qccdsp8480.mbn
    9bee104a48d4aac647287d6c1454df170c1cff7158a2352711fd1e2163ea6d1d  ${dspFw}/cdsp_dtbs.elf
    61301ad82965b291d868989bf224ebe464501d38ea786c8f4ef3231eea6f22d5  dsp/cdsp/fastrpc_shell_3
    b65b25e7c399f5272920e5d2b9f3197164b9eb1818194cb44339bc89f603b1f8  dsp/cdsp/fastrpc_shell_unsigned_3
    SUMS
  '';

  # Files from extract-firmware.sh (newer Windows Update versions) win if present.
  dspFile = f:
    let p = ./firmware + "/${dspFw}/${f}"; in
    if builtins.pathExists p then p else "${hpDsp}/${dspFw}/${f}";

  fastrpc = pkgs.callPackage ./fastrpc.nix { };

  # CDSP process shells and DSP-side libraries, loaded from /usr/lib/dsp.
  dspShells = [
    (if builtins.pathExists ./dsp/cdsp
     then pkgs.runCommand "omnibook-cdsp-shells" { } "cp -r ${./dsp/cdsp} $out"
     else "${hpDsp}/dsp/cdsp")
  ];

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
    version = "7.4.0-rc1-next-20261102";
    modDirVersion = "7.4.0-rc1-next-20261102";

    src = pkgs.fetchgit {
      url = "https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git";
      rev = "next-20261102";
      hash = "sha256-1+ymJDfbviSIkoVDVb0d2Ui6wiMOdxne8TIurXe9UEk=";
    };

    kernelPatches = [
      {
        # 2/5 (glymur GMU compatible) and 5/5 (mahua.dtsi GPU/GMU) of
        # mahua-gpu-v1; 1/5, 3/5 and the bindings are in linux-next.
        name = "mahua-gpu-v1-dt";
        patch = ./patches/mahua-gpu-v1-dt.patch;
      }
      {
        # Board series v2 (3 patches), unchanged from the list.
        name = "glymur-hp-omnibook-ultra-kg0xxx-v2";
        patch = ./patches/glymur-hp-omnibook-ultra-kg0xxx-v2.patch;
      }
      {
        # v2 board moved to a .dtsi; Glymur (same DTB) and Mahua .dts on it.
        name = "mahua-hp-omnibook-ultra-kg0xxx";
        patch = ./patches/mahua-hp-omnibook-ultra-kg0xxx.patch;
      }
      {
        # New -bringup .dts on top: SCMI polling, CRD sound model, pcie4
        # refgen, USB host role, firmware-configured eUSB2 repeaters.
        name = "mahua-hp-omnibook-ultra-kg0xxx-local";
        patch = ./patches/mahua-hp-omnibook-ultra-kg0xxx-local.patch;
      }
      {
        # Glymur DP PHY PLL programming (USB-C DisplayPort), v6 (11 patches).
        name = "glymur-dp-phy-pll-v6";
        patch = ./patches/glymur-dp-phy-pll-v6.patch;
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
        # PCIe PHY REFGEN supplies (driver, binding, in-tree boards); ours are
        # in the board v2 (pcie3), Mahua (pcie3b) and local (pcie4) patches.
        name = "qmp-pcie-refgen-v3";
        patch = ./patches/qmp-pcie-refgen-v3.patch;
      }
      {
        # Suspend: USB GDSCs keep their state, xHCI survives s2idle resume.
        name = "gcc-glymur-usb-ret-on";
        patch = ./patches/gcc-glymur-usb-ret-on.patch;
      }
      {
        # Suspend / USB runtime resume with the M31 eUSB2 PHY.
        name = "glymur-usb-resume-hs-terminations";
        patch = ./patches/glymur-usb-resume-hs-terminations.patch;
      }
      {
        # Suspend: drop the CPU bwmon DDR vote so DDR can idle.
        name = "icc-bwmon-suspend";
        patch = ./patches/icc-bwmon-suspend.patch;
      }
      {
        # Suspend: no QSCRATCH access with clocks off when a cable changes.
        name = "dwc3-qcom-defer-vbus-override-v2";
        patch = ./patches/dwc3-qcom-defer-vbus-override-v2.patch;
      }
      {
        # USB-C DP: balanced runtime PM references across plug/unplug.
        name = "msm-dp-runtime-pm-per-plug-v3";
        patch = ./patches/msm-dp-runtime-pm-per-plug-v3.patch;
      }
      {
        name = "a8xx-gmem-base-v2";
        patch = ./patches/a8xx-gmem-base-v2.patch;
      }
      {
        # CDSP fastrpc context banks 12-14 had the wrong reg (SMMU faults).
        name = "glymur-fastrpc-cdsp-cb-reg-v5";
        patch = ./patches/glymur-fastrpc-cdsp-cb-reg-v5.patch;
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

      # arm64 defconfig leaves these off: BlueZ then has no RFCOMM (headset
      # HFP/HSP), no BNEP (PAN) and no LE-only features.
      BT_LE = yes;
      BT_RFCOMM = module;
      BT_RFCOMM_TTY = yes;
      BT_BNEP = module;

      # CPUCP mailbox (SCMI transport for CPU frequency) built in: as a module
      # the SCMI perf protocol never answers (Konrad Dybcio: "Timing"),
      # https://lore.kernel.org/linux-arm-msm/CAAnD8RZKDiv7eW=63HP+obgwXEUCvoQLNzC+xa3quy3P=PT-QA@mail.gmail.com/
      QCOM_CPUCP_MBOX = yes;

      NTFS3_FS = yes;
      EXFAT_FS = yes;
    };
  });

  # Bring-up variant of the HP OmniBook Ultra (Mahua) device tree: firmware-
  # configured eUSB2 repeaters (see the local patch). USB-C DP is on.
  hardware.deviceTree = {
    enable = true;
    name = "qcom/mahua-hp-omnibook-ultra-kg0xxx-bringup.dtb";
  };

  # scmi-cpufreq registers the boost OPPs (up to 4.72 GHz) but leaves them off.
  # /usr/lib/dsp is on libcdsprpc's default DSP search path (shells for the CDSP).
  systemd.tmpfiles.rules = [ "w /sys/devices/system/cpu/cpufreq/boost - - - - 1" ]
    ++ map (d: "L+ /usr/lib/dsp - - - - ${d}") dspShells;

  # FastRPC / NPU: libcdsprpc, its devices and the DMA heap it allocates from,
  # for members of the fastrpc group. The QNN libraries are not in the image.
  users.groups.fastrpc = { };
  boot.kernelModules = [ "system_heap" ];
  services.udev.extraRules = ''
    SUBSYSTEM=="misc", KERNEL=="fastrpc-cdsp*", GROUP="fastrpc", MODE="0660"
    SUBSYSTEM=="dma_heap", KERNEL=="system", GROUP="fastrpc", MODE="0660"
  '';

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

  # Device-specific firmware that linux-firmware doesn't ship: ath12k board
  # file for Wi-Fi (nix/firmware/ath12k) and the HP-signed ADSP/CDSP files.
  hardware.firmware = [
    (pkgs.runCommand "omnibook-firmware" { } ''
      mkdir -p $out/lib/firmware/${dspFw}
      cp -r ${./firmware/ath12k} $out/lib/firmware/ath12k
      ${lib.concatMapStrings (f: "cp ${dspFile f} $out/lib/firmware/${dspFw}/${f}\n") dspFiles}
    '')
  ];

  # No TPM node in glymur.dtsi/mahua.dtsi: without this both stages wait 90 s
  # for /dev/tpmrm0 (the systemd.mask= kernel args never reached the initrd).
  systemd.tpm2.enable = false;

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
      export PATH=${lib.makeBinPath [ coreutils util-linux gnugrep findutils systemd kmod alsa-utils mesa-demos pipewire wireplumber pulseaudio usbutils bluez edid-decode stress-ng ]}:$PATH
      export ALSA_CONFIG_UCM2=${ucm2}
      ${builtins.readFile ./omnibook-diag.sh}
    '')
    powertop
    stress-ng
    vulkan-tools
    alsa-utils
    _7zz
    fastrpc
    strace
    evtest
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

  # The stick doesn't support TRIM anyway.
  services.fstrim.enable = false;

  boot.initrd = {
    # Stage 1 is the systemd initrd; without this its emergency shell refuses
    # to open ("root account is locked"). Bring-up only.
    systemd.emergencyAccess = true;
    systemd.tpm2.enable = false;
    systemd.extraBin.dmesg = "${pkgs.util-linux}/bin/dmesg";
    systemd.extraBin.grep = "${pkgs.gnugrep}/bin/grep";
    # To inspect the stick when the root partition does not show up.
    systemd.extraBin.ls = "${pkgs.coreutils}/bin/ls";
    systemd.extraBin.lsblk = "${pkgs.util-linux}/bin/lsblk";
    systemd.extraBin.blkid = "${pkgs.util-linux}/bin/blkid";
    systemd.extraBin.sfdisk = "${pkgs.util-linux}/bin/sfdisk";
    # Shown on screen when root never appears; photograph it.
    systemd.services.omnibook-root-diag = {
      wantedBy = [ "emergency.target" ];
      before = [ "emergency.service" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        StandardOutput = "tty";
        TTYPath = "/dev/console";
      };
      script = ''
        set +e
        echo "=== omnibook-root-diag ==="
        ls -l /dev/disk/by-partlabel /dev/disk/by-id
        lsblk -o NAME,SIZE,TYPE,PARTLABEL,FSTYPE
        for d in /dev/sd?; do [ -e "$d" ] && sfdisk -l "$d"; done
        dmesg | grep -i -E 'sd[a-z]|usb [0-9]|gpt|uas|error|-71|-110' | grep -v -i -E 'efivars|ACPI'
        echo "=== end ==="
      '';
    };

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
    systemd.contents = lib.listToAttrs (map (f: {
      name = "/fw/${dspFw}/${f}";
      value.source = dspFile f;
    }) dspFiles);
    allowMissingModules = true;
  };
}