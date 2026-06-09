# Verilator shader/ROM checks.
# run: parity checks; lint: RTL static check; clean: generated dirs.

VERILATOR ?= verilator
REPO_ROOT := $(abspath ../..)
SRC       := $(REPO_ROOT)/icesugar_pro/src

# Synthesizable RTL under test.
SHADER_SV  := $(SRC)/pixel_shader.sv
MEM_SV     := $(SRC)/font_16x32_rom.sv $(SRC)/sprite_rom.sv $(SRC)/spectrum_bin_ram.sv
TOP_SV     := $(SRC)/pixel_shader_top.sv $(SHADER_SV) $(MEM_SV)
ROM_SV     := rom_check_top.sv $(SRC)/font_16x32_rom.sv $(SRC)/sprite_rom.sv

INCLUDES  := -I$(REPO_ROOT)/icesugar_pro/model/include -I$(REPO_ROOT)/shared/include
# Map C11 _Static_assert to C++ for Verilator harnesses.
DEFINES   := -DUI_STATE_VERSION=3 -D_Static_assert=static_assert
LIBS      := $(REPO_ROOT)/build/librender_model.a $(REPO_ROOT)/build/libshared.a
CXX_FLAGS := -std=c++17 -O2 -Wall -Wno-unused-parameter $(INCLUDES) $(DEFINES)

VFLAGS    := --cc --exe --build -j 0 -CFLAGS "$(CXX_FLAGS)" -LDFLAGS "$(LIBS)"

.PHONY: all run run_shader run_top run_rom lint libs mem clean

all: run

# C model archives.
libs:
	cmake --build $(REPO_ROOT)/build --target render_model shared >/dev/null

# Generated ROM memories.
mem:
	python3 $(REPO_ROOT)/tools/rom_to_mem.py --out build >/dev/null

# Bare shader core.
obj_shader/Vpixel_shader: $(SHADER_SV) tb_pixel_shader.cpp libs
	$(VERILATOR) $(VFLAGS) --Mdir obj_shader --top-module pixel_shader \
	    $(SHADER_SV) tb_pixel_shader.cpp

run_shader: obj_shader/Vpixel_shader
	@echo "== bare pixel_shader core (ROM ports backed by C arrays) =="
	obj_shader/Vpixel_shader

# Shader wrapper.
obj_top/Vpixel_shader_top: $(TOP_SV) tb_pixel_shader_top.cpp libs
	$(VERILATOR) $(VFLAGS) --Mdir obj_top --top-module pixel_shader_top \
	    $(TOP_SV) tb_pixel_shader_top.cpp

run_top: obj_top/Vpixel_shader_top mem
	@echo "== pixel_shader_top: shader + .mem ROMs + spectrum RAM (end-to-end) =="
	obj_top/Vpixel_shader_top

# ROM equivalence.
obj_rom/Vrom_check_top: $(ROM_SV) tb_rom_check.cpp libs
	$(VERILATOR) $(VFLAGS) --Mdir obj_rom --top-module rom_check_top \
	    $(ROM_SV) tb_rom_check.cpp

run_rom: obj_rom/Vrom_check_top mem
	@echo "== font_16x32_rom / sprite_rom .mem equivalence =="
	obj_rom/Vrom_check_top

run: run_shader run_top run_rom

# RTL lint.
lint:
	$(VERILATOR) --lint-only -Wall -Wno-UNUSED -Wno-UNUSEDSIGNAL \
	    --top-module pixel_shader_top $(TOP_SV)

clean:
	rm -rf obj_shader obj_top obj_rom build
