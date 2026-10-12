#include <Arduino.h>
#include "esp_camera.h"
#include <WiFi.h>
#include <ESPmDNS.h>
#include "board_config.h"

// ===========================
// Enter your WiFi credentials
// ===========================
// const char *ssid = "SoCSoC";
// const char *password = "12345678";

// OV2640 manual brightness preset. Raise exposure first if the picture is too
// dark; lower it if highlights clip. Gain adds noise, so adjust it second.
constexpr int CAMERA_EXPOSURE = 300;  // OV2640: 0..1200
constexpr int CAMERA_GAIN = 8;        // OV2640: 0..30

void startCameraServer();
void setupLedFlash();

void setup() {
  Serial.begin(115200);
  Serial.printf("PSRAM found: %s\n", psramFound() ? "YES" : "NO");
  Serial.printf("Free heap: %u\n", ESP.getFreeHeap());
  Serial.printf("Free PSRAM: %u\n", ESP.getFreePsram());
  Serial.setDebugOutput(true);
  Serial.println();

  camera_config_t config = {};
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;

  // config.frame_size   = FRAMESIZE_QVGA;       // 320x240
  // config.jpeg_quality = 16;
  // config.fb_count     = 2;
  // config.fb_location  = CAMERA_FB_IN_DRAM;
  // config.grab_mode    = CAMERA_GRAB_LATEST;

  config.frame_size   = FRAMESIZE_QQVGA;       // 160x120
  config.jpeg_quality = 16;
  config.fb_count     = 2;
  config.fb_location  = CAMERA_FB_IN_DRAM;
  config.grab_mode    = CAMERA_GRAB_LATEST;

  // config.frame_size   = FRAMESIZE_VGA;       // 640×480
  // config.jpeg_quality = 12;
  // config.fb_count     = 1;
  // config.fb_location  = CAMERA_FB_IN_DRAM;
  // config.grab_mode    = CAMERA_GRAB_WHEN_EMPTY;

  // config.frame_size   = FRAMESIZE_SVGA;   // 800x600
  // config.jpeg_quality = 15;
  // config.fb_count     = 1;
  // config.fb_location  = CAMERA_FB_IN_DRAM;
  // config.grab_mode    = CAMERA_GRAB_WHEN_EMPTY;
  

#if defined(CAMERA_MODEL_ESP_EYE)
  pinMode(13, INPUT_PULLUP);
  pinMode(14, INPUT_PULLUP);
#endif

  // camera init
  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("Camera init failed with error 0x%x", err);
    return;
  }

  Serial.println("Camera init OK");

  delay(1000);

  camera_fb_t *fb = esp_camera_fb_get();

  if (!fb) {
      Serial.println("FRAME GET FAILED");
  } else {
      Serial.println("FRAME GET OK");

      Serial.printf("Width  : %d\n", fb->width);
      Serial.printf("Height : %d\n", fb->height);
      Serial.printf("Length : %u\n", fb->len);
      Serial.printf("Format : %d\n", fb->format);

      if (fb->len >= 2) {
          Serial.printf(
              "JPEG start : %02X %02X\n",
              fb->buf[0],
              fb->buf[1]
          );
      }

      esp_camera_fb_return(fb);
  }

  // Diagnostic: camera capture speed before Wi-Fi/HTTP starts.
  Serial.printf("CPU frequency: %u MHz\n", getCpuFrequencyMhz());
  const uint32_t capture_start = millis();
  int capture_ok = 0;
  for (int i = 0; i < 30; ++i) {
    camera_fb_t *sample = esp_camera_fb_get();
    if (sample) {
      ++capture_ok;
      esp_camera_fb_return(sample);
    }
  }
  const uint32_t capture_ms = millis() - capture_start;
  Serial.printf("CAPTURE_ONLY: %d frames / %lu ms = %.1f fps\n",
                capture_ok, (unsigned long)capture_ms,
                capture_ms ? 1000.0f * capture_ok / capture_ms : 0.0f);

  sensor_t *s = esp_camera_sensor_get();

  // initial sensors are flipped vertically and colors are a bit saturated
  if (s->id.PID == OV3660_PID) {
    s->set_vflip(s, 1);        // flip it back
    s->set_brightness(s, 1);   // up the brightness just a bit
    s->set_saturation(s, -2);  // lower the saturation
  }
  // drop down frame size for higher initial frame rate
  if (config.pixel_format == PIXFORMAT_JPEG) {
    s->set_colorbar(s, 0);
    s->set_framesize(s, FRAMESIZE_QQVGA);
  }

  if (s->id.PID == OV2640_PID) {
    // Lock exposure and analog gain so a bright monitor or dark object does
    // not make the rest of the picture pulse in brightness while driving.
    const int aec2_result = s->set_aec2(s, 0);
    const int exposure_result = s->set_exposure_ctrl(s, 0);
    const int gain_result = s->set_gain_ctrl(s, 0);
    const int manual_exposure_result = s->set_aec_value(s, CAMERA_EXPOSURE);
    const int manual_gain_result = s->set_agc_gain(s, CAMERA_GAIN);
    Serial.printf("FIXED_EXPOSURE pid=0x%04x aec2=%d aec=%d agc=%d exposure=%d gain=%d values=%d,%d\n",
                  s->id.PID, aec2_result, exposure_result, gain_result,
                  manual_exposure_result, manual_gain_result,
                  CAMERA_EXPOSURE, CAMERA_GAIN);
  } else {
    Serial.printf("FIXED_EXPOSURE skipped for sensor pid=0x%04x (OV2640 preset only)\n", s->id.PID);
  }

