# ============================================================
# CNN accelerator UVM - Synopsys VCS Makefile
#
# Project structure
# .
# ├── rtl/        top_cnn, top_cnn_cntl, act_path, wgt_path, pe_core, out_path (.sv 또는 .v), cnn_defs.vh
#                 AXI4_Lite_* 래퍼는 있어도 컴파일하지 않는다
# ├── tb/         UVM (cnn_pkg.sv + interfaces + sva + tb_top.sv)
# └── Makefile
#
# Usage
#   make sim
#   make run  TEST=cnn_base_test
#   make run  TEST=cnn_random_test NUM_INFER=5
#   make run  TEST=cnn_file_test IMG_HEX=img.hex RAM_HEX=ram.hex EXP_RESULT=12
#   make cov  TEST=cnn_cov_test           (기능 coverage 를 혼자 100% 로 채우는 test)
#   make wave TEST=cnn_base_test          (+DUMP -> wave.fsdb)
#   make report                           (쌓인 모든 test merge -> text + html, code + 기능 coverage)
#   make cov_reset                        (쌓인 test 결과만 지움)
#   make cov_wave
#   make regress                          (모든 test + merge 리포트)
#   make clean
# ============================================================

TEST        ?= cnn_base_test
VERBOSITY   ?= UVM_MEDIUM
TOP         ?= tb_top
SEED        ?= 1

# RTL_DIR 을 GitHub checkout 으로 바꿀 수 있다 : make run RTL_DIR=../V-TRAX/cnn_accelerator/rtl
#   cnn_defs.vh 는 GitHub rtl 에 없으므로 DEFS_DIR (기본 rtl) 에서 찾는다
RTL_DIR     ?= rtl
DEFS_DIR    ?= rtl
TB_DIR      := tb

SIMV        := simv
COMPILE_LOG := compile.log
RUN_LOG     := sim.log
WAVE_FILE   := wave.fsdb

# ------------------------------------------------------------
# Coverage
# ------------------------------------------------------------
COV_DIR     := coverage.vdb
COV_REPORT  := coverage_report

COV_METRICS := line+cond+fsm+tgl+branch+assert

# code coverage 범위 : DUT (tb_top.dut) 만, bind 된 SVA checker 는 제외
COV_HIER    := cov_hier.cfg

# Verdi coverage 에서 저장한 exclusion 파일 (있을 때만 urg 에 넘긴다)
COV_EXCL    ?= cov_excl.el
URG_EXCL    := $(if $(wildcard $(COV_EXCL)),-elfile $(COV_EXCL))

