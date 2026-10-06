#!/usr/bin/env bash
# Regenerate device/kernel/config.aarch64 from arm64 defconfig + pro1x.fragment
# using the kernel's own Kconfig (so dependencies are resolved correctly), then
# verify every requested option and every NixOS-required option.
#
#   ./scripts/gen-kernel-config.sh /path/to/linux   # checkout of the pinned kernel
#
# Needs: make, gcc, flex, bison, aarch64-linux-gnu-gcc (same compiler family as
# the build; compiler-dependent options are evaluated here).
set -euo pipefail

src="$(realpath "${1:?usage: $0 /path/to/linux}")"
root="$(cd "$(dirname "$0")/.." && pwd)"
frag="$root/device/kernel/pro1x.fragment"
out="$root/device/kernel/config.aarch64"
export ARCH=arm64 CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"

build="$(mktemp -d)"; trap 'rm -rf "$build"' EXIT
make -s -C "$src" O="$build" defconfig
grep -E '^(CONFIG_|# CONFIG_[A-Za-z0-9_]+ is not set)' "$frag" >> "$build/.config"
make -s -C "$src" O="$build" olddefconfig 2>&1 | grep -v "override: reassigning" || true

fail=0
check() { # name want(y|m|any)
  local got; got="$(sed -n "s/^CONFIG_$1=//p" "$build/.config")"
  case "$2" in
    any) [[ "$got" == y || "$got" == m ]] || { echo "NOT ENABLED: $1 (got '${got:-unset}')"; fail=1; } ;;
    *)   [[ "$got" == "$2" ]] || { echo "MISMATCH: $1 wanted $2, got '${got:-unset}'"; fail=1; } ;;
  esac
}

while IFS= read -r line; do
  if [[ "$line" =~ ^CONFIG_([A-Za-z0-9_]+)=(.*)$ ]]; then
    check "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  elif [[ "$line" =~ ^#\ CONFIG_([A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
    check "${BASH_REMATCH[1]}" ""   # must end up unset
  fi
done < <(grep -E '^(CONFIG_|# CONFIG_[A-Za-z0-9_]+ is not set)' "$frag")

# Required by NixOS (nixos/modules/system/boot/{kernel,systemd}.nix)
for o in DEVTMPFS CGROUPS INOTIFY_USER SIGNALFD TIMERFD EPOLL NET SYSFS PROC_FS \
         FHANDLE CRYPTO_USER_API_HASH CRYPTO_HMAC CRYPTO_SHA256 DMIID AUTOFS_FS \
         TMPFS_POSIX_ACL TMPFS_XATTR SECCOMP BLK_DEV_INITRD; do check "$o" any; done
check MODULES y; check BINFMT_ELF y

(( fail == 0 )) || { echo "config NOT written" >&2; exit 1; }
cp "$build/.config" "$out"
echo "wrote $out ($(wc -l < "$out") lines)"
