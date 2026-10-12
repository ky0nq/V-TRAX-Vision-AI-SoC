#ifndef CNN_MODEL_DATA_H
#define CNN_MODEL_DATA_H
#include <stdint.h>
#define CNN_LAYER_COUNT 4U
#define CNN_WEIGHT_WORDS 45250U
#define CNN_BIAS_WORDS 43U
typedef struct { int32_t multiplier; unsigned shift; } CNNQuantParam;
extern uint32_t cnn_weight_words[CNN_WEIGHT_WORDS];
extern int32_t cnn_biases[CNN_BIAS_WORDS];
extern const CNNQuantParam cnn_quant[CNN_LAYER_COUNT];
int cnn_load_model_mem(const char *path);
#endif
