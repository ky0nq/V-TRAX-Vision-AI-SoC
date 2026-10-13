# V-TRAX-Vision-AI-SoC
**CNN 가속기 활용 Vision 기반 원격 차량 제어 SoC 설계**

카메라로 본 핸들 각도를 FPGA CNN 가속기가 추론해 무선 미니카를 조향하는 Zybo Z7-20 기반 SoC 프로젝트.

Pcam 5C가 촬영한 운전대 영상을 PL에서 64×64로 축소하고, 직접 설계한 INT8 systolic CNN 가속기가 조향각(°)을 회귀한다. PS(ARM Cortex-A9)는 이 각도와 FSR 페달 입력을 합쳐 주행 명령을 만들고, ESP32/ESP-NOW 링크를 통해 미니카를 구동한다. 영상과 상태는 HDMI와 PC HUD로 동시에 확인한다.

| 항목 | 내용 |
|---|---|
| 보드 | Digilent Zybo Z7-20 (XC7Z020-1CLG400C) |
| 카메라 | Pcam 5C (OV5640, MIPI CSI-2), 1280×720 @ 60 fps |
| 호스트 CPU | ARM Cortex-A9 (Zynq PS), bare-metal |
| AI 모델 | 조향각 회귀 CNN — Conv 2단 + FC 2단, INT8 양자화 |
| 가속기 | 3×3 PE systolic array, AXI4-Lite 제어 |
| 무선 | ESP32 ×3, ESP-NOW + UART |
| 도구 | Vivado / Vitis 2022.2, Arduino (ESP32 core 3.x), Python (PySide6) |
| 기간 | 2026.09.07 ~ 2026.10.14 |

---

## 목차

