#ifndef CNN_INT8_H
#define CNN_INT8_H
#include <stdint.h>
#define CNN_INPUT_BYTES (64 * 64 * 3)
typedef struct { int32_t fc2_mac_before_bias; int32_t fc2_after_bias; int8_t angle_deg; } CNNResult;
typedef struct { uint32_t conv0_fnv1a, pool0_fnv1a, conv1_fnv1a, fc1_fnv1a; } CNNTrace;
int cnn_prepare_weights(void);
int cnn_infer_int8(const int8_t input_hwc[CNN_INPUT_BYTES], CNNResult *result);
void cnn_unpack_image(const uint32_t image_words[4096], int8_t input_hwc[CNN_INPUT_BYTES]);
void cnn_get_trace(CNNTrace *trace);
#endif
