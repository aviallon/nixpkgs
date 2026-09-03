{
  mkKdeDerivation,
  pkg-config,
  gpgmepp,
  libgcrypt,
  libsecret,
  kdoctools,
  fetchpatch
}:
mkKdeDerivation {
  pname = "kwallet";

  extraNativeBuildInputs = [
    pkg-config
  ];

  extraBuildInputs = [
    gpgmepp
    libgcrypt
    libsecret
    kdoctools
  ];

  patches = [
    (fetchpatch {
      name = "0099-fix-memory-leaks-in-kwalletd.patch";
      url = "https://invent.kde.org/frameworks/kwallet/-/merge_requests/166.patch";
      hash = "sha256-TALHgYQKBzQXJdV0Ldry3MsBHy64xnj1RPUsRZPe8g4=";
    })
  ];
}
