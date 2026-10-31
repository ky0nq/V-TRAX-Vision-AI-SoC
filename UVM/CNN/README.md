# cnn_uvm : top_cnn UVM 검증 환경

```
cnn_uvm/
├── Makefile              VCS 컴파일 / 실행 / 커버리지 (vip/Makefile 과 같은 구조)
├── cnn_uvm.f             파일리스트 (다른 툴용)
├── rtl/                  DUT (SystemVerilog)
│   ├── cnn_defs.vh
│   ├── top_cnn.sv        DUT top (CSR + Image RAM + 공유 RAM 포트)
│   ├── top_cnn_cntl.sv   cnn_cntl / pe_cntl
│   ├── act_path.sv       act_ld_unit / input_buf / act_patch_gen / fc_gen / MUX / act_feeder
│   ├── wgt_path.sv       wgt_ld_unit / wgt_buf / wgt_patch_gen / wgt_feeder
│   ├── pe_core.sv        act_skew / wgt_skew / pe_array (3x3 single_pe)
│   └── out_path.sv       param_buf / output_fifo / post_process / pooling_unit / result_buf
├── rtl_orig/             변환 전 원본 Verilog (*.v). 대조용이며 컴파일하지 않는다
├── doc/                  UVM 구조도 (cnn_uvm_block_diagram.html / .md)
└── tb/
    ├── tb_top.sv               top : clk, 인터페이스, DUT, SVA, input_buf probe class, run_test()
    ├── cnn_pkg.sv              UVM package (아래 class 파일을 순서대로 include)
    ├── cnn_tb_defs.svh         계층 경로 매크로 (`CNN_IBUF_MEM)
    ├── cnn_tb_types.sv         레이어 상수 / enum / 형
    ├── cnn_csr_if.sv           CSR 인터페이스 (rst_n 포함)
    ├── cnn_mem_if.sv           고정 지연 RAM 읽기 인터페이스 (#(AW, DW))
    ├── cnn_probe_if.sv         쓰지 않음 (지워도 된다. input_buf 읽기는 tb_top 의 cnn_ibuf_probe class)
    ├── cnn_sva.sv              SVA (top 포트 + 내부 모듈 bind)
    ├── cnn_env_cfg.sv          설정 객체
    ├── cnn_mem_model.sv        RAM 내용 모델 (backdoor 적재 / 읽기, $readmemh)
    ├── cnn_infer_item.sv       자극 (영상 / weight / bias 논리 텐서 <-> RAM 배치)
    ├── cnn_ref_model.sv        golden (cnn_golden) + 정수 레퍼런스 모델 (cnn_ref_model)
    ├── cnn_csr_item.sv         CSR 동작 (reset / start / wait_done / irq_clear / set_irq_en / idle)
    ├── cnn_csr_event.sv        CSR monitor 사건
    ├── cnn_csr_sequencer.sv
    ├── cnn_csr_driver.sv       reset + start 핸드셰이크 + done 대기 + irq_clear
    ├── cnn_csr_monitor.sv      START / LAYER_DONE / DONE / IRQ_CLEAR / RESET 관측
    ├── cnn_csr_agent.sv
    ├── cnn_mem_item.sv         RAM 읽기 관측
    ├── cnn_mem_responder.sv    동기 RAM 응답 (주소 다음 clk 데이터)
    ├── cnn_mem_monitor.sv
    ├── cnn_mem_agent.sv        cnn_mem_agent #(12,24) = Image RAM, #(16,32) = 공유 RAM
    ├── cnn_vsequencer.sv       virtual sequencer (csr_sqr + mem model 핸들)
    ├── cnn_predictor.sv        START 시점 RAM 내용 -> golden
    ├── cnn_scoreboard.sv       o_final_result vs golden, irq 검사, latency
    ├── cnn_layer_checker.sv    레이어마다 input_buf 내용 vs golden (white-box)
    ├── cnn_coverage.sv         기능 커버리지 (결과 범위 x 패턴, 포화 / ReLU, irq_en, FSM)
    ├── cnn_env.sv
    ├── cnn_seq_lib.sv          virtual sequence 들
    └── cnn_test_lib.sv         test 들
```

## 구조

```
                 +-----------------------------------------------------------+
                 |                        cnn_env                            |
  vseq --> vsqr  |  csr_agt (driver/monitor)  --> CSR pins of top_cnn        |
                 |  img_agt  cnn_mem_agent#(12,24) : Image RAM responder     |
                 |  ram_agt  cnn_mem_agent#(16,32) : Weight+Bias RAM         |
                 |  csr_mon.ap --> pred (golden) --> scb / lchk / cov        |
                 +-----------------------------------------------------------+
```

* 자극 : `cnn_infer_item` 이 영상 / weight / bias 를 논리 텐서로 만들고 `pack_to_mem()` 으로 두
  RAM 모델에 DUT 배치대로 쓴다. responder 가 DUT 읽기 주소에 그 내용을 1 clk 뒤에 돌려준다.
* 기대값 : `cnn_predictor` 가 START 를 보면 RAM 모델을 `unpack_from_mem()` 으로 되읽어
  `cnn_ref_model` 로 4 레이어를 계산한다 (post_process 와 같은 정수 산술 : INT32 포화 -> x M ->
  round-half-away -> >> S -> ReLU -> INT8 포화, Layer 0 는 2x2 MaxPool).
* 검사
  * `cnn_scoreboard` : DONE 의 `o_final_result` == golden, `irq == irq_en`, latency 통계
  * `cnn_layer_checker` : `cnn_state` 가 `C_LAYER_END` 를 벗어날 때 `input_buf` 를 읽어 레이어 0/1/2
    결과와 비교 (`+NO_LAYER_CHECK` 로 끈다). 읽기는 tb_top 안의 `cnn_ibuf_probe` class 가 계층 경로로
    하고, checker 는 config_db `"ibuf_probe"` 로 받은 `cnn_ibuf_probe_base` handle 을 쓴다.
    (바깥 계층 참조가 있는 interface 는 virtual interface 로 쓸 수 없어서 class 로 뒀다. IEEE 1800-2017 25.9)
  * `cnn_sva.sv` : top 포트 관계 (irq / busy / done / start_ready), 내부 핸드셰이크
    (요구사항 4 : tile_cfg 는 받을 수 있을 때만, 시작 펄스는 IDLE 에서만, stall 중 데이터 유지 등)
* 커버리지 (`cnn_cov.sv`, `cnn_cov_test` 하나로 100%)
  * `cg_infer` : 최종 결과 범위 x 데이터 패턴, irq_en, 레이어별 INT8 양 / 음 포화 (음 포화는 ReLU 가 없는 L3 만),
    INT32 포화, ReLU clamp, dead layer (레이어 출력 전부 0, DM_MIN)
  * `cg_layer` / `cg_state` : 레이어 완료, FSM 상태 / 전이, tile 상태 (W_LOAD..NXT_TILE) x 레이어 0..3
  * `cg_ctrl_clear` : irq_clear 가 done 유지 중 / 아무것도 없을 때 / 추론 중에 들어옴
  * `cg_ctrl_irq_en` : done 유지 중 irq_en 0->1 / 1->0
  * `cg_ctrl_start` : irq_clear 뒤 START 까지 간격 (0..5 / 6..30 / 31+ clk)
  * `cg_reset` : reset 이 걸린 시점 (idle / done 유지 / 레이어 0..3 처리 중)
  (latency 는 데이터와 무관하게 일정해서 bin 으로 나누지 않고 scoreboard 가 min / avg / max 로 보고한다)

## Code coverage

* 항목 : `line + cond + fsm + tgl + branch` (+ `assert`). 컴파일과 실행 모두 `-cm` 으로 켜져 있고
  `-cm_line contassign` 으로 continuous assign 도 line 에 넣는다.
* 범위 : `cov_hier.cfg` (`-cm_hier`) 로 `tb_top.dut` 아래만 잰다. tb_top / interface / UVM class 는 빠지고,
  bind 로 dut 안에 들어간 `*_sva` checker module 도 뺀다. assertion coverage 는 그대로 모인다.
  RTL 에 module 을 추가해도 dut 아래면 자동으로 들어간다. 새 SVA module 을 bind 하면 `cov_hier.cfg` 에 `-module` 줄을 더한다.
* 누적 : 실행마다 `-cm_name <test>_<seed>` (regress 는 `<test>`) 로 `coverage.vdb` 에 쌓이고 `urg` 가 merge 한다.

```
make regress                # 전 test 실행 (test 별 PASS/FAIL) + merge 리포트
make cov TEST=cnn_cov_test  # test 하나 + 리포트
make report                 # 시뮬레이션 없이 지금까지 쌓인 것으로 리포트만
make cov_reset              # 쌓인 test 결과만 지움 (재컴파일 불필요)
make cov_wave               # Verdi coverage 로 미달 line / cond / toggle 확인
```

* 리포트 : `coverage_report/dashboard.txt` (요약, `make report` 가 터미널에 출력), `modlist.txt` (module 별),
  `hierarchy.txt` (instance 별), html 은 `dashboard.html`.
* 제외 : Verdi coverage 에서 도달 불가 항목 (예 : 상수 tie-off toggle, default branch) 을 exclusion 으로 저장해
  `cov_excl.el` 로 두면 `urg -elfile` 로 자동 적용된다 (다른 이름은 `make report COV_EXCL=xxx.el`).

## 실행

```
cd cnn_uvm
make sim                                  # 컴파일
make run  TEST=cnn_base_test              # 추론 1 회 (DM_SMALL)
make run  TEST=cnn_random_test NUM_INFER=5 SEED=7
make run  TEST=cnn_corner_test            # ZERO / MAX / MIN / ALT / SPARSE / FULL
make run  TEST=cnn_irq_test
make run  TEST=cnn_reset_test RESET_AFTER=20000
make run  TEST=cnn_file_test IMG_HEX=img.hex RAM_HEX=ram.hex EXP_RESULT=12
make wave TEST=cnn_base_test              # +DUMP 로 wave.fsdb 기록 뒤 verdi
make cov / make cov_wave / make regress
```

hex 파일 형식 (`$readmemh`, word 당 한 줄)
* `IMG_HEX`  : 4096 줄, 24bit `{ch2, ch1, ch0}` (word = y*64 + x)
* `RAM_HEX`  : 45293 줄, 32bit (0..45249 weight `{0, lane2, lane1, lane0}`, 45250..45292 bias)
* 또는 `WGT_HEX` 45250 줄 + `BIAS_HEX` 43 줄

## 데이터 패턴 (`cnn_data_mode_e`)

| mode      | 내용 |
|-----------|------|
| DM_SMALL  | 영상 전 범위, weight ±32, bias ±20000 : 출력이 INT8 중간 범위 (기본) |
| DM_FULL   | 전부 전 범위 random : 포화 많음 |
| DM_SPARSE | 대부분 0 |
| DM_ZERO   | 영상 / weight 0 : bias 경로만 |
| DM_MAX    | 전부 +127, bias INT32 최대 : INT32 / INT8 양의 포화 |
| DM_MIN    | 전부 -128, bias INT32 최소 : ReLU 0, 최종 -128 |
| DM_ALT    | +127 / -128 교대 |

## RTL 을 바꿀 때

* 레이어 크기 / 주소 (cnn_cntl parameter) 를 바꾸면 `tb/cnn_tb_types.sv` 의 상수도 같이 바꾼다.
* Requant M / S 는 `cnn_tb_types.sv` 의 `CNN_Lx_QM / QS` 하나로 DUT parameter 와 golden 에 같이 간다.
* DUT 인스턴스 이름 / 계층이 바뀌면 `tb/cnn_tb_defs.svh` 의 `CNN_IBUF_MEM` 을 고친다.
