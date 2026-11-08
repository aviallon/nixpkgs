# Mesa with the Terakan Vulkan driver for AMD TeraScale 2/3 GPUs.
#
# Terakan (https://gitlab.freedesktop.org/Triang3l/mesa, branch `Terakan`) adds
# the `amd_terascale` Vulkan driver for the Evergreen (Radeon HD 5000) and
# Northern Islands (HD 6000) families.  Those GPUs run on the legacy `radeon`
# KMS driver and no upstream Mesa Vulkan driver has ever supported them, so a
# fork is the only way to get Vulkan on them — see the README for what that
# Vulkan 1.0 driver does and does not implement.
#
# The fork's `Terakan` branch is force-updated: it is rebased onto Mesa main
# regularly, so `rev` and `version` must be bumped together (see below).
#
# Building it also narrows the driver lists to what the machines in question
# can use, which is most of the build time: Mesa compiles ~25 gallium and ~15
# Vulkan drivers by default.
#
#   r300                     Radeon R300-R500 (pre-TeraScale)
#   r600                     Radeon R600-Northern Islands, incl. the Terakan targets
#   i915                     Intel Gen 2-3
#   crocus                   Intel Gen 4-7 ("i965" era, pre-Iris)
#   llvmpipe, swrast         software fallback: still needed on a machine with
#                            an unsupported or no GPU, and for headless use
#
# Everything else — amdgpu (GCN+), Iris and newer Intel, NVIDIA, the ARM SoCs,
# the virtual GPU drivers — is left out.  A family can be added back through
# `.override`, with one caveat: RadeonSI/RADV cannot be, because they are the
# only users of Mesa's `amdgpu-virtio` option, which Mesa main rejects — see
# `mesaTools` and the `amdgpu-virtio` note in ../mesa/default.nix.
#
# Use it as the machine's graphics driver set (this is what a GPU-driver
# override normally wants, and it needs no overlay and no world rebuild, because
# `/run/opengl-driver` is what both the DRI drivers and the Vulkan ICD are
# found through):
#
#   hardware.graphics.package = pkgs.mesa-terakan;
#   # and, with hardware.graphics.enable32Bit, for 32-bit applications:
#   hardware.graphics.package32 = pkgs.pkgsi686Linux.mesa-terakan;
#
# Replacing `pkgs.mesa` itself — so build-time consumers see it too, at the cost
# of rebuilding everything that links libGL — needs an overlay that breaks a
# self-reference: `mesa-terakan`'s own `mesa` input is resolved from the same
# fixpoint, so `mesa = final.mesa-terakan;` is infinite recursion.  Re-entering
# the package with the *previous* mesa works:
#
#   nixpkgs.overlays = [
#     (final: prev: {
#       # (`prev.path + "/..."`, not `"${prev.path}/..."`: interpolating a path
#       # value copies the whole nixpkgs tree — `.git` and all — into the store,
#       # which can fail outright on a working checkout.)
#       mesa = prev.callPackage (prev.path + "/pkgs/by-name/me/mesa-terakan/package.nix") {
#         mesa = prev.mesa;
#       };
#     })
#   ];
#
# Terakan submits work through the legacy `radeon` DRM driver, so the kernel
# needs CONFIG_DRM_RADEON (the `radeon` module); `amdgpu` is not involved, and
# on these GPUs the two are mutually exclusive.
{
  lib,
  fetchFromGitLab,
  llvmPackages,
  mesa,
  runCommand,
  stdenv,

  # Driver families to build.  See above for why these are the defaults.
  galliumDrivers ? [
    "crocus"
    "i915"
    "llvmpipe"
    "r300"
    "r600"
  ],
  vulkanDrivers ? [
    "amd_terascale"
    "swrast"
  ],
  # `anti-lag` is in the layer list nixpkgs' Mesa passes, but was dropped from
  # Mesa main, which this branch is rebased onto.
  vulkanLayers ? [
    "device-select"
    "intel-nullhw"
    "overlay"
    "screenshot"
    "vram-report-limit"
  ],
  # Neither the Asahi nor the Panfrost shader compilers can produce code for
  # anything this build targets, and the fork defaults `panfrost-rust` to true,
  # so building them costs a Rust toolchain's worth of compile time.
  mesaTools ? [ ],
}:

let
  rev = "85fe22fa86b92e5ddec92be7e63e83c36ca732a3";

  # Date of `rev`, for the "unstable" version stamp.
  # To update: pick a new `rev` from the branch, then
  #   nix store prefetch-file --unpack \
  #     "https://gitlab.freedesktop.org/api/v4/projects/Triang3l%2Fmesa/repository/archive.tar.gz?sha=$rev"
  # and put its hash below.
  revDate = "2026-11-04";

  # The DRI module each selected gallium driver must have produced.  Only the
  # families this package picks are listed: the name is not uniform upstream
  # (freedreno builds `msm_dri.so`, svga `vmwgfx_dri.so`, ...), and llvmpipe and
  # softpipe both build `swrast_dri.so`.
  driModules = lib.unique (
    map
      (
        driver:
        if
          lib.elem driver [
            "llvmpipe"
            "softpipe"
          ]
        then
          "swrast"
        else
          driver
      )
      (
        lib.intersectLists galliumDrivers [
          "crocus"
          "i915"
          "llvmpipe"
          "r300"
          "r600"
          "softpipe"
          "zink"
        ]
      )
  );
