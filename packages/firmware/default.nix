{ lib, stdenvNoCC }:
# Firmware for the Pro1X, from https://github.com/sm6115-mainline/firmware-fxtec-qx1050 
stdenvNoCC.mkDerivation {
  pname = "firmware-fxtec-qx1050";
  version = "unstable-6c1ef5b";

  src = builtins.fetchGit {
    url = "https://github.com/sm6115-mainline/firmware-fxtec-qx1050.git";
    rev = "6c1ef5bce85750688f789bc6e232ca8237b24713";
  };

  dontBuild = true;
  dontFixup = true; 

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r lib $out/lib
    runHook postInstall
  '';

  meta = {
    description = "Proprietary firmware for the F(x)tec Pro1X (QX1050)";
    license = lib.licenses.unfree;
    platforms = lib.platforms.linux;
  };
}
