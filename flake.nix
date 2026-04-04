{
  description = "ChameleonUltra firmware — build & flash";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        config.segger-jlink.acceptLicense = true;
      };

      # nrfutil with the two plugins we need — all fetched from nixpkgs cache,
      # no manual hash wrangling required.
      nrfutil = pkgs.nrfutil.passthru.withExtensions [
        "nrfutil-device"
        "nrfutil-nrf5sdk-tools"
      ];

      armGcc = pkgs.gcc-arm-embedded;

      # ── Firmware version ──────────────────────────────────────────────────
      # Edit these when you cut a release / tag your fork.
      fwVersion = {
        major = "2";
        minor = "1";
        git = "v2.1.0-nix";
      };

      # ── Build derivation ──────────────────────────────────────────────────
      firmware = pkgs.stdenv.mkDerivation {
        pname = "chameleon-ultra-firmware";
        version = fwVersion.git;

        src = ./.;

        nativeBuildInputs = [
          armGcc
          nrfutil
          pkgs.gnumake
        ];

        # Version overrides passed as make variables so they take precedence
        # over the git-describe calls in Makefile.defs (which fail without a
        # real git history in the sandbox).
        makeFlags = [
          "GIT_VERSION=${fwVersion.git}"
          "APP_FW_SEMVER=${fwVersion.major}.${fwVersion.minor}"
          "APP_FW_VER_MAJOR=${fwVersion.major}"
          "APP_FW_VER_MINOR=${fwVersion.minor}"
        ];

        env = {
          GNU_INSTALL_ROOT = "${armGcc}/bin/";
          GNU_VERSION = armGcc.version;
          CURRENT_DEVICE_TYPE = "ultra";
        };

        buildPhase = ''
          # nrfutil wants a writable HOME for its log file
          export HOME=$(mktemp -d)

          # Bootloader
          make -C firmware/bootloader -j $NIX_BUILD_CORES $makeFlags

          # Application
          make -C firmware/application -j $NIX_BUILD_CORES $makeFlags

          # Package DFU zip
          pushd firmware/objects

          cp ../nrf52_sdk/components/softdevice/s140/hex/s140_nrf52_7.2.0_softdevice.hex \
             softdevice.hex

          # App-only DFU (flashing onto an existing bootloader+softdevice)
          nrfutil nrf5sdk-tools pkg generate \
            --hw-version 0 \
            --key-file ../../resource/dfu_key/chameleon.pem \
            --application application.hex \
            --application-version 1 \
            --sd-req 0x0100 \
            ultra-dfu-app.zip

          # Full DFU (fresh device — bootloader + softdevice + app)
          nrfutil nrf5sdk-tools pkg generate \
            --hw-version 0 \
            --key-file ../../resource/dfu_key/chameleon.pem \
            --bootloader  bootloader.hex  --bootloader-version 1 \
            --application application.hex --application-version 1 \
            --softdevice  softdevice.hex \
            --sd-req 0x0100 --sd-id 0x0100 \
            ultra-dfu-full.zip

          popd
        '';

        installPhase = ''
          mkdir -p $out
          cp firmware/objects/ultra-dfu-app.zip  $out/
          cp firmware/objects/ultra-dfu-full.zip $out/
          cp firmware/objects/application.hex    $out/
          cp firmware/objects/bootloader.hex     $out/
        '';

        dontFixup = true;
      };

      # ── Flash script ──────────────────────────────────────────────────────
      flashScript = pkgs.writeShellApplication {
        name = "flash-chameleon";
        runtimeInputs = [
          nrfutil
          (pkgs.python3.withPackages (p: [ p.pyserial ]))
          pkgs.usbutils
        ];
        text = ''
          DFU_ZIP="${firmware}/ultra-dfu-app.zip"

          echo "Entering DFU mode..."
          if ! python3 resource/tools/enter_dfu.py 2>/dev/null; then
            echo "  Auto-entry failed — press B then plug in USB."
            echo "  LEDs 4 & 5 should blink when in DFU mode."
          fi

          echo "Waiting for DFU device (USB id 1915:521f)..."
          until lsusb | grep -q "1915:521f"; do sleep 1; done

          echo "Flashing $DFU_ZIP ..."
          nrfutil device program \
            --firmware "$DFU_ZIP" \
            --traits nordicDfu

          echo "Done."
        '';
      };

    in
    {
      packages.${system} = {
        default = firmware;
        firmware = firmware;
      };

      apps.${system}.flash = {
        type = "app";
        program = "${flashScript}/bin/flash-chameleon";
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          armGcc
          nrfutil
          (pkgs.python3.withPackages (p: [ p.pyserial ]))
          pkgs.gnumake
          pkgs.git
          pkgs.usbutils
        ];
        shellHook = ''
          export GNU_INSTALL_ROOT="${armGcc}/bin/"
          export GNU_VERSION="${armGcc.version}"
          export CURRENT_DEVICE_TYPE="ultra"
        '';
      };
    };
}
