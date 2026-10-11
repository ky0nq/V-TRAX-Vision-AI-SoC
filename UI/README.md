# V-TRAX PC UI

## 실행 방법

Python이 설치된 Windows PC에서 실행합니다.

### 1. 초기 설치

UI 폴더의 `setup.cmd`를 실행합니다.

가상환경과 필요한 패키지가 설치됩니다. 최초 실행 시에만 필요하며, 설치 중에는 인터넷 연결이 필요합니다.

### 2. 장치 연결

- Zybo USB-UART를 PC에 연결합니다.
- Zybo HDMI 출력을 캡처보드에 연결하고, 캡처보드를 PC에 연결합니다.
- ESP32-CAM 영상 사용 시 PC Wi-Fi를 `CAR_CAMERA`에 연결합니다.

### 3. COM 포트 확인

1. Windows 시작 버튼을 우클릭하여 **장치 관리자**를 엽니다.
2. **포트(COM 및 LPT)** 항목을 펼칩니다.
3. Zybo USB-UART 장치에 표시된 COM 번호를 확인합니다.
   - 구분이 어려우면 USB 케이블을 뺐다가 연결하여 나타나는 항목을 확인합니다.

기본 포트는 `COM4`입니다. COM4를 사용하는 Vitis 터미널 등 다른 프로그램은 닫아주세요.

### 4. UI 실행

포트가 `COM4`이면 `run_ui.cmd`를 실행합니다.

다른 포트이면 UI 폴더에서 CMD를 열고 아래처럼 실행합니다.

```bat
run_ui.cmd --serial-port COM5
```

`COM5`는 장치 관리자에서 확인한 포트 번호로 바꿉니다.

함께 열리는 CMD에서 보드 명령을 입력하고 Enter를 누릅니다. UI 사용 중에는 CMD 창을 닫지 마세요.