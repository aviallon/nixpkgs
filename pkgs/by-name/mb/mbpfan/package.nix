{
  stdenv,
  lib,
  fetchFromGitHub,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "mbpfan";
  version = "2.4.0";
  src = fetchFromGitHub {
    owner = "linux-on-mac";
    repo = "mbpfan";
    rev = "v${finalAttrs.version}";
    sha256 = "sha256-F9IWUcILOuLn5K4zRSU5jn+1Wk1xy0CONSI6JTXU2pA=";
  };
  patches = [
    # Support the applesmc hwmon ABI introduced in Linux 7.3 (fan*_target /
    # pwm*_enable) while keeping the legacy fan*_output / fan*_manual layout.
    # Not yet submitted upstream; mbpfan master is still legacy-only.
    ./applesmc-hwmon-abi.patch
  ];

  installPhase = ''
    mkdir -p $out/bin $out/etc
    cp bin/mbpfan $out/bin
    cp mbpfan.conf $out/etc
  '';
  meta = {
    description = "Daemon that uses input from coretemp module and sets the fan speed using the applesmc module";
    mainProgram = "mbpfan";
    homepage = "https://github.com/linux-on-mac/mbpfan";
    license = lib.licenses.gpl3;
    platforms = lib.platforms.linux;
    maintainers = [ ];
  };
})
