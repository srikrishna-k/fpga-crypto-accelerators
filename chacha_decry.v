`timescale 1ns / 1ps

module chacha_decry(
    input  wire        clk,
    input  wire        rst,
    input  wire        en,
    input  wire [255:0] key,
    input  wire [95:0]  nonce,
    input  wire [511:0] ciphertext,
    output reg [511:0] decrypted_out,
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
            decrypted_out <= 512'd0;
        else if (valid)
            decrypted_out <= ciphertext ^ ks;
    end

endmodule
