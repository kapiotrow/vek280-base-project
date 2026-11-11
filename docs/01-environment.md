# Environment

**Status:** current 2026-11-11 — tool versions and what each variable is for.

## Versions this project is built against

| component | version | why it is pinned |
|---|---|---|
| Vitis | 2025.2 | `aiecompiler`, the HLS engine and `aietools` all come from here |
| PetaLinux sysroot | 2025.2 | supplies `CXX` and the board's XRT headers/libraries |
| versal-common image | v2025.2 | supplies `Image` and the pristine `rootfs.ext4` |
| platform | `xilinx_vek280_base_202520_1` | the VEK280 base platform |

Mixing versions across these four is the single most common cause of an error
message that has nothing to do with what you changed. They go together.

## Setup

```bash
cp setup_env.sh.example setup_env.sh      # edit the five paths at the top
source setup_env.sh
make check_env
```

`setup_env.sh` is **gitignored on purpose**. It is the one file allowed to carry
absolute paths, so nothing else has to — in particular the v++ linker config,
which needs an absolute path and is therefore *generated* rather than committed.

## What each variable is for

| variable | used by |
|---|---|
| `XILINX_VITIS` | `v++`, `aiecompiler`, the HLS headers that `make test_pl` compiles against |
| `PLATFORM` | every `v++` invocation (`--platform`) |
| `COMMON_IMAGE_VERSAL` | `make rootfs` (the pristine rootfs) and `make package` (the kernel `Image`) |
| `SDKTARGETSYSROOT` | the host cross-compile: XRT headers and libraries |
| `CXX` | the aarch64 cross compiler. **Not** the compiler the native tests use |
| `DSPLIB_VITIS` | nothing yet; the DSPLib FFT arrives in phase 3 |

## Two traps

**`source setup_env.sh`, do not execute it.** It exports into your shell. Running
it as `./setup_env.sh` sets variables in a subshell that then exits, and you get
the exact same "did you source it?" errors as if you had done nothing.

**PetaLinux's environment script exits quietly if `LD_LIBRARY_PATH` is set.**
It is a deliberate safety guard, and it returns success. You get a shell with no
`CXX` and no `SDKTARGETSYSROOT`, and the first symptom is a host link failure
about missing XRT headers, twenty minutes later and three targets away.
`setup_env.sh` unsets `LD_LIBRARY_PATH` before sourcing it, and then checks that
`SDKTARGETSYSROOT` actually arrived. Do not remove either line.

## Ordering

Vitis `settings64.sh` is sourced **after** PetaLinux. Both prepend to `PATH`, and
the Vitis tools have to win.
