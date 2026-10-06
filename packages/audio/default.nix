{ lib, stdenv, makeWrapper, alsa-lib, alsa-utils, pipewire, pulseaudio, gawk, coreutils, util-linux, systemd }:

stdenv.mkDerivation {
  pname = "pro1x-audio";
  version = "1";
  src = ../../device/audio;

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ alsa-lib ];
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -o pro1x-voicepcm voicepcm.c -lasound
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/alsa/ucm2 $out/share/wireplumber/wireplumber.conf.d
    install -m755 pro1x-voicepcm $out/bin/
    for s in pro1x-audio-init pro1x-voice-call; do
      install -m755 $s $out/bin/$s
      wrapProgram $out/bin/$s --prefix PATH : ${lib.makeBinPath [ alsa-utils pipewire pulseaudio gawk coreutils util-linux systemd ]}:$out/bin
    done
    cp -r --no-preserve=mode ucm2/. $out/share/alsa/ucm2/
    cp wireplumber.conf.d/*.conf $out/share/wireplumber/wireplumber.conf.d/
    # The UCM voice verb calls the helper through /usr/bin/env on other distributions.
    substituteInPlace $out/share/alsa/ucm2/Pro1X/VoiceCall.conf \
      --replace-fail '/usr/bin/env pro1x-voice-call' "$out/bin/pro1x-voice-call"
    runHook postInstall
  '';
}
