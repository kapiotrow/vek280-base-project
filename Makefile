# ===========================================================================
# VEK280 base project -- Makefile
#
# PHASE 2: the AI Engine is IN THE DATAPATH.
#
#   DDR -> data_src (PL) -> PLIO -> echo_kernel (AIE) -> PLIO -> data_sink -> DDR
#
# The kernel is byte-for-byte the one phase 1 proved; only the edges moved, from
# GMIO to PLIO. What is new is the thing PLIO brings with it: aiesim FAKES the PL
# boundary, feeding a PLIO from a text file, so the cheap rungs can all pass on a
# design that deadlocks the instant it is linked.
#
# `MUTANT=argidx` is that gap, on demand: x86sim passes, aiesim passes, hw_emu
# hangs forever. `make probe_emu` is how you find out why.
#
# Start here:
#     source setup_env.sh
#     make check_env
#     make help
#
# THE DEVELOPMENT CYCLE IS THE POINT OF THIS PROJECT. Four rungs exist today;
# each answers a question no cheaper rung can, and each can be made to fail on
# purpose with MUTANT=. See docs/04-dev-cycle.md before using any of them.
#
#     make test_host    rung 1   ms      the golden model and the checker
#     make x86sim       rung 2   s       the AIE kernel, functionally
#     make test_pl      rung 3   s       the PL kernels' arithmetic (HLS csim)
#     make aiesim       rung 4   min     the AIE graph, PLIO FED FROM A FILE
#     make run_emu      rung 5   ~min    the whole system (hw_emu)
#     make probe_emu    rung 5   ~min    ...with the AXI-Stream handshake probed
#     (the HLS cost half of rung 4 arrives with phase 4; the numbering is kept
#      stable so the docs stay valid)
# ===========================================================================

SHELL := /bin/bash

# ---------------------------------------------------------------------------
# Knobs. Every default lives HERE and nowhere else. Documentation quotes
# `make print-<KNOB>` rather than copying a value, so the two cannot drift.
# ---------------------------------------------------------------------------

# hw_emu or hw. hw_emu is the default because it needs no board.
TARGET ?= hw_emu

# Element count: 32-bit words pushed through the chain.
# Small on purpose -- hw_emu time scales with the data, and every rung through
# phase 4 ends in hw_emu. Sizing up is a hardware exercise.
BASE_N ?= 1024

# PL kernel clock, MHz.
PL_FREQ ?= 250

# Which AI Engine graph to build.
#   base (default)  PLIO in, PLIO out -- what goes into the xclbin (phase 2)
#   echo            GMIO in, GMIO out -- the standalone phase-1 graph
#
# Both wrap THE SAME kernel. Keeping `echo` alive is deliberate: it is the only
# configuration in which the array can be exercised with no PL, no linker config
# and no Vivado, which makes it the right place to debug the kernel itself.
# `make aiesim GRAPH=echo` is the phase-1 run; `make aiesim` is the phase-2 one.
GRAPH ?= base

# The bisect switch. stream (default) = the kernel reads its input.
# synth = the kernel SYNTHESIZES its output and never reads the input, which
# separates "the input never delivers" from "the core never runs" -- two faults
# that are indistinguishable from outside. See echo_kernel.h.
ECHO_SRC ?= stream

# AI Engine kernel geometry and constants. ECHO_N must divide ECHO_TOTAL and be
# a multiple of the kernel's vector width (8).
#
# ONE VARIABLE EACH, reaching the kernel, the graph, the harness and the Python
# generator. Four copies of a constant is four chances for them to disagree.
ECHO_N     ?= 256
ECHO_TOTAL ?= 1024
ECHO_SHIFT ?= 1
ECHO_BIAS  ?= 1000

# 1 = the vectorized kernel branch, 0 = the scalar reference. They must be
# bit-identical; `make x86sim_both` runs both and diffs them.
ECHO_VECTORIZE ?= 1

# Deliberate breakage, so a verification rung can be SEEN to fail.
#   none   (default) the design is correct
#   value  data_sink corrupts one word  -> the check reports a mismatch
#   short  data_src writes n-1 words    -> the design DEADLOCKS in hw_emu
#   aie    echo_kernel's VECTOR branch shifts one bit too far
#   argidx the host sets data_src's args POSITIONALLY -> XRT aborts at launch
#   nograph the host never starts the AIE graph -> the PLIO is never drained
#
# They fail in deliberately different ways. `value` is a wrong answer, `short`
# is a hang, `aie` is wrong ONLY when vectorized -- the normal outcome of a
# hand-vectorization and the hardest to find later.
#
# The last two are INTEGRATION mutants: both PASS EVERY CHEAP RUNG and break the
# linked system, which is the whole lesson of phase 2. They break differently on
# purpose -- `argidx` aborts with a message, `nograph` hangs with nothing -- and
# the second is the one worth practising the probe on.
MUTANT ?= none

# hw_emu takes a long time and starting one by accident is a wasted afternoon,
# so `make run_emu` refuses unless this is set explicitly.
LAUNCH_HW_EMU_EXEC ?= 0

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
DESIGN       := $(PROJECT_ROOT)/design
PL_SRC       := $(DESIGN)/pl_src
AIE_SRC      := $(DESIGN)/aie_src
HOST_SRC     := $(DESIGN)/host_app_src
SYS_CONFIGS  := $(DESIGN)/system_configs
DIRECTIVES   := $(DESIGN)/directives
EXEC_SCRIPTS := $(DESIGN)/exec_scripts
PROFILING    := $(DESIGN)/profiling_configs
SCRIPTS      := $(PROJECT_ROOT)/scripts

BUILD_DIR    := $(PROJECT_ROOT)/build/$(TARGET)
ROOTFS_DIR   := $(PROJECT_ROOT)/build/rootfs
ROOTFS       := $(ROOTFS_DIR)/rootfs.ext4
PKG_OUT      := $(BUILD_DIR)/package

XSA          := base.xsa
APP_ELF      := base_host.elf
LINK_CFG     := $(BUILD_DIR)/base.cfg

# ---------------------------------------------------------------------------
# MUTANT -> preprocessor defines, for both toolchains at once.
#
# The host needs to know too: with a mutant armed it INVERTS its verdict, so a
# PASS becomes the failure. One variable reaches v++ and $(CXX) from here,
# because a constant that two toolchains derive separately is a constant that
# will eventually disagree with itself.
# ---------------------------------------------------------------------------
ifeq ($(MUTANT),none)
  MUTANT_SHORT  := 0
  MUTANT_VALUE  := 0
  MUTANT_AIE    := 0
  MUTANT_ARGIDX  := 0
  MUTANT_NOGRAPH := 0
  MUTANT_ARMED  := 0
