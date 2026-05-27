module twiddle_rom (
    input logic clk,
    input logic [6:0] addr,
    output logic signed [15:0] cos_out,
    output logic signed [15:0] sin_out
);

logic signed [15:0] cos_lut [0:127];
logic signed [15:0] sin_lut [0:127];

initial begin
    cos_lut[ 0] = 16'sd32767; sin_lut[ 0] = 16'sd0;
    cos_lut[ 1] = 16'sd32757; sin_lut[ 1] = -16'sd804;
    cos_lut[ 2] = 16'sd32728; sin_lut[ 2] = -16'sd1608;
    cos_lut[ 3] = 16'sd32678; sin_lut[ 3] = -16'sd2410;
    cos_lut[ 4] = 16'sd32609; sin_lut[ 4] = -16'sd3212;
    cos_lut[ 5] = 16'sd32521; sin_lut[ 5] = -16'sd4011;
    cos_lut[ 6] = 16'sd32412; sin_lut[ 6] = -16'sd4808;
    cos_lut[ 7] = 16'sd32285; sin_lut[ 7] = -16'sd5602;
    cos_lut[ 8] = 16'sd32138; sin_lut[ 8] = -16'sd6393;
    cos_lut[ 9] = 16'sd31971; sin_lut[ 9] = -16'sd7179;
    cos_lut[ 10] = 16'sd31785; sin_lut[ 10] = -16'sd7962;
    cos_lut[ 11] = 16'sd31580; sin_lut[ 11] = -16'sd8739;
    cos_lut[ 12] = 16'sd31356; sin_lut[ 12] = -16'sd9512;
    cos_lut[ 13] = 16'sd31113; sin_lut[ 13] = -16'sd10278;
    cos_lut[ 14] = 16'sd30852; sin_lut[ 14] = -16'sd11039;
    cos_lut[ 15] = 16'sd30572; sin_lut[ 15] = -16'sd11793;
    cos_lut[ 16] = 16'sd30274; sin_lut[ 16] = -16'sd12540;
    cos_lut[ 17] = 16'sd29957; sin_lut[ 17] = -16'sd13279;
    cos_lut[ 18] = 16'sd29622; sin_lut[ 18] = -16'sd14010;
    cos_lut[ 19] = 16'sd29269; sin_lut[ 19] = -16'sd14733;
    cos_lut[ 20] = 16'sd28898; sin_lut[ 20] = -16'sd15447;
    cos_lut[ 21] = 16'sd28510; sin_lut[ 21] = -16'sd16151;
    cos_lut[ 22] = 16'sd28105; sin_lut[ 22] = -16'sd16846;
    cos_lut[ 23] = 16'sd27683; sin_lut[ 23] = -16'sd17530;
    cos_lut[ 24] = 16'sd27245; sin_lut[ 24] = -16'sd18204;
    cos_lut[ 25] = 16'sd26790; sin_lut[ 25] = -16'sd18868;
    cos_lut[ 26] = 16'sd26320; sin_lut[ 26] = -16'sd19520;
    cos_lut[ 27] = 16'sd25835; sin_lut[ 27] = -16'sd20160;
    cos_lut[ 28] = 16'sd25335; sin_lut[ 28] = -16'sd20787;
    cos_lut[ 29] = 16'sd24820; sin_lut[ 29] = -16'sd21402;
    cos_lut[ 30] = 16'sd24290; sin_lut[ 30] = -16'sd22005;
    cos_lut[ 31] = 16'sd23746; sin_lut[ 31] = -16'sd22594;
    cos_lut[ 32] = 16'sd23170; sin_lut[ 32] = -16'sd23170;
    cos_lut[ 33] = 16'sd22594; sin_lut[ 33] = -16'sd23746;
    cos_lut[ 34] = 16'sd22005; sin_lut[ 34] = -16'sd24290;
    cos_lut[ 35] = 16'sd21402; sin_lut[ 35] = -16'sd24820;
    cos_lut[ 36] = 16'sd20787; sin_lut[ 36] = -16'sd25335;
    cos_lut[ 37] = 16'sd20160; sin_lut[ 37] = -16'sd25835;
    cos_lut[ 38] = 16'sd19520; sin_lut[ 38] = -16'sd26320;
    cos_lut[ 39] = 16'sd18868; sin_lut[ 39] = -16'sd26790;
    cos_lut[ 40] = 16'sd18204; sin_lut[ 40] = -16'sd27245;
    cos_lut[ 41] = 16'sd17530; sin_lut[ 41] = -16'sd27683;
    cos_lut[ 42] = 16'sd16846; sin_lut[ 42] = -16'sd28105;
    cos_lut[ 43] = 16'sd16151; sin_lut[ 43] = -16'sd28510;
    cos_lut[ 44] = 16'sd15447; sin_lut[ 44] = -16'sd28898;
    cos_lut[ 45] = 16'sd14733; sin_lut[ 45] = -16'sd29269;
    cos_lut[ 46] = 16'sd14010; sin_lut[ 46] = -16'sd29622;
    cos_lut[ 47] = 16'sd13279; sin_lut[ 47] = -16'sd29957;
    cos_lut[ 48] = 16'sd12540; sin_lut[ 48] = -16'sd30274;
    cos_lut[ 49] = 16'sd11793; sin_lut[ 49] = -16'sd30572;
    cos_lut[ 50] = 16'sd11039; sin_lut[ 50] = -16'sd30852;
    cos_lut[ 51] = 16'sd10278; sin_lut[ 51] = -16'sd31113;
    cos_lut[ 52] = 16'sd9512; sin_lut[ 52] = -16'sd31356;
    cos_lut[ 53] = 16'sd8739; sin_lut[ 53] = -16'sd31580;
    cos_lut[ 54] = 16'sd7962; sin_lut[ 54] = -16'sd31785;
    cos_lut[ 55] = 16'sd7179; sin_lut[ 55] = -16'sd31971;
    cos_lut[ 56] = 16'sd6393; sin_lut[ 56] = -16'sd32138;
    cos_lut[ 57] = 16'sd5602; sin_lut[ 57] = -16'sd32285;
    cos_lut[ 58] = 16'sd4808; sin_lut[ 58] = -16'sd32412;
    cos_lut[ 59] = 16'sd4011; sin_lut[ 59] = -16'sd32521;
    cos_lut[ 60] = 16'sd3212; sin_lut[ 60] = -16'sd32609;
    cos_lut[ 61] = 16'sd2410; sin_lut[ 61] = -16'sd32678;
    cos_lut[ 62] = 16'sd1608; sin_lut[ 62] = -16'sd32728;
    cos_lut[ 63] = 16'sd804; sin_lut[ 63] = -16'sd32757;
    cos_lut[ 64] = 16'sd0; sin_lut[ 64] = -16'sd32767;
    cos_lut[ 65] = -16'sd804; sin_lut[ 65] = -16'sd32757;
    cos_lut[ 66] = -16'sd1608; sin_lut[ 66] = -16'sd32728;
    cos_lut[ 67] = -16'sd2410; sin_lut[ 67] = -16'sd32678;
    cos_lut[ 68] = -16'sd3212; sin_lut[ 68] = -16'sd32609;
    cos_lut[ 69] = -16'sd4011; sin_lut[ 69] = -16'sd32521;
    cos_lut[ 70] = -16'sd4808; sin_lut[ 70] = -16'sd32412;
    cos_lut[ 71] = -16'sd5602; sin_lut[ 71] = -16'sd32285;
    cos_lut[ 72] = -16'sd6393; sin_lut[ 72] = -16'sd32138;
    cos_lut[ 73] = -16'sd7179; sin_lut[ 73] = -16'sd31971;
    cos_lut[ 74] = -16'sd7962; sin_lut[ 74] = -16'sd31785;
    cos_lut[ 75] = -16'sd8739; sin_lut[ 75] = -16'sd31580;
    cos_lut[ 76] = -16'sd9512; sin_lut[ 76] = -16'sd31356;
    cos_lut[ 77] = -16'sd10278; sin_lut[ 77] = -16'sd31113;
    cos_lut[ 78] = -16'sd11039; sin_lut[ 78] = -16'sd30852;
    cos_lut[ 79] = -16'sd11793; sin_lut[ 79] = -16'sd30572;
    cos_lut[ 80] = -16'sd12540; sin_lut[ 80] = -16'sd30274;
    cos_lut[ 81] = -16'sd13279; sin_lut[ 81] = -16'sd29957;
    cos_lut[ 82] = -16'sd14010; sin_lut[ 82] = -16'sd29622;
    cos_lut[ 83] = -16'sd14733; sin_lut[ 83] = -16'sd29269;
    cos_lut[ 84] = -16'sd15447; sin_lut[ 84] = -16'sd28898;
    cos_lut[ 85] = -16'sd16151; sin_lut[ 85] = -16'sd28510;
    cos_lut[ 86] = -16'sd16846; sin_lut[ 86] = -16'sd28105;
    cos_lut[ 87] = -16'sd17530; sin_lut[ 87] = -16'sd27683;
    cos_lut[ 88] = -16'sd18204; sin_lut[ 88] = -16'sd27245;
    cos_lut[ 89] = -16'sd18868; sin_lut[ 89] = -16'sd26790;
    cos_lut[ 90] = -16'sd19520; sin_lut[ 90] = -16'sd26320;
    cos_lut[ 91] = -16'sd20160; sin_lut[ 91] = -16'sd25835;
    cos_lut[ 92] = -16'sd20787; sin_lut[ 92] = -16'sd25335;
    cos_lut[ 93] = -16'sd21402; sin_lut[ 93] = -16'sd24820;
    cos_lut[ 94] = -16'sd22005; sin_lut[ 94] = -16'sd24290;
    cos_lut[ 95] = -16'sd22594; sin_lut[ 95] = -16'sd23746;
    cos_lut[ 96] = -16'sd23170; sin_lut[ 96] = -16'sd23170;
    cos_lut[ 97] = -16'sd23746; sin_lut[ 97] = -16'sd22594;
    cos_lut[ 98] = -16'sd24290; sin_lut[ 98] = -16'sd22005;
    cos_lut[ 99] = -16'sd24820; sin_lut[ 99] = -16'sd21402;
    cos_lut[100] = -16'sd25335; sin_lut[100] = -16'sd20787;
    cos_lut[101] = -16'sd25835; sin_lut[101] = -16'sd20160;
    cos_lut[102] = -16'sd26320; sin_lut[102] = -16'sd19520;
    cos_lut[103] = -16'sd26790; sin_lut[103] = -16'sd18868;
    cos_lut[104] = -16'sd27245; sin_lut[104] = -16'sd18204;
    cos_lut[105] = -16'sd27683; sin_lut[105] = -16'sd17530;
    cos_lut[106] = -16'sd28105; sin_lut[106] = -16'sd16846;
    cos_lut[107] = -16'sd28510; sin_lut[107] = -16'sd16151;
    cos_lut[108] = -16'sd28898; sin_lut[108] = -16'sd15447;
    cos_lut[109] = -16'sd29269; sin_lut[109] = -16'sd14733;
    cos_lut[110] = -16'sd29622; sin_lut[110] = -16'sd14010;
    cos_lut[111] = -16'sd29957; sin_lut[111] = -16'sd13279;
    cos_lut[112] = -16'sd30274; sin_lut[112] = -16'sd12540;
    cos_lut[113] = -16'sd30572; sin_lut[113] = -16'sd11793;
    cos_lut[114] = -16'sd30852; sin_lut[114] = -16'sd11039;
    cos_lut[115] = -16'sd31113; sin_lut[115] = -16'sd10278;
    cos_lut[116] = -16'sd31356; sin_lut[116] = -16'sd9512;
    cos_lut[117] = -16'sd31580; sin_lut[117] = -16'sd8739;
    cos_lut[118] = -16'sd31785; sin_lut[118] = -16'sd7962;
    cos_lut[119] = -16'sd31971; sin_lut[119] = -16'sd7179;
    cos_lut[120] = -16'sd32138; sin_lut[120] = -16'sd6393;
    cos_lut[121] = -16'sd32285; sin_lut[121] = -16'sd5602;
    cos_lut[122] = -16'sd32412; sin_lut[122] = -16'sd4808;
    cos_lut[123] = -16'sd32521; sin_lut[123] = -16'sd4011;
    cos_lut[124] = -16'sd32609; sin_lut[124] = -16'sd3212;
    cos_lut[125] = -16'sd32678; sin_lut[125] = -16'sd2410;
    cos_lut[126] = -16'sd32728; sin_lut[126] = -16'sd1608;
    cos_lut[127] = -16'sd32757; sin_lut[127] = -16'sd804;
end

always_ff @(posedge clk) begin
    cos_out <= cos_lut[addr];
    sin_out <= sin_lut[addr];
end

endmodule

