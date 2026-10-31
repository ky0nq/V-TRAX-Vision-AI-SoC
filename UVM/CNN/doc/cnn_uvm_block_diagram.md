# cnn_uvm 구조도

`agent / coverage / env / interface / package / monitor / item / sequence / sequencer / test / scoreboard / driver / tb_top`
을 파일 하나씩으로 나눈 구조에, CNN 가속기 검증에 필요한 predictor(레퍼런스 모델) · RAM responder ·
layer checker · SVA 를 더한 형태다. (HTML 버전 : 같은 폴더의 `cnn_uvm_block_diagram.html`)

```mermaid
flowchart LR
    subgraph TB[tb_top.sv]
        direction LR
        subgraph TEST[cnn_base_test / random / corner / file / irq / reset  (cnn_test_lib.sv)]
            direction TB
            VSEQ[virtual sequence<br/>cnn_infer_vseq · multi · corner · file · irq · reset]
            subgraph ENV[cnn_env]
                direction LR
                VSQR[vsqr : cnn_vsequencer]
                MEM[(img_mem · ram_mem<br/>cnn_mem_model)]
                PRED[pred : cnn_predictor<br/>cnn_ref_model → cnn_golden]
                SCB[scb : cnn_scoreboard]
                LCHK[lchk : cnn_layer_checker]
                COV[cov : cnn_coverage]
                subgraph CSRA[csr_agt : cnn_csr_agent]
                    direction LR
                    SQR[csr_sqr] --> DRV[csr_drv]
                    MON[csr_mon]
                end
                subgraph IMGA[img_agt : cnn_mem_agent #40;12,24#41;]
                    IRSP[rsp : responder]
                    IMON[mon]
                end
                subgraph RAMA[ram_agt : cnn_mem_agent #40;16,32#41;]
                    RRSP[rsp : responder]
                    RMON[mon]
                end
            end
        end
        CSRIF[[cnn_csr_if<br/>start/ready/busy/irq/done/result/state/rst_n]]
        IMGIF[[cnn_mem_if #40;12,24#41;<br/>rd_addr / rdata]]
        RAMIF[[cnn_mem_if #40;16,32#41;<br/>rd_addr / rdata]]
        PROBE[cnn_ibuf_probe<br/>tb_top 안의 class · ibuf_read]
        DUT[top_cnn<br/>top_cnn_cntl · act_path · wgt_path · pe_core · out_path]
        SVA[cnn_sva.sv<br/>cnn_top_sva + bind]
    end

    VSEQ -- "start(vsqr)" --> VSQR
    VSQR -- "cnn_csr_item" --> SQR
    VSQR -- "pack_to_mem()" --> MEM
    MEM -- "read()" --> IRSP
    MEM -- "read()" --> RRSP
    MEM -- "unpack_from_mem()" --> PRED
    DRV -- "drive" --> CSRIF
    CSRIF -- "sample" --> MON
    CSRIF <--> DUT
    IRSP <--> IMGIF
    IMGIF -- "sample" --> IMON
    IMGIF <--> DUT
    RRSP <--> RAMIF
    RAMIF -- "sample" --> RMON
    RAMIF <--> DUT
    MON -. "ap : cnn_csr_event" .-> PRED
    MON -. "ap" .-> SCB
    MON -. "ap" .-> LCHK
    MON -. "ap" .-> COV
    PRED -. "exp_ap : cnn_golden" .-> SCB
    PRED -. "exp_ap" .-> LCHK
    PRED -. "exp_ap" .-> COV
    PROBE -- "input_buf (계층 참조)" --> DUT
    LCHK -- "ibuf_read()" --> PROBE
    SVA -. bind .-> DUT
```

## 요청하신 구성요소와 파일

| 구성요소 | 파일 (tb/) | 클래스 / 역할 |
|---|---|---|
| interface | cnn_csr_if.sv · cnn_mem_if.sv | CSR + rst_n · 고정 지연 RAM 읽기 (#(AW,DW)). input_buf white-box 읽기는 tb_top 안의 class cnn_ibuf_probe (IEEE 1800-2017 25.9 때문에 interface 로 두지 않는다) |
| item | cnn_csr_item.sv · cnn_infer_item.sv · cnn_csr_event.sv · cnn_mem_item.sv | CSR 동작 · 추론 자극 (텐서 ↔ RAM 배치) · monitor 사건 · RAM 읽기 |
| sequence | cnn_seq_lib.sv | cnn_vseq_base + infer · multi · corner · file · irq · reset |
| sequencer | cnn_csr_sequencer.sv · cnn_vsequencer.sv | CSR sequencer · virtual sequencer |
| driver | cnn_csr_driver.sv (+ cnn_mem_responder.sv) | reset · start · done 대기 · irq_clear / RAM 응답 (reactive) |
| monitor | cnn_csr_monitor.sv · cnn_mem_monitor.sv | START / LAYER_DONE / DONE / IRQ_CLEAR / RESET · RAM 주소 |
| agent | cnn_csr_agent.sv · cnn_mem_agent.sv | CSR agent · cnn_mem_agent #(12,24) img_agt, #(16,32) ram_agt |
| scoreboard | cnn_scoreboard.sv (+ cnn_predictor.sv · cnn_ref_model.sv · cnn_layer_checker.sv) | 최종 결과 비교 · golden 생성 · 레이어별 input_buf 비교 |
| coverage | cnn_coverage.sv (+ cnn_sva.sv cover) | 결과 x 패턴, 포화 / ReLU, irq_en, FSM |
| environment | cnn_env.sv · cnn_env_cfg.sv | 생성 / 연결 · 설정 |
| test | cnn_test_lib.sv | base · random · corner · file · irq · reset |
| package | cnn_pkg.sv · cnn_tb_types.sv · cnn_tb_defs.svh | include 순서 · 상수 / enum · 계층 경로 매크로 |
| tb_top | tb_top.sv (+ cnn_sva.sv) | clk, 인터페이스, DUT, SVA bind, input_buf probe class, config_db, run_test() |

## 추론 1 회의 흐름

1. test 가 virtual sequence 를 `env.vsqr` 에 시작한다.
2. sequence 가 `cnn_infer_item` 을 만들어 `pack_to_mem()` 으로 img_mem / ram_mem 에 DUT 배치대로 쓴다.
3. `cnn_csr_item(OP_START)` 을 csr_sqr 로 보내면 driver 가 start 핸드셰이크를 하고 done_status 를 기다린다.
4. DUT 가 RAM 주소를 내면 responder 가 다음 clk 에 RAM 모델 내용을 돌려준다.
5. csr_mon 이 START 를 내면 predictor 가 RAM 모델을 되읽어 `cnn_ref_model` 로 golden 을 만든다.
6. cnn_state 가 C_LAYER_END 를 벗어날 때마다 layer checker 가 input_buf 를 probe 로 읽어 레이어 0/1/2 결과를 비교한다.
7. DONE 에서 scoreboard 가 `o_final_result` 와 golden 을 비교하고 coverage 가 sample 한다.