else ifeq ($(MUTANT),short)
  MUTANT_SHORT  := 1
  MUTANT_VALUE  := 0
  MUTANT_AIE    := 0
  MUTANT_ARGIDX  := 0
  MUTANT_NOGRAPH := 0
  MUTANT_ARMED  := 1
else ifeq ($(MUTANT),value)
  MUTANT_SHORT  := 0
  MUTANT_VALUE  := 1
  MUTANT_AIE    := 0
  MUTANT_ARGIDX  := 0
  MUTANT_NOGRAPH := 0
  MUTANT_ARMED  := 1
else ifeq ($(MUTANT),aie)
  MUTANT_SHORT  := 0
  MUTANT_VALUE  := 0
  MUTANT_AIE    := 1
  MUTANT_ARGIDX  := 0
  MUTANT_NOGRAPH := 0
  MUTANT_ARMED  := 1
else ifeq ($(MUTANT),argidx)
  MUTANT_SHORT   := 0
  MUTANT_VALUE   := 0
  MUTANT_AIE     := 0
  MUTANT_ARGIDX  := 1
  MUTANT_NOGRAPH := 0
  MUTANT_ARMED   := 1
else ifeq ($(MUTANT),nograph)
  MUTANT_SHORT   := 0
  MUTANT_VALUE   := 0
  MUTANT_AIE     := 0
  MUTANT_ARGIDX  := 0
  MUTANT_NOGRAPH := 1
  MUTANT_ARMED   := 1
else
  $(error MUTANT=$(MUTANT) is not one of: none, value, short, aie, argidx, nograph)
endif
MUTANT_ARGIDX  ?= 0
MUTANT_NOGRAPH ?= 0

MUTANT_DEFS := -D MUTANT_SHORT=$(MUTANT_SHORT) -D MUTANT_VALUE=$(MUTANT_VALUE)

# ---------------------------------------------------------------------------
# v++ flags
# ---------------------------------------------------------------------------
HZ_UNIT        := 1000000
VPP_CLOCK_FREQ := $(shell printf "%.0f" $$(echo "$(PL_FREQ) * $(HZ_UNIT)" | bc))

VPP_FLAGS := -t $(TARGET)
VPP_FLAGS += --platform $(PLATFORM)
VPP_FLAGS += --save-temps
VPP_FLAGS += --temp_dir $(BUILD_DIR)/_x

# Keep v++'s logs and reports inside build/ instead of the project root. Without
# these two, every invocation drops a v++_<kernel>.<target>.log next to the
# Makefile; the reference project accumulated about two hundred of them, which is
# the first impression this project exists to avoid. (xcd.log is written by the
# dispatch client before these take effect and is gitignored instead.)
VPP_FLAGS += --log_dir $(BUILD_DIR)/logs
VPP_FLAGS += --report_dir $(BUILD_DIR)/reports

SRC_XO  := $(BUILD_DIR)/data_src.$(TARGET).xo
SINK_XO := $(BUILD_DIR)/data_sink.$(TARGET).xo
KERNEL_XOS := $(SRC_XO) $(SINK_XO)

VPP_LINK_FLAGS := --config $(LINK_CFG)
VPP_LINK_FLAGS += --vivado.synth.jobs 8
VPP_LINK_FLAGS += --clock.freqHz $(VPP_CLOCK_FREQ):data_src_0
VPP_LINK_FLAGS += --clock.freqHz $(VPP_CLOCK_FREQ):data_sink_0

# ---------------------------------------------------------------------------
# AI Engine compiler flags
#
# The geometry and the kernel constants reach aiecompiler through --Xpreproc,
# which is how a make variable becomes a #define inside an AIE kernel. Every one
# of them is also on the AIE flag stamp, because none of them touches a source
# file: change ECHO_SHIFT with a source-only prerequisite list and the build
# cheerfully reuses the previous libadf.a.
# ---------------------------------------------------------------------------
ifeq ($(GRAPH),base)
  AIE_GRAPH_SRC := $(AIE_SRC)/base_graph.cpp
  AIE_GRAPH_HDRS := $(AIE_SRC)/base_graph.h
else ifeq ($(GRAPH),echo)
  AIE_GRAPH_SRC := $(AIE_SRC)/echo_graph.cpp
  AIE_GRAPH_HDRS := $(AIE_SRC)/echo_graph.h
else
  $(error GRAPH=$(GRAPH) is not one of: base, echo)
endif

# A WHOLE DIRECTORY PER GRAPH, not just a per-graph filename.
#
# aiecompiler writes its output archive as `libadf.a`, with that exact name,
# into the directory it is run from -- the name is not configurable. So two
# graphs cannot be told apart by filename; they have to be told apart by
# location. (Trying the filename first produced a build that compiled the graph
# happily and then failed at the link with "Source file does not exist:
# libadf_base.a", because nothing had ever been going to create that name.)
#
# Separating them matters for the same reason the flag stamps exist: two graphs
# sharing one output path is a stale-artifact trap, and this one would not even
# be caught by a stamp.
AIE_BUILD_DIR := $(BUILD_DIR)/aie_$(GRAPH)
AIE_WORK_DIR  := $(AIE_BUILD_DIR)/Work
AIE_DATA_DIR  := $(AIE_SRC)/aiesim_data/echo

ifeq ($(ECHO_SRC),stream)
  ECHO_SRC_SYNTH := 0
else ifeq ($(ECHO_SRC),synth)
  ECHO_SRC_SYNTH := 1
else
  $(error ECHO_SRC=$(ECHO_SRC) is not one of: stream, synth)
endif

AIE_DEFS := --Xpreproc="-DECHO_N=$(ECHO_N)"
AIE_DEFS += --Xpreproc="-DECHO_TOTAL=$(ECHO_TOTAL)"
AIE_DEFS += --Xpreproc="-DECHO_SHIFT=$(ECHO_SHIFT)"
AIE_DEFS += --Xpreproc="-DECHO_BIAS=$(ECHO_BIAS)"
AIE_DEFS += --Xpreproc="-DECHO_VECTORIZE=$(ECHO_VECTORIZE)"
AIE_DEFS += --Xpreproc="-DECHO_SRC_SYNTH=$(ECHO_SRC_SYNTH)"
AIE_DEFS += --Xpreproc="-DMUTANT_AIE=$(MUTANT_AIE)"

AIE_FLAGS_COMMON := --platform=$(PLATFORM)
AIE_FLAGS_COMMON += -include=$(AIE_SRC)
AIE_FLAGS_COMMON += $(AIE_DEFS)
AIE_FLAGS_COMMON += --pl-freq=$(PL_FREQ)

# The hardware graph: what phase 2 links into the xclbin, and what aiesimulator
# runs against. --target=hw even though nothing is linked yet, because aiesim is
# a simulation OF THE HARDWARE BUILD; x86sim is a different compile entirely.
AIE_FLAGS := --target=hw
AIE_FLAGS += $(AIE_FLAGS_COMMON)
AIE_FLAGS += --workdir=$(AIE_WORK_DIR)

