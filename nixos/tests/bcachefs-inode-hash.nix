# VM regression test for the bcachefs inode-hash `BUG_ON(ret)` crash
#
# `bch2_inode_hash_insert()` (fs/vfs/fs.c) used to do
#
#     ret = rhltable_insert(&c->vfs.inodes_by_inum_table, ...);
#     BUG_ON(ret);                 /* <-- ud2 on any nonzero return */
#
# and threw away the return value of the *first* insertion
# (`rhashtable_lookup_insert_key(&c->vfs.inodes_table, ...)`), retrying forever
# whenever it was not -EEXIST.  Everything an rhashtable insertion can return
# that is not -EEXIST is allocation-related (-ENOMEM / -EBUSY / -EAGAIN, the
# rhashtable grows its table with kmalloc(GFP_ATOMIC) on the insertion path), so
# a transient allocation failure in `nested_table_alloc()` / the bucket-table
# growth turned into a kernel BUG.
#
# This test drives the two inode rhashtables with a slab-fault injection aimed
# at the tasks that insert inodes, and asserts that:
#
#   * `unpatched` (the stock out-of-tree module): the BUG fires;
#   * `patched`   (the v2 fix + the lookup companion): it does not, every file
#     is still reachable (no spurious ENOENT), and the filesystem is clean;
#   * `mutated`   (the v2 fix with `BUG_ON(ret)` put back): the BUG fires again,
#     i.e. the test really fails if the fix is reverted.
#
# All three nodes run the same kernel and the same script; only the bcachefs
# module differs, and each node proves which build it loaded by hashing the file
# `modinfo -n bcachefs` points at and comparing it against the hashes of all
# three variants, which are installed side by side under /etc/bcachefs-variants.
{ pkgs, lib, ... }:

let
  # ---------------------------------------------------------------------------
  # Kernel under test: the fault injection framework.  Off in the stock nixpkgs
  # config; without it the failing allocation cannot be produced on demand.
  # FAILSLAB is the primary instrument (it fails kmem_cache_alloc itself, i.e.
  # exactly `kmalloc(PAGE_SIZE, GFP_ATOMIC|__GFP_ZERO)` in nested_table_alloc());
  # FAIL_PAGE_ALLOC is enabled as well because the failure *reported* in the
  # original incident surfaced as a page-allocation failure of the kmalloc-4k
  # slab.
  # ---------------------------------------------------------------------------
  faultInjectionPatch = {
    name = "fault-injection-bcachefs-inode-hash";
    patch = null;
    structuredExtraConfig = with lib.kernel; {
      FAULT_INJECTION = yes;
      FAULT_INJECTION_DEBUG_FS = yes;
      FAILSLAB = yes;
      FAIL_PAGE_ALLOC = yes;
    };
  };

  # ---------------------------------------------------------------------------
  # bcachefs module source patches.  `fs/vfs/fs.c` is src/fs/bcachefs/vfs/fs.c
  # inside the DKMS tree the out-of-tree module is built from, hence
  # `patch -p2 --directory=src/fs/bcachefs`.
  #
  # fixV2Patch and lookupPatch are byte-for-byte the delivered patches;
  # mutationPatch is new and is used by the `mutated` variant only.
  # ---------------------------------------------------------------------------
  fixV2Patch = builtins.toFile "bcachefs-inode-hash-fix-v2.patch" ''
    --- a/fs/vfs/fs.c	2026-11-04 12:15:34.975662748 +0100
+++ b/fs/vfs/fs.c	2026-11-04 12:15:34.976950127 +0100
@@ -505,51 +505,145 @@
 	return 0;
 }
 
