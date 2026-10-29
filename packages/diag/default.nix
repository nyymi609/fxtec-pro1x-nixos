# Qualcomm DIAG router (linux-msm/diag): talks to the modem's DIAG service over rpmsg
# (libudev) and QRTR, and serves it to userspace tools.
{ lib, stdenv, fetchgit, qrtr, systemdLibs }:

stdenv.mkDerivation {
  pname = "qcom-diag";
  version = "unstable";

  src = fetchgit {
    url = "https://github.com/linux-msm/diag.git";
    rev = "23c12c167e93215853af4e59c021551767f6fec8";
    hash = "sha256-rDtXNYwXzd29iTv6ZXobX7WfTRruT6jGT7TQUIgiZPY=";
  };

  buildInputs = [ qrtr systemdLibs ];

  makeFlags = [ "prefix=${placeholder "out"}" ];

  meta = {
    description = "Qualcomm DIAG router for the modem on mainline Linux";
    homepage = "https://github.com/linux-msm/diag";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
  };
}