LIBADF_A := $(AIE_BUILD_DIR)/libadf.a

# x86sim builds to its own tree: a different target, a different Work/, and no
# relationship to $(TARGET) at all -- x86sim is not hw_emu.
#
# The workdir is ABSOLUTE because the recipe cd's into the build directory
# first, and a relative --workdir would land somewhere unintended.
X86_BUILD_DIR := $(PROJECT_ROOT)/build/x86sim_$(GRAPH)
X86_WORK_DIR  := $(X86_BUILD_DIR)/Work

X86_AIE_FLAGS := --target=x86sim
X86_AIE_FLAGS += $(AIE_FLAGS_COMMON)
X86_AIE_FLAGS += --workdir=$(X86_WORK_DIR)

# Simulator flags. The wall-clock `timeout` wrappers in the recipes are not
# belt-and-braces: the harness deliberately never calls end(), because end() and
# the simulator's cycle timeout deadlock each other (see echo_graph.cpp), so a
# broken run does not terminate on its own.
X86_SIM_FLAGS := --pkg-dir=$(X86_WORK_DIR)
X86_SIM_FLAGS += --output-dir=$(X86_BUILD_DIR)

# HOW aiesim TERMINATES, AND WHY THE VERDICT IS NOT ITS EXIT STATUS.
#
# The harness calls run(-1) -- infinite iterations -- and never calls end().
# Both are deliberate: with run(N) the ADF runtime begins tearing the simulation
# down once N invocations complete, and during teardown no cycles are driven for
# the shim DMA, so a GMIO wait() that has not yet finished never will. end() and
# the cycle timeout then deadlock each other. See echo_graph.cpp.
#
# The consequence is that THE SIMULATION DOES NOT STOP WHEN THE WORK IS DONE.
# The cores keep looping, and the run is ended from outside -- in practice by
# the wall-clock `timeout` below, which is why the recipe is prefixed with `-`
# and why the PASS/FAIL comes from the checker reading the dumped file rather
# than from aiesimulator's exit status.
#
# MEASURED on this design (1024 elements, 4 invocations): the work is complete
# and echo_out.bin is written well inside 90 s; the run then continues until the
# timeout fires, whatever that is set to. 900 s and 90 s both PASS and both take
# exactly their timeout. So this number is a budget, not a duration.
#
# If you grow the graph and the run starts FAILING, check the log for the
# "[echo] wrote ... echo_out.bin" line before raising anything: if it is absent,
# the work did not finish in the budget. If it is present, the problem is not
# here.
SIM_WALL_TIMEOUT ?= 120

# Secondary net: stop after this many simulated cycles. In practice the wall
# timeout above fires first on this design, so treat this as the guard for a
# graph that stalls rather than as the thing that ends a healthy run.
#
# NOTE THE POSITION OF BOTH DEFINITIONS. They must come BEFORE the
# AIE_SIM_FLAGS assignment below, because that uses `:=` and `:=` expands
# immediately. With the knob defined afterwards the flag silently became
# `--simulation-cycle-timeout=` with no value, aiesimulator refused to start,
# the recipe's `-` prefix swallowed the failure, and the checker then compared
# the PREVIOUS run's output file and reported PASS. The `rm -f` in the aiesim
# recipe is the other half of that lesson.
AIESIM_CYCLE_TIMEOUT ?= 100000

AIE_SIM_FLAGS := --pkg-dir=$(AIE_WORK_DIR)
AIE_SIM_FLAGS += --simulation-cycle-timeout=$(AIESIM_CYCLE_TIMEOUT)
# -i names the directory aiesim reads PLIO input files from. For GRAPH=echo
# there are no PLIO ports and it is simply unused.
AIE_SIM_FLAGS += -i=$(AIE_DATA_DIR)

# WHERE THE ANSWER ENDS UP, and it differs between the two graphs because the
# two mechanisms are different:
#
#   GRAPH=echo  the HARNESS writes echo_out.bin with its own fwrite, having
#               pulled the data back over GMIO itself.
#   GRAPH=base  AIESIM writes stream_out.txt, from the PLIO declaration in the
#               graph. The harness does not touch the data at all -- which is
#               precisely why this graph's harness is ten lines long, and
#               precisely why it proves so much less.
ifeq ($(GRAPH),base)
  AIESIM_ACTUAL   := $(AIE_BUILD_DIR)/aiesimulator_output/stream_out.txt
  AIESIM_TEXTFLAG := --actual-text
else
  AIESIM_ACTUAL   := $(AIE_BUILD_DIR)/echo_out.bin
  AIESIM_TEXTFLAG :=
endif

# ECHO_SRC=synth is a DIAGNOSTIC build, not a test: the kernel deliberately
# ignores its input, so the golden cannot apply. The checker is told to report
# "did the core run" instead of pass/fail.
SYNTH_FLAG := $(if $(filter 1,$(ECHO_SRC_SYNTH)),--synth-probe --synth-period $(ECHO_N),)

# With a mutant armed, the checker INVERTS its verdict: a match becomes the
# failure. One variable, so the two simulation rungs cannot disagree about it.
#
# BUT "ARMED" IS NOT THE SAME AS "REACHED", and conflating the two is a bug this
# Makefile had. MUTANT=aie breaks the kernel's VECTOR branch only, so at
# ECHO_VECTORIZE=0 it is compiled out and the build is correct. Demanding a
# failure there made `make x86sim_both MUTANT=aie` fail on its scalar half --
# for the right reason, with the wrong verdict.
#
# So the simulation rungs ask whether the mutant is EFFECTIVE in the build being
# checked, not merely whether one was named. The general rule, worth keeping as
# more mutants appear: a mutant only inverts a verdict on a build that actually
# contains it.
MUTANT_AIE_EFFECTIVE := $(and $(filter 1,$(MUTANT_AIE)),$(filter 1,$(ECHO_VECTORIZE)))
SIM_MUTANT_EFFECTIVE := $(strip $(MUTANT_AIE_EFFECTIVE))

CHECK_EXPECT := $(if $(SIM_MUTANT_EFFECTIVE),--expect-fail,)

# ---------------------------------------------------------------------------
# Host compile flags (cross, for the board/emulated APU)
# ---------------------------------------------------------------------------
# __PS_ENABLE_AIE__ is required by the XRT AIE headers.
GCC_FLAGS := -O2 -std=c++17 -D__linux__ -D__PS_ENABLE_AIE__
GCC_FLAGS += -DBASE_N=$(BASE_N)
GCC_FLAGS += -DMUTANT_ARMED=$(MUTANT_ARMED)
GCC_FLAGS += -DMUTANT_ARGIDX=$(MUTANT_ARGIDX)
GCC_FLAGS += -DMUTANT_NOGRAPH=$(MUTANT_NOGRAPH)
# The AIE kernel's constants, so the host's golden models what the array does.
# ONE Makefile variable reaches both toolchains -- --Xpreproc for the kernel,
# -D for the host. Deriving them separately is how the two come to disagree.
GCC_FLAGS += -DBASE_ECHO_SHIFT=$(ECHO_SHIFT)
GCC_FLAGS += -DBASE_ECHO_BIAS=$(ECHO_BIAS)
GCC_FLAGS += -DBASE_ECHO_N=$(ECHO_N)

