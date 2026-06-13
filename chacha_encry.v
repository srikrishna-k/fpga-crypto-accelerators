`timescale 1ns / 1ps

module chacha_encry(
    input  wire        clk,
    input  wire        rst,
    input  wire        en,
    input  wire [255:0] key,
    input  wire [95:0]  nonce,
    input  wire [511:0] plaintext,
    output reg [511:0] ciphertext,
    output wire        valid
);
    wire [511:0] ks;

    chacha_keystreamgen k (
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
