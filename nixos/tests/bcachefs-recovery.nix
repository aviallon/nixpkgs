{ pkgs, ... }:
{
  name = "bcachefs-recovery";

  meta = {
    inherit (pkgs.bcachefs-tools.meta) maintainers;
  };

  nodes.machine =
    { config, lib, pkgs, ... }:
    {
      # A single empty 4 GiB disk shows up as /dev/vdb (vda is the root disk).
      virtualisation.emptyDiskImages = [ 4096 ];

      # Not bcachefs-specific; kept for parity with nixos/tests/bcachefs.nix.
      networking.hostId = "deadbeef";

      # This pulls in the OUT-OF-TREE module built from pkgs.bcachefs-tools:
      # nixos/modules/tasks/filesystems/bcachefs.nix does
      #   boot.extraModulePackages = [ config.boot.bcachefs.modulePackage ];
      # and boot.bcachefs.modulePackage defaults to
      #   config.boot.kernelPackages.callPackage pkgs.bcachefs-tools.kernelModule { }
      # (pkgs.bcachefs-tools is the aviallon fork in this tree). The runtime
      # test below asserts the loaded .ko still lives under updates/, which is
      # where out-of-tree modules land, i.e. it is not the in-tree module.
      boot.supportedFilesystems = [ "bcachefs" ];

      assertions = [
        {
          assertion =
            lib.elem config.boot.bcachefs.modulePackage config.boot.extraModulePackages
            && lib.getName config.boot.bcachefs.package == "bcachefs-tools";
          message = ''
            boot.supportedFilesystems = [ "bcachefs" ] must install the out-of-tree
            module built from pkgs.bcachefs-tools via boot.extraModulePackages.
          '';
        }
      ];

      environment.systemPackages = with pkgs; [
        bcachefs-tools
        coreutils
        util-linux
      ];
    };

  testScript = ''
    import re

    disk = "/dev/vdb"
    mnt = "/mnt"

    def parse_size(text):
        units = {"": 1, "k": 1024, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3}
        m = re.fullmatch(r"([0-9.]+)([kKMG]?)", text.strip())
        assert m, f"cannot parse size {text!r}"
        return int(float(m.group(1)) * units[m.group(2)])

    def must_search(pattern, text):
        m = re.search(pattern, text)
        assert m is not None, f"pattern {pattern!r} not found in:\n{text}"
        return m

    def list_data_extent(dev, inode, bucket_size):
        # bcachefs list prints, for each extents-btree key:
        #   u64s 8 type extent <pos> len <sectors> ...
        #     crc64: ...
        #     ptr: <dev> <dev-idx>:<bucket>:<bucket-sector-offset> gen <n>
        # so the absolute byte offset is bucket * bucket_size + offset * 512.
        out = machine.succeed(f"bcachefs list -b extents {dev}")
        lines = out.splitlines()
        for i, line in enumerate(lines):
            m = re.search(r"type extent ([0-9]+):([0-9]+):\S+ len ([0-9]+)", line)
            if not m or int(m.group(1)) != inode:
                continue
            for j in range(i + 1, min(i + 5, len(lines))):
                pm = re.search(r"ptr:\s+\S+\s+[0-9]+:([0-9]+):([0-9]+)\s+gen", lines[j])
                if pm:
                    return int(pm.group(1)) * bucket_size + int(pm.group(2)) * 512
        raise AssertionError(f"no on-disk extent for inode {inode}:\n{out}")

    def list_extent_btree_node(dev, inode, bucket_size):
        # Pick the level-0 (leaf) extents-btree node whose key range covers
        # `inode`, then return its absolute byte offset on the device.
        out = machine.succeed(f"bcachefs list -m formats {dev}")
        lines = out.splitlines()
        candidates = []
        for i, line in enumerate(lines):
            m = re.match(r"l 0 (\S+) - (\S+):", line)
            if not m:
                continue
            token = m.group(2).split(":")[0]
            max_pos = int(token) if token.isdigit() else (1 << 64) - 1
            if max_pos >= inode:
                candidates.append((max_pos, i))
        assert candidates, f"no level-0 btree node covers inode {inode}:\n{out}"
        _, i = min(candidates)
        for j in range(i + 1, min(i + 6, len(lines))):
            pm = re.search(r"ptr:\s+\S+\s+[0-9]+:([0-9]+):([0-9]+)\s+gen", lines[j])
            if pm:
                return int(pm.group(1)) * bucket_size + int(pm.group(2)) * 512
        raise AssertionError(f"no ptr for the node covering inode {inode}:\n{out}")

    def corrupt(dev, offset, length):
        # Deterministic, file-specific overwrite: random bytes at an absolute
        # offset, never random bytes somewhere on the disk.
        assert offset % 512 == 0 and length % 512 == 0 and length > 0
        machine.succeed(
            f"dd if=/dev/urandom of={dev} bs=512 seek={offset // 512} "
            f"count={length // 512} conv=notrunc,fsync status=none"
        )

    # --- 1. the loaded module must be the out-of-tree module from pkgs.bcachefs-tools
    machine.succeed("modprobe bcachefs")
    modinfo = machine.succeed("modinfo bcachefs")
    assert "updates/src/fs/bcachefs" in modinfo, (
        "bcachefs is not the out-of-tree module built from pkgs.bcachefs-tools "
        "(expected an updates/src/fs/bcachefs path):\n" + modinfo
    )
    machine.succeed("bcachefs version")
    machine.succeed("mkfs.bcachefs --help > /dev/null")

    # --- 2. create the filesystem on the empty disk image
    machine.succeed("udevadm settle")
    machine.succeed(f"mkfs.bcachefs --force -L recovery {disk}")
    superblock = machine.succeed(f"bcachefs show-super {disk}")
    bucket_size = parse_size(must_search(r"Bucket size:\s+(\S+)", superblock).group(1))
    node_size = parse_size(must_search(r"btree_node_size:\s+(\S+)", superblock).group(1))

    # --- 3. mount it and write the target file
    machine.succeed(f"mkdir -p {mnt}")
    machine.succeed(f"mount -t bcachefs {disk} {mnt}")
    machine.succeed(f"findmnt -t bcachefs {mnt}")
    machine.succeed(f"dd if=/dev/urandom of={mnt}/target.bin bs=1M count=8 conv=fsync")
    machine.succeed("sync")
    inode = int(machine.succeed(f"stat -c %i {mnt}/target.bin").strip())
    before_sha = machine.succeed(f"sha256sum {mnt}/target.bin").split()[0]
    machine.succeed(f"umount {mnt}")

    # --- 4. damage the file's ACTUAL on-disk data extent
    data_phys = list_data_extent(disk, inode, bucket_size)
    corrupt(disk, data_phys, 512)

    # --- 5. the damage must be observable: a fresh mount cannot read the file
    # (bcachefs verifies data checksums on read; with a single replica an
    # unrecoverable checksum error surfaces as EIO)
    machine.succeed(f"mount -t bcachefs {disk} {mnt}")
    status, out = machine.execute(f"cat {mnt}/target.bin > /dev/null 2>&1")
    if status == 0:
        after_sha = machine.succeed(f"sha256sum {mnt}/target.bin").split()[0]
        assert after_sha != before_sha, "the on-disk corruption is not observable"
    machine.succeed(f"umount {mnt}")

    # --- 6. additionally damage the extents-btree leaf node that holds this
    # inode's extent keys. Offline fsck does NOT read file data (a data-only
    # corruption leaves "bcachefs fsck -n" at exit 0), so metadata damage is
    # what exercises fsck's detection and repair, while still being pinned to
    # this specific file via its inode.
    node_phys = list_extent_btree_node(disk, inode, bucket_size)
    corrupt(disk, node_phys, node_size)

    # --- 7. fsck must detect the damage, then repair it
    status, out = machine.execute(f"bcachefs fsck -n {disk} 2>&1")
    machine.log(f"fsck -n after damage: exit status {status}")
    assert status != 0, "fsck -n did not detect the damaged btree node:\n" + out

    status, out = machine.execute(f"bcachefs fsck -y {disk} 2>&1")
    # fsck(8) exit status is a bitmask: 1 = errors fixed, 4 = still has errors,
    # 8 = fatal/operational error. A successful repair is therefore NOT exit 0:
    # this bcachefs sets bit 1, and also bit 8 because fs.exit() reports
    # "shutdown_with_errors_fixed" whenever it genuinely repaired something.
    # So only bit 4 (uncorrected errors) is a real failure signal here; the
    # decisive checks are the clean re-run and the remount below.
    machine.log(f"fsck -y repair: exit status {status}\n{out}")
    assert (status & 4) == 0, f"fsck -y left uncorrected errors (status {status}):\n{out}"
    assert "errors fixed" in out, f"fsck -y did not report a repair (status {status}):\n{out}"

    status, out = machine.execute(f"bcachefs fsck -n {disk} 2>&1")
    machine.log(f"fsck -n after repair, before remount: exit status {status}")
    assert status == 0, f"filesystem is not clean after fsck -y (status {status}):\n{out}"

    # --- 8. the damage must have been recorded against this specific inode
    damage = machine.succeed(f"bcachefs list -b damage {disk}")
    assert str(inode) in damage, f"no persistent damage record for inode {inode}:\n{damage}"

    # --- 9. remount: the filesystem must be usable again
    machine.succeed(f"mount -t bcachefs {disk} {mnt}")
    machine.succeed(f"findmnt -t bcachefs {mnt}")
    damaged = machine.succeed(f"bcachefs damage ls -R {mnt}")
    assert "target.bin" in damaged, f"damage ls does not report the damaged file:\n{damaged}"

    machine.succeed(f"dd if=/dev/urandom of={mnt}/post-recovery.bin bs=1M count=4 conv=fsync")
    machine.succeed(f"sha256sum {mnt}/post-recovery.bin > /tmp/post-recovery.sha256")
    machine.succeed(f"umount {mnt}")

    # ... and newly written data must survive a remount
    machine.succeed(f"mount -t bcachefs {disk} {mnt}")
    machine.succeed("sha256sum -c /tmp/post-recovery.sha256")
    machine.succeed(f"umount {mnt}")
  '';
}