GCC_INC := -I$(SDKTARGETSYSROOT)/usr/include/xrt
GCC_INC += -I$(SDKTARGETSYSROOT)/usr/include
GCC_INC += -I$(XILINX_VITIS)/aietools/include
GCC_INC += -I$(HOST_SRC)

# -ladf_api_xrt is what xrt::graph needs. It lives in aietools, not the sysroot,
# and it is the one host-side dependency the AI Engine adds.
GCC_LIBS := -L$(SDKTARGETSYSROOT)/usr/lib
GCC_LIBS += -L$(XILINX_VITIS)/aietools/lib/aarch64.o
GCC_LIBS += -ladf_api_xrt -lxrt_coreutil

# Native compiler for the rung-1 and rung-3 tests. NOT $(CXX): that one is the
# aarch64 cross compiler and its output cannot run here.
HOST_CXX := g++

# ---------------------------------------------------------------------------
# Python, with the Vitis environment's interference removed.
#
# THE TRAP: `source settings64.sh` sets PYTHONHOME and PYTHONPATH to point at
# Vivado's own bundled interpreter. A plain `python3` then runs whatever binary
# is on PATH against VIVADO's standard library, and the mismatch surfaces as
#
#     AssertionError: SRE module mismatch
#
# from inside `import argparse` -- an error with no visible connection to
# anything you did, in a script that works perfectly in a clean shell.
#
# Unsetting the two variables for the duration of the call is the fix. Every
# python invocation in this Makefile goes through $(PYTHON) so there is exactly
# one place where this is handled.
PYTHON := env -u PYTHONHOME -u PYTHONPATH python3

# ===========================================================================
.PHONY: help check_env all
.DEFAULT_GOAL := help

help:
	@echo ""
	@echo "VEK280 base project -- phase 2 (PS + PL + AIE, all in the datapath)"
	@echo ""
	@echo "  FIRST:         source setup_env.sh && make check_env"
	@echo ""
	@echo "  Development cycle (read docs/04-dev-cycle.md):"
	@echo "    test_host      rung 1  ms   golden model + the checker itself"
	@echo "    x86sim         rung 2  s    the AIE kernel, functionally"
	@echo "    x86sim_both    rung 2  s    ...both branches, diffed bit for bit"
	@echo "    test_pl        rung 3  s    PL kernels, HLS C simulation"
	@echo "    aiesim         rung 4  min  the AIE graph -- PLIO FED FROM A FILE"
	@echo "    run_emu        rung 5  min  full system in hw_emu"
	@echo "    debug_sim           --      re-elaborate the snapshot with trace info"
	@echo "    probe_emu      rung 5  min  ...run with the AXI-Stream handshake probed"
	@echo ""
	@echo "  Build steps (each one is also the name of what it produces):"
	@echo "    gen_vectors    stimulus + golden, cross-checked against the C++ one"
	@echo "    graph          libadf.a -- the AIE graph, and its schedule"
	@echo "    kernels        .xo  -- HLS compile of the two PL kernels"
	@echo "    xsa            .xsa -- v++ link: kernels into the platform"
	@echo "    application    .elf -- cross-compiled host app"
	@echo "    rootfs         a packageable copy of the common-image rootfs"
	@echo "    package        the bootable SD image / emulation package"
	@echo "    sd_card        kernels + xsa + application + package"
	@echo ""
	@echo "  Knobs (current value):"
	@echo "    TARGET=$(TARGET)        hw_emu | hw"
	@echo "    BASE_N=$(BASE_N)        32-bit words through the PL chain"
	@echo "    PL_FREQ=$(PL_FREQ)      PL kernel clock, MHz"
	@echo "    ECHO_N=$(ECHO_N) ECHO_TOTAL=$(ECHO_TOTAL)   AIE elements per firing / in total"
	@echo "    ECHO_SHIFT=$(ECHO_SHIFT) ECHO_BIAS=$(ECHO_BIAS)      out = (in >> SHIFT) + BIAS"
	@echo "    ECHO_VECTORIZE=$(ECHO_VECTORIZE)       1 = vector branch, 0 = scalar reference"
	@echo "    GRAPH=$(GRAPH)          base (PLIO, in the xclbin) | echo (GMIO, sim only)"
	@echo "    ECHO_SRC=$(ECHO_SRC)    stream | synth   (the bisect switch)"
	@echo "    MUTANT=$(MUTANT)        none|value|short|aie|argidx|nograph"
	@echo "    LAUNCH_HW_EMU_EXEC=$(LAUNCH_HW_EMU_EXEC)  must be 1 for run_emu"
	@echo ""
	@echo "  make print-<KNOB>   print one default (what the docs quote)"
	@echo "  make clean / cleanall"
	@echo ""

check_env:
	@$(SCRIPTS)/check_env.sh

# Print any variable's value. Documentation and scripts ask for a default this
# way instead of copying it, so there is only ever one place to change it.
print-%:
	@echo '$($*)'

# ---------------------------------------------------------------------------
# Flag stamps.
#
# THE TRAP THESE EXIST FOR: BASE_N, MUTANT and TARGET are make variables. They
# touch no source file, so a source-only prerequisite list is perfectly happy to
# reuse the PREVIOUS build's .xo and .elf -- and the run then reports results
# from a binary you did not build. The reference project lost a debug cycle to
# exactly this: two different configurations produced byte-identical output
# because one had silently reused the other's artifacts.
#
# The stamp is rewritten only when its contents change, so this does not force a
# rebuild on every invocation.
# ---------------------------------------------------------------------------
.PHONY: FORCE
FORCE:

%.flagstamp: FORCE
	@mkdir -p $(dir $@)
	@echo '$(FLAGS_FOR_STAMP)' | cmp -s - $@ || echo '$(FLAGS_FOR_STAMP)' > $@

KERNEL_FLAGS_STAMP := $(BUILD_DIR)/kernels.flagstamp
$(KERNEL_FLAGS_STAMP): FLAGS_FOR_STAMP := $(VPP_FLAGS) $(MUTANT_DEFS) $(VPP_CLOCK_FREQ)

APP_FLAGS_STAMP := $(BUILD_DIR)/app.flagstamp
$(APP_FLAGS_STAMP): FLAGS_FOR_STAMP := $(GCC_FLAGS)

