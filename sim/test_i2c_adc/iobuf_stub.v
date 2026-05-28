// Stub IOBUF for cocotb / iverilog simulation only.
// Models Xilinx IOBUF primitive: T=1 → high-Z, T=0 → drive I to IO.
module IOBUF(inout IO, output O, input I, input T);
    assign IO = T ? 1'bz : I;
    assign O  = IO;
endmodule
