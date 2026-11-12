#!/usr/bin/env python3
# Copyright (C) 2026 Ning <mimallaus@gmail.com>
"""Exercise the actual U-Boot erase command with injected flash failures."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--prepared', action='store_true', help='require the patch in the supplied source')
args = parser.parse_args()
build = Path(__file__).resolve().parents[1]
openwrt = Path(os.environ.get("OPENWRT_DIR", build / "openwrt"))
uboot = Path(os.environ.get("UBOOT_DIR", openwrt / "build_dir/target-aarch64_cortex-a53_musl/"
                           "u-boot-mt7981_openwrt_one-ram/u-boot-2025.10"))
cc = shutil.which("cc")
assert cc, "Install a host C compiler for the erase-command test"

# Keep the production control flow intact. Substitute only the MTD device,
# low-level erase/bad-block operations and unrelated LED/device helpers.
prefix = r'''
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef unsigned long long u64;
struct cmd_tbl { int unused; };
struct mtd_info { u64 size; unsigned int erasesize; };
struct erase_info { struct mtd_info *mtd; u64 addr; u64 len; };
static struct mtd_info device = { 0x80000, 0x20000 };
static int erase_error, error_block, bad_block, lookup_error_block;
static unsigned int attempted, lookups;
#define CMD_RET_USAGE 2
#define CMD_RET_FAILURE 1
#define CMD_RET_SUCCESS 0
#define IS_ERR_OR_NULL(p) (!(p))
static struct mtd_info *get_mtd_by_name(const char *name) {
    return strcmp(name, "spi-nand0") == 0 ? &device : NULL;
}
static u64 hextoul(const char *s, char **end) { return strtoull(s, end, 16); }
static bool mtd_is_aligned_with_block_size(struct mtd_info *m, u64 n) {
    return n % m->erasesize == 0;
}
static unsigned int mtd_div_by_eb(u64 n, struct mtd_info *m) { return n / m->erasesize; }
static int mtd_block_isbad(struct mtd_info *m, u64 addr) {
    int block = addr / m->erasesize;
    lookups |= 1U << block;
    if (block == lookup_error_block) return -EIO;
    return block == bad_block;
}
static int mtd_erase(struct mtd_info *m, struct erase_info *e) {
    int block = e->addr / m->erasesize;
    attempted |= 1U << block;
    return block == error_block ? erase_error : 0;
}
static void put_mtd_device(struct mtd_info *m) { (void)m; }
static void led_activity_blink(void) {}
static void led_activity_off(void) {}
'''
main = r'''
int main(int argc, char **argv) {
    if (argc != 6) return 2;
    char *command[] = { argv[5], "spi-nand0" };
    erase_error = atoi(argv[1]);
    error_block = atoi(argv[2]);
    bad_block = atoi(argv[3]);
    lookup_error_block = atoi(argv[4]);
    int ret = do_mtd_erase(NULL, 0, 2, command);
    printf("RESULT %d %u %u\n", ret, attempted, lookups);
    return ret;
}
'''

with tempfile.TemporaryDirectory(prefix="one-mtd-erase-") as tmp:
    root = Path(tmp)
    (root / "cmd").mkdir()
    shutil.copy2(uboot / "cmd/mtd.c", root / "cmd/mtd.c")
    patch = str(build / "patches/openwrt-one/uboot/z10-mtd-erase-failure.patch")
    if not args.prepared:
        check = subprocess.run(["git", "apply", "--check", patch], cwd=root, capture_output=True)
        if check.returncode == 0:
            subprocess.run(["git", "apply", patch], cwd=root, check=True)
    subprocess.run(["git", "apply", "--reverse", "--check", patch], cwd=root, check=True)
    source = (root / "cmd/mtd.c").read_text()
    function = "static int do_mtd_erase(" + source.split("static int do_mtd_erase(", 1)[1].split(
        "\nstatic int do_mtd_bad(", 1)[0]
    (root / "probe.c").write_text(prefix + function + main)
    subprocess.run([cc, "-std=c99", "-Wall", "-Wextra", "-Wno-unused-parameter",
                    "-o", str(root / "probe"), str(root / "probe.c")], check=True)
    # Four blocks: first/middle/last failure must stop before the next block.
    cases = [("success", 0, -1, -1, -1, 0, 15, 15)]
    for block in [0, 1, 3]:
        visited = (1 << (block + 1)) - 1
        for name, error in [("io", -5), ("other", -22)]:
            cases.append((f"{name}_{block}", error, block, -1, -1, 1, visited, visited))
        cases.append((f"known_bad_{block}", 0, -1, block, -1, 0, 15 ^ (1 << block), 15))
        cases.append((f"lookup_error_{block}", 0, -1, -1, block, 1, (1 << block) - 1, visited))
    cases.append(("bad_then_io", -5, 2, 0, -1, 1, 6, 7))
    cases = [("erase", *case) for case in cases]
    cases.append(("erase.dontskipbad", "scrub_success", 0, -1, -1, -1, 0, 15, 0))
    for block in [0, 1, 3]:
        visited = (1 << (block + 1)) - 1
        # Explicit scrub retains upstream -EIO handling, including reserved
        # blocks. Other errors still stop; no bad-block precheck is performed.
        cases.append(("erase.dontskipbad", f"scrub_io_{block}", -5, block, -1, -1, 0, 15, 0))
        cases.append(("erase.dontskipbad", f"scrub_other_{block}", -22, block, -1, -1, 1, visited, 0))
        cases.append(("erase.dontskipbad", f"scrub_bad_{block}", 0, -1, block, block, 0, 15, 0))
    failures = []
    for command, name, error, error_block, bad_block, lookup_block, exit_code, erased, checked in cases:
        result = subprocess.run([str(root / "probe"), str(error), str(error_block),
                                 str(bad_block), str(lookup_block), command], text=True, capture_output=True)
        expected = f"RESULT {exit_code} {erased} {checked}"
        if result.returncode != exit_code or result.stdout.splitlines()[-1] != expected:
            failures.append(f"{name}: expected {expected}; got {result.stdout.splitlines()[-1]}")
    assert not failures, "\n".join(failures)
    print(f"PASS: {len(cases)} actual erase-command cases, including failures and explicit scrub")
