/*
 * Model C CPU inference - matching cnn_accelerator_ver7 RTL MATH.
 *
 * Conv0   : 64x64x3 -> 64x64x6, K=3x3, stride=1, pad=1, ReLU
 * MaxPool : 64x64x6 -> 32x32x6, K=2x2, stride=2
 * Conv1   : 32x32x6 -> 32x32x4, K=3x3, stride=1, pad=1, ReLU
 * FC1     : 4096 -> 32, ReLU (input flattened in pixel-major HWC)
 * FC2     : 32 -> 1, NO ReLU, signed INT8 degrees
 *
 * Accumulator: signed INT32. In this fixed model K<=4096 and operands are
 * INT8, so the bias-free MAC sum is bounded by 4096*128*128=67,108,864
 * and cannot overflow INT32. For the bias addition, RTL saturates to INT32.
 * Requantization: signed INT64 product, round-nearest/ties-away-from-zero,
 * right shift S, hidden ReLU, signed INT8 saturation.
 */

#include "cnn_int8.h"
#include "cnn_model_data.h"

#include <stddef.h>
#include <stdint.h>

#define CONV0_OC  6
#define CONV0_K  27
#define CONV1_OC  4
#define CONV1_K  54
#define FC1_OC   32
#define FC1_K 4096
#define FC2_OC    1
#define FC2_K   32

/* Constant unpacked CPU weights. Prepared ONCE, not timed. */
static int8_t w_conv0[CONV0_OC * CONV0_K];
static int8_t w_conv1[CONV1_OC * CONV1_K];
static int8_t w_fc1[FC1_OC * FC1_K];
static int8_t w_fc2[FC2_OC * FC2_K];

/* Static scratch space: avoiding large stack frames on bare-metal A9. */
static int8_t conv0_buf[64 * 64 * CONV0_OC];
static int8_t pool0_buf[32 * 32 * CONV0_OC];
static int8_t conv1_buf[32 * 32 * CONV1_OC];
static int8_t fc1_buf[FC1_OC];
static int weights_ready = 0;

static int8_t signed_lane(uint32_t word, unsigned lane)
{
    uint32_t u = (word >> (8U * lane)) & UINT32_C(0xFF);
    /* C conversion is safe because the signed value is now in [-128,127]. */
    return (int8_t)((u < 128U) ? (int32_t)u : (int32_t)u - 256);
}

static int32_t saturate_i32(int64_t value)
{
    if (value > INT32_MAX) return INT32_MAX;
    if (value < INT32_MIN) return INT32_MIN;
    return (int32_t)value;
}

/* RTL post_process: clamp ACC+bias to int32, int64 multiply, ties-away
 * rounding, arithmetic right shift, optional ReLU, signed INT8 saturation.
 * This avoids C implementation-defined right shift of negative values.
 */
static int8_t requant(int32_t acc, int32_t bias,
                      CNNQuantParam param, int relu,
                      int32_t *after_bias)
{
    int32_t a32 = saturate_i32((int64_t)acc + (int64_t)bias);
    int64_t p = (int64_t)a32 * (int64_t)param.multiplier;
    int64_t q;

    if (after_bias != NULL) *after_bias = a32;

    if (param.shift == 0U) {
        q = p;
    } else {
        int64_t half = INT64_C(1) << (param.shift - 1U);
        /* P fits within (-2^62,2^62), so negating P is safe. */
        if (p >= 0) q = (p + half) >> param.shift;
        else        q = -(((-p) + half) >> param.shift);
    }

    if (relu && q < 0) return (int8_t)0;
    if (q > 127) return (int8_t)127;
    if (q < -128) return (int8_t)-128;
    return (int8_t)q;
}

static int unpack_layer(int8_t *out, unsigned weight_base,
                        unsigned K, unsigned out_channels)
{
    unsigned oc, k;
    for (oc = 0; oc < out_channels; ++oc) {
        unsigned group = oc / 3U;
        unsigned lane = oc % 3U;
        for (k = 0; k < K; ++k) {
            uint32_t packed = cnn_weight_words[weight_base + group * K + k];
            if (packed & UINT32_C(0xFF000000)) return -1;
            out[oc * K + k] = signed_lane(packed, lane);
        }
    }
    return 0;
}

int cnn_prepare_weights(void)
{
    unsigned layer;
    for (layer = 0; layer < CNN_LAYER_COUNT; ++layer) {
        if (cnn_quant[layer].multiplier <= 0 || cnn_quant[layer].shift > 30U) {
            weights_ready = 0;
            return -1;
        }
    }
    if (unpack_layer(w_conv0, 0U, CONV0_K, CONV0_OC) ||
        unpack_layer(w_conv1, 54U, CONV1_K, CONV1_OC) ||
        unpack_layer(w_fc1, 162U, FC1_K, FC1_OC) ||
        unpack_layer(w_fc2, 45218U, FC2_K, FC2_OC)) {
        weights_ready = 0;
        return -1;
    }
    weights_ready = 1;
    return 0;
}

void cnn_unpack_image(const uint32_t image_words[4096],
                      int8_t input_hwc[CNN_INPUT_BYTES])
{
    unsigned pos;
    for (pos = 0; pos < 4096U; ++pos) {
        uint32_t word = image_words[pos];
        input_hwc[3U * pos + 0U] = signed_lane(word, 0U);
        input_hwc[3U * pos + 1U] = signed_lane(word, 1U);
        input_hwc[3U * pos + 2U] = signed_lane(word, 2U);
    }
}

