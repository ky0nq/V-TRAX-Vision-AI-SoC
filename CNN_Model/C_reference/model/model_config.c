#include "model_config.h"

/* test */
const LayerConfig test_conv_config = {
    .input_h = 2,
    .input_w = 2,
    .input_c = 3,

    .output_h = 2,
    .output_w = 2,
    .output_c = 3,

    .kernel_h = 3,
    .kernel_w = 3,
    .stride = 1,
    .padding = 1,

    .relu_en = 0
};