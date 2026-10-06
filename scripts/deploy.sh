#!/usr/bin/env bash
# Update the phone over USB ethernet WITHOUT reflashing userdata.
#   ./scripts/deploy.sh [config] [phone]      defaults: phosh-xc 172.16.42.1
# `config` is any nixosConfigurations name of the flake in the current directory
# (built-in: minimal, phosh and their -xc cross-kernel variants; or your own).
# From your own flake: nix run github:<you>/fxtec-pro1x-nixos#deploy -- my-pro1x
#
# Builds the system, `nix copy`s it into the phone's store, makes it the system
# profile and writes its U-Boot entry (kernel, initrd, DTB, extlinux.conf) to /boot
# on the phone. After a reboot U-Boot boots the new generation; older ones stay in the
# U-Boot menu (hold volume-down). New files must be `git add`ed first (flakes only
# see tracked files). Add your ssh key to hosts/minimal to avoid password prompts.
set -euo pipefail

cfg="${1:-phosh-xc}"; host="${2:-172.16.42.1}"

top="$(nix build --no-link --print-out-paths ".#nixosConfigurations.$cfg.config.system.build.toplevel")"

nix copy --no-check-sigs --to "ssh-ng://nixos@$host" "$top"
ssh -t "nixos@$host" sudo nix-env -p /nix/var/nix/profiles/system --set "$top"
ssh -t "nixos@$host" sudo "$top/bin/switch-to-configuration" boot

echo
echo "system copied: $top"
echo "Reboot the phone: U-Boot boots the new generation."
echo "If U-Boot itself needs reflashing (first time / recovery), slot a only:"
echo "  nix build .#flash-uboot && ./result/bin/pro1x-flash-uboot"
