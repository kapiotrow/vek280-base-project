# Build flow

**Status:** current 2026-11-11 — phase 0 (PS + PL). The AIE steps are marked.

## What the artifacts actually are

Vitis names things unhelpfully. In order of appearance:

| artifact | made by | what it is |
|---|---|---|
| `.xo` | `v++ -c` | one PL kernel, synthesised from C++ to RTL and zipped with its `kernel.xml` interface description. One per kernel |
| `libadf.a` | `aiecompiler` | the compiled AI Engine graph: core binaries, DMA configuration, the whole array programme. *(phase 1)* |
| `.xsa` | `v++ -l` | the **linked system**: your `.xo`s and `libadf.a` placed into the platform's block design, routed, with the NoC and clocks resolved. This is the long step |
| `.xclbin` | `v++ --package` | the runtime-loadable container XRT opens. Built from the `.xsa` |
| SD image | `v++ --package` | `.xclbin` + Linux `Image` + rootfs + your ELF + whatever else you listed as `--package.sd_file` |

The three `v++` modes — `-c`, `-l`, `--package` — are the whole flow. Everything
in the Makefile is one of them, plus a compiler for the host.

## Targets

```
make check_env      validate the toolchain. Run it first, always.

make test_host      rung 1   native, ms
make test_pl        rung 3   native, s

make kernels        .xo      v++ -c, one per PL kernel        ~20 s
make xsa            .xsa     v++ -l                           minutes
make application    .elf     $(CXX), cross for the APU        ~1 s
make rootfs         a packageable COPY of the common rootfs
make package        the bootable image / emulation package
make sd_card        kernels + xsa + application + package

make run_emu LAUNCH_HW_EMU_EXEC=1     rung 5
make clean / cleanall
make print-<KNOB>   one default, as the docs quote it
```

Artifacts land in `build/$(TARGET)/`, so an `hw_emu` tree and a `hw` tree coexist.

## Three things in here are generated, not committed

Each one is generated because committing it would bake a machine-specific or
target-specific value into the repository.

**`build/$(TARGET)/base.cfg`**, from `design/system_configs/base.cfg.in`. v++
demands an **absolute** path for `userPostSysLinkOverlayTcl`. Committing one
means the project builds on exactly one machine; the reference project this is
derived from has `/home/<someone>/...` in its linker config to this day. The
Makefile substitutes `@PROJECT_ROOT@`.

**`build/$(TARGET)/run_script.sh`**, from `design/exec_scripts/run_script.sh`.
`XCL_EMULATION_MODE` must be set for `hw_emu` and must **not** be set on
hardware — it tells XRT to open the emulation driver instead of the device. The
Makefile substitutes `@EMU_MODE@` per target. Packaging the template verbatim
produces a hardware image that cannot talk to its own hardware.

**`build/rootfs/rootfs.ext4`**, a copy of the common-image rootfs with three
ext4 features stripped. See [06-traps.md](06-traps.md) — packaging into the
pristine image corrupts it, reports success, and every subsequent run dies at
boot.

## Flag stamps

`BASE_N`, `MUTANT` and `TARGET` are make variables. They touch no source file,
so a prerequisite list built only from sources will happily reuse the previous
build's `.xo` and `.elf` — and the run then reports results from a binary you
did not build.

The `%.flagstamp` rule writes the flag list to a file, and only when it has
changed. Anything whose output depends on a flag depends on its stamp. The
reference project lost a debug cycle to precisely this: two configurations
produced byte-identical output because one had silently reused the other's
artifacts, and byte-identical output is extremely convincing.

If you add a knob that reaches a toolchain, add it to the relevant stamp in the
same commit.

## One variable, both toolchains

`MUTANT` reaches `v++` (as `-D MUTANT_SHORT=` / `-D MUTANT_VALUE=`) and `$(CXX)`
(as `-DMUTANT_ARMED=`) from one place in the Makefile.

That is a rule worth keeping as the project grows: **any constant that two
toolchains both need must be passed to both from a single Makefile variable.**
Derive it independently on each side and they will eventually disagree, and a
`#ifndef` default in the host is what makes that disagreement silent instead of
a compile error.
