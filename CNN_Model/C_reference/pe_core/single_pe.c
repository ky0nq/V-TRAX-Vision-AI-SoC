/*
Single PE C Reference Model

Purpose:
- Match the current RTL single_pe behavior cycle-by-cycle.
- One call to pe_step() represents one rising clock edge.
- RTL nonblocking assignment behavior is modeled using "old_*" state values.

Current RTL behavior:
1) Stage 1: when step_en=1, capture act/weight and product_q.
2) Stage 2: accumulate the product captured in the PREVIOUS cycle.
3) pq_valid / pq_last are pipeline tokens for product_q.
4) acc_clear has priority and discards a pending MAC token.
5) result_valid is a one-cycle pulse.
*/

#include <stdbool.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdio.h>


/* =========================================================
 * RTL Input Ports
 * ========================================================= */
typedef struct {
    bool rst_n;
    bool step_en;
    bool acc_clear;
    bool mac_valid;
    bool mac_last;

    int8_t act_in;
    int8_t weight_in;
} PEInput;


/* =========================================================
 * RTL Output Ports
 * ========================================================= */
typedef struct {
    int8_t act_out;
    int8_t weight_out;

    int32_t result_data;
    bool result_valid;
} PEOutput;


/* =========================================================
 * Internal Registers
 * ========================================================= */
typedef struct {
    int32_t acc_reg;

    /* 1-stage multiplication pipeline */
    int16_t product_q;
    bool pq_valid;
    bool pq_last;

    /* RTL output registers */
    int8_t act_out_reg;
    int8_t weight_out_reg;
    int32_t result_data_reg;
    bool result_valid_reg;
} PEState;


/* =========================================================
 * 32-bit two's-complement wrap
 *
 * Verilog signed [31:0] addition naturally wraps at 32 bits.
 * C signed overflow is undefined, so wrap it explicitly.
 * ========================================================= */
static int32_t wrap_i32(int64_t value)
{
    uint32_t bits;

    bits = (uint32_t)((uint64_t)value & UINT64_C(0xFFFFFFFF));

    if (bits & UINT32_C(0x80000000)) {
        return (int32_t)((int64_t)bits - INT64_C(0x100000000));
    }

    return (int32_t)bits;
}


/* =========================================================
 * PE Reset / Initial State
 * ========================================================= */
static void pe_init(PEState *pe)
{
    pe->acc_reg = 0;

    pe->product_q = 0;
    pe->pq_valid = false;
    pe->pq_last = false;

    pe->act_out_reg = 0;
    pe->weight_out_reg = 0;
    pe->result_data_reg = 0;
    pe->result_valid_reg = false;
}


/* =========================================================
 * Copy current registered outputs
 * ========================================================= */
static void pe_get_output(const PEState *pe, PEOutput *out)
{
    out->act_out = pe->act_out_reg;
    out->weight_out = pe->weight_out_reg;
    out->result_data = pe->result_data_reg;
    out->result_valid = pe->result_valid_reg;
}


/* =========================================================
 * One rising clock edge
 *
 * Important:
 * RTL uses nonblocking assignments (<=).
 * Therefore Stage 2 must use the OLD product_q / pq_valid /
 * pq_last values from before this clock edge.
 * ========================================================= */
static void pe_step(
    PEState *pe,
    const PEInput *in,
    PEOutput *out
)
{
    /* Save old register values before this clock edge */
    const int32_t old_acc_reg = pe->acc_reg;
    const int16_t old_product_q = pe->product_q;
    const bool old_pq_valid = pe->pq_valid;
    const bool old_pq_last = pe->pq_last;

    int32_t acc_next;

    /* -----------------------------------------------------
     * Asynchronous reset behavior
     * ----------------------------------------------------- */
    if (!in->rst_n) {
        pe_init(pe);
        pe_get_output(pe, out);
        return;
    }

    /* -----------------------------------------------------
     * acc_clear has priority over normal operation
     *
     * RTL clears:
     *   acc_reg
     *   result_data
     *   result_valid
     *   pq_valid
     *   pq_last
     *
     * RTL does NOT clear:
     *   act_out
     *   weight_out
     *   product_q
     * ----------------------------------------------------- */
    if (in->acc_clear) {
        pe->acc_reg = 0;
        pe->result_data_reg = 0;
        pe->result_valid_reg = false;

        pe->pq_valid = false;
        pe->pq_last = false;

        pe_get_output(pe, out);
        return;
    }

    /* result_valid is a one-cycle pulse */
    pe->result_valid_reg = false;

    /* =====================================================
     * Stage 1
     * Capture new input/product for the NEXT cycle.
     * ===================================================== */

    pe->pq_valid = in->step_en && in->mac_valid;
    pe->pq_last =
        in->step_en &&
        in->mac_valid &&
        in->mac_last;

    if (in->step_en) {
        pe->act_out_reg = in->act_in;
        pe->weight_out_reg = in->weight_in;

        pe->product_q =
            (int16_t)in->act_in *
            (int16_t)in->weight_in;
    }

    /* =====================================================
     * Stage 2
     * Accumulate the product captured in the PREVIOUS cycle.
     *
     * old_pq_valid is used intentionally.
     * This matches Verilog nonblocking assignment behavior.
     * ===================================================== */
    if (old_pq_valid) {
        acc_next = wrap_i32(
            (int64_t)old_acc_reg +
            (int64_t)old_product_q
        );

        pe->acc_reg = acc_next;

        if (old_pq_last) {
            pe->result_data_reg = acc_next;
            pe->result_valid_reg = true;
        }
    }

    pe_get_output(pe, out);
}


