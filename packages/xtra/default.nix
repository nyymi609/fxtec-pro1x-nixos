{ lib, stdenvNoCC, makeWrapper, writeShellApplication, python3, libqmi, libqrtr-glib, curl, coreutils, gawk }:

let
  inject = stdenvNoCC.mkDerivation {
    pname = "pro1x-xtra-inject";
    version = "1";
    dontUnpack = true;
    nativeBuildInputs = [ makeWrapper ];
    installPhase = ''
      install -Dm755 ${./xtra-inject.py} $out/libexec/xtra-inject.py
      makeWrapper ${python3.withPackages (p: [ p.pygobject3 ])}/bin/python3 $out/bin/xtra-inject \
        --add-flags "-I $out/libexec/xtra-inject.py" \
        --prefix GI_TYPELIB_PATH : ${lib.makeSearchPath "lib/girepository-1.0" [ libqmi libqrtr-glib ]}
    '';
  };
in
# Fetches the modem's XTRA file at most once a day (cached in $STATE_DIRECTORY,
# used for up to its 7 days when there is no network) and injects it with the
# current time.
writeShellApplication {
  name = "pro1x-xtra";
  runtimeInputs = [ inject libqmi curl coreutils gawk ];
  text = ''
    dir=''${STATE_DIRECTORY:-/var/lib/pro1x-xtra}
    mkdir -p "$dir"
    # The modem names its own file (xtra3grcej.bin: GPS, GLONASS, BeiDou, Galileo)
    mapfile -t urls < <(qmicli -d qrtr://0 --loc-get-predicted-orbits-data-source 2>/dev/null |
      awk -F"'" '/Server [0-9]+:/ { print $2 }')
    [ "''${#urls[@]}" -gt 0 ] || urls=(https://path1.xtracloud.net/xtra3grcej.bin https://path2.xtracloud.net/xtra3grcej.bin)
    file=$dir/$(basename "''${urls[0]}")

    if [ ! -s "$file" ] || [ -n "$(find "$file" -mmin +1440)" ]; then
      for url in "''${urls[@]}"; do
        if curl -sf -m 60 -o "$file.new" "$url" && [ -s "$file.new" ]; then
          mv "$file.new" "$file"
          echo "fetched $url"
          break
        fi
      done
      rm -f "$file.new"
    fi

    qmicli -d qrtr://0 --loc-inject-time >/dev/null && echo "time injected"
    if [ -s "$file" ] && [ -z "$(find "$file" -mmin +10080)" ]; then
      xtra-inject "$file"
      qmicli -d qrtr://0 --loc-get-predicted-orbits-data-validity 2>/dev/null | tail -n 1
    else
      echo "no XTRA file younger than 7 days" >&2
    fi
  '';
}
