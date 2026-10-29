# Qualcomm DIAG router (linux-msm/diag): talks to the modem's DIAG service over rpmsg
# and serves it to userspace tools.
#
# UNTESTED. First build: the hash below is a placeholder, Nix prints the real one;
# then pin `rev` to a commit instead of HEAD. If the build fails on a missing
# dependency, add it to buildInputs.
{ lib, stdenv, fetchgit, meson, ninja, pkg-config, qrtr, systemdLibs }:

stdenv.mkDerivation {
  pname = "qcom-diag";
  version = "unstable";

  src = fetchgit {
    url = "https://github.com/linux-msm/diag.git";
    rev = "23c12c167e93215853af4e59c021551767f6fec8";
    hash = "sha256-rDtXNYwXzd29iTv6ZXobX7WfTRruT6jGT7TQUIgiZPY=";
  };

  nativeBuildInputs = [ meson ninja pkg-config ];
  buildInputs = [ qrtr systemdLibs ];

  meta = {
    description = "Qualcomm DIAG router for the modem on mainline Linux";
    homepage = "https://github.com/linux-msm/diag";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
  };
}
