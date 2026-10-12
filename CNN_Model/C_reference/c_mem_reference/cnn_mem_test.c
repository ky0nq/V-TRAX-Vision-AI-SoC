/*
 * Run the INT8 C reference model with one RTL image .mem file.
 *
 * MEM format from dataset_4_rtl_64x64:
 *   4096 lines, one 24-bit RGB word per line: RRGGBB
 *   address = y * 64 + x
 *
 * RTL input loader converts each RGB byte with XOR 0x80, producing
 * signed INT8 (equivalent to unsigned byte minus 128).
 */

#include "cnn_int8.h"
#include "cnn_model_data.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define IMAGE_PIXELS 4096U
#define IMAGE_BYTES  (IMAGE_PIXELS * 3U)

/* Load RRGGBB .mem and reproduce act_path's XOR 24'h808080. */
static int load_rgb_mem_quantized(const char *path,
                                  int8_t input_hwc[IMAGE_BYTES])
{
    FILE *fp;
    unsigned int word;
    unsigned int i;

    fp = fopen(path, "r");
    if (fp == NULL) {
        fprintf(stderr, "cannot open %s: %s\n", path, strerror(errno));
        return -1;
    }

    for (i = 0; i < IMAGE_PIXELS; ++i) {
        unsigned int r, g, b;

        if (fscanf(fp, "%x", &word) != 1 || word > 0xFFFFFFU) {
            fprintf(stderr, "invalid RGB word at line %u in %s\n",
                    i + 1U, path);
            fclose(fp);
            return -1;
        }

        r = (word >> 16) & 0xFFU;
        g = (word >> 8)  & 0xFFU;
        b = word & 0xFFU;

        input_hwc[3U * i + 0U] = (int8_t)((int)r - 128);
        input_hwc[3U * i + 1U] = (int8_t)((int)g - 128);
        input_hwc[3U * i + 2U] = (int8_t)((int)b - 128);
    }

    fclose(fp);
    return 0;
}

static void print_result(const char *path, const CNNResult *result)
{
    printf("%s\n", path);
    printf("  fc2_mac_before_bias = %d\n", result->fc2_mac_before_bias);
    printf("  fc2_after_bias      = %d\n", result->fc2_after_bias);
    printf("  angle_deg           = %d\n", result->angle_deg);
}

int main(int argc, char **argv)
{
    int8_t input_hwc[IMAGE_BYTES];
    CNNResult result;
    int i;

    if (argc < 3) {
        fprintf(stderr,
                "usage: %s <model.mem> <image.mem> [image2.mem ...]\n",
                argv[0]);
        return 2;
    }

    if (cnn_load_model_mem(argv[1]) != 0) return 1;

    if (cnn_prepare_weights() != 0) {
        fprintf(stderr, "cnn_prepare_weights() failed\n");
        return 1;
    }

    for (i = 2; i < argc; ++i) {
        if (load_rgb_mem_quantized(argv[i], input_hwc) != 0)
            return 1;

        if (cnn_infer_int8(input_hwc, &result) != 0) {
            fprintf(stderr, "cnn_infer_int8() failed for %s\n", argv[i]);
            return 1;
        }

        print_result(argv[i], &result);
    }

    return 0;
}