1. [시스템 구조](#시스템-구조)
2. [Repository 구성](#Repository-구성)
3. [CNN 가속기](#cnn-가속기)
4. [영상 파이프라인 및 주변 IP](#영상-파이프라인-및-주변-ip)
5. [미니카 제어](#미니카-제어)
6. [PC UI](#pc-ui)
7. [빌드 및 실행](#빌드-및-실행)
8. [검증](#검증)
9. [팀](#팀)

---

## 시스템 구조

<img width="5672" height="4424" alt="image" src="https://github.com/user-attachments/assets/24c7ccd1-bf51-4037-adfb-5b6be3ac2f74" />

**데이터 흐름**

1. 카메라 프레임(1280×720 RGB)을 자체 설계 DMA가 DDR 프레임 버퍼 3개에 순환 기록한다.
2. CAPTURE IP가 DDR에서 256×256 관심 영역을 읽어 4×4 블록 평균으로 64×64 RGB888 이미지를 만든다.
3. CNN 가속기가 이 이미지로 조향각을 추론해 `RESULT` 레지스터에 기록한다 (1 LSB = 1°).
4. PS가 조향각과 FSR 페달 값을 묶어 `CommandPacket`을 만들고 100 Hz로 차량에 전송한다.
5. HDMI에는 카메라 영상과 캡처 영역 박스가, PC HUD에는 조향각·페달·카메라 영상이 표시된다.

---

## Repository 구성

```
V-TRAX/
├─ cnn_accelerator/
│  ├─ rtl/                 CNN 가속기 RTL (개발본)
│  └─ C_Golden_code/       블록별 C golden model + PC 추론 참조 코드
├─ Zybo_IP/                Vivado IP Repository
│  ├─ IP_CNN/              CNN 가속기 패키징본 (RTL + weight/param .mem + TB)
│  ├─ IP_VDMA/             자체 설계 DMA (S2MM + MM2S, 프레임 버퍼 3개)
│  ├─ IP_CAPTURE/          DDR → 256×256 크롭 → 64×64 축소 캡처
│  ├─ IP_BBOX/             HDMI 출력 영상에 캡처 영역 박스 오버레이
│  ├─ IP_AXI_APB/          AXI4-Lite → APB 브리지
│  ├─ IP_GPIO/ IP_TIMER/ IP_UART/   APB 주변장치
│  └─ P-CAM_HDMI_IP/       Pcam 5C / HDMI 브링업용 IP와 PS 드라이버
├─ TOP_Block/
│  └─ Image.v              weight·param·로딩 화면을 담은 BRAM 프런트엔드
├─ UI/
│  ├─ zybo/                보드 측 UDP 텔레메트리·영상 송신
│  └─ python/              PC HUD (PySide6 + QML)
└─ minicar_control/        무선 미니카 제어 (Zybo 앱 + ESP32 펌웨어 + PC 도구)
```

---

## CNN 가속기

### Custom CNN 모델

| Layer | 연산 | 입력 | 출력 | Weight (word) |
|---|---|---|---|---:|
| L0 | Conv 3×3, S1, P1 + ReLU + MaxPool 2×2 | 64×64×3 | 32×32×6 | 54 |
| L1 | Conv 3×3, S1, P1 + ReLU | 32×32×6 | 32×32×4 | 108 |
| L2 | FC + ReLU | 4096 | 32 | 45,056 |
| L3 | FC (회귀 출력) | 32 | 1 | 32 |

- 수치 포맷: activation·weight **signed INT8**, 누산기·bias **signed INT32**
- 재양자화: `q = sat_int8( round( (acc + bias) × M / 2^S ) )`, 레이어별 `M`, `S = 30`
- 입력 전처리: RGB 각 채널에 `0x80` XOR (uint8 − 128)
- 최종 출력: signed INT8 조향각, **1 LSB = 1°**
- 메모리: weight 45,250 word + param 43 record를 하나의 BRAM에 연속 배치

### 아키텍처

<img width="7584" height="7508" alt="image" src="https://github.com/user-attachments/assets/02bc4ffd-dced-4eca-bc08-0bd9a584d4a0" />

| 모듈 | 역할 |
|---|---|
| `top_cnn` | 가속기 최상위. 제어부와 3개 데이터 경로, PE 코어 연결 |
| `cnn_cntl` | 레이어 시퀀서. 4개 레이어의 shape·주소·재양자화 파라미터를 순서대로 적용 |
| `pe_cntl` | 타일 실행 제어. weight chunk 적재, feed, MAC valid/last 타이밍 생성 |
| `act_path` | 이미지 적재, `input_buf`, Conv용 patch 생성기와 FC용 생성기, feeder |
| `wgt_path` | weight chunk 적재, `wgt_buf`, patch 생성기, feeder |
| `pe_core` | activation/weight skew 레지스터와 3×3 PE array (INT8×INT8 → INT32 누산) |
| `out_path` | 출력 FIFO, bias 가산·재양자화·ReLU, 2×2 MaxPool, 결과 기록 |
| `AXI4_Lite_interconnect` | AXI4-Lite 슬레이브 CSR |

**설계 포인트**

- **24-bit 3-lane 버스** — 한 word에 INT8 3개를 실어 PE array의 3개 행/열에 동시에 공급한다. 유효 lane은 keep 마스크로 표시한다.
- **타일 단위 실행** — 한 번에 출력 위치 3개 × 출력 채널 3개(oc_group)를 계산한다. Conv0은 위치 타일 1,366개, Conv1은 342개다.
- **Ping-pong activation 버퍼** — `input_buf`(24 bit × 16,384 word) 하나를 A/B 두 영역으로 나누고, 레이어마다 읽는 영역과 쓰는 영역을 맞바꾼다.
- **이중 weight 버퍼** — `wgt_buf`(256 word × 2)의 한쪽을 PE에 공급하는 동안 다른 쪽에 다음 chunk를 미리 적재한다. FC1(K = 4096)은 16 chunk로 나누어 처리한다.
- **자율 레이어 실행** — start 한 번으로 4개 레이어를 끝까지 실행하고, 최종 FC가 끝났을 때만 done / IRQ를 올린다.
- **범용 파라미터화** — 레이어 shape, weight·param 주소, 재양자화 계수가 모두 parameter라서 다른 모델로 교체할 수 있다.

### 제어 FSM

`cnn_cntl`은 레이어 단위 순서(파라미터 적재 → weight chunk 적재 → 타일 설정 → PE 실행 → 다음 타일/레이어)를, `pe_cntl`은 타일 하나 안에서의 feed · chunk 교체 · drain 타이밍을 담당한다.

### 레지스터 맵 (AXI4-Lite)

| Offset | 이름 | 비트 | 설명 |
|---|---|---|---|
| `0x00` | CONTROL | `[0]` start | 1을 쓰면 추론 1회 요청 (write-triggered) |
| | | `[1]` irq_clear | 1을 쓰면 done / IRQ 해제 |
| | | `[2]` irq_en | IRQ 출력 enable |
| `0x04` | STATUS (RO) | `[0]` busy | 추론 중 |
| | | `[1]` start_ready | 새 start 수락 가능 |
| | | `[2]` done | 추론 완료, 결과 유효 |
| | | `[3]` start_pending | start 요청 대기 중 |
| `0x08` | RESULT (RO) | `[7:0]` | 조향각, signed INT8 |

```c
// 추론 1회
Xil_Out32(CNN_BASE + 0x00, 0x1);                       // start
while (!(Xil_In32(CNN_BASE + 0x04) & 0x4)) { }         // done 대기
int8_t angle = (int8_t)(Xil_In32(CNN_BASE + 0x08) & 0xFF);
Xil_Out32(CNN_BASE + 0x00, 0x2);                       // done / irq clear
```

---

## 영상 파이프라인 및 주변 IP

| IP | 인터페이스 | 설명 |
|---|---|---|
| `IP_VDMA` | AXI4-Lite, AXI4-Stream, AXI Master ×2 | S2MM(카메라 → DDR)과 MM2S(DDR/BRAM → 영상)를 하나로 묶은 VDMA 방식 DMA. 프레임 버퍼 최대 3개를 순환 기록하고, MM2S는 방금 기록이 끝난 버퍼를 읽는다. 로딩 화면용 고정 주소 모드 지원 |
| `IP_CAPTURE` | AXI4-Lite, AXI HP Master | DDR 프레임에서 256×256 ROI를 읽어 4×4 평균으로 64×64 RGB888 생성, CNN 입력 RAM에 저장 |
| `IP_BBOX` | AXI4-Lite, AXI4-Stream | 영상 스트림에 256×256 박스를 덧그려 캡처 영역을 HDMI에 표시. 위치·색상 설정 가능 |
| `TOP_Block/Image.v` | BRAM 포트 | weight / param / 로딩 이미지를 담은 BRAM의 프런트엔드. 100 MHz 타이밍을 위해 2단 파이프라인 적용 |
| `IP_AXI_APB` | AXI4-Lite → APB | APB 주변장치용 브리지 |
| `IP_GPIO`, `IP_TIMER`, `IP_UART` | APB | 범용 주변장치 |
| `P-CAM_HDMI_IP` | — | MIPI D-PHY RX, CSI-2 RX, Bayer→RGB, Gamma, rgb2dvi와 OV5640·HDMI PS 드라이버 |

**CNN 입력 캡처** — 1280×720 프레임에서 256×256 ROI를 잘라 4×4 픽셀마다 RGB를 각각 합산한 뒤 16으로 나누어(>> 4) 64×64 이미지를 만든다. DDR은 AXI HP 포트의 64-bit beat로 읽고, 내부 바이트 버퍼에서 24-bit 픽셀 단위로 다시 정렬한다.

**DMA 데이터 폭 정렬** — 24-bit 픽셀 스트림과 32-bit DMA, 64-bit PS HP 포트 사이의 폭 차이를 packetizer / depacketizer와 AXI Interconnect 폭 변환으로 맞춘다.

**소프트웨어 스택** — PS 애플리케이션은 HW IP 위에 Interface · HAL · Driver · Application 계층으로 나뉜다.

---

## 미니카 제어

FSR 페달 2개와 조향 입력이 4개 노드를 거쳐 차량을 구동한다. 상세 사양은 [`minicar_control/README.md`](minicar_control/README.md)에 있다.

<img width="1188" height="556" alt="image" src="https://github.com/user-attachments/assets/86320d04-3d18-4be8-a6c8-d994036e5bbb" />

- **패킷** — 8 byte `SensorPacket`(페달 원시값 상행)과 `CommandPacket`(주행 명령 하행), CRC-8 보호
  <img width="1140" height="318" alt="image" src="https://github.com/user-attachments/assets/20b0055c-4086-4418-89c6-1f350c132eb2" />
- **판단 지점 일원화** — 페달 레벨 변환과 안전 판정은 Zybo 한 곳에서만 수행
- **조향 소스 전환** — `vehicle.h`의 `STEERING_SOURCE_CNN` 스위치로 PC 키보드와 CNN `RESULT` 레지스터 전환
- **안전 동작** — 센서 200 ms, PC 500 ms, 명령 300 ms 타임아웃 시 E-Stop 또는 failsafe 정지. CNN 결과는 200 ms가 지나면 무효 처리
- **차량** — L298N + TT 모터 ×4, ACEBOTT QD001 V2 두 가지 지원

---

## PC UI

`UI/python`은 PySide6 + QML로 만든 주행 HUD다. 조향각 게이지, 페달 압력, 야간 주행 3D 장면, 카메라 영상을 표시한다.

| 경로 | 형식 | 용도 |
|---|---|---|
| UDP 7000 | JSON | 텔레메트리 (`pressure`, `angle`, `cnn_valid`) |
| UDP 7001 | HUDV v1 (RGB565 / RGB888) | Zybo 카메라 영상 (256×256 CNN 뷰) |
| USB HDMI 캡처 | — | Zybo HDMI 출력 직접 수신 (기본 모드) |
| UART | 텍스트 | 차량 제어 및 FSR 값 |

`UI/zybo`는 보드 측 송신부로, DDR 프레임에서 CNN 뷰를 잘라 UDP로 보낸다. 네트워크 기본값은 PC `192.168.10.1`, Zybo `192.168.10.2`다.

---

## 빌드 및 실행

### 1. 하드웨어 (Vivado 2022.2)

1. `Settings → IP → Repository`에 `Zybo_IP/`를 추가한다.
2. 블록 디자인에 Pcam 5C 입력, DMA, CAPTURE, BBOX, CNN IP와 APB 주변장치를 배치한다.
3. weight / param `.mem`(`Zybo_IP/IP_CNN/src/wgt.mem`, `prm.mem`)을 BRAM 초기값으로 지정한다.
4. 합성·구현 후 bitstream을 포함해 `.xsa`를 export한다.

### 2. 소프트웨어 (Vitis 2022.2)

1. `.xsa`로 standalone 플랫폼(`ps7_cortexa9_0`)을 만든다.
2. `UI/zybo/src`, `minicar_control/zybo/src`, `Zybo_IP/P-CAM_HDMI_IP/src`의 소스를 애플리케이션에 추가한다.
3. BSP의 `stdout` / `stdin`을 `ps7_uart_1`로 설정한다. `ps7_uart_0`은 ESP32 허브와의 바이너리 패킷 전용이다.
4. CNN 조향을 쓰려면 `STEERING_SOURCE_CNN`을 `1`로 바꾼다.

### 3. ESP32 펌웨어

Arduino IDE에서 `minicar_control/firmware/`의 스케치를 각 보드에 업로드한다. 보드를 교체하면 스케치 안의 MAC 상수를 함께 고친다.

### 4. PC HUD

```bat
cd UI\python
setup.cmd
run_car_ui.cmd COM4 auto "USB Video"   :: 보드 연결
run_demo.cmd                           :: 보드 없이 UI만 확인
```

---

## 검증

### C golden model

`cnn_accelerator/C_Golden_code`

| 폴더 | 대상 |
|---|---|
| `act_path/`, `wgt_path/`, `pe_core/`, `cntl_unit/` | 블록 단위 golden model과 기대 trace |
| `c_mem_reference/` | RTL과 같은 `.mem` 입력으로 PC에서 전체 추론을 수행하는 참조 코드 |

```bash
cd cnn_accelerator/C_Golden_code/c_mem_reference
gcc -std=c11 -O2 -Wall -Wextra cnn_int8.c cnn_model_data.c cnn_mem_test.c -o cnn_mem_test
./cnn_mem_test model.mem ram_hex/capture_08685.mem     # angle_deg = 4
```

### UVM 검증 환경

`top_cnn`을 DUT로 하는 UVM 테스트벤치다. 세 인터페이스마다 agent를 두고, predictor가 만든 기대값을 scoreboard에서 DUT 결과와 비교한다.

| 구성 요소 | 역할 |
|---|---|
| `host_agent` (`cnn_ctrl_if`) | start / IRQ clear 등 호스트 제어 구동과 상태·결과 모니터링 |
| `img_agent` (`cnn_img_if`) | `image_memory`를 가진 responder. DUT의 이미지 RAM 읽기에 응답 |
| `wgt_agent` (`cnn_wgt_if`) | `ram_memory`(weight & bias)를 가진 responder. DUT의 weight / param 읽기에 응답 |
| `predictor` | 이미지와 weight 메모리로 기대 결과를 계산하는 참조 모델 |
| `scoreboard` / `layer_scb` | 최종 각도 비교 / `act_buf_probe`로 관측한 레이어별 중간 결과 비교 |
| `coverage`, `sva` | 기능 커버리지 수집과 프로토콜 assertion |

### RTL 시뮬레이션

`Zybo_IP/IP_CNN/src/tb_top_cnn_board.v`가 이미지 여러 장을 차례로 추론하고, 결과 각도를 기준 모델 값(`expected_angles.mem`)과 비교하며 done / busy / IRQ 동작을 함께 확인한다. `IP_VDMA`는 `tb_dma_top.sv`로 검증한다.

---

## 팀

4팀 **SoC닥SoC닥** — 대한상공회의소 경기도팹리스아카데미 온디바이스 AI 시스템반도체 설계 2기 과정 최종 프로젝트

| 이름 | 역할 |
|---|---|
| 공경환 | CNN PE core · 출력단 설계, 가속기 성능 분석 및 결과 비교 |
| 선우정욱 | System Top 통합, DMA IP, 시스템 Interface 설계 |
| 신민지 | DMA IP 설계 및 검증, 시스템 Interface 설계 |
| 이나경 | 팀장 · CNN Controller 설계, CNN Top 통합 및 UVM 검증 |
| 정광근 | CNN AXI Slave · 입력단 설계, 입력단-연산부 UVM 검증, UI 디자인 |
| 조강혁 | Vehicle System 설계, 자동차 3D 모델링 |
