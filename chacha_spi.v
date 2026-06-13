`timescale 1ns / 1ps

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
