# env-templates — u-boot defenv as board-agnostic templates

One logic, one template; each board supplies parameters. This replaces the
hand-maintained per-board defenv patch hunks with generated patches.

## Layout
- `media/<medium>.env.in` — **board-agnostic** defenv templates (emmc / sdmmc /
  snand). Board-specific strings appear as `@DTBBASE@` / `@IMGPREFIX@` placeholders.
  This is the **source of truth** — edit logic here, once, for all boards.
- `boards/<board>.params` — per-board values (`DTBBASE`, `IMGPREFIX`,
  `DEFENV_BASE`, `MEDIA`, `SOC_ENV`). A new board = a new params file (+ vendored
  pristine). Sets `SOC_ENV=<soc>` to pull the shared per-SoC constants.
- `soc/<soc>.params` — per-SoC env constants shared by all boards of that SoC
  (`LOADADDR`, `BOOTARGS_BASE`, `UBOOTENV_VOL`, `SNAND_WRITE_BL2`,
  `RESET_FACTORY_SNAND`). Values containing `$loadaddr`/`&&` are single-quoted
  (u-boot env text, not shell). mt7988/7987/7986 each have a set.
- `pristine/<DEFENV_BASE>_<medium>_env` — the OpenWrt-pristine defenv, i.e. the
  file as created by `uboot-mediatek/patches/450-add-bpi-r4.patch`. Used only as
  the diff base when generating the replacement patch. **Re-vendor if the u-boot
  version or the OpenWrt 450 patch changes.**
- `gen-defenv.sh` — generator.

## Output (generated, committed, do NOT hand-edit)
`patches/<board>/uboot/z06-bpirouter-defenv-<medium>.patch` — each replaces the
pristine defenv with the A/B-enabled env. The build flow is **unchanged**:
`prepare.sh` copies these like any other patch and OpenWrt applies them after 450.

## Workflow
```sh
# edit media/*.env.in (shared logic) or boards/<board>.params (board values), then:
./env-templates/gen-defenv.sh --board bpi-r4     # rewrites the z06 patches
git add env-templates patches/bpi-r4/uboot/z06-*.patch
# commit
```
`--verify` renders without writing and asserts no placeholder was left unset.

## Invariant
For an onboarded board, `gen-defenv.sh` output applied onto `pristine/` must equal
the maintained defenv patches byte-for-byte for each supported medium.

## What folded in here
- `z01` keeps only its 3 defconfig hunks (BOOTDELAY/AUTOBOOT); its defenv rewrites
  moved into the templates.
- `z04` (snand emmc_init both-slots) → `snand.env.in` / `z06-...-snand.patch`.
- `z05` (emmc A/B runtime + golden_restore) → `emmc.env.in` / `z06-...-emmc.patch`.
