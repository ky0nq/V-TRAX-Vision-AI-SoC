#include "cnn_model_data.h"
#include <stdio.h>

uint32_t cnn_weight_words[CNN_WEIGHT_WORDS];
int32_t cnn_biases[CNN_BIAS_WORDS];
/* Quantization from the same export as Weight_Bias_Image.coe. */
const CNNQuantParam cnn_quant[CNN_LAYER_COUNT] = {
    {1574039, 30U}, {3254702, 30U}, {485488, 30U}, {1726771, 30U}
};

int cnn_load_model_mem(const char *path)
{
    FILE *fp = fopen(path, "r");
    unsigned i, word;
    if (!fp) { perror(path); return -1; }
    for (i = 0; i < CNN_WEIGHT_WORDS + CNN_BIAS_WORDS; ++i) {
        if (fscanf(fp, "%x", &word) != 1) {
            fprintf(stderr, "model.mem invalid at line %u\n", i + 1U);
            fclose(fp); return -1;
        }
        if (i < CNN_WEIGHT_WORDS) cnn_weight_words[i] = (uint32_t)word;
        else {
            uint32_t bits = (uint32_t)word;
            cnn_biases[i - CNN_WEIGHT_WORDS] =
                (bits <= INT32_MAX) ? (int32_t)bits :
                (int32_t)((int64_t)bits - INT64_C(4294967296));
        }
    }
    fclose(fp);
    return 0;
}
