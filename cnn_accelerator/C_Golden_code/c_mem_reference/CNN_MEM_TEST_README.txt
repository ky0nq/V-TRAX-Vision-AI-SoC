PC-Based Image MEM Inference Verification Using C (No FPGA/Vitis Required) 
=======================================================================

Included Files:
  cnn_int8.c           Existing CPU reference inference code provided by the user
  cnn_int8.h           Type definitions and function declarations for the C code
  cnn_model_data.c/h   Loads weights and biases from the ROM model.mem file
  cnn_mem_test.c       Reads 64x64 RRGGBB image MEM files and prints inference results
  model.mem            Weight/bias file used in the ROM + UART RTL test

1. Extract dataset_4_rtl_64x64.zip:
   ram_hex/capture_08685.mem through ram_hex/capture_08729.mem

2. Extract this package as well and open a terminal in the package directory.

3. Compile with GCC or Clang (MinGW64 GCC is supported on Windows):

   gcc -std=c11 -O2 -Wall -Wextra cnn_int8.c cnn_model_data.c cnn_mem_test.c -o cnn_mem_test.exe

4. Run inference on one image:

   ./cnn_mem_test.exe model.mem ram_hex/capture_08685.mem

   If the image ZIP was extracted elsewhere, replace ram_hex/... with its actual path.
   In PowerShell:

   .\cnn_mem_test.exe model.mem .\ram_hex\capture_08685.mem

5. Run inference on multiple images:

   PowerShell:
   .\cnn_mem_test.exe model.mem .\ram_hex\*.mem

   Note: Wildcard expansion for external programs can vary by PowerShell environment.
   A reliable way to execute the program once per file is:

   Get-ChildItem .\ram_hex\*.mem | ForEach-Object { .\cnn_mem_test.exe model.mem $_.FullName }

Verified Reference Output (capture_08685.mem):
  fc2_mac_before_bias = 13634
  fc2_after_bias      = 3995
  angle_deg           = 4

Input Processing:
  Each line of an image MEM file contains an RGB uint8 pixel in RRGGBB format.
  To match the actual RTL act_path, each channel is XORed with 0x80
  (equivalent to original_value - 128 when interpreted as signed int8).
  The resulting values are then supplied to the inference model as an HWC
  array in R, G, B channel order.

  The previously suggested input_scale division is NOT applied because it
  does not match the current RTL input path.

Verification Scope:
  The values above are calculated by the C software reference model.
  They are reference values for comparison against RTL, not evidence that
  the same results have been measured on the FPGA board.
  Any differences between the original C model's computational assumptions
  and the actual RTL implementation must be checked separately.
