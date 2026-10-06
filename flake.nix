{
  description = "NixOS on the F(x)tec Pro1X (QX1050 / SM6115) with a mainline kernel";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;

      # Machines you can build on. The phone itself is always aarch64-linux.
      buildHosts = [ "x86_64-linux" "aarch64-linux" ];
      forBuildHosts = f: lib.genAttrs buildHosts f;
      overlay = import ./overlay.nix;

      # Kernel and U-Boot are cross-compiled on an x86_64 build host; the rest of the
      # system stays native aarch64 so it comes from cache.nixos.org (or binfmt/qemu).
      xc = (import nixpkgs {
        system = "x86_64-linux";
        overlays = [ overlay ];
        config.allowUnfree = true;
      }).pkgsCross.aarch64-multiplatform;

      aarch64 = import nixpkgs {
        system = "aarch64-linux";
        overlays = [ overlay ];
        config.allowUnfree = true; # Qualcomm firmware blobs
      };

      # Flashable artifacts of any system that uses nixosModules.default, built with
      # the tools of the build machine ("x86_64-linux" cross-compiles U-Boot).
      # Returns { flashScript, rootfsImg, ubootImg, flashUbootScript }.
      mkArtifacts = system: nixosConfig:
        import ./lib/artifacts.nix {
          inherit lib nixosConfig;
          hostPkgs = nixpkgs.legacyPackages.${system};
          uboot = if system == "x86_64-linux" then xc.pro1x-uboot else aarch64.pro1x-uboot;
        };

      # The example hosts. `<name>-xc` uses the cross-compiled kernel.
      mkExample = name: modules: cross: lib.nixosSystem {
        modules = [ self.nixosModules.default ]
          ++ lib.optional cross self.nixosModules.cross-kernel
          ++ modules;
      };

      examples = {
        minimal = [ self.nixosModules.host-minimal ];
        phosh = [ self.nixosModules.host-phosh ];
      };
    in
    {
      overlays.default = overlay;

      # mkImages "x86_64-linux" cfg -> { flash, flash-uboot, rootfs, uboot-img } for a plain
      # nixosSystem that imports nixosModules.default (see README).
      lib = {
        inherit mkArtifacts;
        mkImages = system: nixosConfig:
          let a = mkArtifacts system nixosConfig; in {
            flash = a.flashScript;
            flash-uboot = a.flashUbootScript;
            rootfs = a.rootfsImg;
            uboot-img = a.ubootImg;
          };
      };

      nixosModules = {
        hardware = ./modules/hardware.nix;
        audio = ./modules/audio.nix;
        camera = ./modules/camera.nix;
        keyboard = ./modules/keyboard.nix;
        modem = ./modules/modem.nix;
        usb-network = ./modules/usb-network.nix;
        default.imports = with self.nixosModules; [ hardware audio camera keyboard modem usb-network ];
        # Use on x86_64 build machines: kernel cross-compiled instead of built natively
        # (or emulated). Without it the kernel is built natively for aarch64.
        cross-kernel.pro1x.kernelPackage = xc.pro1x-kernel;
        # Ready-made configurations to import into your own host.
        host-minimal = ./hosts/minimal;
        host-phosh = ./hosts/phosh;
      };

      templates.default = {
        path = ./templates/host;
        description = "Your own Pro1X host built on this flake";
      };

      nixosConfigurations =
        lib.mapAttrs (n: m: mkExample n m false) examples
        // lib.mapAttrs' (n: m: lib.nameValuePair "${n}-xc" (mkExample n m true)) examples;

      packages = forBuildHosts (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          cfg = n: self.nixosConfigurations.${if system == "x86_64-linux" then "${n}-xc" else n};
          art = lib.mapAttrs (n: _: mkArtifacts system (cfg n)) examples;
        in
        {
          # U-Boot only (first install / recovery): ./result/bin/pro1x-flash-uboot
          uboot-img = art.minimal.ubootImg;
          flash-uboot = art.minimal.flashUbootScript;
          # nix run .#deploy -- <nixosConfiguration name> [phone-address]
          deploy = pkgs.writeShellScriptBin "pro1x-deploy" (builtins.readFile ./scripts/deploy.sh);
          kernel = xc.pro1x-kernel;
          uboot = xc.pro1x-uboot;
          firmware = aarch64.pro1x-firmware;
        }
        // lib.concatMapAttrs (n: a: { "flash-${n}" = a.flashScript; "rootfs-${n}" = a.rootfsImg; }) art);

      devShells = forBuildHosts (system: {
        default = nixpkgs.legacyPackages.${system}.mkShell {
          packages = with nixpkgs.legacyPackages.${system}; [ android-tools git nixpkgs-fmt python3 ];
        };
      });

      formatter = forBuildHosts (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
