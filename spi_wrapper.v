`timescale 1ns / 1ps

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

    // Internal registers
    reg [9:0]   bit_cnt;
    reg [607:0] shift_reg;      // 96-bit nonce + 512-bit plaintext
    reg [511:0] tx_output_reg;
    reg          key_is_valid;
    reg          key_done_pulse;

    // Reset-pulse counter
    reg [$clog2(START_RESET_CYCLES+1)-1:0] rst_cnt;

    // SCLK 2-FF synchroniser + edge detect
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            tx_output_reg <= 512'd0;
        else if (chacha_done)
            tx_output_reg <= data_out;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt        <= 10'd0;
            shift_reg      <= 608'd0;
            spi_miso       <= 1'b0;
            key            <= 256'd0;
            nonce          <= 96'd0;
            plaintext_in   <= 512'd0;
            chacha_rst     <= 1'b0;
            rst_cnt        <= 1'b0;
            key_is_valid   <= 1'b0;
            key_done_pulse <= 1'b0;
        end else if (spi_cs_n || restart_transaction) begin
            bit_cnt        <= 10'd0;
            shift_reg      <= 608'd0;
            chacha_rst     <= 1'b0;
            rst_cnt        <= 1'b0;
            key_done_pulse <= 1'b0;
            spi_miso       <= tx_output_reg[511];   // pre-drive MSB
        end else begin
            if (chacha_rst) begin
                if (rst_cnt == (START_RESET_CYCLES - 1)) begin
                    chacha_rst <= 1'b0;
                    rst_cnt    <= 1'b0;
                end else begin
                    rst_cnt <= rst_cnt + 1'b1;
                end
            end

            // READ: capture MOSI on rising SCLK
            if (sclk_posedge_w) begin
                shift_reg <= {shift_reg[606:0], spi_mosi};
                bit_cnt   <= bit_cnt + 1'b1;
            end

            // WRITE: drive MISO on falling SCLK
            if (sclk_negedge_w) begin
                spi_miso <= tx_output_reg[511 - (bit_cnt % 512)];
            end

            if (key_load_mode) begin
                if (bit_cnt == 10'd255 && sclk_posedge_w) begin
                    if (!(LOCK_KEY_AFTER_LOAD && key_is_valid)) begin
                        key          <= {shift_reg[254:0], spi_mosi};
                        key_is_valid <= 1'b1;
                    end
                    key_done_pulse <= 1'b1;
                end else begin
                    key_done_pulse <= 1'b0;
                end
            end else begin
                if (bit_cnt == 10'd95 && sclk_posedge_w) begin
                    nonce <= {shift_reg[94:0], spi_mosi};
                end

                if (bit_cnt == 10'd607 && sclk_posedge_w) begin
                    plaintext_in <= {shift_reg[510:0], spi_mosi};
                    chacha_rst   <= 1'b1;
                    rst_cnt      <= 1'b0;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            done <= 1'b0;
        else if (restart_transaction)
            done <= 1'b0;
        else if (chacha_rst)
            done <= 1'b0;
        else if (chacha_done || key_done_pulse)
            done <= 1'b1;
    end

    always @(*) begin
        key_loaded_status = key_is_valid;
    end

endmodule