# ---------------------------------------------------------------------------
# Rung 1: the golden model and the checker. Native, milliseconds.
# ---------------------------------------------------------------------------
.PHONY: test_host
test_host:
	@mkdir -p $(BUILD_DIR)
	$(HOST_CXX) -O2 -std=c++17 -Wall -Wextra \
	    -DBASE_ECHO_SHIFT=$(ECHO_SHIFT) -DBASE_ECHO_BIAS=$(ECHO_BIAS) \
	    $(HOST_SRC)/test/test_golden.cpp $(HOST_SRC)/golden.cpp \
	    -o $(BUILD_DIR)/test_golden
	@echo ""
	@timeout 120 $(BUILD_DIR)/test_golden

# ---------------------------------------------------------------------------
# Rung 3: the PL kernels in HLS C simulation. Native, seconds.
#
# Compiled with the system g++ against the Vitis HLS headers -- no vitis_hls
# process, no project, no synthesis. The #pragma HLS lines are not understood by
# g++ and are not meant to be; they are ignored here, which is also precisely
# the limitation of this rung (it never exercises an AXI interface).
# ---------------------------------------------------------------------------
.PHONY: test_pl
test_pl:
	@mkdir -p $(BUILD_DIR)
	$(HOST_CXX) -O2 -std=c++17 -Wall -Wno-unknown-pragmas \
	    -isystem $(XILINX_VITIS)/include $(MUTANT_DEFS) \
	    -DBASE_ECHO_SHIFT=$(ECHO_SHIFT) -DBASE_ECHO_BIAS=$(ECHO_BIAS) \
	    $(PL_SRC)/test/test_pl_loopback.cpp $(HOST_SRC)/golden.cpp \
	    -o $(BUILD_DIR)/test_pl
	@echo ""
	@timeout 120 $(BUILD_DIR)/test_pl

# ---------------------------------------------------------------------------
# Simulation stimulus and golden.
#
# ONE script writes both, so they cannot come to describe different experiments.
# It also cross-checks itself against the C++ stimulus generator: the same
# contract exists in Python (for the simulation harness) and in C++ (for the
# host from phase 2 on), and two implementations of one contract is exactly the
# situation that produces a silent mismatch.
# ---------------------------------------------------------------------------
.PHONY: gen_vectors
gen_vectors:
	@mkdir -p $(BUILD_DIR)
	@$(MAKE) --no-print-directory test_host >/dev/null
	@$(BUILD_DIR)/test_golden $(BUILD_DIR)/stimulus_cpp.bin
	$(PYTHON) $(SCRIPTS)/gen_vectors.py \
	    --out-dir $(AIE_DATA_DIR) \
	    --total $(ECHO_TOTAL) --shift $(ECHO_SHIFT) --bias $(ECHO_BIAS) \
	    --check-cpp $(BUILD_DIR)/stimulus_cpp.bin

# ---------------------------------------------------------------------------
# The AI Engine graph, compiled for hardware.
#
# This is the cheap structural question: does the graph compile, where did the
# kernels get placed, and what did the compiler SCHEDULE them at? It needs no
# v++, no Vivado and no link, and from phase 2 onward it is the target to reach
# for when the question is about the array rather than the system -- on the
# reference project it answers in ~5 minutes what a full package costs 25.
# ---------------------------------------------------------------------------
AIE_FLAGS_STAMP := $(AIE_BUILD_DIR)/aie.flagstamp
$(AIE_FLAGS_STAMP): FLAGS_FOR_STAMP := $(AIE_FLAGS)

.PHONY: graph
graph: $(LIBADF_A)

$(LIBADF_A): $(AIE_FLAGS_STAMP) $(AIE_GRAPH_SRC) $(AIE_GRAPH_HDRS) \
             $(AIE_SRC)/echo_kernel.h $(AIE_SRC)/echo_kernel.cpp
	@mkdir -p $(AIE_BUILD_DIR)
	@echo "aiecompiler --target=hw GRAPH=$(GRAPH) -> $(AIE_BUILD_DIR)/aiecompiler.log"
	@cd $(AIE_BUILD_DIR) && aiecompiler $(AIE_FLAGS) $(AIE_GRAPH_SRC) > aiecompiler.log 2>&1 \
	    || { echo "AIE COMPILE FAILED -- last 40 lines:"; tail -40 aiecompiler.log; exit 1; }
	@grep -cE "^(ERROR|WARNING)" $(AIE_BUILD_DIR)/aiecompiler.log >/dev/null 2>&1 && \
	    grep -E "^(ERROR|WARNING)" $(AIE_BUILD_DIR)/aiecompiler.log | head -5 || true
	@echo "graph: $(LIBADF_A)"
	@echo ""
	@echo "--- the compiler's SCHEDULE for each kernel. NOT a measurement: it is"
	@echo "--- what the scheduler believes, before any DMA contention exists."
	@echo "--- 'make aiesim' gives the simulated figure, which is the honest one."
	@$(PYTHON) $(SCRIPTS)/aie_report.py $(AIE_WORK_DIR) || true

# ---------------------------------------------------------------------------
# Rung 2: x86sim -- the AIE kernel, functionally. Seconds.
#
# The kernel's C++ compiled for the host and run natively. It answers "does my
# kernel compute the right thing" and NOTHING else: no timing, no DMA, no
# placement, no array. That is the whole point -- it is the cheapest rung that
# can see an AIE kernel at all, so arithmetic belongs here and not in aiesim.
# ---------------------------------------------------------------------------
X86_FLAGS_STAMP := $(X86_BUILD_DIR)/aie.flagstamp
$(X86_FLAGS_STAMP): FLAGS_FOR_STAMP := $(X86_AIE_FLAGS)

.PHONY: x86sim_graph x86sim
x86sim_graph: $(X86_FLAGS_STAMP) $(AIE_GRAPH_SRC) $(AIE_GRAPH_HDRS) \
              $(AIE_SRC)/echo_kernel.h $(AIE_SRC)/echo_kernel.cpp
	@mkdir -p $(X86_BUILD_DIR)
	@echo "aiecompiler --target=x86sim ... -> $(X86_BUILD_DIR)/aiecompiler_x86.log"
	@cd $(X86_BUILD_DIR) && aiecompiler $(X86_AIE_FLAGS) $(AIE_GRAPH_SRC) \
	    > aiecompiler_x86.log 2>&1 \
	    || { echo "AIE COMPILE FAILED -- last 40 lines:"; tail -40 aiecompiler_x86.log; exit 1; }

