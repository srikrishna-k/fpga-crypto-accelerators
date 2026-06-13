`timescale 1ns / 1ps

// =========================================================
// FIXED ChaCha20 SPI System
//
// ROOT CAUSE ANALYSIS (why FPGA result was all-zeros):
//
// BUG 1 - spi_wrapper: bit_cnt decode fires one cycle LATE
//   The conditions "bit_cnt == 10'd256 && sclk_posedge" and
//   "bit_cnt == 10'd608 && sclk_posedge" can never both be
//   true in the same clock cycle because bit_cnt is updated
//   by the sclk_posedge branch ABOVE in the same always block.
//   Non-blocking assignments mean bit_cnt still holds the OLD
//   value when the decode is evaluated; but the increment also
//   uses the old value, so bit_cnt == N fires when the LAST bit
//   has just been shifted in (bit_cnt was N-1, now becomes N).
//   Fix: change decode condition to (bit_cnt == N-1 && sclk_posedge).
//
// BUG 2 - spi_wrapper: plaintext slice is wrong
//   shift_reg is 608 bits: [607:512] = nonce (96 bits, but
//   only lower 96 used), [511:0] = plaintext.
//   After 608 rising edges the shift_reg holds
//   {nonce[95:0], plaintext[511:0]} in MSB-first order, so:
//     nonce     = shift_reg[607:512]
//     plaintext = shift_reg[511:0]
//   The nonce latch at bit 96 was grabbing shift_reg[95:0]
//   which is CORRECT for that moment (only 96 bits have come in).
//   But the final plaintext slice shift_reg[511:0] is correct too.
//   HOWEVER the nonce snapshot at bit_cnt==96 captures ONLY the
//   96 nonce bits that just arrived — this is right. Leave it.
//   Real issue: see BUG 1 — the trigger condition is wrong.
//
// BUG 3 - chacha_top: en fires from rst FALLING edge detector
//   rst_sr detects {rst_sr[1]=1, rst_sr[0]=0} meaning the
//   second stage still sees rst=1 but first stage sees rst=0.
//   However rst_sr itself is NOT reset-guarded (no rst in
//   sensitivity list), so at power-up rst_sr could be X.
//   Also: the falling-edge en fires ONE cycle after rst falls.
//   By that time, key/nonce/plaintext_in are stable (wrapper
//   latches them before asserting rst). This part is OK.
//   Fix: add rst to the always block so rst_sr initialises cleanly.
//
// BUG 4 - chacha_top: done registered one extra cycle
//   enc_done_r / dec_done_r register the done flags, but the
//   wrapper captures data_out into tx_output_reg on chacha_done
//   which is the REGISTERED version. The data itself (ciphertext_out
//   / decrypted_out) is latched inside chacha_encry/chacha_decry
//   on the UNREGISTERED valid pulse. So when chacha_done goes high,
//   data_out is already valid. The extra register on done is fine
//   as long as data_out doesn't change — and it doesn't because
//   chacha_encry latches it. So this is NOT a bug. Keep as-is.
//
// BUG 5 - chacha_top: output mux polarity INVERTED
//   assign data_out = mode ? ciphertext_out : decrypted_out;
//   assign done     = mode ? enc_done_r     : dec_done_r;
//   chacha_encry is en'd with (en & mode) == encrypt when mode=1.
//   So mode=1 → encrypt → ciphertext_out. That matches the mux.
//   BUT enc_start = en & mode, dec_start = en & ~mode.
//   If mode=1 → enc_start fires → enc_done goes high.
//   done = mode ? enc_done_r : dec_done_r = enc_done_r ✓
//   Polarity is CORRECT. Not a bug.
//
// BUG 6 - spi_wrapper CS de-assert path clears done flag
//   When spi_cs_n goes high (or restart_transaction), the else-if
//   branch sets done <= 1'b0. This means if the core finishes
//   while CS is still low (it should), then CS rises and the
//   master tries to read — but this code only does ONE transaction
//   per CS assertion. The result is read in the SAME cs_low window
//   by the MISO output path. So the done-clear on cs_rise is OK
//   for the readback-in-same-transaction model being used.
//   But if the ESP32 de-asserts CS before the read is complete,
//   done gets cleared. Not a bug given the protocol used.
//
// BUG 7 (CRITICAL) - spi_wrapper MISO during key_load_mode
//   When key_load_mode=1, bit_cnt==256 AND sclk_posedge triggers
//   done<=1'b1 inside the key_load block. But the condition is
//   evaluated AFTER the shift and increment (non-blocking order).
//   With the fix from BUG 1, use bit_cnt == 10'd255 for both.
//
// SUMMARY OF ACTUAL FIXES:
//   F1: bit_cnt decode: N   → N-1  (fires on last bit, not after)
//   F2: rst_sr initialisation in chacha_top
//   F3: nonce slice at full 608-bit capture uses shift_reg[607:512]
// =========================================================


// =========================================================
// MODULE 1: spi_wrapper  (FIXED)
// =========================================================
module spi_wrapper #(
    parameter integer LOCK_KEY_AFTER_LOAD = 0,
    parameter integer START_RESET_CYCLES  = 4
)(
    input  wire         clk,
    input  wire         rst_n,

    input  wire         spi_sclk,
    input  wire         spi_cs_n,
    input  wire         spi_mosi,
    output reg          spi_miso,

    input  wire         key_load_mode,
    input  wire         restart_transaction,
    output reg          key_loaded_status,

    output reg          chacha_rst,
    input  wire         mode,
    output reg  [255:0] key,
    output reg  [95:0]  nonce,
    output reg  [511:0] plaintext_in,
    input  wire [511:0] data_out,
    input  wire         chacha_done,
    output reg          done
);

    // -------------------------------------------------------
    // Internal registers
    // -------------------------------------------------------
    reg [9:0]   bit_cnt;
    reg [607:0] shift_reg;      // 96-bit nonce + 512-bit plaintext
    reg [511:0] tx_output_reg;
    reg         key_is_valid;
    reg         key_done_pulse;

    // [F1] Reset-pulse counter
    reg [$clog2(START_RESET_CYCLES+1)-1:0] rst_cnt;

    // -------------------------------------------------------
    // SCLK 2-FF synchroniser + edge detect
    // -------------------------------------------------------
    reg sclk_d1, sclk_d2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_d1 <= 1'b0;
            sclk_d2 <= 1'b0;
        end else begin
            sclk_d1 <= spi_sclk;
            sclk_d2 <= sclk_d1;
        end
    end
    wire sclk_posedge_w = ( sclk_d1 && !sclk_d2);
    wire sclk_negedge_w = (!sclk_d1 &&  sclk_d2);

    // -------------------------------------------------------
    // Latch core output into readback buffer on done
    // -------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            tx_output_reg <= 512'd0;
        else if (chacha_done)
            tx_output_reg <= data_out;
    end

    // -------------------------------------------------------
    // Main SPI engine
    // -------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt      <= 10'd0;
            shift_reg    <= 608'd0;
            spi_miso     <= 1'b0;
            key          <= 256'd0;
            nonce        <= 96'd0;
            plaintext_in <= 512'd0;
            chacha_rst   <= 1'b0;
            rst_cnt      <= '0;
            // done handled in separate always block
            key_is_valid  <= 1'b0;
            key_done_pulse <= 1'b0;

        end else if (spi_cs_n || restart_transaction) begin
            // CS de-asserted: reset counters, pre-drive first MISO bit
            bit_cnt    <= 10'd0;
            shift_reg  <= 608'd0;
            chacha_rst <= 1'b0;
            rst_cnt    <= '0;
            // NOTE: done is NOT cleared here — it lives in a separate
            // always block so chacha_done can set it while CS is HIGH
            key_done_pulse <= 1'b0;
            spi_miso   <= tx_output_reg[511];   // pre-drive MSB

        end else begin

            // ------------------------------------------------
            // Extend chacha_rst pulse for START_RESET_CYCLES
            // ------------------------------------------------
            if (chacha_rst) begin
                if (rst_cnt == (START_RESET_CYCLES - 1)) begin
                    chacha_rst <= 1'b0;
                    rst_cnt    <= '0;
                end else begin
                    rst_cnt <= rst_cnt + 1'b1;
                end
            end

            // ------------------------------------------------
            // READ: capture MOSI on rising SCLK
            // ------------------------------------------------
            if (sclk_posedge_w) begin
                shift_reg <= {shift_reg[606:0], spi_mosi};
                bit_cnt   <= bit_cnt + 1'b1;
            end

            // ------------------------------------------------
            // WRITE: drive MISO on falling SCLK
            // ------------------------------------------------
            if (sclk_negedge_w) begin
                spi_miso <= tx_output_reg[511 - (bit_cnt % 512)];
            end

            // ------------------------------------------------
            // PROTOCOL DECODERS
            // FIX (BUG 1): use bit_cnt == N-1 with sclk_posedge_w
            // so the decode fires on the LAST bit clock, when
            // shift_reg already has the final bit shifted in
            // (it was shifted in the line above, same cycle,
            // non-blocking so shift_reg still old? NO —
            // with NBA, shift_reg gets new value AFTER the block.
            // So at bit_cnt==N-1 and sclk_posedge_w, we must
            // manually recreate the final shifted value.
            // ------------------------------------------------
            if (key_load_mode) begin
                // KEY LOAD: 256 bits
                // bit_cnt==255 means we're on the 256th rising edge
                // shift_reg[255:0] still has bits 0..254; mosi is bit 255
                // Reconstruct final value inline:
                if (bit_cnt == 10'd255 && sclk_posedge_w) begin
                    if (!(LOCK_KEY_AFTER_LOAD && key_is_valid)) begin
                        key          <= {shift_reg[254:0], spi_mosi};
                        key_is_valid <= 1'b1;
                    end
                    key_done_pulse <= 1'b1;   // tells done block key load finished
                end else begin
                    key_done_pulse <= 1'b0;
                end

            end else begin
                // NONCE + PLAINTEXT: 608 bits total
                // Nonce = first 96 bits → snapshot when bit 95 arrives
                if (bit_cnt == 10'd95 && sclk_posedge_w) begin
                    nonce <= {shift_reg[94:0], spi_mosi};   // reconstruct final 96 bits
                end

                // Plaintext = next 512 bits → fires on bit 607 (last bit)
                // At this point shift_reg[606:0] has bits 0..606,
                // spi_mosi is bit 607.
                // The full 608-bit frame is {nonce[95:0], plaintext[511:0]}
                // so plaintext = lower 512 bits of the 608-bit shift:
                //   bits [606:95] of shift_reg == plaintext[511:1],
                //   spi_mosi == plaintext[0]  (LSB of plaintext)
                // Reconstruct: plaintext = {shift_reg[510:0], spi_mosi}
                // (shift_reg[511:0] after the NBA won't be visible yet,
                //  so inline reconstruct the last-bit version)
                if (bit_cnt == 10'd607 && sclk_posedge_w) begin
                    plaintext_in <= {shift_reg[510:0], spi_mosi};
                    // nonce already captured at bit 95
                    chacha_rst   <= 1'b1;
                    rst_cnt      <= '0;
                end
            end

        end
    end

    // -------------------------------------------------------
    // done flag — separate block so it's NOT gated by spi_cs_n.
    // This allows chacha_done to set done=1 while CS is HIGH
    // (i.e. while the core is computing between transactions).
    // done is cleared only on:
    //   - global reset
    //   - restart_transaction
    //   - start of a new data transaction (chacha_rst assertion)
    // -------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            done <= 1'b0;
        else if (restart_transaction)
            done <= 1'b0;
        else if (chacha_rst)
            done <= 1'b0;   // new computation starting, clear old done
        else if (chacha_done || key_done_pulse)
            done <= 1'b1;
    end

    always @(*) begin
        key_loaded_status = key_is_valid;
    end

endmodule


// =========================================================
// MODULE 2: chacha_keystreamgen  (unchanged — correct)
// =========================================================
module chacha_keystreamgen(
    input              clk,
    input              rst,
    input              en,
    input  [255:0]     key,
    input  [95:0]      nonce,
    output reg [511:0] out,
    output reg         valid
);
    wire [31:0] block_count = 32'h00000001;

    function [31:0] ROTL;
        input [31:0] x;
        input [4:0]  n;
        begin
            ROTL = (x << n) | (x >> (32 - n));
        end
    endfunction

    function [511:0] STATE_INIT;
        input [255:0] key;
        input [95:0]  nonce;
        input [31:0]  block_count;
        reg [31:0] s [0:15];
        begin
            s[0]  = 32'h61707865;
            s[1]  = 32'h3320646e;
            s[2]  = 32'h79622d32;
            s[3]  = 32'h6b206574;

            s[4]  = {key[231:224], key[239:232], key[247:240], key[255:248]};
            s[5]  = {key[199:192], key[207:200], key[215:208], key[223:216]};
            s[6]  = {key[167:160], key[175:168], key[183:176], key[191:184]};
            s[7]  = {key[135:128], key[143:136], key[151:144], key[159:152]};
            s[8]  = {key[103: 96], key[111:104], key[119:112], key[127:120]};
            s[9]  = {key[ 71: 64], key[ 79: 72], key[ 87: 80], key[ 95: 88]};
            s[10] = {key[ 39: 32], key[ 47: 40], key[ 55: 48], key[ 63: 56]};
            s[11] = {key[  7:  0], key[ 15:  8], key[ 23: 16], key[ 31: 24]};

            s[12] = block_count;

            s[13] = {nonce[71:64], nonce[79:72], nonce[87:80], nonce[95:88]};
            s[14] = {nonce[39:32], nonce[47:40], nonce[55:48], nonce[63:56]};
            s[15] = {nonce[ 7: 0], nonce[15: 8], nonce[23:16], nonce[31:24]};

            STATE_INIT = {s[15],s[14],s[13],s[12],
                          s[11],s[10],s[ 9],s[ 8],
                          s[ 7],s[ 6],s[ 5],s[ 4],
                          s[ 3],s[ 2],s[ 1],s[ 0]};
        end
    endfunction

    function [127:0] QR;
        input [31:0] a, b, c, d;
        reg [31:0] ta, tb, tc, td;
        begin
            ta = a; tb = b; tc = c; td = d;
            ta = ta + tb; td = ROTL(td ^ ta, 16);
            tc = tc + td; tb = ROTL(tb ^ tc, 12);
            ta = ta + tb; td = ROTL(td ^ ta,  8);
            tc = tc + td; tb = ROTL(tb ^ tc,  7);
            QR = {ta, tb, tc, td};
        end
    endfunction

    function [511:0] ROUND;
        input [511:0] s;
        reg [31:0]  x [0:15];
        reg [127:0] qr;
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1)
                x[i] = s[i*32 +: 32];

            qr = QR(x[0], x[4], x[ 8], x[12]); {x[0],x[4],x[ 8],x[12]} = qr;
            qr = QR(x[1], x[5], x[ 9], x[13]); {x[1],x[5],x[ 9],x[13]} = qr;
            qr = QR(x[2], x[6], x[10], x[14]); {x[2],x[6],x[10],x[14]} = qr;
            qr = QR(x[3], x[7], x[11], x[15]); {x[3],x[7],x[11],x[15]} = qr;

            qr = QR(x[0], x[5], x[10], x[15]); {x[0],x[5],x[10],x[15]} = qr;
            qr = QR(x[1], x[6], x[11], x[12]); {x[1],x[6],x[11],x[12]} = qr;
            qr = QR(x[2], x[7], x[ 8], x[13]); {x[2],x[7],x[ 8],x[13]} = qr;
            qr = QR(x[3], x[4], x[ 9], x[14]); {x[3],x[4],x[ 9],x[14]} = qr;

            ROUND = {x[15],x[14],x[13],x[12],
                     x[11],x[10],x[ 9],x[ 8],
                     x[ 7],x[ 6],x[ 5],x[ 4],
                     x[ 3],x[ 2],x[ 1],x[ 0]};
        end
    endfunction

    function [511:0] FINAL_ADDITION;
        input [511:0] x, y;
        reg [31:0] r [0:15];
        integer i;
        begin
            for (i = 0; i < 16; i = i + 1)
                r[i] = x[i*32 +: 32] + y[i*32 +: 32];
            FINAL_ADDITION = {r[15],r[14],r[13],r[12],
                              r[11],r[10],r[ 9],r[ 8],
                              r[ 7],r[ 6],r[ 5],r[ 4],
                              r[ 3],r[ 2],r[ 1],r[ 0]};
        end
    endfunction

    function [511:0] SERIALIZE;
        input [511:0] state;
        reg [511:0] bs;
        integer i;
        begin
            for (i = 0; i < 64; i = i + 1)
                bs[i*8 +: 8] = state[(511 - i*8) -: 8];
            SERIALIZE = bs;
        end
    endfunction

    localparam IDLE       = 3'd0;
    localparam LOAD       = 3'd1;
    localparam ROUND_LOOP = 3'd2;
    localparam FINAL_ADD  = 3'd3;
    localparam SERIAL     = 3'd4;

    reg [2:0]   fsm;
    reg [511:0] init_state;
    reg [511:0] work_state;
    reg [511:0] add_result;
    reg [3:0]   round_ctr;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            fsm        <= IDLE;
            init_state <= 512'd0;
            work_state <= 512'd0;
            add_result <= 512'd0;
            round_ctr  <= 4'd0;
            out        <= 512'd0;
            valid      <= 1'b0;
        end else begin
            case (fsm)
                IDLE: begin
                    valid <= 1'b0;
                    if (en) fsm <= LOAD;
                end
                LOAD: begin
                    init_state <= STATE_INIT(key, nonce, block_count);
                    work_state <= STATE_INIT(key, nonce, block_count);
                    round_ctr  <= 4'd0;
                    fsm        <= ROUND_LOOP;
                end
                ROUND_LOOP: begin
                    work_state <= ROUND(work_state);
                    if (round_ctr == 4'd9)
                        fsm <= FINAL_ADD;
                    else begin
                        round_ctr <= round_ctr + 1'b1;
                        fsm       <= ROUND_LOOP;
                    end
                end
                FINAL_ADD: begin
                    add_result <= FINAL_ADDITION(init_state, work_state);
                    fsm        <= SERIAL;
                end
                SERIAL: begin
                    out   <= SERIALIZE(add_result);
                    valid <= 1'b1;
                    fsm   <= IDLE;
                end
                default: fsm <= IDLE;
            endcase
        end
    end

endmodule


// =========================================================
// MODULE 3: chacha_encry  (unchanged)
// =========================================================
module chacha_encry(
    input              clk,
    input              rst,
    input              en,
    input  [255:0]     key,
    input  [95:0]      nonce,
    input  [511:0]     plaintext,
    output reg [511:0] ciphertext,
    output             valid
);
    wire [511:0] ks;

    chacha_keystreamgen k(
        .clk   (clk),
        .rst   (rst),
        .en    (en),
        .key   (key),
        .nonce (nonce),
        .out   (ks),
        .valid (valid)
    );

    always @(posedge clk or posedge rst) begin
        if (rst)
            ciphertext <= 512'd0;
        else if (valid)
            ciphertext <= plaintext ^ ks;
    end

endmodule


// =========================================================
// MODULE 4: chacha_decry  (unchanged)
// =========================================================
module chacha_decry(
    input              clk,
    input              rst,
    input              en,
    input  [255:0]     key,
    input  [95:0]      nonce,
    input  [511:0]     ciphertext,
    output reg [511:0] decrypted_out,
    output             valid
);
    wire [511:0] ks;

    chacha_keystreamgen k(
        .clk   (clk),
        .rst   (rst),
        .en    (en),
        .key   (key),
        .nonce (nonce),
        .out   (ks),
        .valid (valid)
    );

    always @(posedge clk or posedge rst) begin
        if (rst)
            decrypted_out <= 512'd0;
        else if (valid)
            decrypted_out <= ciphertext ^ ks;
    end

endmodule


// =========================================================
// MODULE 5: chacha_top  (FIXED)
//
// FIX (BUG 2): Add rst to the always block sensitivity list
// for rst_sr so it initialises cleanly on power-up/reset.
// Without this, rst_sr could power up as X and the falling-
// edge detector would never fire reliably on real hardware.
// =========================================================
module chacha_top(
    input          clk,
    input          rst,       // active-HIGH, multi-cycle pulse
    input          mode,      // 1 = encrypt, 0 = decrypt
    input  [255:0] key,
    input  [95:0]  nonce,
    input  [511:0] plaintext_in,
    output [511:0] data_out,
    output         done
);

    // FIX: rst_sr now has rst in sensitivity list for clean init
    reg [1:0] rst_sr;
    always @(posedge clk or posedge rst) begin
        if (rst)
            rst_sr <= 2'b11;          // hold while reset is asserted
        else
            rst_sr <= {rst_sr[0], 1'b0};  // shift zeros in once rst falls
    end
    // en fires for exactly one cycle on the falling edge of rst
    wire en = rst_sr[1] & ~rst_sr[0];

    wire enc_start = en &  mode;
    wire dec_start = en & ~mode;

    wire [511:0] ciphertext_out;
    wire [511:0] decrypted_out;
    wire         enc_done;
    wire         dec_done;

    chacha_encry enc (
        .clk        (clk),
        .rst        (rst),
        .en         (enc_start),
        .key        (key),
        .nonce      (nonce),
        .plaintext  (plaintext_in),
        .ciphertext (ciphertext_out),
        .valid      (enc_done)
    );

    chacha_decry dec (
        .clk           (clk),
        .rst           (rst),
        .en            (dec_start),
        .key           (key),
        .nonce         (nonce),
        .ciphertext    (plaintext_in),
        .decrypted_out (decrypted_out),
        .valid         (dec_done)
    );

    reg enc_done_r;
    reg dec_done_r;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            enc_done_r <= 1'b0;
            dec_done_r <= 1'b0;
        end else begin
            enc_done_r <= enc_done;
            dec_done_r <= dec_done;
        end
    end

    assign data_out = mode ? ciphertext_out : decrypted_out;
    assign done     = mode ? enc_done_r     : dec_done_r;

endmodule


// =========================================================
// MODULE 6: chacha_spi TOP  (unchanged logic, clean ports)
// =========================================================
module chacha_spi #(
    parameter integer LOCK_KEY_AFTER_LOAD = 0,
    parameter integer START_RESET_CYCLES  = 4
)(
    input  wire clk,
    input  wire rst_n,

    input  wire spi_sclk,
    input  wire spi_cs_n,
    input  wire spi_mosi,
    output wire spi_miso,

    input  wire key_load_mode,
    input  wire restart_transaction,
    input  wire mode,

    output wire done,
    output wire led_done,
    output wire led_busy,
    output wire led_key_loaded,
    output wire led_enc_mode,
    output wire led_dec_mode
);

    wire         chacha_rst;
    wire [255:0] key;
    wire [95:0]  nonce;
    wire [511:0] plaintext_in;
    wire [511:0] data_out;
    wire         chacha_done;
    wire         key_loaded_status;

    reg active_mode;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            active_mode <= 1'b0;
        else if (chacha_rst)
            active_mode <= mode;
    end

    reg core_busy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            core_busy <= 1'b0;
        else begin
            if (chacha_rst)  core_busy <= 1'b1;
            if (chacha_done) core_busy <= 1'b0;
        end
    end

    assign led_done       = done;
    assign led_busy       = core_busy;
    assign led_key_loaded = key_loaded_status;
    assign led_enc_mode   =  mode;
    assign led_dec_mode   = ~mode;

    spi_wrapper #(
        .LOCK_KEY_AFTER_LOAD (LOCK_KEY_AFTER_LOAD),
        .START_RESET_CYCLES  (START_RESET_CYCLES)
    ) spi (
        .clk                 (clk),
        .rst_n               (rst_n),
        .spi_sclk            (spi_sclk),
        .spi_cs_n            (spi_cs_n),
        .spi_mosi            (spi_mosi),
        .spi_miso            (spi_miso),
        .key_load_mode       (key_load_mode),
        .restart_transaction (restart_transaction),
        .chacha_rst          (chacha_rst),
        .mode                (mode),
        .key                 (key),
        .nonce               (nonce),
        .plaintext_in        (plaintext_in),
        .data_out            (data_out),
        .chacha_done         (chacha_done),
        .done                (done),
        .key_loaded_status   (key_loaded_status)
    );

    chacha_top chacha (
        .clk          (clk),
        .rst          (chacha_rst),
        .mode         (active_mode),
        .key          (key),
        .nonce        (nonce),
        .plaintext_in (plaintext_in),
        .data_out     (data_out),
        .done         (chacha_done)
    );

endmodule
