# mesa-terakan

Mesa built from the [Terakan][] fork, which adds `amd_terascale` — a Vulkan 1.0
driver for the AMD TeraScale 2/3 GPU families.

## Why a fork

The GPUs in question (Radeon HD 5000 "Evergreen", HD 6000 "Northern Islands")
run on the legacy `radeon` KMS driver. Neither RADV nor the proprietary AMD
Vulkan driver supports them, and no upstream Mesa Vulkan driver ever has, so
Terakan is the only way to get Vulkan on them at all.

The driver accepts exactly `CHIP_CEDAR`..`CHIP_ARUBA`
(`terakan_physical_device_is_chip_family_supported()`): TeraScale 2 and 3, and
nothing else — not the R600/R700 cards, not GCN.

## State of the driver

What it advertises on real hardware (an HD 6730M, `1002:6740`): **Vulkan 1.0**
(`apiVersion 1.0.367`, `driverVersion 0.0.1`) and 29 device extensions —
`VK_KHR_swapchain` (rev 70), `VK_KHR_timeline_semaphore`,
`VK_KHR_dynamic_rendering`, `VK_KHR_format_feature_flags2`,
`VK_EXT_extended_dynamic_state`/`_3`, `VK_EXT_color_write_enable`,
`VK_EXT_depth_clip_control`, `VK_EXT_depth_bias_control`,
`VK_EXT_sample_locations`, `VK_EXT_vertex_attribute_divisor`,
`VK_EXT_non_seamless_cube_map`, `VK_EXT_host_query_reset`,
`VK_KHR_external_memory_fd`/`_dma_buf`, and so on. Allowed present modes are
`FIFO` and `MAILBOX` (not `IMMEDIATE` or `FIFO_RELAXED`).

What is *not* there, and is what modern translation layers ask for: Vulkan 1.1
or newer, `VK_KHR_synchronization2`, descriptor indexing
(`VK_EXT_descriptor_indexing`) and buffer device address. DXVK 2.x targets
Vulkan 1.1, so whether it (and hence Proton) works here has to be tried rather
than assumed; a pre-2.x DXVK, which required only Vulkan 1.0, is the likelier
candidate. The driver also prints "terakan is not a conformant Vulkan
implementation, testing use only" at instance creation, which is the author's
own assessment.

Measured on that machine, through this package (`vkcube`, Wayland WSI):

| present mode | frames | wall | rate |
| --- | --- | --- | --- |
| `FIFO` (vsync) | 300 | 4.94 s | 60.8 fps |
| `MAILBOX` | 1200 | 1.96 s | 613 fps |

One rough edge found while doing so: full `vulkaninfo` (not `--summary`)
segfaults reproducibly (2 of 2 runs, exit 139) while printing
`VkPhysicalDeviceExtendedDynamicState3FeaturesEXT`, i.e. inside the
`vkGetPhysicalDeviceFeatures2` chain. `vkcube` and `vulkaninfo --summary` are
unaffected.

## Using it

On NixOS, point the graphics module at it — this is all a driver override
normally wants, needs no overlay, and does not rebuild the world, because
`/run/opengl-driver` is what both the DRI drivers and the Vulkan ICD are found
through:

```nix
hardware.graphics.package = pkgs.mesa-terakan;
# and, with hardware.graphics.enable32Bit, for 32-bit applications:
hardware.graphics.package32 = pkgs.pkgsi686Linux.mesa-terakan;
```

nixpkgs' `vulkan-loader` is compiled with
`-DSYSCONFDIR=${driverLink}/share`, so the new
`share/vulkan/icd.d/terascale_icd.*.json` is found without any environment
variable. (Outside NixOS nothing fills `/run/opengl-driver`; there set
`VK_DRIVER_FILES` to the manifest.)

Replacing `pkgs.mesa` itself — so build-time consumers see it too, at the cost
of rebuilding everything that links libGL — needs an overlay, and a naive one
does **not** work:

```nix
# infinite recursion: `mesa-terakan`'s own `mesa` input is resolved from the
# same fixpoint, so it ends up being itself
nixpkgs.overlays = [ (final: prev: { mesa = final.mesa-terakan; }) ];
```

Re-entering the package with the *previous* mesa does:

```nix
nixpkgs.overlays = [
  (final: prev: {
    mesa = prev.callPackage "${prev.path}/pkgs/by-name/me/mesa-terakan/package.nix" {
      mesa = prev.mesa;
    };
  })
];
```

Note that overriding `pkgs.mesa` rebuilds a large part of the closure — a few
hundred packages, not a few. `libgbm` deliberately stays on its own (older)
version either way: nixpkgs builds it from a separate expression with no
drivers, and it is already version-skewed from `mesa` upstream.

The GPU is reached through the legacy **`radeon`** kernel driver, so the kernel
needs `CONFIG_DRM_RADEON` (the `radeon` module). `amdgpu` is not used by this
hardware and the two are mutually exclusive on it.