+/*
+ * Throw away an inode that never made it into the inode cache: either another
+ * inode with the same key won the race, or an insertion failed.
+ */
+static void bch2_discard_unhashed_inode(struct bch_inode_info *inode)
+{
+	/*
+	 * bcachefs doesn't use I_NEW; we have no use for it since we only
+	 * insert fully created inodes in the inode hash table. But
+	 * discard_new_inode() expects it to be set...
+	 */
+	inode_state_set_raw(&inode->v, I_NEW);
+	/*
+	 * We don't want bch2_evict_inode() to delete the inode on disk: the
+	 * inode was never handed to any caller. Normally new inodes don't
+	 * have nlink == 0 - except tmpfiles do...
+	 */
+	set_nlink(&inode->v, 1);
+	discard_new_inode(&inode->v);
+}
+
+/*
+ * Drop our by-inode-number entry, and EI_INODE_HASHED with it.
+ *
+ * The flag is cleared first, the same order as bch2_inode_hash_remove(): a
+ * concurrent bch2_inode_hash_find() must not be able to take a new reference
+ * to an inode that is leaving the inode cache.
+ *
+ * Returns true when the entry is gone, i.e. when the inode is unreachable and
+ * may be freed. Removal cannot fail - the entry was just inserted, and
+ * rhltable_remove() only ever returns 0 or -ENOENT - so a failure is WARN()ed
+ * rather than BUG_ON()ed, which would be the very crash class this code exists
+ * to avoid. When it does fail, though, the inode must NOT be freed:
+ * rhltable_remove() unlinks an entry while an RCU walker already inside
+ * bch2_inode_or_descendents_is_open() may still be dereferencing it, so
+ * freeing here would be a use-after-free. A deliberately leaked inode is the
+ * lesser evil.
+ */
+static bool bch2_inode_hash_unhash(struct bch_fs *c, struct bch_inode_info *inode)
+{
+	clear_bit(EI_INODE_HASHED, &inode->ei_flags);
+
+	return !WARN_ON_ONCE(rhltable_remove(&c->vfs.inodes_by_inum_table,
+					     &inode->ei_inum_hash.hash,
+					     bch2_vfs_inodes_by_inum_params));
+}
+
 static struct bch_inode_info *bch2_inode_hash_insert(struct bch_fs *c,
 						     struct btree_trans *trans,
 						     struct bch_inode_info *inode)
 {
-	struct bch_inode_info *old = inode;
+	struct bch_inode_info *old;
+	int ret;
 
 	set_bit(EI_INODE_HASHED, &inode->ei_flags);
+
+	/*
+	 * Insert into the by-inode-number table first.
+	 *
+	 * The invariant this function has to preserve, on the error paths as
+	 * well as on success, is the one that matters functionally: an inode
+	 * reachable through bch2_inode_hash_find() always has its
+	 * by-inode-number entry. bch2_inode_or_descendents_is_open() answers
+	 * "not open" from that second table alone, and fsck deletes unlinked
+	 * inodes it believes are not open - so an inode findable in the cache
+	 * with no by-inode-number entry is the state that must never exist.
+	 * Inserting here first means that window never opens.
+	 *
+	 * The opposite - a by-inode-number entry with no cache entry - is
+	 * harmless and transient. It is also why bch2_inode_hash_remove() may
+	 * remove *this* entry first: it clears EI_INODE_HASHED under i_lock
+	 * before it does, so no concurrent bch2_inode_hash_find() can newly
+	 * reference the inode from that point on.
+	 *
+	 * This keeps the failure paths simple too: this is the only insertion
+	 * that may need an undo.
+	 */
+	ret = rhltable_insert(&c->vfs.inodes_by_inum_table,
+			      &inode->ei_inum_hash.hash,
+			      bch2_vfs_inodes_by_inum_params);
+	if (unlikely(ret)) {
+		clear_bit(EI_INODE_HASHED, &inode->ei_flags);
+		bch2_discard_unhashed_inode(inode);
+		return ERR_PTR(ret);
+	}
+
 retry:
-	if (unlikely(rhashtable_lookup_insert_key(&c->vfs.inodes_table,
+	ret = rhashtable_lookup_insert_key(&c->vfs.inodes_table,
 					&inode->ei_inum_hash.inum,
 					&inode->hash,
-					bch2_vfs_inodes_params))) {
+					bch2_vfs_inodes_params);
+	if (unlikely(ret)) {
+		/*
+		 * rhashtable_lookup_insert_key() returns -EEXIST when another
+		 * thread already has this inode in cache, but a real error
+		 * otherwise: the insert may allocate (a nested bucket table)
+		 * with GFP_ATOMIC, which fails under memory pressure with
+		 * -ENOMEM, and a concurrent rehash can fail it with -EBUSY,
+		 * -E2BIG, ... Only -EEXIST can be resolved by looking the
+		 * other inode up.
+		 */
+		if (ret != -EEXIST)
+			goto err;
+
 		old = bch2_inode_hash_find(c, trans, inode_inum(inode));
+		if (IS_ERR(old)) {
+			ret = PTR_ERR(old);
+			goto err;
+		}
 		if (!old)
 			goto retry;
 
-		clear_bit(EI_INODE_HASHED, &inode->ei_flags);
-
-		/*
-		 * bcachefs doesn't use I_NEW; we have no use for it since we
-		 * only insert fully created inodes in the inode hash table. But
-		 * discard_new_inode() expects it to be set...
-		 */
-		inode_state_set_raw(&inode->v, I_NEW);
 		/*
-		 * We don't want bch2_evict_inode() to delete the inode on disk,
-		 * we just raced and had another inode in cache. Normally new
-		 * inodes don't have nlink == 0 - except tmpfiles do...
+		 * Another inode with the same key is in cache, and is the one
+		 * returned: drop ours again - unless undoing the
+		 * by-inode-number insertion fails, in which case it is
+		 * deliberately leaked (see bch2_inode_hash_unhash()).
 		 */
-		set_nlink(&inode->v, 1);
-		discard_new_inode(&inode->v);
+		if (bch2_inode_hash_unhash(c, inode))
+			bch2_discard_unhashed_inode(inode);
 		return old;
-	} else {
-		int ret = rhltable_insert(&c->vfs.inodes_by_inum_table,
-					  &inode->ei_inum_hash.hash,
-					  bch2_vfs_inodes_by_inum_params);
-		BUG_ON(ret);
+	}
 
-		inode_fake_hash(&inode->v);
+	inode_fake_hash(&inode->v);
 
-		inode_sb_list_add(&inode->v);
+	inode_sb_list_add(&inode->v);
 
-		fast_list_set(&c->vfs.inodes, inode->ei_inodes_idx, inode);
-		return inode;
-	}
+	fast_list_set(&c->vfs.inodes, inode->ei_inodes_idx, inode);
+	return inode;
+err:
+	/*
+	 * The inode never went into the inode cache, so undoing the
+	 * by-inode-number insertion is all there is to do - and if even that
+	 * fails, the inode is deliberately leaked (see
+	 * bch2_inode_hash_unhash()).
+	 */
+	if (bch2_inode_hash_unhash(c, inode))
+		bch2_discard_unhashed_inode(inode);
+	return ERR_PTR(ret);
 }
 
 static struct inode *bch2_alloc_inode(struct super_block *sb)
  '';

  lookupPatch = builtins.toFile "bcachefs-lookup-error-propagation.patch" ''
    --- a/fs/vfs/fs.c	2026-11-04 12:15:34.981538663 +0100