x86sim: x86sim_graph gen_vectors
	@test "$(GRAPH)" = "echo" || { \
	    echo "ERROR: x86sim needs GRAPH=echo."; \
	    echo ""; \
	    echo "  The PLIO graph's harness performs no I/O of its own -- aiesim"; \
	    echo "  reads and writes the PLIO files itself, and x86simulator does"; \
	    echo "  not do that. So there would be nothing to check."; \
	    echo ""; \
	    echo "  The kernel is the SAME in both graphs, which is the point:"; \
	    echo "  prove it on the GMIO graph, where it is cheap, then link it."; \
	    echo ""; \
	    echo "    make x86sim GRAPH=echo"; \
	    exit 1; }
	rm -f $(X86_BUILD_DIR)/echo_out.bin   # see the note in the aiesim recipe
	cd $(X86_BUILD_DIR) && \
	    ECHO_DATA_DIR=$(AIE_DATA_DIR) ECHO_OUT_DIR=$(X86_BUILD_DIR) \
	    timeout $(SIM_WALL_TIMEOUT) x86simulator $(X86_SIM_FLAGS) 2>&1 | tee x86sim.log
	@echo ""
	$(PYTHON) $(SCRIPTS)/check_sim_output.py \
	    --actual $(X86_BUILD_DIR)/echo_out.bin \
	    --golden $(AIE_DATA_DIR)/golden.bin $(CHECK_EXPECT) $(SYNTH_FLAG)

# The equality the vectorized kernel is only worth having if it holds: run both
# branches through rung 2 and diff the dumps byte for byte.
#
# "Bit-identical" is a claim, not a hope. A hand-vectorization that merely
# agrees to within an LSB has a rounding difference you have not found yet.
.PHONY: x86sim_both
x86sim_both: GRAPH := echo
x86sim_both:
	@echo "=== ECHO_VECTORIZE=1 (vectorized) ==="
	@$(MAKE) --no-print-directory x86sim GRAPH=echo ECHO_VECTORIZE=1
	@cp $(X86_BUILD_DIR)/echo_out.bin $(BUILD_DIR)/echo_out_vec.bin
	@echo ""
	@echo "=== ECHO_VECTORIZE=0 (scalar reference) ==="
	@$(MAKE) --no-print-directory x86sim GRAPH=echo ECHO_VECTORIZE=0
	@cp $(X86_BUILD_DIR)/echo_out.bin $(BUILD_DIR)/echo_out_scalar.bin
	@echo ""
	@echo "=== vectorized vs scalar ==="
	@if cmp -s $(BUILD_DIR)/echo_out_vec.bin $(BUILD_DIR)/echo_out_scalar.bin; then \
	    echo "BIT-IDENTICAL -- the vectorization is numerically free."; \
	else \
	    echo "DIFFER -- the vectorized branch is not the scalar one."; \
	    cmp -l $(BUILD_DIR)/echo_out_vec.bin $(BUILD_DIR)/echo_out_scalar.bin | head -5; \
	    if [ "$(MUTANT_ARMED)" = "1" ]; then \
	        echo "(a mutant is armed, so this is the expected outcome)"; \
	    else \
	        exit 1; \
	    fi; \
	fi

# ---------------------------------------------------------------------------
# Rung 4: aiesim -- what the kernel COSTS. Minutes.
#
# Cycle-approximate simulation of the real array: the compiled kernel on a
# simulated core, with simulated DMAs and real contention. This is where a cycle
# count comes from.
#
# WHAT IT CANNOT SEE, and it is the ladder's most important limitation: aiesim
# FAKES the PL boundary. A PLIO is fed from a text file, so there is no PL in
# the simulation at all. A graph can pass aiesim cleanly and still deadlock the
# instant a real PL kernel is on the other end of that stream. Phase 2 exists
# for precisely that reason, and it is why rung 5 is not optional.
#
# Phase 1 uses GMIO only, so that limitation does not bite yet. It will.
# ---------------------------------------------------------------------------
.PHONY: aiesim
aiesim: graph gen_vectors
	@# DELETE THE OUTPUT BEFORE THE RUN. Not hygiene -- correctness.
	@#
	@# The recipe below is prefixed with `-` so that a simulator which exits
	@# non-zero still reaches the checker (aiesimulator's exit status is not a
	@# reliable verdict). The cost of that is a simulation which never starts
	@# leaves the PREVIOUS run's echo_out.bin in place, and the checker then
	@# compares a stale file and reports PASS.
	@#
	@# That happened here, during development, for exactly that reason: a
	@# mis-expanded flag stopped aiesimulator from launching and the rung
	@# reported success. A checker that can pass without its input having been
	@# produced is not a checker.
	rm -f $(AIESIM_ACTUAL)
	-cd $(AIE_BUILD_DIR) && \
	    ECHO_DATA_DIR=$(AIE_DATA_DIR) ECHO_OUT_DIR=$(AIE_BUILD_DIR) \
	    timeout $(SIM_WALL_TIMEOUT) aiesimulator $(AIE_SIM_FLAGS) 2>&1 | tee aiesim.log
	@echo ""
	@echo "--- GRAPH=$(GRAPH): checking $(AIESIM_ACTUAL)"
ifeq ($(GRAPH),base)
	@echo "--- REMEMBER WHAT THIS RUN DID NOT TEST: the PLIO was fed from"
	@echo "--- $(AIE_DATA_DIR)/stream_in.txt, not by data_src."
	@echo "--- There is no PL in an AIE simulation. A PASS here is consistent"
	@echo "--- with a design that deadlocks the moment it is linked."
	@echo "--- Try: make run_emu MUTANT=argidx LAUNCH_HW_EMU_EXEC=1"
endif
	$(PYTHON) $(SCRIPTS)/check_sim_output.py \
	    --actual $(AIESIM_ACTUAL) $(AIESIM_TEXTFLAG) \
	    --golden $(AIE_DATA_DIR)/golden.bin $(CHECK_EXPECT) $(SYNTH_FLAG)

# ---------------------------------------------------------------------------
# PL kernels: HLS -> .xo
# ---------------------------------------------------------------------------
.PHONY: kernels
kernels: $(KERNEL_XOS)

$(SRC_XO): $(KERNEL_FLAGS_STAMP) $(PL_SRC)/data_src/data_src.cpp \
                                 $(PL_SRC)/data_src/data_src.h $(PL_SRC)/base_axis.h
	@mkdir -p $(BUILD_DIR)
	v++ $(VPP_FLAGS) $(MUTANT_DEFS) --hls.clock $(VPP_CLOCK_FREQ):data_src \
	    -c -k data_src $(PL_SRC)/data_src/data_src.cpp -o $@

$(SINK_XO): $(KERNEL_FLAGS_STAMP) $(PL_SRC)/data_sink/data_sink.cpp \
                                  $(PL_SRC)/data_sink/data_sink.h $(PL_SRC)/base_axis.h
	@mkdir -p $(BUILD_DIR)
	v++ $(VPP_FLAGS) $(MUTANT_DEFS) --hls.clock $(VPP_CLOCK_FREQ):data_sink \
	    -c -k data_sink $(PL_SRC)/data_sink/data_sink.cpp -o $@