## Driver selection

Terakan covers a small corner of what Mesa supports, and Mesa happily spends
most of its compile time on drivers those machines can never load, so the driver
lists are narrowed to the two families at hand plus the software fallback:

| kept | covers |
| --- | --- |
| `r600` | Radeon R600 → Northern Islands, **including the Terakan targets** |
| `r300` | Radeon R300–R500 (the pre-TeraScale cards on the same `radeon` driver) |
| `crocus` | Intel Gen 4–7 (the "i965" era, pre-Iris) |
| `i915` | Intel Gen 2–3 |
| `llvmpipe`, `swrast` | software rasterizers: still needed with no GPU, for headless use and as the fallback when a card is unsupported |
| `amd_terascale` | the Vulkan driver this package is for |

Everything else is dropped: `radeonsi`/`radv` (GCN+), `iris` and newer Intel,
NVIDIA, the ARM SoCs, the virtual-GPU drivers, and the Dozen/D3D12 drivers.

`zink` is *not* in the list. It is worth considering on a Terakan machine (it
would let GL applications run on top of the new Vulkan driver), but the `r600`
GL driver is the better path there; add `"zink"` to `galliumDrivers` if you want
to experiment — DXVK/vkd3d talk to Vulkan directly and do not need it.

Anything can be added back, since the driver lists stay overridable:

```nix
final.mesa-terakan.override { galliumDrivers = [ "crocus" "i915" "llvmpipe" "r300" "r600" "zink" ]; }
```

…with one exception: **RadeonSI and RADV cannot be added**, because they are the
only users of Mesa's `amdgpu-virtio` option and Mesa main rejects the deprecated
spelling of it outright (fork-state item 2 below).

## Measured build cost

Same machine (32 cores, `--max-jobs 1`), same nixpkgs, `nix build` wall clock
including install/fixup:

| build | ninja steps | wall |
| --- | --- | --- |
| `pkgs.mesa` (nixpkgs default, every driver) | 5928 | 699 s |
| `mesa-terakan` | 1949 | 151 s |

i.e. ~4.6× less wall clock on ~3× fewer build steps. (The two are not the same
source tree — stock is 26.2.4, this is 27.0.0-devel, which is larger — so the
saving from the narrowing is if anything understated.)

Where this build's compile time actually goes (durations per target, summed from
ninja's own log — 37.9 job-minutes; the log carries 1974 timed entries against
the build's 1949 edges, a few being bookkeeping rows):

| subsystem | job-min | % |
| --- | --- | --- |
| `src/compiler` (nir, glsl, clc, spirv) | 7.7 | 20% |
| `src/mesa` (core GL) | 7.3 | 19% |
| `src/intel` (ISL/ELK for crocus) | 5.8 | 15% |
| gallium frontends/targets | 4.8 | 13% |
| `src/amd/terascale` (**Terakan itself**) | 3.6 | 9% |
| `src/vulkan/runtime` | 2.5 | 7% |
| the kept GL drivers (crocus, r600, r300, i915, llvmpipe) | 3.4 | 9% |
| rusticl | 0.7 | 2% |

The driver being added is a small fraction of the work; the Intel and GL core
trees are what a Terakan machine cannot avoid, since `crocus` needs them.

For reference, the fork built with nixpkgs' *default* driver/tool selection does
not even configure against this nixpkgs — see "Fork state" below.

## Verification

Artifacts, from `nix build .#legacyPackages.x86_64-linux.mesa-terakan`:

* `share/vulkan/icd.d/terascale_icd.x86_64.json` → `lib/libvulkan_terascale.so`
  by absolute path, plus `lvp_icd.x86_64.json`; no `radeon`/`intel`/`nouveau`
  ICD.
* `lib/dri/`: `crocus_dri.so`, `i915_dri.so`, `r300_dri.so`, `r600_dri.so`,
  `r600_drv_video.so` (VDPAU), `swrast_dri.so`, `kms_swrast_dri.so`, plus the
  `libdril_dri.so` loader — and no `radeonsi_dri.so`, `iris_dri.so`,
  `nouveau_dri.so` or `panfrost_dri.so`.
* `libvulkan_terascale.so` exports `vk_icdGetInstanceProcAddr`,
  `vk_icdGetPhysicalDeviceProcAddr` and
  `vk_icdNegotiateLoaderICDInterfaceVersion`.

Functional test — the fork ships a `radeon` drm-shim that fakes the kernel
driver, so the *shipped* library can be driven without a TeraScale card. Only
the shim is patched for the test (its PCI id is hardcoded to an RV515, with the
comment "nothing looks at the pci id", which is no longer true); the driver
under test is the built one, unmodified:

