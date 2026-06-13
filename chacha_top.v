`timescale 1ns / 1ps

module chacha_top(
    input  wire        clk,
    input  wire        rst,       // active-HIGH, multi-cycle pulse
    input  wire        mode,      // 1 = encrypt, 0 = decrypt
    input  wire [255:0] key,
    input  wire [95:0]  nonce,
    input  wire [511:0] plaintext_in,
    output wire [511:0] data_out,
    output wire        done
);

    reg [1:0] rst_sr;
    always @(posedge clk or posedge rst) begin
        if (rst)
            rst_sr <= 2'b11;          
        else
            rst_sr <= {rst_sr[0], 1'b0};  
    end
    
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
