{
  lib,
  stdenv,
  fetchFromGitHub,
  pkg-config,
  libuuid,
  libsodium,
  libunwind,
  keyutils,
  kmod,
  liburcu,
  zlib,
  libaio,
  zstd,
  lz4,
  attr,
  udev,
  fuse3,
  cargo,
  rustc,
  rustPlatform,
  rust-bindgen,
  jq,
  makeWrapper,
  nix-update-script,
  versionCheckHook,
  nixosTests,
  installShellFiles,
  fuseSupport ? false,
  udevCheckHook,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "bcachefs-tools";
  version = "1.39.5";

  # Pinned to our bcachefs-tools fork, branch nixos/1.39.5-backports:
  # v1.39.5 plus two backports (btree node use-after-free GPF in
  # bch2_btree_node_get(); btree_bitmap_gc unable to shrink
  # btree_bitmap_shift, upstream issue koverstreet/bcachefs#1082 / open PR
  # koverstreet/bcachefs-tools#741). Drop once upstream ships fixes.
  src = fetchFromGitHub {
    owner = "aviallon";
    repo = "bcachefs-tools";
    rev = "b1bf09c30fe281aa07f6c4d00ab64a20c644ce43";
    hash = "sha256-gQ3lz+4YRyQYSC5bYXuWDdNAZ4RqTnLZEs108t1EFBA=";
  };

  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit (finalAttrs) src;
    hash = "sha256-hbh4+vpZtVpda2yVZK+fkdPXWd5+GYLbWYPfJsYtPfM=";
  };

  postPatch = ''
    substituteInPlace Makefile \
      --replace-fail "target/release/bcachefs" "target/${stdenv.hostPlatform.rust.rustcTargetSpec}/release/bcachefs"

    substituteInPlace src/commands/mount.rs \
      --replace-fail 'std::process::Command::new("modprobe")' 'std::process::Command::new("${lib.getExe' kmod "modprobe"}")'
  '';

  nativeBuildInputs = [
    pkg-config
    cargo
    rustc
    rustPlatform.cargoSetupHook
    rustPlatform.bindgenHook
    rust-bindgen
    jq
    makeWrapper
    installShellFiles
  ];

  buildInputs = [
    libaio
    keyutils
    lz4
    libsodium
    libunwind
    liburcu
    libuuid
    zstd
    zlib
    attr
    udev
  ]
  ++ lib.optional fuseSupport fuse3;

  makeFlags = [
    "PREFIX=${placeholder "out"}"
    "VERSION=${finalAttrs.version}"
    "INITRAMFS_DIR=${placeholder "out"}/etc/initramfs-tools"
    "DKMSDIR=${placeholder "dkms"}"

    # Tries to install to the 'systemd-minimal' and 'udev' nix installation paths
    "PKGCONFIG_SERVICEDIR=$(out)/lib/systemd/system"
    "PKGCONFIG_UDEVDIR=$(out)/lib/udev"
  ]
  ++ lib.optional fuseSupport "BCACHEFS_FUSE=1";

  enableParallelBuilding = true;

  installFlags = [
    "install"
    "install_dkms"
  ];

  env = {
    CARGO_BUILD_TARGET = stdenv.hostPlatform.rust.rustcTargetSpec;
    "CARGO_TARGET_${stdenv.hostPlatform.rust.cargoEnvVarTarget}_LINKER" = "${stdenv.cc.targetPrefix}cc";
    PKG_CONFIG_SYSTEMD_SYSTEMDSYSTEMGENERATORDIR = "${placeholder "out"}/lib/systemd/system-generators";
  };

  # Workaround for RISCV cross-compilation issue
  # https://github.com/koverstreet/bcachefs-tools/issues/850
  preBuild = lib.optionalString stdenv.hostPlatform.isRiscV ''
    export BINDGEN_EXTRA_CLANG_ARGS="$BINDGEN_EXTRA_CLANG_ARGS --target=riscv64-unknown-linux-gnu -march=rv64gc"
  '';

  # FIXME: Try enabling this once the default linux kernel is at least 6.7
  doCheck = false; # needs bcachefs module loaded on builder

  preCheck = lib.optionalString (!fuseSupport) ''
    rm tests/test_fuse.py
  '';
  checkFlags = [ "BCACHEFS_TEST_USE_VALGRIND=no" ];

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    udevCheckHook
    versionCheckHook
  ];
  versionCheckProgramArg = "version";

  postInstall = lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
    installShellCompletion --cmd bcachefs \
      --bash <($out/sbin/bcachefs completions bash) \
      --zsh  <($out/sbin/bcachefs completions zsh) \
      --fish <($out/sbin/bcachefs completions fish)
  '';

  outputs = [
    "out"
    "dkms"
  ];

  passthru = {
    # See NOTE in linux-kernels.nix
    kernelModule = import ./kernel-module.nix finalAttrs.finalPackage;

    tests = {
      smoke-test = nixosTests.bcachefs;
      inherit (nixosTests.installer) bcachefsSimple bcachefsEncrypted bcachefsMulti;
    };

    updateScript = nix-update-script { };
  };

  meta = {
    description = "Tool for managing bcachefs filesystems";
    homepage = "https://bcachefs.org/";
    downloadPage = "https://github.com/koverstreet/bcachefs-tools";
    license = lib.licenses.gpl2Only;
    maintainers = with lib.maintainers; [
      davidak
      johnrtitor
    ];
    platforms = lib.platforms.linux;
    mainProgram = "bcachefs";
  };
})