```sh
# in the fork's tree, with -Dtools=drm-shim configured:
SHA=$(nix build --no-link --print-out-paths .#legacyPackages.x86_64-linux.mesa-terakan)
ICD=$SHA/share/vulkan/icd.d/terascale_icd.x86_64.json
VULKANINFO=$(nix build --no-link --print-out-paths .#legacyPackages.x86_64-linux.vulkan-tools)/bin/vulkaninfo

LD_PRELOAD=.../libradeon_noop_drm_shim.so RADEON_GPU_ID=0x6740 \
  VK_ICD_FILENAMES=$ICD $VULKANINFO --summary
```

which enumerates, for each faked chip:

```
deviceID   = 0x6740   deviceName = AMD Radeon HD 6700M Series (Whistler XT)
deviceID   = 0x68be   deviceName = AMD Radeon HD 5750 (Juniper LE)
```

and, as the negative control, faking the shim's default RV515 (`0x7140`,
outside `CHIP_CEDAR`..`CHIP_ARUBA`) enumerates **no** device — the filtering
works, rather than the driver merely loading.

`passthru.tests.installed-drivers` re-checks the above contract cheaply, with no
GPU: the ICD manifest exists and is unique, the library it names was installed,
it exports the three loader entry points, and every gallium driver *asked for*
has produced its DRI module (and lavapipe its own manifest, when `swrast` is
selected). Deriving the DRI checks from `galliumDrivers` is what keeps a
legitimate `.override` from failing the test; the Terakan manifest is required
unconditionally, since a build without it is not this package.

Both directions were checked by mutation. Dropping `crocus` from
`galliumDrivers` still passes, and removing `amd_terascale` fails on
`expected exactly one terascale ICD manifest, found 0` (the build then has a
`share/vulkan/icd.d/` containing only lavapipe's manifest).

**Not** proven here: that rendering is *correct* on real silicon (the frames
were presented, not read back and compared), and that any particular game runs.
Both need the actual hardware and game.

## Fork state

Everything below is a property of the pinned commit (`rev`), not of this
packaging, and worth reporting upstream:

1. **`assert()` in a non-void function.** `terakan_hw_config_sqk_get_stage_srvs_()`
   ends with `assert(!"Unsupported shader stage")` in a `switch` default. With
   assertions compiled out (`-Db_ndebug=true`, which nixpkgs sets) that is
   undefined behaviour *and* `-Werror=return-type`. Fixed here by
   `ndebug-unreachable-stage.patch`, which uses Mesa's own `UNREACHABLE()`.
2. **`amdgpu-virtio` is a hard error** on this branch: it is deprecated in
   favour of the `amd-options` array, and Meson rejects *both* `true` and
   `false` for it. `default.nix` therefore only passes it for builds that
   actually include RadeonSI/RADV (where it can have an effect) — which is what
   makes a driver-narrowed build possible at all, and also why RadeonSI/RADV
   cannot be added back to this package.
3. **`anti-lag` is no longer a Vulkan layer** on Mesa main; the variant passes
   the remaining five.
4. **`panfrost-rust` defaults to `true`** on this branch, and the Asahi/Panfrost
   tool targets pull Rust components nixpkgs' Mesa never builds — so
   nixpkgs' `mesa-rust-package-cache` (vendored for 26.2.4) does not contain the
   crates and Meson tries to download them. `mesaTools = [ ]` avoids the whole
   tree, which this build has no use for anyway.
5. **`freedreno`'s `dependency('libarchive', allow_fallback: true)`** — a
   dependency nixpkgs' Mesa does not put in `buildInputs` — makes Meson try to
   *download* a wrap subproject, which fails in a build with a read-only
   package cache. Another reason the default driver list cannot simply be
   passed to this tree.

## Updating

The branch is force-updated (rebased onto Mesa main), so pin the commit and bump
both `rev` and `revDate` together:

```sh
rev=$(git -C ~/Programing/Opensource/terakan-mesa rev-parse origin/Terakan)
git -C ~/Programing/Opensource/terakan-mesa log -1 --format=%cs $rev   # -> revDate
nix store prefetch-file --unpack \
  "https://gitlab.freedesktop.org/api/v4/projects/Triang3l%2Fmesa/repository/archive.tar.gz?sha=$rev"
```

then re-run `passthru.tests.installed-drivers`, and expect two things to need
attention:

* `ndebug-unreachable-stage.patch` is one line against a file under active
  development, so it may need regenerating;
* `postPatch` (in `../mesa/default.nix`) compares three GL headers against
  `mesa-gl-headers`, which is pinned to an older Mesa (25.1.0). They are
  byte-identical at this `rev`, but a bump that touches `dri_interface.h`,
  `eglmesaext.h` or `eglext_angle.h` fails the build with `exit 42`.

And if the bump makes rusticl need a crate that is not in nixpkgs' vendored
`mesa-rust-package-cache` (`../mesa/wraps.json`, pinned to the 26.2.4 tree),
configure fails trying to download it into a read-only cache directory —
`wraps.json` has to be regenerated with `../mesa/update-wraps.py`.

[Terakan]: https://gitlab.freedesktop.org/Triang3l/mesa/-/tree/Terakan