/* Convolution cross-correlation, no kernel flip.
 * [OC][KY][KX][IC] weight order (IC fastest) as RTL k sequence.
 * Output is pixel-major [Y][X][OC], same as accelerator feature memory.
 */
static void conv3x3_same(const int8_t *input,
                         unsigned width, unsigned in_channels,
                         unsigned out_channels, const int8_t *weights,
                         const int32_t *bias, CNNQuantParam param,
                         int8_t *output)
{
    unsigned oy, ox, oc, ky, kx, ic;
    unsigned K = 9U * in_channels;

    for (oy = 0; oy < width; ++oy) {
        for (ox = 0; ox < width; ++ox) {
            for (oc = 0; oc < out_channels; ++oc) {
                const int8_t *w = weights + oc * K;
                int32_t acc = 0;

                for (ky = 0; ky < 3U; ++ky) {
                    int iy = (int)oy + (int)ky - 1;
                    if (iy < 0 || iy >= (int)width) continue;
                    for (kx = 0; kx < 3U; ++kx) {
                        int ix = (int)ox + (int)kx - 1;
                        unsigned kbase = (ky * 3U + kx) * in_channels;
                        if (ix < 0 || ix >= (int)width) continue;
                        {
                            const int8_t *pix = input +
                                ((unsigned)iy * width + (unsigned)ix) * in_channels;
                            for (ic = 0; ic < in_channels; ++ic) {
                                acc += (int32_t)pix[ic] * (int32_t)w[kbase + ic];
                            }
                        }
                    }
                }

                output[(oy * width + ox) * out_channels + oc] =
                    requant(acc, bias[oc], param, 1, NULL);
            }
        }
    }
}

static void pool2x2_stride2(const int8_t input[64 * 64 * CONV0_OC],
                            int8_t output[32 * 32 * CONV0_OC])
{
    unsigned oy, ox, c, ky, kx;
    for (oy = 0; oy < 32U; ++oy) {
        for (ox = 0; ox < 32U; ++ox) {
            for (c = 0; c < CONV0_OC; ++c) {
                int8_t mx = -128;
                for (ky = 0; ky < 2U; ++ky) {
                    for (kx = 0; kx < 2U; ++kx) {
                        unsigned pos = ((2U * oy + ky) * 64U + (2U * ox + kx));
                        int8_t v = input[pos * CONV0_OC + c];
                        if (v > mx) mx = v;
                    }
                }
                output[(oy * 32U + ox) * CONV0_OC + c] = mx;
            }
        }
    }
}

int cnn_infer_int8(const int8_t input_hwc[CNN_INPUT_BYTES],
                   CNNResult *result)
{
    unsigned oc, k;
    int32_t acc;
    if (!weights_ready || input_hwc == NULL || result == NULL) return -1;

    conv3x3_same(input_hwc, 64U, 3U, CONV0_OC,
                 w_conv0, cnn_biases + 0, cnn_quant[0], conv0_buf);

    pool2x2_stride2(conv0_buf, pool0_buf);

    conv3x3_same(pool0_buf, 32U, 6U, CONV1_OC,
                 w_conv1, cnn_biases + 6, cnn_quant[1], conv1_buf);

    /* FC1 input order is HWC (pixel-major), NOT PyTorch CHW. */
    for (oc = 0; oc < FC1_OC; ++oc) {
        const int8_t *w = w_fc1 + oc * FC1_K;
        acc = 0;
        for (k = 0; k < FC1_K; ++k) {
            acc += (int32_t)conv1_buf[k] * (int32_t)w[k];
        }
        fc1_buf[oc] = requant(acc, cnn_biases[10U + oc], cnn_quant[2], 1, NULL);
    }

    /* FC2: no ReLU. Output is signed INT8 degrees, 1 LSB = 1 degree. */
    acc = 0;
    for (k = 0; k < FC2_K; ++k) {
        acc += (int32_t)fc1_buf[k] * (int32_t)w_fc2[k];
    }
    result->fc2_mac_before_bias = acc;
    result->angle_deg = requant(acc, cnn_biases[42], cnn_quant[3], 0,
                                &result->fc2_after_bias);
    return 0;
}

/* FNV-1a hashes are debug aids, not part of inference or measured time. */
static uint32_t fnv1a(const int8_t *data, unsigned size)
{
    uint32_t h = UINT32_C(2166136261);
    unsigned i;
    for (i = 0; i < size; ++i) {
        h ^= (uint8_t)data[i];
        h *= UINT32_C(16777619);
    }
    return h;
}

void cnn_get_trace(CNNTrace *trace)
{
    if (trace == NULL) return;
    trace->conv0_fnv1a = fnv1a(conv0_buf, 64U * 64U * CONV0_OC);
    trace->pool0_fnv1a = fnv1a(pool0_buf, 32U * 32U * CONV0_OC);
    trace->conv1_fnv1a = fnv1a(conv1_buf, 32U * 32U * CONV1_OC);
    trace->fc1_fnv1a = fnv1a(fc1_buf, FC1_OC);
}