+++ b/fs/vfs/fs.c	2026-11-04 12:15:34.982470012 +0100
@@ -1060,12 +1060,29 @@
 	int ret = bch2_hash_info_init(c, &dir->ei_inode, &hash);
 	bch_err_fn(c, ret);
 	if (ret)
-		return d_splice_alias(NULL, dentry);
+		/*
+		 * A failure here (casefolded directory, casefold not enabled
+		 * on this filesystem) is not "no such name": answering with a
+		 * negative dentry would make the directory look empty.
+		 */
+		return ERR_PTR(bch2_err_class(ret));
 
 	struct bch_inode_info *inode;
-	bch2_trans_do(c,
+	ret = bch2_trans_do(c,
 		PTR_ERR_OR_ZERO(inode = bch2_lookup_trans(trans, inode_inum(dir),
 							  &hash, &dentry->d_name)));
+	/*
+	 * ENOENT is the normal "no such name" answer and has to stay a
+	 * negative dentry: lookup_open() calls ->lookup() with LOOKUP_CREATE
+	 * and turns an ERR_PTR(-ENOENT) into a failed open(O_CREAT). Every
+	 * other error is real and must be reported as such - turning it into
+	 * "this name does not exist" is how an allocation failure in
+	 * bch2_new_inode() or bch2_inode_hash_insert() used to be reported as
+	 * a hidden ENOENT for a file that does exist.
+	 */
+	if (ret && !bch2_err_matches(ret, ENOENT))
+		return ERR_PTR(bch2_err_class(ret));
+
 	if (IS_ERR(inode))
 		inode = NULL;
 
  '';

  mutationPatch = builtins.toFile "bcachefs-inode-hash-mutation.patch" ''
    --- a/fs/vfs/fs.c
+++ b/fs/vfs/fs.c
@@ -566,6 +566,7 @@
 	ret = rhltable_insert(&c->vfs.inodes_by_inum_table,
 			      &inode->ei_inum_hash.hash,
 			      bch2_vfs_inodes_by_inum_params);
+	BUG_ON(ret);
 	if (unlikely(ret)) {
 		clear_bit(EI_INODE_HASHED, &inode->ei_flags);
 		bch2_discard_unhashed_inode(inode);
  '';

  applyFix = ''
    patch -p2 --batch --directory=src/fs/bcachefs < ${fixV2Patch}
    patch -p2 --batch --directory=src/fs/bcachefs < ${lookupPatch}
  '';

  applyMutation = ''
    patch -p2 --batch --directory=src/fs/bcachefs < ${mutationPatch}
  '';

  variants = {
    unpatched = {
      patchScript = "";
      expectBug = true;
      description = "stock out-of-tree module, no fix";
    };
    patched = {
      patchScript = applyFix;
      expectBug = false;
      description = "v2 fix + lookup companion";
    };
    mutated = {
      patchScript = applyFix + applyMutation;
      expectBug = true;
      description = "v2 fix + lookup companion + mutation restoring BUG_ON(ret)";
    };
  };

  variantNames = lib.attrNames variants;

  commonNode =
    { pkgs, ... }:
    {
      virtualisation.emptyDiskImages = [ 4096 ];
      # The workload needs several tasks inserting inodes at the same time.
      virtualisation.cores = 4;
      virtualisation.memorySize = 2048;

      networking.hostId = "deadbeef";

      boot.supportedFilesystems = [ "bcachefs" ];
      boot.kernelPatches = [ faultInjectionPatch ];
      # The oops must survive in dmesg long enough to be asserted on.
      boot.kernelParams = [ "log_buf_len=8M" ];

      environment.systemPackages = with pkgs; [
        bcachefs-tools
        coreutils
        kmod
        python3
        util-linux
        xz
      ];
    };

  expectations = builtins.toJSON (
    lib.mapAttrs (n: v: {
      expectBug = v.expectBug;
      description = v.description;
    }) variants
  );
in
{
  name = "bcachefs-inode-hash";

  meta = {
    inherit (pkgs.bcachefs-tools.meta) maintainers;
  };

  nodes = lib.genAttrs variantNames (
    name:
    { config, pkgs, ... }:
    let
      # The node's kernel, i.e. the fault-injection one.
      kp = config.boot.kernelPackages;

      # Exactly the derivation NixOS itself builds for
      # `boot.bcachefs.modulePackage`, plus the source patches.
      mkModule =
        extraPatch:
        (kp.callPackage pkgs.bcachefs-tools.kernelModule { }).overrideAttrs (old: {
          postPatch = (old.postPatch or "") + extraPatch;
        });

      modules = lib.mapAttrs (n: v: mkModule v.patchScript) variants;
    in
    {
      imports = [ commonNode ];

      # Only one module can occupy the module tree (all three install
      # updates/src/fs/bcachefs/bcachefs.ko): this is the one under test.
      boot.bcachefs.modulePackage = modules.${name};

      # All three builds are installed as plain trees, so the test can prove
      # inside the VM which one the kernel actually loaded.
      environment.etc = lib.mapAttrs' (
        n: m:
        lib.nameValuePair "bcachefs-variants/${n}" {
          source = "${m}/lib/modules";
        }
      ) modules;
    }
  );

  testScript = ''
    import json
    import textwrap
    import time

    EPATH = "/etc/bcachefs-variants"
    DISK = "/dev/vdb"
    MNT = "/mnt"
    VARIANTS = ["unpatched", "patched", "mutated"]
    EXPECT = json.loads("""${expectations}""")

    # --- workload shape ----------------------------------------------------------
    NFILES = 20000
    # All walkers start at the same instant on a freshly mounted filesystem.  That
    # is what makes the two inode rhashtables overshoot their load factor before the
    # asynchronous rehash worker can grow them, which is the state in which an
    # insertion takes the allocating (and therefore failable) path.
    NWALKERS = 16
    CYCLES = 12
    WALK_TIMEOUT = 30

    # --- fault injection ---------------------------------------------------------
    # Primary: failslab, task-filtered.  It fails kmem_cache_alloc() itself, for the
    # tasks that marked themselves with /proc/<pid>/make-it-fail, and with the
    # default ignore-gfp-wait=1 it only touches allocations that cannot reclaim -
    # i.e. the GFP_ATOMIC / GFP_NOWAIT allocations of the rhashtable insertion path,
    # including `kmalloc(PAGE_SIZE, GFP_ATOMIC|__GFP_ZERO)` in nested_table_alloc().
    # The rehash kworker is deliberately NOT marked, so the tables can still be
    # grown asynchronously and the walkers recover from the first insertion's
    # failure instead of spinning forever.
    FI_VERBOSE = 2
    # Mark kworker/* threads too, so the asynchronous rehash cannot heal the tables.
    MARK_KWORKERS = 1
    # Push the rehash workers to SCHED_IDLE during the walk (see the report).
    DEPRIORITIZE_KWORKERS = 1
    FI_VERBOSE_RATELIMIT_MS = 50
    FI_USE_FAILSLAB = True
    FI_SLAB_PROBABILITY = 70
    FI_SLAB_TASK_FILTER = 1
    FI_SLAB_IGNORE_GFP_WAIT = 0
    FI_SLAB_CACHE_FILTER = 1

    # Secondary: fail_page_alloc (off by default).
    FI_USE_FAIL_PAGE_ALLOC = False
    FI_PAGE_PROBABILITY = 100
    FI_PAGE_MIN_ORDER = 0
    FI_PAGE_IGNORE_GFP_WAIT = 0
    FI_PAGE_IGNORE_GFP_HIGHMEM = 1
    FI_PAGE_TASK_FILTER = 1

    FAILSLAB = "/sys/kernel/debug/failslab"
    FAILPAGE = "/sys/kernel/debug/fail_page_alloc"

    # `times` is decremented once per injected failure, so a large budget turned
    # into a counter: FI_TIMES_BUDGET - <value read back> is the exact number of
    # allocations the injection actually failed.
    FI_TIMES_BUDGET = 2000000000


    def fi_times(machine, knob):
        try:
            return int(machine.succeed("cat " + knob + "/times").strip())
        except (ValueError, AttributeError):
            return -1


    WALKER_SRC = r"""
    import json
    import os
    import sys
    import time

    # Printing a traceback reads the source file back; that path is not needed here
    # and must not be allowed to abort the process before it reports.
    sys.tracebacklimit = 0

    mnt = sys.argv[1]
    nfiles = int(sys.argv[2])
    shard = int(sys.argv[3])
    nshards = int(sys.argv[4])
    usefault = int(sys.argv[5])
    startat = float(sys.argv[6])


    def main():
        if usefault:
            try:
                with open("/proc/self/make-it-fail", "w") as f:
                    f.write("1")
            except OSError:
                pass

        # Busy-wait for the common start instant: every walker begins its stat()
        # loop in the same microsecond, which is what lets the insertions arrive in
        # a burst rather than spread out over milliseconds.
        while time.time() < startat:
            pass

        t_loop = time.time()
        stats = 0
        enoent = 0
        errs = 0
        kinds = {}
        first_at = 0.0
        i = shard
        while i < nfiles:
            try:
                os.stat(mnt + "/f" + str(i))
                stats += 1
                if not first_at:
                    first_at = time.time()
            except FileNotFoundError:
                enoent += 1
            except BaseException as e:
                errs += 1
                name = type(e).__name__ + "/errno=" + str(e.errno) if isinstance(e, OSError) else type(e).__name__
                kinds[name] = kinds.get(name, 0) + 1
            i += nshards
        return {
            "shard": shard,
            "stats": stats,
            "enoent": enoent,
            "errs": errs,
            "kinds": kinds,
            "elapsed": round(time.time() - t_loop, 3),
            "first_at": round(first_at - t_loop, 6) if first_at else None,
        }


    try:
        result = main()
    except BaseException as e:
        result = {"shard": shard, "fatal": type(e).__name__ + ": " + str(e)}
    print(json.dumps(result))
    """

    DEPRIO_SRC = r"""
    import os
    import sys

    policy = os.SCHED_IDLE if sys.argv[1] == "idle" else os.SCHED_OTHER
    n = 0
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open("/proc/" + d + "/comm") as f:
                comm = f.read().strip()
        except OSError:
            continue
        if not comm.startswith("kworker"):
            continue
        try:
            os.sched_setscheduler(int(d), policy, os.sched_param(0))
            n += 1
        except OSError:
            pass
    print("kworkers set to " + sys.argv[1] + ": " + str(n))
    """

    MARKKW_SRC = r"""
    import os
    import sys
    import time

    # Runs unmarked, so that marking the workers does not itself depend on an
    # allocation that the injection may be failing.
    stop = sys.argv[1]
    while not os.path.exists(stop):
        for d in os.listdir("/proc"):
            if not d.isdigit():
                continue
            try:
                with open("/proc/" + d + "/comm") as f:
                    comm = f.read().strip()
            except OSError:
                continue
            if not comm.startswith("kworker"):
                continue
            try:
                with open("/proc/" + d + "/make-it-fail", "w") as f:
                    f.write("1")
            except OSError:
                pass
        time.sleep(0.02)
    """

    WALK_SRC = r"""
    #!/bin/sh
    # $1 mount point, $2 nfiles, $3 nwalkers, $4 start delay in seconds,
    # $5 mark the rehash workers with make-it-fail
    mnt=$1
    n=$2
    w=$3
    delay=$4
    markkw=$5
    rm -f /run/stopmark
    if [ "$5" = "1" ]; then
      python3 /run/markkw.py /run/stopmark &
    fi
    startat=$(python3 -c "import time,sys;print(time.time()+float(sys.argv[1]))" "$delay")
    i=0
    while [ $i -lt $w ]; do
      python3 /run/walker.py "$mnt" "$n" "$i" "$w" 1 "$startat" > /run/walk.$i.out 2>&1 &
      i=$((i+1))
    done
    wait
    touch /run/stopmark
    cat /run/walk.*.out
    """


    PROBLEMS = []


    def check(machine, cond, msg):
        if cond:
            return True
        machine.log("PROBLEM: " + msg)
        PROBLEMS.append(msg)
        return False


    def count_lines(machine, pattern):
        status, out = machine.execute("dmesg | grep -c '" + pattern + "' || true")
        out = out.strip()
        try:
            return int(out.splitlines()[-1])
        except (ValueError, IndexError):
            return -1


    def bug_lines(machine):
        status, out = machine.execute(
            "dmesg | grep -B3 -A40 -m2 'kernel BUG at ' | head -160"
        )
        return out


    def ko_hash(machine, path):
        if path.endswith(".xz"):
            return machine.succeed(
                "xz -dc " + path + " | sha256sum | cut -d' ' -f1"
            ).strip()
        return machine.succeed("sha256sum " + path + " | cut -d' ' -f1").strip()


    # A function the v2 fix introduces.  It cannot be present in the stock build, so
    # finding it in the *loaded* module image proves that the patched source really
    # is what the kernel is running (the sha256 check alone only proves which of the
    # three installed builds was loaded).
    PATCH_MARKER = "bch2_discard_unhashed_inode"


    def ko_marker_count(machine, path):
        if path.endswith(".xz"):
            cmd = "xz -dc " + path + " | grep -a -c " + PATCH_MARKER + " || true"
        else:
            cmd = "grep -a -c " + PATCH_MARKER + " " + path + " || true"
        out = machine.succeed(cmd).strip()
        try:
            return int(out.splitlines()[-1])
        except (ValueError, IndexError):
            return -1


    def modinfo_path(machine):
        p = machine.succeed("modinfo -n bcachefs").strip()
        for cand in (p, p + ".xz", p[:-3] if p.endswith(".xz") else p + ".ko"):
            status, _ = machine.execute("test -e " + cand)
            if status == 0:
                return cand
        raise AssertionError("no module file found for modinfo -n bcachefs -> " + p)


    def variant_modules(machine):
        """path of each variant's bcachefs.ko as installed under /etc"""
        paths = {}
        for v in VARIANTS:
            p = machine.succeed(
                "find -H " + EPATH + "/" + v + " -name 'bcachefs.ko*' -print -quit"
            ).strip()
            assert p, "no bcachefs.ko installed for variant " + v
            paths[v] = p
        return paths


    def verify_module_identity(machine, name):
        paths = variant_modules(machine)
        hashes = {v: ko_hash(machine, p) for v, p in paths.items()}
        markers = {v: ko_marker_count(machine, p) for v, p in paths.items()}
        assert len(set(hashes.values())) == len(VARIANTS), (
            "the three variants must be three different builds, got " + repr(hashes)
        )
        for v in VARIANTS:
            assert (markers[v] > 0) == (v in ("patched", "mutated")), (
                "the "
                + v
                + " build has an unexpected "
                + PATCH_MARKER
                + " count: "
                + repr(markers)
            )

        loaded_path = modinfo_path(machine)
        loaded = ko_hash(machine, loaded_path)
        for v in VARIANTS:
            assert (loaded == hashes[v]) == (v == name), (
                "the loaded module ("
                + loaded_path
                + ", sha256 "
                + loaded
                + ") is not the "
                + name
                + " build; per-variant hashes: "
                + repr(hashes)
            )
        loaded_marker = ko_marker_count(machine, loaded_path)
        want_marker = name in ("patched", "mutated")
        assert (loaded_marker > 0) == want_marker, (
            "the loaded module "
            + loaded_path
            + " carries "
            + ("no " if loaded_marker == 0 else "some ")
            + PATCH_MARKER
            + ", so it is not the "
            + name
            + " build"
        )
        machine.log(
            "module identity OK for node "
            + name
            + ": modinfo -n bcachefs -> "
            + loaded_path
            + " sha256="
            + loaded
            + " "
            + PATCH_MARKER
            + "="
            + str(loaded_marker)
            + "; per-variant sha256 "
            + repr(hashes)
            + "; per-variant "
            + PATCH_MARKER
            + " "
            + repr(markers)
        )
        machine.succeed("modprobe bcachefs")
        machine.succeed("grep -q '^bcachefs ' /proc/modules")
        machine.succeed("bcachefs version")


    def slab_cache_filter(machine, enable):
        """Set/clear SLAB_FAILSLAB on the kmalloc caches.

        Bucket tables come from kmalloc-128 .. kmalloc-32k, and the rehash worker
        (GFP_KERNEL) is only reachable with `ignore-gfp-wait=0`; restricting
        failslab to those caches keeps that from hitting everything else.
        """
        val = 1 if enable else 0
        status, out = machine.execute(
            "n=0; bad=0; badnames=; "
            "for d in /sys/kernel/slab/*; do "
            "case $(basename $d) in kmalloc*) "
            "if echo " + str(val) + " > $d/failslab 2>/dev/null; then n=$((n+1)); "
            "else bad=$((bad+1)); badnames=$badnames $(basename $d); fi;; esac; "
            'done; echo "set=$n refused=$bad"; echo "refused:$badnames" | head -c 400'
        )
        machine.log(
            "slab cache filter "
            + ("on" if enable else "off")
            + ": "
            + out.replace("\n", " ")
        )
        return out


    def debugfs(machine):
        machine.succeed("mkdir -p /sys/kernel/debug")
        status, _ = machine.execute("mountpoint -q /sys/kernel/debug")
        if status != 0:
            machine.succeed("mount -t debugfs none /sys/kernel/debug")


    def fi_off(machine):
        machine.succeed("echo 0 > " + FAILSLAB + "/probability || true")
        machine.succeed("echo 0 > " + FAILPAGE + "/probability || true")


    def inject(machine, enable):
        # Arm (or disarm) both fault-injection attributes.
        #
        # Order matters: every knob that limits the injection (verbose, task-filter,
        # times, space) must be in place *before* probability is raised.  Otherwise
        # the whole VM is injected for a moment, every injected failure dumps a
        # stack, and the resulting serial-console flood wedges the test driver.
        debugfs(machine)
        attrs = (
            (
                FAILSLAB,
                FI_USE_FAILSLAB,
                FI_SLAB_PROBABILITY,
                (
                    ("verbose", FI_VERBOSE),
                    ("verbose_ratelimit_burst", 1),
                    ("verbose_ratelimit_interval_ms", FI_VERBOSE_RATELIMIT_MS),
                    ("task-filter", FI_SLAB_TASK_FILTER),
                    ("cache-filter", FI_SLAB_CACHE_FILTER),
                    ("ignore-gfp-wait", FI_SLAB_IGNORE_GFP_WAIT),
                    ("space", 0),
                    ("times", FI_TIMES_BUDGET),
                    ("interval", 1),
                ),
            ),
            (
                FAILPAGE,
                FI_USE_FAIL_PAGE_ALLOC,
                FI_PAGE_PROBABILITY,
                (
                    ("verbose", FI_VERBOSE),
                    ("verbose_ratelimit_burst", 1),
                    ("verbose_ratelimit_interval_ms", FI_VERBOSE_RATELIMIT_MS),
                    ("task-filter", FI_PAGE_TASK_FILTER),
                    ("min-order", FI_PAGE_MIN_ORDER),
                    ("ignore-gfp-wait", FI_PAGE_IGNORE_GFP_WAIT),
                    ("ignore-gfp-highmem", FI_PAGE_IGNORE_GFP_HIGHMEM),
                    ("space", 0),
                    ("times", FI_TIMES_BUDGET),
                    ("interval", 1),
                ),
            ),
        )
        for knob, active, prob, values in attrs:
            for k, v in values:
                machine.succeed("echo " + str(v) + " > " + knob + "/" + k)
            machine.succeed(
                "echo "
                + str(prob if (active and enable) else 0)
                + " > "
                + knob
                + "/probability"
            )
            status, out = machine.execute(
                "for f in " + knob + "/*; do echo -n \"$f=\"; cat $f; done | tr '\\n' ' '"
            )
            machine.log(
                "injection "
                + ("on" if (active and enable) else "off")
                + " ("
                + knob
                + "): "
                + out.replace("\n", " ")
            )


    def fi_failed(machine):
        """Exact number of allocations each attribute actually failed."""
        total = 0
        for knob, on in ((FAILSLAB, FI_USE_FAILSLAB), (FAILPAGE, FI_USE_FAIL_PAGE_ALLOC)):
            if not on:
                continue
            left = fi_times(machine, knob)
            if left >= 0:
                total += FI_TIMES_BUDGET - left
        return total


    def write_helpers(machine):
        machine.succeed(
            "cat > /run/walker.py <<'PYEOF'\n"
            + textwrap.dedent(WALKER_SRC).strip()
            + "\nPYEOF"
        )
        machine.succeed(
            "cat > /run/markkw.py <<'MKW_SRC'\n"
            + textwrap.dedent(MARKKW_SRC).strip()
            + "\nMKW_SRC"
        )
        machine.succeed(
            "cat > /run/deprio.py <<'DEPSRC'\n"
            + textwrap.dedent(DEPRIO_SRC).strip()
            + "\nDEPSRC"
        )
        machine.succeed(
            "cat > /run/walk.sh <<'SHEOF'\n" + textwrap.dedent(WALK_SRC).strip() + "\nSHEOF"
        )
        machine.succeed("chmod +x /run/walk.sh")


    def prepare_fs(machine):
        machine.succeed("udevadm settle")
        machine.succeed("mkfs.bcachefs --force -L inodehash " + DISK)
        machine.succeed("mkdir -p " + MNT)
        machine.succeed("mount -t bcachefs " + DISK + " " + MNT)
        machine.succeed(
            "cd " + MNT + " && python3 -c '"
            "import os\n"
            "for i in range(" + str(NFILES) + "):\n"
            '    fd = os.open("f" + str(i), os.O_CREAT | os.O_WRONLY, 0o600)\n'
            "    os.close(fd)\n"
            "'"
        )
        machine.succeed(
            "dd if=/dev/urandom of=" + MNT + "/target.bin bs=1M count=4 conv=fsync"
        )
        machine.succeed("sha256sum " + MNT + "/target.bin > /run/target.sha256")
        machine.succeed("sync")
        machine.succeed("umount " + MNT)
        machine.log("filesystem prepared with " + str(NFILES) + " files + target.bin")


    def run_walk(machine, cycle, injected):
        """Run one walk, optionally with the fault injection armed."""
        machine.succeed("rm -f /run/walk.*.out")
        if injected:
            slab_cache_filter(machine, True)
            inject(machine, True)
        status, out = machine.execute(
            "timeout "
            + str(WALK_TIMEOUT)
            + " sh /run/walk.sh "
            + MNT
            + " "
            + str(NFILES)
            + " "
            + str(NWALKERS)
            + " 2 "
            + str(MARK_KWORKERS)
            + " || true",
            timeout=WALK_TIMEOUT + 120,
        )
        failed = fi_failed(machine) if injected else 0
        if injected:
            inject(machine, False)
            slab_cache_filter(machine, False)
        machine.log(
            "cycle "
            + str(cycle)
            + ": walk exit status "
            + str(status)
            + ", allocations actually failed = "
            + str(failed)
        )
        machine.log("cycle " + str(cycle) + ": walk output\n" + out)
        # A walker stuck in the allocation-failure retry loop must not poison the
        # rest of the run (the unpatched module can livelock there, see the report).
        machine.execute("timeout 20 pkill -9 -f '^python3 /run/walker.py' || true")
        machine.execute("timeout 20 pkill -9 -f '^/run/walk.sh' || true")
        return failed


    def walker_totals(machine):
        status, out = machine.execute("cat /run/walk.*.out 2>/dev/null || true")
        tot = {
            "stats": 0,
            "enoent": 0,
            "errs": 0,
            "count": 0,
            "kinds": {},
            "fatal": [],
            "elapsed": 0.0,
            "first_at": [],
        }
        for line in out.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            tot["count"] += 1
            if "fatal" in d:
                tot["fatal"].append(repr(d["fatal"]))
                continue
            for k in ("stats", "enoent", "errs"):
                tot[k] += d.get(k, 0)
            for k, n in d.get("kinds", {}).items():
                tot["kinds"][k] = tot["kinds"].get(k, 0) + n
            tot["elapsed"] = max(tot["elapsed"], d.get("elapsed") or 0)
            if d.get("first_at") is not None:
                tot["first_at"].append(d["first_at"])
        tot["first_at"].sort()
        return tot


    def check_walk_complete(machine, tot, cycle, expect_files):
        """A walk that did not actually run proves nothing: fail loudly."""
        ok = check(
            machine,
            tot["count"] == NWALKERS,
            "cycle "
            + str(cycle)
            + ": only "
            + str(tot["count"])
            + " of "
            + str(NWALKERS)
            + " walkers reported: "
            + repr(tot),
        )
        check(machine, not tot["fatal"], "cycle " + str(cycle) + ": " + repr(tot["fatal"]))
        check(
            machine,
            tot["stats"] + tot["enoent"] + tot["errs"] == expect_files,
            "cycle "
            + str(cycle)
            + ": the walk did not account for every file: "
            + repr(tot),
        )
        return ok


    def umount(machine, cycle):
        status, out = machine.execute(
            "timeout 30 umount " + MNT + " || timeout 15 umount -l " + MNT + " || true"
        )
        machine.log("cycle " + str(cycle) + ": umount output " + out.strip())
        return status


    def scenario(machine, name, expect_bug):
        machine.log("=== node " + name + ": " + EXPECT[name]["description"] + " ===")

        # The point of the test is that an oops is survivable: set it explicitly and
        # assert it, do not assume it.
        machine.succeed("echo 0 > /proc/sys/kernel/panic_on_oops")
        panic = machine.succeed("cat /proc/sys/kernel/panic_on_oops").strip()
        assert panic == "0", "panic_on_oops is " + panic + ": an oops would reboot the VM"

        write_helpers(machine)
        verify_module_identity(machine, name)

        debugfs(machine)
        fi_off(machine)
        status, out = machine.execute("ls /sys/kernel/slab/ | tr '\\n' ' ' | head -c 2000")
        machine.log("slab cache names: " + out)

        prepare_fs(machine)
        base_bugs = count_lines(machine, "kernel BUG at ")
        machine.log("baseline 'kernel BUG at' count: " + str(base_bugs))

        # One mount for all the cycles, plus a warm-up walk: that leaves the btree
        # and page caches hot, so a measured walk only has to *repopulate the inode
        # cache*.  A cold walk instead spends milliseconds per file reading btrees,
        # which gives the asynchronous rehash worker ample time to grow the tables
        # long before they can overshoot their load factor.
        machine.succeed("mount -t bcachefs " + DISK + " " + MNT)
        run_walk(machine, "warmup", False)
        warm = walker_totals(machine)
        machine.log("warmup walker totals: " + repr(warm))
        check_walk_complete(machine, warm, "warmup", NFILES)

        def drop_vfs_caches(tag):
            # Evicts dentries and idle inodes, i.e. empties the two inode
            # rhashtables (and lets them shrink back to their minimum size), while
            # keeping the btree and page caches warm.
            machine.succeed("sync")
            status, out = machine.execute("echo 3 > /proc/sys/vm/drop_caches")
            machine.log(tag + ": drop_caches status " + str(status))

        # --- control cycle: the workload alone, with the injection off -----------
        drop_vfs_caches("control")
        run_walk(machine, "control", False)
        control = walker_totals(machine)
        machine.log("control walker totals: " + repr(control))
        check_walk_complete(machine, control, "control", NFILES)
        check(
            machine,
            control["errs"] == 0 and control["enoent"] == 0,
            "the control walk (no injection) did not read every file cleanly: "
            + repr(control),
        )
        check(
            machine,
            count_lines(machine, "kernel BUG at ") == base_bugs,
            "the control walk crashed the kernel on its own",
        )

        # --- injection cycles ----------------------------------------------------
        bugs = base_bugs
        injected = 0
        for cycle in range(CYCLES):
            drop_vfs_caches("cycle " + str(cycle))
            # The drop above schedules the shrink of both inode rhashtables back to
            # their minimum size; let the rehash workers do that first, *then* push
            # them to SCHED_IDLE so that they cannot undo the overshoot the walkers
            # are about to create.  (The workers are also what makes a plain
            # walk unable to overshoot: a rehash of a small table is over long
            # before a walker can insert 0.25 * size more inodes.)
            time.sleep(1.0)
            if DEPRIORITIZE_KWORKERS:
                status, out = machine.execute("timeout 60 python3 /run/deprio.py idle")
                machine.log("cycle " + str(cycle) + ": deprioritise rehash workers: " + out)
            injected = run_walk(machine, cycle, True)
            if DEPRIORITIZE_KWORKERS:
                status, out = machine.execute("timeout 60 python3 /run/deprio.py other")
                machine.log("cycle " + str(cycle) + ": restore rehash workers: " + out)
            bugs = count_lines(machine, "kernel BUG at ")
            cycle_tot = walker_totals(machine)
            machine.log(
                "cycle "
                + str(cycle)
                + ": kernel BUG count = "
                + str(bugs)
                + " (baseline "
                + str(base_bugs)
                + "), allocations actually failed = "
                + str(injected)
                + ", walkers = "
                + repr(cycle_tot)
            )
            if bugs > base_bugs:
                break
            check_walk_complete(machine, cycle_tot, cycle, NFILES)
        fi_off(machine)
        machine.log("allocations actually failed in the last cycle = " + str(injected))

        tot = walker_totals(machine)
        machine.log("last cycle walker totals: " + repr(tot))
        traces = count_lines(machine, "bch2_inode_hash_insert")
        machine.log("dmesg lines mentioning bch2_inode_hash_insert: " + str(traces))
        machine.log("per-cycle stats, all cycles: " + repr(tot))

        if bugs > base_bugs:
            machine.log("--- dmesg oops ---\n" + bug_lines(machine))

        # The VM must still be alive after the oops (panic_on_oops=0).
        machine.succeed("echo alive > /run/alive && cat /run/alive")

        if expect_bug:
            check(
                machine,
                bugs > base_bugs,
                "expected the BUG_ON in bch2_inode_hash_insert to fire with the "
                + name
                + " module but dmesg has no new `kernel BUG at` line; "
                + "walker totals: "
                + repr(tot),
            )
            check(
                machine,
                traces > 0,
                "a BUG fired but no oops mentions bch2_inode_hash_insert: "
                + bug_lines(machine),
            )
            machine.log(
                "OK: "
                + name
                + " reproduced the inode-hash BUG ("
                + str(bugs - base_bugs)
                + " new oops)"
            )
        else:
            check(
                machine,
                bugs == base_bugs,
                "the patched module still crashed: "
                + str(bugs - base_bugs)
                + " new `kernel BUG at` line(s) in dmesg\n"
                + bug_lines(machine),
            )
            check_walk_complete(machine, tot, "final", NFILES)
            check(
                machine,
                tot["enoent"] == 0,
                "an existing file became ENOENT under allocation failure: the "
                "lookup companion patch is not propagating the error: " + repr(tot),
            )
            machine.succeed("sha256sum -c /run/target.sha256")
            machine.succeed("umount " + MNT)
            status, out = machine.execute("timeout 300 bcachefs fsck -n " + DISK + " 2>&1")
            machine.log("fsck -n exit status " + str(status) + "\n" + out)
            check(
                machine,
                status == 0,
                "filesystem is not clean after the run (status " + str(status) + ")",
            )
            machine.log("OK: " + name + " survived the whole run with no crash")


    start_all()

    for _name, _node in (
        ("unpatched", unpatched),
        ("patched", patched),
        ("mutated", mutated),
    ):
        scenario(_node, _name, EXPECT[_name]["expectBug"])

    assert not PROBLEMS, (
        "the test found " + str(len(PROBLEMS)) + " problem(s):\n" + "\n".join(PROBLEMS)
    )

  '';
}
