# ===========================================================================
# VEK280 base project -- Makefile
#
# PHASE 0: PS + PL only. DDR -> data_src -> AXI4-Stream -> data_sink -> DDR,
# driven by XRT from the APU, verified against a host-side golden model.
# No AI Engine yet; the array arrives in phase 1, in simulation.
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
#     make test_pl      rung 3   s       the PL kernels' arithmetic (HLS csim)
#     make run_emu      rung 5   ~tens of min   the whole system (hw_emu)
#     (rungs 2 and 4 -- x86sim/aiesim and the HLS cost report -- arrive with
#      phases 1 and 4; the numbering is kept stable so docs stay valid)
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

# Deliberate breakage, so a verification rung can be SEEN to fail.
#   none   (default) the design is correct
#   value  data_sink corrupts one word  -> the check reports a mismatch
#   short  data_src writes n-1 words    -> the design DEADLOCKS in hw_emu
#
# `short` and `value` fail in different ways on purpose: one is a wrong answer,
# the other is a hang. They are diagnosed by completely different means, and the
# hang is the class this toolchain produces most often.
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
  MUTANT_SHORT := 0
  MUTANT_VALUE := 0
  MUTANT_ARMED := 0
else ifeq ($(MUTANT),short)
  MUTANT_SHORT := 1
  MUTANT_VALUE := 0
  MUTANT_ARMED := 1
else ifeq ($(MUTANT),value)
  MUTANT_SHORT := 0
  MUTANT_VALUE := 1
  MUTANT_ARMED := 1
else
  $(error MUTANT=$(MUTANT) is not one of: none, value, short)
endif

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
# Host compile flags (cross, for the board/emulated APU)
# ---------------------------------------------------------------------------
GCC_FLAGS := -O2 -std=c++17 -D__linux__
GCC_FLAGS += -DBASE_N=$(BASE_N)
GCC_FLAGS += -DMUTANT_ARMED=$(MUTANT_ARMED)

GCC_INC := -I$(SDKTARGETSYSROOT)/usr/include/xrt
GCC_INC += -I$(SDKTARGETSYSROOT)/usr/include
GCC_INC += -I$(HOST_SRC)

GCC_LIBS := -L$(SDKTARGETSYSROOT)/usr/lib -lxrt_coreutil

# Native compiler for the rung-1 and rung-3 tests. NOT $(CXX): that one is the
# aarch64 cross compiler and its output cannot run here.
HOST_CXX := g++

# ===========================================================================
.PHONY: help check_env all
.DEFAULT_GOAL := help

help:
	@echo ""
	@echo "VEK280 base project -- phase 0 (PS + PL, no AIE)"
	@echo ""
	@echo "  FIRST:         source setup_env.sh && make check_env"
	@echo ""
	@echo "  Development cycle (read docs/04-dev-cycle.md):"
	@echo "    test_host      rung 1  ms   golden model + the checker itself"
	@echo "    test_pl        rung 3  s    PL kernels, HLS C simulation"
	@echo "    run_emu        rung 5  long full system in hw_emu"
	@echo ""
	@echo "  Build steps (each one is also the name of what it produces):"
	@echo "    kernels        .xo  -- HLS compile of the two PL kernels"
	@echo "    xsa            .xsa -- v++ link: kernels into the platform"
	@echo "    application    .elf -- cross-compiled host app"
	@echo "    rootfs         a packageable copy of the common-image rootfs"
	@echo "    package        the bootable SD image / emulation package"
	@echo "    sd_card        kernels + xsa + application + package"
	@echo ""
	@echo "  Knobs (current value):"
	@echo "    TARGET=$(TARGET)        hw_emu | hw"
	@echo "    BASE_N=$(BASE_N)        32-bit words through the chain"
	@echo "    PL_FREQ=$(PL_FREQ)      PL kernel clock, MHz"
	@echo "    MUTANT=$(MUTANT)        none | value | short  (deliberate breakage)"
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
	    $(PL_SRC)/test/test_pl_loopback.cpp $(HOST_SRC)/golden.cpp \
	    -o $(BUILD_DIR)/test_pl
	@echo ""
	@timeout 120 $(BUILD_DIR)/test_pl

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

$(BUILD_DIR)/$(XSA): $(KERNEL_XOS) $(LINK_CFG)
	v++ $(VPP_FLAGS) $(VPP_LINK_FLAGS) -l $(KERNEL_XOS) \
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
package: $(BUILD_DIR)/$(APP_ELF) $(BUILD_DIR)/$(XSA) $(ROOTFS) \
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
	    $(BUILD_DIR)/$(XSA)

.PHONY: sd_card
sd_card: kernels xsa application package

# ---------------------------------------------------------------------------
# Rung 5: hw_emu
#
# The guard is deliberate. This run takes a long time and nothing about it is
# recoverable if you did not mean to start it.
#
# -no-reboot reuses the already-booted image, which is most of the wall time.
# ---------------------------------------------------------------------------
.PHONY: run_emu
run_emu:
ifeq ($(LAUNCH_HW_EMU_EXEC),1)
	@test -d $(PKG_OUT) || { echo "ERROR: no package -- run 'make sd_card' first"; exit 1; }
	cd $(PKG_OUT) && ./launch_hw_emu.sh -no-reboot -run-app run_script.sh 2>&1 \
	    | tee $(BUILD_DIR)/run_emu.log
	@echo ""
	@echo "---- verdict ----"
	@grep -E "\[host\]|TEST PASSED|ERROR:" $(BUILD_DIR)/run_emu.log || true
else
	@echo "hw_emu is slow and starting one by accident wastes an afternoon."
	@echo "Run it on purpose:"
	@echo "    make run_emu LAUNCH_HW_EMU_EXEC=1"
endif

# ---------------------------------------------------------------------------
.PHONY: clean cleanall
clean:
	rm -rf $(BUILD_DIR)

cleanall:
	rm -rf $(PROJECT_ROOT)/build
