# ChaCha20 Crypto-Accelerator: Hardware Architecture Specification

This document provides a technical breakdown of the sub-block micro-architecture, matrix state mapping, and clock domain boundary conditions for the FPGA-accelerated ChaCha20 cryptographic engine.

---

## 1. 512-bit Ingress SPI Protocol Engine & Matrix Mapping

The `spi_wrapper` ingests a raw 512-bit stream over the SPI bus. Because data shifts from right to left (MSB-first entrance), the first elements transmitted are pushed to the highest index positions:

### Matrix State Configuration (Word Alignment)

| Matrix Position | Bit Range | Word Designation | Description / Contents |
| :--- | :--- | :--- | :--- |
| **Row 0: Words [0:3]** | `[511:384]` | 4 Constant Words | Fixed protocol constants (`"expand 32-byte k"`) |
| **Row 1: Words [4:7]** | `[383:256]` | First 4 Words of Key | Upper 128 bits of the secret key payload |
| **Row 2: Words [8:11]** | `[255:128]` | Next 4 Words of Key | Lower 128 bits of the secret key payload |
| **Row 3: Word [12]** | `[127:96]`  | 1 Counter Word | Block sequence counter |
| **Row 3: Words [13:15]**| `[95:0]`    | 3 Nonce Words | Initialization Vector / Nonce payload |

---

## 2. Clock Domain Crossing (CDC) & Edge Detection

The hardware stack interfaces across two asynchronous clock domains: the external SPI Master Clock (`spi_sclk`) and the internal high-speed FPGA System Clock (`clk`). 

To mitigate metastability risks at the sample boundary, incoming control transitions are passed through a dedicated **2-Stage Flip-Flop (2-FF) Synchronizer** paired with combinatorial edge-detection gating.

### Edge Gating Equations
* **Rising Edge Pulse:** `assign sclk_rising = (sclk_sync_r1 && !sclk_sync_r2);`
* **Falling Edge Pulse:** `assign sclk_falling = (!sclk_sync_r1 && sclk_sync_r2);`

---

## 3. High-Throughput Parallel Execution Core

Once the full 512-bit frame has migrated into the internal ingress registers, the `chacha_top` controller commands the matrix round primitives. The execution pipeline launches simultaneous Column and Diagonal quarter-rounds, performing high-speed 32-bit ARX (Add-Rotate-XOR) operations natively in hardware to maximize throughput.
