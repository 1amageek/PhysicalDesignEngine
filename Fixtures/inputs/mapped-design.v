// Geometry-smoke fixture cells; no foundry or timing claim.
module NAND2_X1(); endmodule
module BUF_X1(); endmodule
module fixture_top();
  NAND2_X1 U1();
  BUF_X1 U2();
endmodule