# ---------------------------------------------------------------------------
# The linker config is GENERATED from its template, so the absolute path v++
# demands for userPostSysLinkOverlayTcl never has to be committed.
# ---------------------------------------------------------------------------
$(LINK_CFG): $(SYS_CONFIGS)/base.cfg.in
	@mkdir -p $(BUILD_DIR)
	sed 's|@PROJECT_ROOT@|$(PROJECT_ROOT)|g' $< > $@
	@echo "generated $@"

# ---------------------------------------------------------------------------
# Link: kernels into the platform -> .xsa
# ---------------------------------------------------------------------------
.PHONY: xsa
xsa: $(BUILD_DIR)/$(XSA)

# The AIE graph is now part of the system, so libadf.a is a link input.
# GRAPH must be `base` here: the `echo` graph has GMIO ports and no PLIO, so it
# satisfies none of the stream_connect lines in the linker config.
$(BUILD_DIR)/$(XSA): $(KERNEL_XOS) $(LIBADF_A) $(LINK_CFG)
	@test "$(GRAPH)" = "base" || { \
	    echo "ERROR: the xclbin needs the PLIO graph. Use GRAPH=base (the default)."; \
	    echo "       GRAPH=echo is the standalone GMIO graph -- simulation only."; \
	    exit 1; }
	v++ $(VPP_FLAGS) $(VPP_LINK_FLAGS) -l $(KERNEL_XOS) $(LIBADF_A) \
	    -o $@ 2>&1 | tee $(BUILD_DIR)/vpp_link.log

# ---------------------------------------------------------------------------
# Host application (cross-compiled for the APU)
# ---------------------------------------------------------------------------
.PHONY: application
application: $(BUILD_DIR)/$(APP_ELF)

$(BUILD_DIR)/$(APP_ELF): $(APP_FLAGS_STAMP) $(HOST_SRC)/base_host.cpp \
                         $(HOST_SRC)/golden.cpp $(HOST_SRC)/golden.h
	@mkdir -p $(BUILD_DIR)
	@test -n "$(SDKTARGETSYSROOT)" || { echo "ERROR: SDKTARGETSYSROOT unset -- source setup_env.sh"; exit 1; }
	$(CXX) $(GCC_FLAGS) $(GCC_INC) \
	    $(HOST_SRC)/base_host.cpp $(HOST_SRC)/golden.cpp \
	    $(GCC_LIBS) -o $@

# ---------------------------------------------------------------------------
# rootfs
#
# A COPY, not the original, and then feature-downgraded.
#
# v++ --package writes into the rootfs image, and the 2025.2 common-image
# rootfs.ext4 carries ext4 features its packaging step mishandles. The result is
# a corrupted filesystem: packaging reports success and every run afterwards
# dies during boot, which looks like a design fault and is not one. Stripping
# the three features below is the fix, and doing it on a copy means the pristine
# image stays pristine -- you will need it again.
# ---------------------------------------------------------------------------
.PHONY: rootfs
rootfs: $(ROOTFS)

$(ROOTFS): $(COMMON_IMAGE_VERSAL)/rootfs.ext4
	@mkdir -p $(ROOTFS_DIR)
	cp $< $@
	tune2fs -O ^orphan_file,^metadata_csum_seed,^metadata_csum $@
	e2fsck -fy $@ || test $$? -lt 4
	@echo "rootfs: $@ ready for packaging"

# ---------------------------------------------------------------------------
# The on-target run script is GENERATED, not copied: XCL_EMULATION_MODE must be
# set for hw_emu and must NOT be set on hardware. See the template's header.
# ---------------------------------------------------------------------------
$(BUILD_DIR)/run_script.sh: $(EXEC_SCRIPTS)/run_script.sh
	@mkdir -p $(BUILD_DIR)
	sed 's|@EMU_MODE@|$(if $(filter hw_emu,$(TARGET)),hw_emu,)|' $< > $@
	chmod +x $@

# ---------------------------------------------------------------------------
# Package: .xsa + ELF + rootfs + kernel image -> bootable image / emu package
# ---------------------------------------------------------------------------
.PHONY: package
# --package.defer_aie_run: do NOT start the AIE graph at boot.
#
# In this design the graph is driven entirely by the two PL kernels over PLIO,
# and the host never touches it. The packager would otherwise arrange for the
# graph to be started as part of loading the xclbin, which is harmless here but
# makes the control flow a lie: it hides WHO starts the array. Deferring it keeps
# that explicit, and it is required as soon as a host wants to configure the
# graph before it runs.
package: $(BUILD_DIR)/$(APP_ELF) $(BUILD_DIR)/$(XSA) $(LIBADF_A) $(ROOTFS) \
         $(BUILD_DIR)/run_script.sh
	v++ --package $(VPP_FLAGS) \
	    --package.rootfs $(ROOTFS) \
	    --package.kernel_image $(COMMON_IMAGE_VERSAL)/Image \
	    --package.boot_mode=sd \
	    --package.out_dir $(PKG_OUT) \
	    --package.image_format=ext4 \
	    --package.sd_file $(BUILD_DIR)/$(APP_ELF) \
	    --package.sd_file $(BUILD_DIR)/run_script.sh \
	    --package.sd_file $(PROFILING)/xrt.ini \
	    --package.defer_aie_run \
	    $(BUILD_DIR)/$(XSA) $(LIBADF_A)

.PHONY: sd_card
sd_card: kernels graph xsa application package

# ---------------------------------------------------------------------------
# Rung 5: hw_emu
#
# The guard is deliberate. This run takes a long time and nothing about it is
# recoverable if you did not mean to start it.
#
# -no-reboot reuses the already-booted image, which is most of the wall time.
#
# EMU_WALL_TIMEOUT bounds the run. A phase-2 deadlock produces no output at all,
# so without this a hung emulation runs until someone notices.
# ---------------------------------------------------------------------------
EMU_WALL_TIMEOUT ?= 900
.PHONY: run_emu
run_emu:
ifeq ($(LAUNCH_HW_EMU_EXEC),1)
	@test -d $(PKG_OUT) || { echo "ERROR: no package -- run 'make sd_card' first"; exit 1; }
	@# THE TIMEOUT IS NOT OPTIONAL HERE. Since phase 2 this project ships a
	@# mutant whose whole purpose is to hang (MUTANT=argidx), and a genuine
	@# PLIO deadlock produces no error and no output -- so an unbounded run_emu
	@# waits forever and takes the terminal with it. Ask me how I know.
	-cd $(PKG_OUT) && timeout $(EMU_WALL_TIMEOUT) \
	    ./launch_hw_emu.sh -no-reboot -run-app run_script.sh 2>&1 \
	    | tee $(BUILD_DIR)/run_emu.log
	@echo ""
	@echo "---- verdict ----"
	@grep -E "\[host\]|TEST PASSED|ERROR:" $(BUILD_DIR)/run_emu.log || true
	@# A run that produced no PASS/FAIL line did not finish. Say so, rather
	@# than letting a silent exit look like success.
	@if ! grep -qE "\[host\] (PASS|FAIL|mutant detected)" $(BUILD_DIR)/run_emu.log; then \
	    echo ""; \
	    echo "NO VERDICT: the run did not reach its own check."; \
	    echo "  The last [host] line above is where it stopped. If it is"; \
	    echo "  'waiting for ...', this is a DEADLOCK -- see docs/04-dev-cycle.md"; \
	    echo "  and run:  make debug_sim && make probe_emu LAUNCH_HW_EMU_EXEC=1"; \
	    exit 1; \
	fi