# ------------------------------------------------------------
# Source files
#   DUT = top_cnn. AXI4-Lite 래퍼 (AXI4_Lite_*) 는 컴파일하지 않는다 : TB 의 host_agent 가 start 핀을 직접 준다
#   RTL 은 .sv 와 .v 를 모두 받는다. 같은 이름의 .sv 가 있으면 .v 는 빼서 중복 정의를 막는다
# ------------------------------------------------------------
RTL_EXCLUDE := $(wildcard $(RTL_DIR)/AXI4_Lite*)
RTL_SV   := $(filter-out $(RTL_EXCLUDE), $(sort $(wildcard $(RTL_DIR)/*.sv)))
RTL_V    := $(filter-out $(RTL_EXCLUDE) $(RTL_SV:.sv=.v), $(sort $(wildcard $(RTL_DIR)/*.v)))
RTL_SRCS := $(RTL_SV) $(RTL_V)
RTL_DEPS := $(RTL_SRCS) $(wildcard $(RTL_DIR)/*.vh) $(wildcard $(DEFS_DIR)/*.vh)

# cnn_pkg.sv includes UVM class files.
# Compile interface -> sva -> package -> top.
TB_SRCS := \
	$(TB_DIR)/cnn_ctrl_if.sv \
	$(TB_DIR)/cnn_img_if.sv \
	$(TB_DIR)/cnn_wgt_if.sv \
	$(TB_DIR)/cnn_sva.sv \
	$(TB_DIR)/cnn_pkg.sv \
	$(TB_DIR)/tb_top.sv

# Recompile when any TB file changes.
TB_DEPS := $(wildcard $(TB_DIR)/*.sv) $(wildcard $(TB_DIR)/*.svh)

INC_DIRS := \
	+incdir+$(TB_DIR) \
	+incdir+$(RTL_DIR) \
	+incdir+$(DEFS_DIR)

# ------------------------------------------------------------
# Test plusargs (비어 있으면 안 붙는다)
# ------------------------------------------------------------
PLUSARGS :=
ifdef NUM_INFER
PLUSARGS += +NUM_INFER=$(NUM_INFER)
endif
ifdef IMG_HEX
PLUSARGS += +IMG_HEX=$(IMG_HEX)
endif
ifdef RAM_HEX
PLUSARGS += +RAM_HEX=$(RAM_HEX)
endif
ifdef WGT_HEX
PLUSARGS += +WGT_HEX=$(WGT_HEX)
endif
ifdef BIAS_HEX
PLUSARGS += +BIAS_HEX=$(BIAS_HEX)
endif
ifdef EXP_RESULT
PLUSARGS += +EXP_RESULT=$(EXP_RESULT)
endif
ifdef RESET_AFTER
PLUSARGS += +RESET_AFTER=$(RESET_AFTER)
endif
ifdef DONE_TIMEOUT
PLUSARGS += +DONE_TIMEOUT=$(DONE_TIMEOUT)
endif
ifdef NO_LAYER_CHECK
PLUSARGS += +NO_LAYER_CHECK
endif
ifdef NO_COV
PLUSARGS += +NO_COV
endif
# +DUMP 은 run 레시피에서 $(if $(DUMP),+DUMP) 로 붙인다 (make wave 의 target 변수 DUMP 가 먹도록)

# ------------------------------------------------------------
# VCS options
# ------------------------------------------------------------
VCS_FLAGS := \
	-full64 \
	-sverilog \
	-ntb_opts uvm \
	-timescale=1ns/1ps \
	-debug_access+all \
	-kdb \
	-assert svaext \
	-cm $(COV_METRICS) \
	-cm_dir $(COV_DIR) \
	-cm_hier $(COV_HIER) \
	-cm_line contassign

.PHONY: all sim run wave cov report cov_wave cov_reset regress clean help

all: run

# ============================================================
# Compile + Elaborate
# ============================================================
sim: $(SIMV)

$(SIMV): $(RTL_DEPS) $(TB_DEPS) $(COV_HIER)
	vcs $(VCS_FLAGS) \
		$(INC_DIRS) \
		$(RTL_SRCS) \
		$(TB_SRCS) \
		-top $(TOP) \
		-o $(SIMV) \
		-l $(COMPILE_LOG)

# ============================================================
# Run UVM Simulation + Coverage
# ============================================================
run: sim
	./$(SIMV) \
		+UVM_TESTNAME=$(TEST) \
		+UVM_VERBOSITY=$(VERBOSITY) \
		+ntb_random_seed=$(SEED) \
		$(PLUSARGS) $(if $(DUMP),+DUMP) \
		-cm $(COV_METRICS) \
		-cm_dir $(COV_DIR) \
		-cm_name $(TEST)_$(SEED) \
		-l $(RUN_LOG)

# ============================================================
# Open Waveform
# ============================================================
wave: DUMP := 1
wave: run
	verdi -ssf $(WAVE_FILE) &

# ============================================================
# Generate Coverage Report
# ============================================================
#   cov    : TEST 하나 실행 + report
#   report : 이미 쌓인 coverage.vdb 의 모든 test 를 merge 해서 리포트만 만든다
#            (text + html. code coverage = DUT 의 line/cond/fsm/tgl/branch, 기능 coverage = covergroup/assert)
cov: run
	@$(MAKE) --no-print-directory report

report:
	urg \
		-dir $(COV_DIR) \
		-report $(COV_REPORT) \
		-format both \
		$(URG_EXCL)
	@awk -f scripts/cov_holes.awk $(COV_REPORT)/modinfo.txt > $(COV_REPORT)/holes.txt

	@echo ""
	@echo "========================================"
	@echo " Coverage Report Generated"
	@echo "========================================"
	@cat $(COV_REPORT)/dashboard.txt
	@echo "----------------------------------------"
	@echo "Database  : $(COV_DIR)"
	@echo "Report    : $(COV_REPORT)/dashboard.html (html), *.txt (text)"
	@echo "Per module: $(COV_REPORT)/modlist.txt"
	@echo "Per inst  : $(COV_REPORT)/hierarchy.txt"
	@echo "Holes     : $(COV_REPORT)/holes.txt (uncovered line/cond/toggle/fsm/branch only)"
	@echo "========================================"

# ============================================================
# Coverage reset : 쌓인 test 결과만 지운다 (설계 정보는 남아서 재컴파일 불필요)
# ============================================================
cov_reset:
	rm -rf $(COV_DIR)/snps/coverage/db/testdata $(COV_REPORT)

# ============================================================
# Open Coverage with Verdi
# ============================================================
cov_wave: cov
	verdi -cov -covdir $(COV_DIR) &

# ============================================================
# Regression : 모든 test 를 차례로
# ============================================================
REGRESS_TESTS := cnn_base_test cnn_corner_test cnn_random_test cnn_irq_test cnn_reset_test cnn_cov_test

regress: sim
	@for t in $(REGRESS_TESTS); do \
		echo "==== $$t ===="; \
		./$(SIMV) +UVM_TESTNAME=$$t +UVM_VERBOSITY=UVM_LOW +ntb_random_seed=$(SEED) \
			-cm $(COV_METRICS) -cm_dir $(COV_DIR) -cm_name $$t -l sim_$$t.log > /dev/null; \
		grep -E "TEST PASSED|TEST FAILED" sim_$$t.log; \
	done
	@$(MAKE) --no-print-directory report

# ============================================================
# Clean
# ============================================================
clean:
	rm -rf \
		$(SIMV) \
		simv.daidir \
		csrc \
		ucli.key \
		vc_hdrs.h \
		DVEfiles \
		novas.conf \
		novas.rc \
		verdiLog \
		AN.DB \
		$(COV_DIR) \
		$(COV_REPORT) \
		*.vdb \
		*.vpd \
		*.vcd \
		*.fsdb \
		*.log \
		cov_img.hex \
		cov_ram.hex

# ============================================================
# Help
# ============================================================
help:
	@echo "make sim"
	@echo "  Compile and elaborate with VCS"
	@echo ""
	@echo "make run TEST=<test> [SEED=n] [VERBOSITY=UVM_HIGH]"
	@echo "  Tests : cnn_base_test cnn_random_test cnn_corner_test cnn_file_test cnn_irq_test cnn_reset_test cnn_cov_test"
	@echo ""
	@echo "make run TEST=cnn_random_test NUM_INFER=5"
	@echo "make run TEST=cnn_file_test IMG_HEX=img.hex RAM_HEX=ram.hex [EXP_RESULT=n]"
	@echo "make run TEST=cnn_file_test IMG_HEX=img.hex WGT_HEX=wgt.hex BIAS_HEX=bias.hex"
	@echo "make run TEST=cnn_reset_test RESET_AFTER=20000"
	@echo ""
	@echo "make wave TEST=<test>"
	@echo "  Run with +DUMP and open FSDB waveform in Verdi"
	@echo ""
	@echo "make cov TEST=<test>"
	@echo "  Run one test, then text + html coverage report (code coverage = DUT only, see cov_hier.cfg)"
	@echo "make report"
	@echo "  Merge every test already in coverage.vdb and report (no simulation)"
	@echo "make regress"
	@echo "  Run all regression tests (PASS/FAIL per test), then merged report"
	@echo "make cov_reset"
	@echo "  Drop accumulated test data in coverage.vdb (keeps design, no recompile)"
	@echo "make cov_wave"
	@echo "  Open coverage in Verdi (save exclusions as cov_excl.el, urg picks it up)"
	@echo ""
	@echo "make clean"