/* =========================================================
 * Simple test
 *
 * activation = { 2, -1, 3 }
 * weight     = { 4,  5,-2 }
 *
 * result = 2*4 + (-1)*5 + 3*(-2)
 *        = 8 - 5 - 6
 *        = -3
 * ========================================================= */
int main(void)
{
    const int8_t activation[] = {2, -1, 3};
    const int8_t weight[]     = {4, 5, -2};

    const size_t k_len =
        sizeof(activation) / sizeof(activation[0]);

    PEState pe;
    PEInput in = {0};
    PEOutput out = {0};

    size_t cycle = 0;

    /* 1. Initial state */
    pe_init(&pe);

    /* 2. Reset cycle */
    in.rst_n = false;

    pe_step(&pe, &in, &out);
    cycle++;

    printf(
        "Cycle %zu RESET   : acc=%" PRId32
        ", result=%" PRId32
        ", valid=%d\n",
        cycle,
        pe.acc_reg,
        out.result_data,
        (int)out.result_valid
    );

    /* 3. Release reset and clear accumulator */
    in.rst_n = true;
    in.acc_clear = true;

    pe_step(&pe, &in, &out);
    cycle++;

    printf(
        "Cycle %zu CLEAR   : acc=%" PRId32
        ", result=%" PRId32
        ", valid=%d\n",
        cycle,
        pe.acc_reg,
        out.result_data,
        (int)out.result_valid
    );

    /* 4. Send K MAC inputs */
    for (size_t k = 0; k < k_len; ++k) {
        in.acc_clear = false;
        in.step_en = true;
        in.mac_valid = true;
        in.mac_last = (k == k_len - 1);

        in.act_in = activation[k];
        in.weight_in = weight[k];

        pe_step(&pe, &in, &out);
        cycle++;

        printf(
            "Cycle %zu MAC %zu   : "
            "act=%d, weight=%d, "
            "acc=%" PRId32 ", "
            "product_q=%d, pq_valid=%d, pq_last=%d, "
            "result=%" PRId32 ", result_valid=%d\n",
            cycle,
            k + 1,
            (int)in.act_in,
            (int)in.weight_in,
            pe.acc_reg,
            (int)pe.product_q,
            (int)pe.pq_valid,
            (int)pe.pq_last,
            out.result_data,
            (int)out.result_valid
        );
    }

    /*
     * 5. Flush one cycle
     *
     * The last MAC product was captured into product_q in the
     * previous cycle. This cycle accumulates that product and
     * generates result_valid.
     */
    in.step_en = false;
    in.mac_valid = false;
    in.mac_last = false;

    pe_step(&pe, &in, &out);
    cycle++;

    printf(
        "Cycle %zu FLUSH   : "
        "acc=%" PRId32 ", "
        "result=%" PRId32 ", result_valid=%d\n",
        cycle,
        pe.acc_reg,
        out.result_data,
        (int)out.result_valid
    );

    /* 6. Compare with expected result */
    const int32_t expected = -3;

    printf(
        "\nExpected result = %" PRId32
        "\nPE result       = %" PRId32 "\n",
        expected,
        out.result_data
    );

    if (out.result_valid &&
        out.result_data == expected) {
        printf("PASS\n");
        return 0;
    }

    printf("FAIL\n");
    return 1;
}