else
	@echo "hw_emu is slow and starting one by accident wastes an afternoon."
	@echo "Run it on purpose:"
	@echo "    make run_emu LAUNCH_HW_EMU_EXEC=1"
endif

# ---------------------------------------------------------------------------
# The AXI4-Stream handshake probe.
#
# This is phase 2's debugging tool, and the one the rest of the ladder cannot
# substitute for. When a PLIO design hangs you get no error, no timeout and no
# output; TVALID and TREADY tell you in one glance which side is at fault.
#
#     make debug_sim    re-elaborate the emulation snapshot WITH trace info
#     make probe_emu    run it with the probe armed, then analyse the VCD
#
# debug_sim must be re-run after every `make package`, because packaging
# regenerates elaborate.sh and drops the patch.
# ---------------------------------------------------------------------------
XSIM_DIR := $(PKG_OUT)/sim/behav_waveform/xsim

# Which stream to probe. The default is the PL->AIE direction, which is where a
# starved AIE kernel shows up. For the AIE->PL direction use:
#     make probe_emu PROBE_CU=data_sink_0 PROBE_PORT=in
PROBE_CU   ?= data_src_0
PROBE_PORT ?= out

.PHONY: debug_sim probe_emu
debug_sim:
	@test -f $(XSIM_DIR)/elaborate.sh || { \
	    echo "ERROR: $(XSIM_DIR)/elaborate.sh missing -- run 'make package' first"; exit 1; }
	@# THREE SEPARATE THINGS EACH DEFEAT WAVEFORM CAPTURE, AND ALL THREE ARE SILENT.
	@#
	@# 1. v++ generates elaborate.sh with `xelab --incr --debug off`, so the
	@#    snapshot carries NO trace information. log_vcd then fails with
	@#    "[Simulator 45-10] ... compiled without trace information", and since
	@#    simulate.sh runs xsim with -onerror quit, that error kills the whole
	@#    emulation before Linux boots.
	@#
	@# 2. `--incr` is dropped deliberately. Incremental reuse across a CHANGED
	@#    --debug setting is what produces a snapshot that still lacks trace data
	@#    while reporting success.
	@#
	@# 3. elaborate.sh carries RELATIVE include paths (../../../../prj.ip_user_files/...)
	@#    that resolve only in the Vivado project tree where v++ originally ran it.
	@#    In the copied package tree they dangle, xelab fails to compile the
	@#    SystemC interface -- and STILL PRINTS "Built simulation snapshot".
	@#    A broken snapshot that looks successful. From the xsim dir, ../../../../
	@#    is the build dir, so the prj.* trees are linked there.
	cp -f $(XSIM_DIR)/elaborate.sh $(XSIM_DIR)/elaborate.sh.orig
	sed -i 's/xelab --incr --debug off /xelab --debug typical /g' $(XSIM_DIR)/elaborate.sh
	@grep -q -- '--debug typical' $(XSIM_DIR)/elaborate.sh || { \
	    echo "ERROR: elaborate.sh did not match the expected xelab flags."; \
	    echo "       Inspect it by hand -- the tool's generated command changed."; \
	    exit 1; }
	ln -sfn _x/link/vivado/vpl/prj/prj.ip_user_files $(BUILD_DIR)/prj.ip_user_files
	ln -sfn _x/link/vivado/vpl/prj/prj.gen           $(BUILD_DIR)/prj.gen
	rm -rf $(XSIM_DIR)/xsim.dir/tb_behav
	cd $(XSIM_DIR) && ./elaborate.sh 2>&1 | tee elaborate_debug.log
	@# "Built simulation snapshot" is NOT sufficient -- see note 3 above.
	@if grep -qi "No such file or directory" $(XSIM_DIR)/elaborate_debug.log; then \
	    echo "ERROR: elaboration still has unresolved includes -- the snapshot is"; \
	    echo "       not trustworthy, whatever the success message says."; \
	    exit 1; \
	fi
	@echo "debug_sim: snapshot re-elaborated with trace information."

probe_emu:
ifeq ($(LAUNCH_HW_EMU_EXEC),1)
	@test -d $(PKG_OUT) || { echo "ERROR: no package -- run 'make sd_card' first"; exit 1; }
	@test -f $(XSIM_DIR)/elaborate_debug.log || { \
	    echo "ERROR: run 'make debug_sim' first -- the stock snapshot has no trace info."; \
	    exit 1; }
	rm -f $(XSIM_DIR)/plio_probe.vcd
	-cd $(PKG_OUT) && USER_PRE_SIM_SCRIPT=$(EXEC_SCRIPTS)/plio_probe.tcl \
	    PROBE_CU=$(PROBE_CU) PROBE_PORT=$(PROBE_PORT) \
	    timeout $(PROBE_WALL_TIMEOUT) ./launch_hw_emu.sh -no-reboot -run-app run_script.sh \
	    2>&1 | tee $(BUILD_DIR)/probe_emu.log
	@echo ""
	@echo "--- which signals the probe actually resolved ---"
	@grep -E "plio_probe:|  (OK|MISSING) " $(BUILD_DIR)/probe_emu.log | head -30 || true
	@echo ""
	@echo "--- handshake analysis ---"
	$(PYTHON) $(SCRIPTS)/analyze_plio_vcd.py $(XSIM_DIR)/plio_probe.vcd $(BASE_N)
else
	@echo "probe_emu runs an hw_emu. Run it on purpose:"
	@echo "    make debug_sim                               # once per package"
	@echo "    make probe_emu LAUNCH_HW_EMU_EXEC=1"
endif

# A probe run is expected to HANG when it is doing its job -- that is the whole
# point -- so it gets its own, shorter wall timeout. The VCD is written
# incrementally, so a killed run still leaves a parseable file.
PROBE_WALL_TIMEOUT ?= 900

# ---------------------------------------------------------------------------
.PHONY: clean cleanall
clean:
	rm -rf $(BUILD_DIR)

cleanall:
	rm -rf $(PROJECT_ROOT)/build
