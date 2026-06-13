# Hardware Acceleration of Cryptographic Engines via SPI

This repository documents the implementation and hardware verification of FPGA-based cryptographic accelerators driven by an ESP32 microcontroller over a custom SPI protocol layer.

## Description

This project implements a high-throughput hardware-acceleration framework for modern cryptographic primitives. Designed in Verilog and deployed on an FPGA fabric, the system exposes a custom SPI slave engine that bridges the hardware cores directly to an ESP32 microcontroller acting as the operational master bus.

### Why This Architecture?
Standard software implementations of stream ciphers like ChaCha20 can bottleneck low-power microcontrollers when processing large data streams. Offloading the heavy computation—such as the 20 rounds of matrix quarter-rounds, additions, and rotations—to dedicated FPGA hardware frees up processor cycles while minimizing latency.

### How It Works Under the Hood
1. **SPI Layer Synchronization:** The ESP32 utilizes a custom serial driver to stream configuration bytes, keys, and payload data to the FPGA.
2. **Dynamic Ingress/Egress Piping:** A specialized 608-bit shifting buffer on the FPGA captures data streams natively in a single continuous chip-select event, preventing truncation or data drops.
3. **Pipeline Isolation:** Once calculation finishes, data is isolated into a dedicated transmission register (`tx_output_reg`) allowing stable read-back without interfering with incoming clock cycles.

---

## Technical Specifications (Current Architecture)

| Metric | ChaCha20 Engine Configuration |
| :--- | :--- |
| **Cipher Type** | Stream Cipher |
| **Key Size** | 256 bits (32 Bytes) |
| **Initialization Vectors** | 96 bits Nonce (12 Bytes) |
| **Data Block Size** | 512 bits (64 Bytes) |
| **SPI Stream Window** | 608 bits continuous (Nonce + Data) |

*Note: Legacy/Upcoming AES-128 hardware modules will be integrated into the framework in the coming days.*

---

## System Architecture & Hardware Interface Mapping

* **ESP32 GPIO18** -> FPGA `spi_sclk` (SPI Clock)
* **ESP32 GPIO23** -> FPGA `spi_mosi` (Master Out Slave In)
* **ESP32 GPIO19** -> FPGA `spi_miso` (Master In Slave Out)
* **ESP32 GPIO5** -> FPGA `spi_cs_n` (Chip Select - Active Low)

---

## Project Log & Updates

### June 13, 2026
* **Repository Initialized:** Created the master remote repository hosted at `github.com/srikrishna-k/fpga-crypto-accelerators`.
* **Consolidated Core Architecture Uploaded:** Uploaded `chacha_spi.v` containing the complete consolidated RTL stack (SPI wrapper, sub-top controllers, and core keystream generation primitives) alongside the ESP32 verification driver.
* **Fixed All-Zero Output Bug:** Expanded the internal SPI shift register to 608 bits to prevent the 96-bit Nonce from being truncated during stream ingress.
* **Decoupled Read/Write Pipelines:** Isolated outbound data into a dedicated `tx_output_reg` to ensure `spi_cs_n` transitions do not clear calculated results before the ESP32 can read them back.
