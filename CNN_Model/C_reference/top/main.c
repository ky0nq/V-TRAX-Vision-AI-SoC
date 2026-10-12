#include <stdio.h>
#include <stdlib.h>
#include <inttypes.h>

#include "cnn_types.h"
#include "cnn_layer.h"
#include "patch_gen.h"
#include "pe_array.h"
#include "model_config.h"
#include "post_process.h"

int main(void)
{
    enum {
        K = 27,             // 3x3 kernel x RGB 3 channels
        OUTPUT_CHANNELS = 3 // Number of output channels to test
    };

    // 1. Test image: 2x2 RGB image in HWC order
    const act_t input[12] = {
        1, 2, 3,   4, 5, 6,
        7, 8, 9,  10, 11, 12
    };

    // Test configuration
    const LayerConfig layer = test_conv_config;

    // Patch expected at output coordinate (0, 0)
    // This test assumes zero-point = 0
    const act_t expected_patch[K] = {
        0, 0, 0,  0, 0, 0,   0, 0, 0,
        0, 0, 0,  1, 2, 3,   4, 5, 6,
        0, 0, 0,  7, 8, 9,  10, 11, 12
    };

    // Weight constants for each output channel
    const weight_t channel_weight[OUTPUT_CHANNELS] = {
        1, 2, -1
    };

    // Correct MAC result before post-processing
    const accum_t expected_result[OUTPUT_CHANNELS] = {
        78, 156, -78
    };

    const output_t expected_post[OUTPUT_CHANNELS] = {
    78, 127, -78
    };

    act_t patch[K];
    weight_t weight[K];

    // 2. Call the function in patch_gen.c
    patch_generate(input, patch, &layer, 0, 0);

    // 3. Check patch values and element ordering
    for (int k = 0; k < K; k++) {
        if (patch[k] != expected_patch[k]) {
            printf(
                "PATCH FAIL: k=%d, actual=%d, expected=%d\n",
                k,
                (int)patch[k],
                (int)expected_patch[k]
            );

            return EXIT_FAILURE;
        }
    }

    printf("PATCH PASS\n");

    // 4. Prepare weights per output channel and run MAC
    for (int oc = 0; oc < OUTPUT_CHANNELS; oc++) {

        for (int k = 0; k < K; k++) {
            weight[k] = channel_weight[oc];
        }

        accum_t result = 0;

        // Call the function in pe_array.c
        pe_mac(patch, weight, K, &result);

        printf(
            "channel %d: result=%" PRId32
            ", expected=%" PRId32 "\n",
            oc,
            result,
            expected_result[oc]
        );

        // 5. Compare against expected results
        if (result != expected_result[oc]) {
            printf("MAC FAIL\n");
            return EXIT_FAILURE;
        }

        // Test condition: Bias = 0, ReLU OFF
        output_t post_result = post_process(result, 0, 0);

        printf(
            "post channel %d: result=%d, expected=%d\n",
            oc,
            (int)post_result,
            (int)expected_post[oc]
        );

        if (post_result != expected_post[oc]) {
            printf("POST FAIL\n");
            return EXIT_FAILURE;
        }
    }

    printf("ALL PASS\n");
    return EXIT_SUCCESS;
}