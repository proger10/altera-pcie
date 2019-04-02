//
// Copyright (C) 2019 Chris McClelland
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
module tlp_recv(
    // Clock, config & interrupt signals
    input logic pcieClk_in,  // 125MHz core clock from PCIe PLL

    // Incoming messages from the CPU
    input tlp_xcvr_pkg::uint64 rxData_in,
    input logic rxValid_in,
    output logic rxReady_out,
    input logic rxSOP_in,
    input logic rxEOP_in,

    // Action FIFO, telling the tlp_send module what to do
    output tlp_xcvr_pkg::Action actData_out,
    output logic actValid_out,

    output tlp_xcvr_pkg::uint64 c2fData_out,
    output logic c2fValid_out
  );

  // Get stuff from the associated package
  import tlp_xcvr_pkg::*;

  // FSM states
  typedef enum {
    S_IDLE,
    S_READ,
    S_WRITE,
    S_CMP1,
    S_CMP2
  } State;
  State state = S_IDLE;
  State state_next;

  // Registers, etc
  BusID reqID = 'X;
  BusID reqID_next;
  Tag tag = 'X;
  Tag tag_next;
  typedef logic[4:0] QWCount;
  QWCount qwCount = 'X;
  QWCount qwCount_next;

  // Typed versions of incoming messages
  Header hdr;
  RdReq0 rr0;
  RdReq1 rr1;
  Write1 rw1;
  Completion0 rc0;
  `ifdef SIMULATION
    Write0 rw0;
    Completion1 rc1;
  `endif

  // Infer registers
  always_ff @(posedge pcieClk_in) begin: infer_regs
    state <= state_next;
    reqID <= reqID_next;
    tag <= tag_next;
    qwCount <= qwCount_next;
  end

  // Receiver FSM processes messages from the root port (e.g CPU writes & read requests)
  always_comb begin: next_state
    // Registers
    state_next = state;
    reqID_next = 'X;
    tag_next = 'X;
    qwCount_next = 'X;

    // Action FIFO
    actData_out = 'X;
    actValid_out = 0;

    // I was born ready...
    rxReady_out = 1;

    // CPU->FPGA DMA pipe
    c2fData_out = 'X;
    c2fValid_out = 0;

    // Typed messages
    hdr = 'X;
    rr0 = 'X;
    rr1 = 'X;
    rw1 = 'X;
    rc0 = 'X;
    `ifdef SIMULATION
      rw0 = 'X;
      rc1 = 'X;
    `endif

    // Next state logic
    case (state)
      // Host is reading
      S_READ: begin
        rr1 = rxData_in;
        actData_out = genRegRead(ExtChan'(rr1.qwAddr), reqID, tag);
        actValid_out = 1;
        state_next = S_IDLE;
      end

      // Host is writing
      S_WRITE: begin
        rw1 = rxData_in;
        actData_out = genRegWrite(ExtChan'(rw1.qwAddr), rw1.data);
        actValid_out = 1;
        state_next = S_IDLE;
      end

      // Host is giving us some DMA data
      S_CMP1: begin
        `ifdef SIMULATION
          rc1 = rxData_in;
        `endif
        qwCount_next = qwCount;
        state_next = S_CMP2;
      end
      S_CMP2: begin
        c2fData_out = rxData_in;
        c2fValid_out = 1;
        qwCount_next = QWCount'(qwCount - 1);
        if (qwCount == 0) begin
          state_next = S_IDLE;
          qwCount_next = 'X;
        end
      end

      // S_IDLE and others
      default: begin
        hdr = rxData_in;
        if (rxValid_in && rxSOP_in) begin
          // We have the first two longwords in a new message...
          if (hdr.fmt == H3DW_WITHDATA && hdr.typ == MEM_RW_REQ) begin
            // The CPU is writing to the FPGA. We'll find out the address and data word
            // on the next cycle.
            `ifdef SIMULATION
              rw0 = rxData_in;
            `endif
            state_next = S_WRITE;
          end else if (hdr.fmt == H3DW_NODATA && hdr.typ == MEM_RW_REQ) begin
            // The CPU is reading from the FPGA; save the msgID. See fig 2-13 in
            // the PCIe spec: the msgID is a 16-bit requester ID and an 8-bit tag.
            // We'll find out the address on the next cycle.
            rr0 = rxData_in;
            reqID_next = rr0.reqID;
            tag_next = rr0.tag;
            state_next = S_READ;
          end else if (hdr.fmt == H3DW_WITHDATA && hdr.typ == COMPLETION) begin
            rc0 = rxData_in;
            qwCount_next = QWCount'(rc0.dwCount/2 - 1);  // FIXME: this assumes the dwCount is always even
            state_next = S_CMP1;
          end
        end
      end
    endcase
  end
endmodule