#if defined(CAMERA_MODEL_M5STACK_WIDE) || defined(CAMERA_MODEL_M5STACK_ESP32CAM)
  s->set_vflip(s, 1);
  s->set_hmirror(s, 1);
#endif

#if defined(CAMERA_MODEL_ESP32S3_EYE)
  s->set_vflip(s, 1);
#endif

// Setup LED FLash if LED pin is defined in camera_pins.h
#if defined(LED_GPIO_NUM)
  setupLedFlash();
#endif

  WiFi.mode(WIFI_AP);

  IPAddress ip(192, 168, 4, 1);
  IPAddress gateway(192, 168, 4, 1);
  IPAddress subnet(255, 255, 255, 0);

  if (!WiFi.softAPConfig(ip, gateway, subnet)) {
    Serial.println("AP IP configuration failed");
    return;
  }

  if (!WiFi.softAP("CAR_CAMERA", "12345678", 6, 0, 1)) {
    Serial.println("AP start failed");
    return;
  }

  startCameraServer();

  if (MDNS.begin("vision-drive-cam")) {
    MDNS.addService("visioncam", "tcp", 81);
  }

  Serial.println("Connect PC Wi-Fi to: CAR_CAMERA");
  Serial.print("Camera address: http://");
  Serial.println(WiFi.softAPIP());
  Serial.println("Stream: http://192.168.4.1:81/stream");

  // ================================================
  // STA mode
  // ================================================

  // WiFi.begin(ssid, password);
  // WiFi.setSleep(false);

  // Serial.print("WiFi connecting");
  // while (WiFi.status() != WL_CONNECTED) {
  //   delay(500);
  //   Serial.print(".");
  // }
  // Serial.println("");
  // Serial.println("WiFi connected");

  // startCameraServer();

  // if (MDNS.begin("vision-drive-cam")) {
  //   MDNS.addService("visioncam", "tcp", 81);
  //   Serial.println("ESP32-CAM discovery ready");
  // } else {
  //   Serial.println("ESP32-CAM discovery failed; use the printed IP manually");
  // }

  // Serial.print("Camera Ready! Use 'http://");
  // Serial.print(WiFi.localIP());
  // Serial.println("' to connect");
}

void loop() {
  // Do nothing. Everything is done in another task by the web server
  delay(10000);
}
