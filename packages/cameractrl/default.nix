{ lib
, stdenv
, fetchFromGitLab
, meson
, ninja
, pkg-config
, vala
, blueprint-compiler
, wrapGAppsHook4
, desktop-file-utils
, glib
, gtk4
, gtk4-layer-shell
, libadwaita
, libgudev
}:

stdenv.mkDerivation {
  pname = "cameractrl";
  version = "unstable";

  src = fetchFromGitLab {
    owner = "NekoCWD";
    repo = "cameractrl";
    rev = "4c8ac34295df52c5f887a9e51ec64f54ef26c636";
    hash = "sha256-4op0Cz/2+DtIBevnI+2KlrdCDTubQZKQSJh6asRzLTk=";
  };

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    vala
    blueprint-compiler
    wrapGAppsHook4
    desktop-file-utils
  ];

  buildInputs = [
    glib
    gtk4
    gtk4-layer-shell
    libadwaita
    libgudev
  ];

  meta = {
    description = "Camera controls (focus, ...) for V4L2 sub-devices on mobile Linux";
    homepage = "https://gitlab.com/NekoCWD/cameractrl";
    license = lib.licenses.gpl3Plus;
    mainProgram = "cameractr";
  };
}
