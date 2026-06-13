`timescale 1ns / 1ps

module chacha_keystreamgen(
    input  wire        clk,
    input  wire        rst,
    input  wire        en,
    input  wire [255:0] key,
    input  wire [95:0]  nonce,
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