in
(mesa.override (
  {
    inherit
      galliumDrivers
      vulkanDrivers
      vulkanLayers
      ;
  }
  # On darwin `mesa` is an entirely different expression that knows nothing
  # about `mesaTools`; `meta.platforms` below keeps it from being built there,
  # but evaluation must not blow up either.
  // lib.optionalAttrs stdenv.hostPlatform.isLinux { inherit mesaTools; }
)).overrideAttrs
  (
    finalAttrs: prevAttrs: {
      pname = "mesa-terakan";
      version = "27.0.0-devel-unstable-${revDate}";

      # `fetchFromGitLab` fetches the archive tarball rather than cloning, which
      # matters here: a full clone of Mesa is several gigabytes.
      src = fetchFromGitLab {
        domain = "gitlab.freedesktop.org";
        owner = "Triang3l";
        repo = "mesa";
        inherit rev;
        hash = "sha256-GozLBK/FpuPoeQS5jSi6HJLdodml3FPAtbVR/JL0Cpk=";
      };

      # A fork bump usually means revisiting this patch: it fixes a spot where the
      # fork relies on `assert()` being live, which nixpkgs' `-Db_ndebug=true`
      # (see default.nix) does not guarantee.
      patches = prevAttrs.patches ++ [ ./ndebug-unreachable-stage.patch ];

      # Dropping the Dozen drivers means nothing links libspirv_to_dxil, so the
      # `spirv2dxil` output stays empty and nix refuses to finish a build whose
      # declared output was never created.  (It cannot be dropped from `outputs`
      # instead: postInstall refers to `$spirv2dxil` under `set -u`.)
      postInstall = (prevAttrs.postInstall or "") + ''
        mkdir -p $spirv2dxil
      '';

      meta = removeAttrs prevAttrs.meta [ "changelog" ] // {
        description = "Mesa with the Terakan Vulkan driver for AMD TeraScale 2/3 GPUs";
        longDescription = ''
          A fork of Mesa adding `amd_terascale` (Terakan), a Vulkan 1.0 driver for
          the AMD TeraScale 2 and 3 families — Radeon HD 5000 "Evergreen" and
          HD 6000 "Northern Islands" — which are driven by the legacy `radeon`
          kernel driver and are unsupported by either RADV or the proprietary AMD
          Vulkan driver.

          Built with a narrowed driver list (old Intel and pre-GCN Radeon, plus the
          software rasterizers), so it is not a drop-in replacement for the full
          Mesa on a machine with newer hardware.
        '';
        homepage = "https://gitlab.freedesktop.org/Triang3l/mesa/-/tree/Terakan";
        # `changelog` is dropped rather than set to `null`: the inherited URL
        # points at upstream Mesa's release notes for a version this is not, the
        # fork publishes none of its own, and checkMeta rejects `null`.
        # `maintainers` is emptied because the inherited ones maintain upstream
        # Mesa's *code*, not this packaging — whoever owns this file should be
        # listed here instead.
        maintainers = [ ];
        # Terakan is Linux-only: it needs the `radeon` DRM driver.
        platforms = lib.platforms.linux;
      };

      passthru = prevAttrs.passthru // {
        tests = (prevAttrs.passthru.tests or { }) // {
          # `amd_terascale` is not in Mesa's default driver list, so a build in
          # which it silently went missing would look perfectly fine: assert the
          # installed contract.  The DRI assertions are derived from
          # `galliumDrivers`, so a legitimate `.override` neither fails here nor
          # goes unchecked, but the Terakan manifest is required unconditionally
          # — a build without it is not this package.  Cheap, needs no GPU.
          installed-drivers =
            runCommand "mesa-terakan-installed-drivers"
              {
                nativeBuildInputs = [ llvmPackages.llvm ];
              }
              ''
                mesa=${finalAttrs.finalPackage}
                fail() {
                  echo "$*" >&2
                  exit 1
                }

                # Every gallium driver selected must have produced its DRI module.
                ${lib.concatMapStrings (m: ''
                  [ -f "$mesa/lib/dri/${m}_dri.so" ] || fail "missing $mesa/lib/dri/${m}_dri.so"
                '') driModules}

                ${lib.optionalString (lib.elem "swrast" vulkanDrivers) ''
                  ls -1 "$mesa"/share/vulkan/icd.d/lvp_icd.*.json >/dev/null 2>&1 ||
                    fail "the swrast Vulkan driver was asked for but installed no ICD manifest"
                ''}

                ${lib.optionalString (!lib.elem "amd_terascale" vulkanDrivers) ''
                  echo "note: amd_terascale is not in vulkanDrivers, so the Terakan check below" >&2
                  echo "      is expected to fail; it only guards the default configuration." >&2
                ''}
                count=$(ls -1 "$mesa"/share/vulkan/icd.d/terascale_icd.*.json | wc -l)
                [ "$count" = 1 ] || fail "expected exactly one terascale ICD manifest, found $count"
                icd=$(ls -1 "$mesa"/share/vulkan/icd.d/terascale_icd.*.json)
                libpath=$(grep -o '"library_path": *"[^"]*"' "$icd" | cut -d'"' -f4)
                [ -f "$libpath" ] || fail "$icd points at a library that was not installed: $libpath"
                for sym in vk_icdGetInstanceProcAddr vk_icdGetPhysicalDeviceProcAddr vk_icdNegotiateLoaderICDInterfaceVersion; do
                  llvm-nm -D --defined-only "$libpath" | grep -qE " T $sym$" || fail "$libpath does not export $sym"
                done

                touch $out
              '';
        };
      };
    }
  )
