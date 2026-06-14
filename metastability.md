# ChaCha20 Crypto-Accelerator: Hardware Architecture & CDC Specification

This specification documents the 512-bit ingress packet layout, matrix state word-slicing rules, and the hardware synchronization boundaries implemented to handle asynchronous Clock Domain Crossings (CDC) safely.

---

## 1. 512-bit Ingress SPI Protocol Engine & Matrix Mapping

The `spi_wrapper` ingests a raw 512-bit serial data stream over the SPI bus interface. Because data shifts from right to left (MSB-first entrance into the buffer), the elements transmitted first are progressively pushed down into the highest index register ranges.

### Matrix State Configuration (Word Alignment)

The 512-bit ingress block is sliced directly into sixteen 32-bit words to form the standard $4 \times 4$ ChaCha20 execution matrix array:

| Matrix Position | Bit Range | Word Designation | Description / Contents |
| :--- | :--- | :--- | :--- |
| **Row 0: Words [0:3]** | `[511:384]` | 4 Constant Words | Fixed protocol constants (`"expand 32-byte k"`) |
| **Row 1: Words [4:7]** | `[383:256]` | First 4 Words of Key | Upper 128 bits of the secret key payload |
| **Row 2: Words [8:11]** | `[255:128]` | Next 4 Words of Key | Lower 128 bits of the secret key payload |
| **Row 3: Word [12]** | `[127:96]`  | 1 Counter Word | Block sequence counter |
| **Row 3: Words [13:15]**| `[95:0]`    | 3 Nonce Words | Initialization Vector / Nonce payload |

---

## 2. Clock Domain Crossing (CDC) & Metastability Hazards

The hardware stack interfaces across two completely asynchronous, isolated clock domains: the external SPI Master Clock (`spi_sclk`) driven by a host controller, and the internal high-speed FPGA System Clock (`clk`). 

### The Physical Cause of Metastability
When an asynchronous signal transitions right inside the critical **setup or hold time** window of an internal capturing register, the flip-flop's internal transistor feedback loops fail to settle cleanly into a digital logic high (`1`) or low (`0`). 

Instead, the output voltage floats at an intermediate level, oscillating unpredictably like a ball balanced on the knife-edge peak of a steep hill. If this unstable voltage propagates down into the main ChaCha20 state controllers, it causes catastrophic logic failure and system crashes.

---

## 3. The Solution: 2-Stage Flip-Flop (2-FF) Synchronizer

To quarantine metastability hazards, incoming control lines pass through a dedicated cascade of two back-to-back D-Flip-Flops clocked entirely by the destination domain (`clk`).

```text
                           FPGA System Clock Domain (clk)
                           ┌─────────────────┐       ┌─────────────────┐
  Asynchronous             │   Stage 1 FF    │       │   Stage 2 FF    │   Synchronized
  Input Signal ───────────►│ D             Q ├──────►│ D             Q ├───────────────►
  (e.g., spi_sclk)         │                 │       │                 │   Output Pulse
                           │    ► [clk]      │       │    ► [clk]      │
                           └───────▲─────────┘       └───────▲─────────┘
                                   │                         │
  FPGA Internal clk ───────────────┴─────────────────────────┴──────────────────────────
