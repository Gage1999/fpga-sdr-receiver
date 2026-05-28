# Verilator parity harness for pixel_shader.sv.
#
# Builds the SV under test together with tb_pixel_shader.cpp, links against
# the C reference model (librender_model.a + libshared.a built by the
# top-level cmake), and runs the harness.
#
# Usage (from this directory):
#   make            -- build the harness binary
#   make run        -- build and run; prints per-case match percentage
#   make clean      -- nuke obj_dir/

VERILATOR ?= verilator

REPO_ROOT := $(abspath ../..)
BUILD_DIR := obj_dir
SV_TOP    := pixel_shader

SV_SRC    := pixel_shader.sv
CPP_TB    := tb_pixel_shader.cpp

INCLUDES  := -I$(REPO_ROOT)/icesugar_pro/model/include \
             -I$(REPO_ROOT)/shared/include

# Match the cmake build's compile-def so ui_state.h layout is consistent.
DEFINES   := -DUI_STATE_VERSION=3

LIBS      := $(REPO_ROOT)/build/librender_model.a \
             $(REPO_ROOT)/build/libshared.a

CXX_FLAGS := -std=c++17 -O2 -Wall -Wno-unused-parameter $(INCLUDES) $(DEFINES)

BIN       := $(BUILD_DIR)/V$(SV_TOP)

.PHONY: all run clean libs

all: $(BIN)

# Ensure the cmake-built archives exist. Cheap if already built.
libs:
	cmake --build $(REPO_ROOT)/build --target render_model shared >/dev/null

$(BIN): $(SV_SRC) $(CPP_TB) libs
	$(VERILATOR) --cc --exe --build -j 0 \
	    -CFLAGS "$(CXX_FLAGS)" \
	    -LDFLAGS "$(LIBS)" \
	    --top-module $(SV_TOP) \
	    $(SV_SRC) $(CPP_TB)

run: $(BIN)
	$(BIN)

clean:
	rm -rf $(BUILD_DIR)
