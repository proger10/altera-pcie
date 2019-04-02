//
// Copyright (C) 2014, 2017, 2019 Chris McClelland
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software
// and associated documentation files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright  notice and this permission notice  shall be included in all copies or
// substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
// BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
`timescale 1ps / 1ps

module tlp_xcvr_tb;

  import tlp_xcvr_pkg::*;

  localparam int CLK_PERIOD = 10;
  logic sysClk, dispClk;
  BusID cfgBusDev;

  // Incoming messages from the CPU
  uint64 rxData;
  logic rxValid;
  logic rxReady;
  logic rxSOP;
  logic rxEOP;

  // Outgoing messages to the CPU
  uint64 txData;
  logic txValid;
  logic txReady;
  logic txSOP;
  logic txEOP;

  // Internal read/write interface
  Channel cpuChan;
  Data cpuWrData;
  logic cpuWrValid;
  logic cpuWrReady;
  Data cpuRdData;
  logic cpuRdValid;
  logic cpuRdReady;

  // 64-bit RNG as FPGA->CPU DMA data-source
  uint64 f2cData;
  uint64 f2cDataX;
  logic f2cValid;
  logic f2cReady;
  logic f2cReset;
  assign f2cDataX = (f2cValid && f2cReady) ? f2cData : 'X;

  // Register array
  Data[0:2**CHAN_WIDTH-1] regArray = '0;
  Data[0:2**CHAN_WIDTH-1] regArray_next;

  // PCIe bus IDs
  localparam BusID CPU_ID = 13'h1CCC;
  localparam BusID FPGA_ID = 13'h1FFF;
  localparam QWAddr F2CBASE_VALUE = 29'h1BADCAFE;
  localparam QWAddr C2FBASE_VALUE = 29'h1F00C0DE;

  // Instantiate transciever
  tlp_xcvr uut(
    sysClk, cfgBusDev,
    rxData, rxValid, rxReady, rxSOP, rxEOP,  // CPU->FPGA messages
    txData, txValid, txReady, txSOP, txEOP,  // FPGA->CPU messages
    cpuChan,                                 // register address
    cpuWrData, cpuWrValid, cpuWrReady,       // register write pipe
    cpuRdData, cpuRdValid, cpuRdReady,       // register read pipe
    f2cData, f2cValid, f2cReady, f2cReset    // FPGA->CPU DMA pipe
  );

  // Instantiate 64-bit random-number generator, as FPGA->CPU DMA data-source
  dvr_rng64 rng(
    .clk_in    (sysClk),
    .reset_in  (f2cReset),
    .data_out  (f2cData),
    .valid_out (f2cValid),
    .ready_in  (f2cReady)
  );

  initial begin: sysClk_drv
    sysClk = 0;
    #(5000*CLK_PERIOD/8)
    forever #(1000*CLK_PERIOD/2) sysClk = ~sysClk;
  end

  initial begin: dispClk_drv
    dispClk = 0;
    #(1000*CLK_PERIOD/2)
    forever #(1000*CLK_PERIOD/2) dispClk = ~dispClk;
  end

  task tick(int n);
    for (int i = 0; i < n; i = i + 1)
      @(posedge sysClk);
  endtask

  task doWrite(ExtChan chan, Data val, int ticks = 3);
    rxData = genRegWrite0(.reqID(CPU_ID));
    rxValid = 1;
    rxSOP = 1;
    @(posedge sysClk);
    rxData = genRegWrite1(.qwAddr('h40000 + chan), .data(val));
    rxSOP = 0;
    rxEOP = 1;
    @(posedge sysClk);
    rxData = 'X;
    rxValid = 0;
    rxEOP = 0;
    tick(ticks);
  endtask

  task doDmaRdCmp(int startIndex);
    rxData = genDmaCmp0(.cmpID(CPU_ID), .dwCount(32));
    rxValid = 1;
    rxSOP = 1;
    @(posedge sysClk);
    rxSOP = 0;
    rxData = genDmaCmp1(.reqID(FPGA_ID), .tag('h0C), .lowAddr(0));
    for (int i = 0; i < 16; i = i + 1) begin
      @(posedge sysClk);
      rxData = dvr_rng_pkg::SEQ64[startIndex+i];
    end
    rxEOP = 1;
    @(posedge sysClk);
    rxEOP = 0;
    rxValid = 0;
    tick(5);
  endtask

  function string assertString(logic b);
    return b ? "asserted" : "deasserted";
  endfunction

  task expectTX(uint64 data, uint64 mask, logic valid, logic sop, logic eop);
    @(posedge dispClk);
    if (txValid != valid) begin
      $display("\nFAILURE [%0dns]: Expected txValid to be %s", $time()/1000, assertString(valid)); tick(4); $stop(1);
    end
    if (txSOP != sop) begin
      $display("\nFAILURE [%0dns]: Expected txSOP to be ", $time()/1000, assertString(sop)); tick(4); $stop(1);
    end
    if (txEOP != eop) begin
      $display("\nFAILURE [%0dns]: Expected txEOP to be ", $time()/1000, assertString(eop)); tick(4); $stop(1);
    end
    if ((txData & mask) != data) begin
      $display("\nFAILURE [%0dns]: Expected txData to be %H, actually got %H", $time()/1000, data, txData & mask); tick(4); $stop(1);
    end
  endtask

  task doRead(ExtChan chan, output Data readData);
    rxData = genRegRdReq0(.reqID(CPU_ID));
    rxValid = 1;
    rxSOP = 1;
    @(posedge sysClk);

    rxData = genRegRdReq1(.qwAddr('h40000 + chan));
    rxSOP = 0;
    rxEOP = 1;
    @(posedge sysClk);

    rxData = 'X;
    rxValid = 0;
    rxEOP = 0;

    expectTX(genRegCmp0(.cmpID(FPGA_ID)), '1, 1, 1, 0);
    expectTX(genRegCmp1(.data(0), .reqID(CPU_ID), .tag(0), .lowAddr(LowAddr'(chan))), 64'hFFFFFFFF, 1, 0, 1);
    readData = Data'(txData >> 32);
    tick(3);
  endtask

  // Infer registers
  always_ff @(posedge sysClk) begin: infer_regs
    regArray <= regArray_next;
  end

  // Connect registers to PCIe register interface
  always_comb begin: next_state
    cpuRdData = regArray[cpuChan];
    cpuRdValid = 1;  // always ready to supply data
    cpuWrReady = 1;  // always ready to receive data
    regArray_next = regArray;
    if (cpuWrValid)
      regArray_next[cpuChan] = cpuWrData;
  end

  // Main test
  initial begin: main
    Data readValue;
    int tlp, qw;
    rxData = 'X;
    rxValid = 0;
    rxSOP = 0;
    rxEOP = 0;
    txReady = 1;
    cfgBusDev = FPGA_ID;

    // The TLP message-types must all be 64-bits wide
    if ($size(Header) != 64) begin
      $display("\nFAILURE: tlp_xcvr_pkg::Header has an illegal width (%0d)", $size(Header)); $stop(1);
    end

    if ($size(Write0) != 64) begin
      $display("\nFAILURE: tlp_xcvr_pkg::Write0 has an illegal width (%0d)", $size(Write0)); $stop(1);
    end
    if ($size(Write1) != 64) begin
      $display("\nFAILURE: tlp_xcvr_pkg::Write1 has an illegal width (%0d)", $size(Write1)); $stop(1);
    end

    if ($size(RdReq0) != 64) begin
      $display("\nFAILURE: tlp_xcvr_pkg::RdReq0 has an illegal width (%0d)", $size(RdReq0)); $stop(1);
    end
    if ($size(RdReq1) != 64) begin
      $display("\nFAILURE: tlp_xcvr_pkg::RdReq1 has an illegal width (%0d)", $size(RdReq1)); $stop(1);
    end

    if ($size(Completion0) != 64) begin
      $display("\nFAILURE: tlp_xcvr_pkg::Completion0 has an illegal width (%0d)", $size(Completion0)); $stop(1);
    end
    if ($size(Completion1) != 64) begin
      $display("\nFAILURE: tlp_xcvr_pkg::Completion1 has an illegal width (%0d)", $size(Completion1)); $stop(1);
    end

    // The Action message-types must all be ACTION_BITS wide
    if ($size(RegRead) != ACTION_BITS) begin
      $display("\nFAILURE: tlp_xcvr_pkg::RegRead has an illegal width (%0d)", $size(RegRead)); $stop(1);
    end
    if ($size(RegWrite) != ACTION_BITS) begin
      $display("\nFAILURE: tlp_xcvr_pkg::RegWrite has an illegal width (%0d)", $size(RegWrite)); $stop(1);
    end

    // Register readback test
    $display("\nRegister readback test:");
    for (int i = 0; i < CTL_BASE; i = i + 1)
      doWrite(i, dvr_rng_pkg::SEQ32[i]);
    for (int i = 0; i < CTL_BASE; i = i + 1) begin
      doRead(i, readValue);
      if (readValue !== dvr_rng_pkg::SEQ32[i]) begin
        $display("\nFAILURE [%0dns]: Expected doRead(%0d) to return %H; actually got %H", $time()/1000, i, dvr_rng_pkg::SEQ32[i], readValue); tick(4); $stop(1);
      end
      $display("  doRead(%0d) -> %H", i, readValue);
    end
    for (int i = CTL_BASE; i < 2*CTL_BASE; i = i + 1) begin
      doRead(i, readValue);
      if (readValue !== 32'hDEADBEEF) begin
        $display("\nFAILURE [%0dns]: Expected doRead(%0d) to return DEADDEAD; actually got %H", $time()/1000, i, readValue); tick(4); $stop(1);
      end
      $display("  doRead(%0d) -> %H", i, readValue);
    end

    // DMA write test
    $display("\nDMA write test:");
    doWrite(DMA_ENABLE, 0, 2);
    if (uut.send.f2cEnabled !== 0) begin
      $display("\nFAILURE [%0dns]: Expected f2cEnabled to be deasserted", $time()/1000); tick(4); $stop(1);
    end
    doWrite(F2C_BASE, F2CBASE_VALUE, 2);
    if (uut.send.f2cBase !== F2CBASE_VALUE) begin
      $display("\nFAILURE [%0dns]: Expected DMA_BASE to be %H; actually got %H", $time()/1000, F2CBASE_VALUE, uut.send.f2cBase); tick(4); $stop(1);
    end
    doWrite(DMA_ENABLE, 1, 2);
    if (uut.send.f2cEnabled !== 1) begin
      $display("\nFAILURE [%0dns]: Expected f2cEnabled to be asserted", $time()/1000); tick(4); $stop(1);
    end

    // Wait for DMA writes to start
    @(posedge uut.f2cValid_in);

    // We should get 15 TLPs (0-14) in quick succession
    for (tlp = 0; tlp < 15; tlp = tlp + 1) begin
      // Verify packet header
      expectTX({FPGA_ID, 48'h00FF40000020}, '1, 1, 1, 0);
      expectTX(8*F2CBASE_VALUE + tlp*128, '1, 1, 0, 0);

      // Verify data
      for (qw = 0; qw < 15; qw = qw + 1)
        expectTX(dvr_rng_pkg::SEQ64[tlp*16+qw], '1, 1, 0, 0);
      expectTX(dvr_rng_pkg::SEQ64[tlp*16+qw], '1, 1, 0, 1);

      // Verify wrPtr send
      expectTX({FPGA_ID, 48'h00FF40000002}, '1, 1, 1, 0);
      expectTX(8*F2CBASE_VALUE + 16*128, '1, 1, 0, 0);
      expectTX(tlp+1, '1, 1, 0, 1);
      $display("  Verified TLP %0d", tlp);
    end

    // Acknowledge consumption of first TLP, allowing FPGA to overwrite it
    tick(4);
    doWrite(F2C_RDPTR, 1, 1);

    // Verify TLP 15
    expectTX({FPGA_ID, 48'h00FF40000020}, '1, 1, 1, 0);
    expectTX(8*F2CBASE_VALUE + tlp*128, '1, 1, 0, 0);

    for (qw = 0; qw < 15; qw = qw + 1)
      expectTX(dvr_rng_pkg::SEQ64[tlp*16+qw], '1, 1, 0, 0);
    expectTX(dvr_rng_pkg::SEQ64[tlp*16+qw], '1, 1, 0, 1);

    expectTX({FPGA_ID, 48'h00FF40000002}, '1, 1, 1, 0);
    expectTX(8*F2CBASE_VALUE + 16*128, '1, 1, 0, 0);
    expectTX(0, '1, 1, 0, 1);
    $display("  Verified TLP %0d", tlp);

    tick(8);
    doWrite(C2F_WRPTR, 1);


    tick(20);
    doDmaRdCmp(0);

    tick(300);
    $display("\nSUCCESS: Simulation stopped due to successful completion!");
    $stop(0);
  end
endmodule