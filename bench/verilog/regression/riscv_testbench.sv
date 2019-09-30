////////////////////////////////////////////////////////////////////////////////
//                                            __ _      _     _               //
//                                           / _(_)    | |   | |              //
//                __ _ _   _  ___  ___ _ __ | |_ _  ___| | __| |              //
//               / _` | | | |/ _ \/ _ \ '_ \|  _| |/ _ \ |/ _` |              //
//              | (_| | |_| |  __/  __/ | | | | | |  __/ | (_| |              //
//               \__, |\__,_|\___|\___|_| |_|_| |_|\___|_|\__,_|              //
//                  | |                                                       //
//                  |_|                                                       //
//                                                                            //
//                                                                            //
//              MPSoC-RISCV CPU                                               //
//              TestBench                                                     //
//              AMBA3 AHB-Lite Bus Interface                                  //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

/* Copyright (c) 2019-2020 by the author(s)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 * =============================================================================
 * Author(s):
 *   Francisco Javier Reina Campo <frareicam@gmail.com>
 */

`include "riscv_mpsoc_pkg.sv"

module riscv_testbench;

  //core parameters
  parameter XLEN               = 64;
  parameter PLEN               = 64;          //64bit address bus
  parameter PC_INIT            = 'h8000_0000; //Start here after reset
  parameter BASE               = PC_INIT;     //offset where to load program in memory
  parameter INIT_FILE          = "test.hex";
  parameter MEM_LATENCY        = 1;
  parameter WRITEBUFFER_SIZE   = 4;
  parameter HAS_U              = 1;
  parameter HAS_S              = 1;
  parameter HAS_H              = 1;
  parameter HAS_MMU            = 1;
  parameter HAS_FPU            = 1;
  parameter HAS_RVA            = 1;
  parameter HAS_RVM            = 1;
  parameter MULT_LATENCY       = 1;

  parameter HTIF               = 0; //Host-interface
  parameter TOHOST             = 32'h80001000;
  parameter UART_TX            = 32'h80001080;

  //caches
  parameter ICACHE_SIZE        = 0;
  parameter DCACHE_SIZE        = 0;

  parameter PMA_CNT            = 4;

  parameter CORES_PER_SIMD     = 8;
  parameter CORES_PER_MISD     = 8;

  //noc parameters
  parameter CHANNELS           = 2;
  parameter PCHANNELS          = 2;
  parameter VCHANNELS          = 2;

  parameter X                  = 2;
  parameter Y                  = 2;
  parameter Z                  = 2;

  parameter CORES_PER_TILE     = CORES_PER_SIMD + CORES_PER_MISD;
  parameter NODES              = X*Y*Z;
  parameter CORES              = NODES*CORES_PER_TILE;

  parameter HADDR_SIZE         = PLEN;
  parameter HDATA_SIZE         = XLEN;
  parameter PADDR_SIZE         = PLEN;
  parameter PDATA_SIZE         = XLEN;

  parameter STDOUT_FILENAME    = "stdout";
  parameter TRACEFILE_FILENAME = "trace";
  parameter ENABLE_TRACE       = 0;
  parameter TERM_CROSS_NUM     = NODES;

  parameter GLIP_WIDTH         = XLEN;
  parameter GLIP_PORT          = 23000;
  parameter GLIP_UART_LIKE     = 0;

  //////////////////////////////////////////////////////////////////
  //
  // Constants
  //

  localparam MULLAT = MULT_LATENCY > 4 ? 4 : MULT_LATENCY;

  localparam MISD_BITS = $clog2(CORES_PER_MISD);
  localparam SIMD_BITS = $clog2(CORES_PER_SIMD);

  //////////////////////////////////////////////////////////////////
  //
  // Functions
  //

  function integer onehot2int_simd;
    input [CORES_PER_SIMD-1:0] onehot;

    for (onehot2int_simd = - 1; |onehot; onehot2int_simd++) onehot = onehot >> 1;
  endfunction //onehot2int_simd

  function [2:0] highest_simd_requested_priority (
    input [CORES_PER_SIMD-1:0] hsel
  );
    logic [CORES_PER_SIMD-1:0][2:0] priorities;
    integer t;
    highest_simd_requested_priority = 0;
    for (t=0; t<CORES_PER_SIMD; t++) begin
      priorities[t] = t;
      if (hsel[t] && priorities[t] > highest_simd_requested_priority) highest_simd_requested_priority = priorities[t];
    end
  endfunction //highest_simd_requested_priority

  function [CORES_PER_SIMD-1:0] requesters_simd;
    input [CORES_PER_SIMD-1:0] hsel;
    input [2:0] priority_select;
    logic [CORES_PER_SIMD-1:0][2:0] priorities;
    integer t;

    for (t=0; t<CORES_PER_SIMD; t++) begin
      priorities      [t] = t;
      requesters_simd [t] = (priorities[t] == priority_select) & hsel[t];
    end
  endfunction //requesters_simd


  function [CORES_PER_SIMD-1:0] nxt_simd_master;
    input [CORES_PER_SIMD-1:0] pending_masters;  //pending masters for the requesed priority level
    input [CORES_PER_SIMD-1:0] last_master;      //last granted master for the priority level
    input [CORES_PER_SIMD-1:0] current_master;   //current granted master (indpendent of priority level)

    integer t, offset;
    logic [CORES_PER_SIMD*2-1:0] sr;

    //default value, don't switch if not needed
    nxt_simd_master = current_master;

    //implement round-robin
    offset = onehot2int_simd(last_master) + 1;

    sr = {pending_masters, pending_masters};
    for (t = 0; t < CORES_PER_SIMD; t++)
      if ( sr[t + offset] ) return (1 << ((t+offset) % CORES_PER_SIMD));
  endfunction

  function integer onehot2int_misd;
    input [CORES_PER_MISD-1:0] onehot;

    for (onehot2int_misd = - 1; |onehot; onehot2int_misd++) onehot = onehot >> 1;
  endfunction //onehot2int_misd


  function [2:0] highest_misd_requested_priority (
    input [CORES_PER_MISD-1:0] hsel
  );
    logic [CORES_PER_MISD-1:0][2:0] priorities;
    integer t;
    highest_misd_requested_priority = 0;
    for (t=0; t<CORES_PER_MISD; t++) begin
      priorities[t] = t;
      if (hsel[t] && priorities[t] > highest_misd_requested_priority) highest_misd_requested_priority = priorities[t];
    end
  endfunction //highest_misd_requested_priority

  function [CORES_PER_MISD-1:0] requesters_misd;
    input [CORES_PER_MISD-1:0] hsel;
    input [2:0] priority_select;
    logic [CORES_PER_MISD-1:0][2:0] priorities;
    integer t;

    for (t=0; t<CORES_PER_MISD; t++) begin
      priorities      [t] = t;
      requesters_misd [t] = (priorities[t] == priority_select) & hsel[t];
    end
  endfunction //requesters_misd

  function [CORES_PER_MISD-1:0] nxt_misd_master;
    input [CORES_PER_MISD-1:0] pending_masters;  //pending masters for the requesed priority level
    input [CORES_PER_MISD-1:0] last_master;      //last granted master for the priority level
    input [CORES_PER_MISD-1:0] current_master;   //current granted master (indpendent of priority level)

    integer t, offset;
    logic [CORES_PER_MISD*2-1:0] sr;

    //default value, don't switch if not needed
    nxt_misd_master = current_master;

    //implement round-robin
    offset = onehot2int_misd(last_master) + 1;

    sr = {pending_masters, pending_masters};
    for (t = 0; t < CORES_PER_MISD; t++)
      if ( sr[t + offset] ) return (1 << ((t+offset) % CORES_PER_MISD));
  endfunction

  //////////////////////////////////////////////////////////////////
  //
  // Variables
  //
  genvar                      i, j, k, t;

  logic                       HCLK,
                              HRESETn;

  logic                       com_misd_rst,
                              logic_misd_rst;

  logic                       com_simd_rst,
                              logic_simd_rst;

  //GLIP host connection
  logic [GLIP_WIDTH     -1:0] glip_misd_in_data;
  logic                       glip_misd_in_valid;
  logic                       glip_misd_in_ready;

  logic [GLIP_WIDTH     -1:0] glip_misd_out_data;
  logic                       glip_misd_out_valid;
  logic                       glip_misd_out_ready;

  logic [GLIP_WIDTH     -1:0] glip_simd_in_data;
  logic                       glip_simd_in_valid;
  logic                       glip_simd_in_ready;

  logic [GLIP_WIDTH     -1:0] glip_simd_out_data;
  logic                       glip_simd_out_valid;
  logic                       glip_simd_out_ready;

  logic [X-1:0][Y-1:0][Z-1:0][XLEN           -1:0] trace_misd_insn;
  logic [X-1:0][Y-1:0][Z-1:0][XLEN           -1:0] trace_misd_pc;
  logic [X-1:0][Y-1:0][Z-1:0]                      trace_misd_jb;
  logic [X-1:0][Y-1:0][Z-1:0]                      trace_misd_jal;
  logic [X-1:0][Y-1:0][Z-1:0]                      trace_misd_jr;
  logic [X-1:0][Y-1:0][Z-1:0][XLEN           -1:0] trace_misd_jbtarget;
  logic [X-1:0][Y-1:0][Z-1:0]                      trace_misd_valid;
  logic [X-1:0][Y-1:0][Z-1:0][XLEN           -1:0] trace_misd_data;
  logic [X-1:0][Y-1:0][Z-1:0][                4:0] trace_misd_addr;
  logic [X-1:0][Y-1:0][Z-1:0]                      trace_misd_we;

  logic [X-1:0][Y-1:0][Z-1:0][XLEN           -1:0] trace_simd_insn;
  logic [X-1:0][Y-1:0][Z-1:0][XLEN           -1:0] trace_simd_pc;
  logic [X-1:0][Y-1:0][Z-1:0]                      trace_simd_jb;
  logic [X-1:0][Y-1:0][Z-1:0]                      trace_simd_jal;
  logic [X-1:0][Y-1:0][Z-1:0]                      trace_simd_jr;
  logic [X-1:0][Y-1:0][Z-1:0][XLEN           -1:0] trace_simd_jbtarget;
  logic [X-1:0][Y-1:0][Z-1:0]                      trace_simd_valid;
  logic [X-1:0][Y-1:0][Z-1:0][XLEN           -1:0] trace_simd_data;
  logic [X-1:0][Y-1:0][Z-1:0][                4:0] trace_simd_addr;
  logic [X-1:0][Y-1:0][Z-1:0]                      trace_simd_we;

  logic [X-1:0][Y-1:0][Z-1:0][XLEN           -1:0] trace_r3_misd;
  logic [X-1:0][Y-1:0][Z-1:0][XLEN           -1:0] trace_r3_simd;

  logic [NODES          -1:0] termination_misd;
  logic [NODES          -1:0] termination_simd;

  //PMA configuration
  logic [PMA_CNT-1:0][    13:0] pma_cfg;
  logic [PMA_CNT-1:0][PLEN-1:0] pma_adr;

  //AHB instruction - Single Port
  logic [X-1:0][Y-1:0][Z-1:0]                      sins_simd_HSEL;
  logic [X-1:0][Y-1:0][Z-1:0][PLEN           -1:0] sins_simd_HADDR;
  logic [X-1:0][Y-1:0][Z-1:0][XLEN           -1:0] sins_simd_HWDATA;
  logic [X-1:0][Y-1:0][Z-1:0][XLEN           -1:0] sins_simd_HRDATA;
  logic [X-1:0][Y-1:0][Z-1:0]                      sins_simd_HWRITE;
  logic [X-1:0][Y-1:0][Z-1:0][                2:0] sins_simd_HSIZE;
  logic [X-1:0][Y-1:0][Z-1:0][                2:0] sins_simd_HBURST;
  logic [X-1:0][Y-1:0][Z-1:0][                3:0] sins_simd_HPROT;
  logic [X-1:0][Y-1:0][Z-1:0][                1:0] sins_simd_HTRANS;
  logic [X-1:0][Y-1:0][Z-1:0]                      sins_simd_HMASTLOCK;
  logic [X-1:0][Y-1:0][Z-1:0]                      sins_simd_HREADY;
  logic [X-1:0][Y-1:0][Z-1:0]                      sins_simd_HRESP;

  //AHB data - Single Port
  logic [X-1:0][Y-1:0][Z-1:0]                      sdat_misd_HSEL;
  logic [X-1:0][Y-1:0][Z-1:0][PLEN           -1:0] sdat_misd_HADDR;
  logic [X-1:0][Y-1:0][Z-1:0][XLEN           -1:0] sdat_misd_HWDATA;
  logic [X-1:0][Y-1:0][Z-1:0][XLEN           -1:0] sdat_misd_HRDATA;
  logic [X-1:0][Y-1:0][Z-1:0]                      sdat_misd_HWRITE;
  logic [X-1:0][Y-1:0][Z-1:0][                2:0] sdat_misd_HSIZE;
  logic [X-1:0][Y-1:0][Z-1:0][                2:0] sdat_misd_HBURST;
  logic [X-1:0][Y-1:0][Z-1:0][                3:0] sdat_misd_HPROT;
  logic [X-1:0][Y-1:0][Z-1:0][                1:0] sdat_misd_HTRANS;
  logic [X-1:0][Y-1:0][Z-1:0]                      sdat_misd_HMASTLOCK;
  logic [X-1:0][Y-1:0][Z-1:0]                      sdat_misd_HREADY;
  logic [X-1:0][Y-1:0][Z-1:0]                      sdat_misd_HRESP;

  //AHB instruction - Multi Port
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                      mins_misd_HSEL;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][PLEN           -1:0] mins_misd_HADDR;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][XLEN           -1:0] mins_misd_HWDATA;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][XLEN           -1:0] mins_misd_HRDATA;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                      mins_misd_HWRITE;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][                2:0] mins_misd_HSIZE;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][                2:0] mins_misd_HBURST;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][                3:0] mins_misd_HPROT;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][                1:0] mins_misd_HTRANS;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                      mins_misd_HMASTLOCK;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                      mins_misd_HREADY;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                      mins_misd_HRESP;

  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                      mins_simd_HSEL;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][PLEN           -1:0] mins_simd_HADDR;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][XLEN           -1:0] mins_simd_HWDATA;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][XLEN           -1:0] mins_simd_HRDATA;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                      mins_simd_HWRITE;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][                2:0] mins_simd_HSIZE;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][                2:0] mins_simd_HBURST;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][                3:0] mins_simd_HPROT;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][                1:0] mins_simd_HTRANS;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                      mins_simd_HMASTLOCK;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                      mins_simd_HREADY;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                      mins_simd_HRESP;

  //AHB data - Multi Port
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                      mdat_misd_HSEL;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][PLEN           -1:0] mdat_misd_HADDR;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][XLEN           -1:0] mdat_misd_HWDATA;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][XLEN           -1:0] mdat_misd_HRDATA;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                      mdat_misd_HWRITE;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][                2:0] mdat_misd_HSIZE;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][                2:0] mdat_misd_HBURST;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][                3:0] mdat_misd_HPROT;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][                1:0] mdat_misd_HTRANS;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                      mdat_misd_HMASTLOCK;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                      mdat_misd_HREADY;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                      mdat_misd_HRESP;

  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                      mdat_simd_HSEL;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][PLEN           -1:0] mdat_simd_HADDR;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][XLEN           -1:0] mdat_simd_HWDATA;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][XLEN           -1:0] mdat_simd_HRDATA;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                      mdat_simd_HWRITE;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][                2:0] mdat_simd_HSIZE;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][                2:0] mdat_simd_HBURST;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][                3:0] mdat_simd_HPROT;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][                1:0] mdat_simd_HTRANS;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                      mdat_simd_HMASTLOCK;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                      mdat_simd_HREADY;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                      mdat_simd_HRESP;

  //Data Model Memory
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0]                      dat_HSEL;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0][PLEN           -1:0] dat_HADDR;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0][XLEN           -1:0] dat_HWDATA;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0][XLEN           -1:0] dat_HRDATA;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0]                      dat_HWRITE;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0][                2:0] dat_HSIZE;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0][                2:0] dat_HBURST;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0][                3:0] dat_HPROT;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0][                1:0] dat_HTRANS;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0]                      dat_HMASTLOCK;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0]                      dat_HREADY;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0]                      dat_HRESP;

  //Debug Interface
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0]                      dbg_bp,
                                                                       dbg_stall,
                                                                       dbg_strb,
                                                                       dbg_ack,
                                                                       dbg_we;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0][PLEN           -1:0] dbg_addr;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0][XLEN           -1:0] dbg_dati,
                                                                       dbg_dato;

  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                      dbg_misd_bp,
                                                                       dbg_misd_stall,
                                                                       dbg_misd_strb,
                                                                       dbg_misd_ack,
                                                                       dbg_misd_we;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][PLEN           -1:0] dbg_misd_addr;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][XLEN           -1:0] dbg_misd_dati,
                                                                       dbg_misd_dato;

  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                      dbg_simd_bp,
                                                                       dbg_simd_stall,
                                                                       dbg_simd_strb,
                                                                       dbg_simd_ack,
                                                                       dbg_simd_we;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][PLEN           -1:0] dbg_simd_addr;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][XLEN           -1:0] dbg_simd_dati,
                                                                       dbg_simd_dato;

  //Interrupts
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                      ext_misd_nmi;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                      ext_misd_tint;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                      ext_misd_sint;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][                3:0] ext_misd_int;

  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                      ext_simd_nmi;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                      ext_simd_tint;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                      ext_simd_sint;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][                3:0] ext_simd_int;

  //GPIO
  logic [X-1:0][Y-1:0][Z-1:0][PDATA_SIZE     -1:0] gpio_misd_i,
                                                   gpio_misd_o,
                                                   gpio_misd_oe;

  logic [X-1:0][Y-1:0][Z-1:0][PDATA_SIZE     -1:0] gpio_simd_i,
                                                   gpio_simd_o,
                                                   gpio_simd_oe;

  //Host Interface
  logic                       host_csr_req,
                              host_csr_ack,
                              host_csr_we;
  logic [XLEN           -1:0] host_csr_tohost,
                              host_csr_fromhost;

  logic [NODES-1:0][XLEN -1:0] dii_out_data;
  logic [NODES-1:0]            dii_out_last;
  logic [NODES-1:0]            dii_out_valid;
  logic [NODES-1:0]            dii_out_ready;

  //Unified memory interface
  logic [1:0][X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0][                1:0] mem_htrans;
  logic [1:0][X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0][                2:0] mem_hburst;
  logic [1:0][X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0]                      mem_hready,
                                                                            mem_hresp;
  logic [1:0][X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0][PLEN           -1:0] mem_haddr;
  logic [1:0][X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0][XLEN           -1:0] mem_hwdata,
                                                                            mem_hrdata;
  logic [1:0][X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0][                2:0] mem_hsize;
  logic [1:0][X-1:0][Y-1:0][Z-1:0][CORES_PER_TILE-1:0]                      mem_hwrite;

  //MISD mux
  logic [X-1:0][Y-1:0][Z-1:0][                2:0] requested_misd_priority_lvl;  //requested priority level
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD -1:0] priority_misd_masters;        //all masters at this priority level

  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD -1:0] pending_misd_master,            //next master waiting to be served
                                                   last_granted_misd_master;       //for requested priority level
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD -1:0] last_granted_misd_masters [3];  //per priority level, for round-robin


  logic [MISD_BITS      -1:0] granted_misd_master_idx     [X][Y][Z],    //granted master as index
                              granted_misd_master_idx_dly [X][Y][Z];    //deleayed granted master index (for HWDATA)

  logic [CORES_PER_MISD -1:0] granted_misd_master         [X][Y][Z];

  //SIMD mux
  logic [                2:0] requested_simd_priority_lvl [X][Y][Z];    //requested priority level
  logic [CORES_PER_SIMD -1:0] priority_simd_masters       [X][Y][Z];    //all masters at this priority level

  logic [CORES_PER_SIMD -1:0] pending_simd_master         [X][Y][Z],    //next master waiting to be served
                              last_granted_simd_master    [X][Y][Z];    //for requested priority level
  logic [CORES_PER_SIMD -1:0] last_granted_simd_masters   [X][Y][Z][3]; //per priority level, for round-robin


  logic [SIMD_BITS      -1:0] granted_simd_master_idx     [X][Y][Z],    //granted master as index
                              granted_simd_master_idx_dly [X][Y][Z];    //deleayed granted master index (for HWDATA)

  logic [CORES_PER_SIMD -1:0] granted_simd_master         [X][Y][Z];


  ////////////////////////////////////////////////////////////////
  //
  // Module Body
  //

  //Define PMA regions

  //crt.0 (ROM) region
  assign pma_adr[0] = TOHOST >> 2;
  assign pma_cfg[0] = {`MEM_TYPE_MAIN, 8'b1111_1000, `AMO_TYPE_NONE, `TOR};

  //TOHOST region
  assign pma_adr[1] = ((TOHOST >> 2) & ~'hf) | 'h7;
  assign pma_cfg[1] = {`MEM_TYPE_IO,   8'b0100_0000, `AMO_TYPE_NONE, `NAPOT};

  //UART-Tx region
  assign pma_adr[2] = UART_TX >> 2;
  assign pma_cfg[2] = {`MEM_TYPE_IO,   8'b0100_0000, `AMO_TYPE_NONE, `NA4};

  //RAM region
  assign pma_adr[3] = 1 << 31;
  assign pma_cfg[3] = {`MEM_TYPE_MAIN, 8'b1111_0000, `AMO_TYPE_NONE, `TOR};

  //Interrupts
  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          assign gpio_misd_i [i][j][k] = 'b0;
          assign gpio_simd_i [i][j][k] = 'b0;
        end
      end
    end
  endgenerate

  //GPIO inputs
  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          for (t=0; t < CORES_PER_MISD; t++) begin
            assign ext_misd_nmi  [i][j][k][t]= 1'b0;
            assign ext_misd_tint [i][j][k][t]= 1'b0;
            assign ext_misd_sint [i][j][k][t]= 1'b0;
            assign ext_misd_int  [i][j][k][t]= 1'b0;
          end

          for (t=0; t < CORES_PER_SIMD; t++) begin
            assign ext_simd_nmi  [i][j][k][t]= 1'b0;
            assign ext_simd_tint [i][j][k][t]= 1'b0;
            assign ext_simd_sint [i][j][k][t]= 1'b0;
            assign ext_simd_int  [i][j][k][t]= 1'b0;
          end
        end
      end
    end
  endgenerate

  //Hookup Device Under Test
  riscv_mpsoc #(
    .XLEN             ( XLEN             ),
    .PLEN             ( PLEN             ), //31bit address bus
    .PC_INIT          ( PC_INIT          ),
    .HAS_USER         ( HAS_U            ),
    .HAS_SUPER        ( HAS_S            ),
    .HAS_HYPER        ( HAS_H            ),
    .HAS_RVA          ( HAS_RVA          ),
    .HAS_RVM          ( HAS_RVM          ),
    .MULT_LATENCY     ( MULLAT           ),

    .PMA_CNT          ( PMA_CNT          ),
    .ICACHE_SIZE      ( ICACHE_SIZE      ),
    .ICACHE_WAYS      ( 1                ),
    .DCACHE_SIZE      ( DCACHE_SIZE      ),
    .DTCM_SIZE        ( 0                ),
    .WRITEBUFFER_SIZE ( WRITEBUFFER_SIZE ),

    .MTVEC_DEFAULT    ( 32'h80000004     ),

    .CORES_PER_SIMD   ( CORES_PER_SIMD   ),
    .CORES_PER_MISD   ( CORES_PER_MISD   ),

    .X                ( X                ),
    .Y                ( Y                ),
    .Z                ( Z                )
  )
  dut (
    .HRESETn   ( HRESETn ),
    .HCLK      ( HCLK    ),

    .pma_cfg_i ( pma_cfg ),
    .pma_adr_i ( pma_adr ),

    .*
  );

  riscv_debug_ring #(
    .XLEN ( XLEN ),
    .CHANNELS ( CHANNELS ),
    .NODES ( NODES )
  )
  debug_ring (
    .rst ( HRESETn ),
    .clk ( HCLK    ),

    .id_map        (),

    .dii_in_data   (),
    .dii_in_last   (),
    .dii_in_valid  (),
    .dii_in_ready  (),

    .dii_out_data  (dii_out_data),
    .dii_out_last  (dii_out_last),
    .dii_out_valid (dii_out_valid),
    .dii_out_ready (dii_out_ready)
  );

  riscv_glip_tcp #(
    .XLEN (XLEN)
  )
  glip_tcp_misd (
    .clk_io    ( HCLK    ),
    .clk_logic ( HCLK    ),
    .rst       ( HRESETn ),

    //GLIP FIFO Interface
    .fifo_in_data   ( glip_misd_in_data  ),
    .fifo_in_valid  ( glip_misd_in_valid ),
    .fifo_in_ready  ( glip_misd_in_ready ),

    .fifo_out_data  ( glip_misd_out_data  ),
    .fifo_out_valid ( glip_misd_out_valid ),
    .fifo_out_ready ( glip_misd_out_ready ),

    //GLIP Control Interface
    .logic_rst ( logic_misd_rst ),
    .com_rst   ( com_misd_rst   )
  );

  riscv_glip_tcp #(
    .XLEN (XLEN)
  )
  glip_tcp_simd (
    .clk_io    ( HCLK    ),
    .clk_logic ( HCLK    ),
    .rst       ( HRESETn ),

    //GLIP FIFO Interface
    .fifo_in_data   ( glip_simd_in_data  ),
    .fifo_in_valid  ( glip_simd_in_valid ),
    .fifo_in_ready  ( glip_simd_in_ready ),

    .fifo_out_data  ( glip_simd_out_data  ),
    .fifo_out_valid ( glip_simd_out_valid ),
    .fifo_out_ready ( glip_simd_out_ready ),

    //GLIP Control Interface
    .logic_rst ( logic_simd_rst ),
    .com_rst   ( com_simd_rst   )
  );

  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          riscv_r3_checker #(
            .XLEN (XLEN)
          )
          r3_checker_misd (
            .clk   ( HCLK),

            .valid ( trace_misd_valid [i][j][k] ),
            .we    ( trace_misd_we    [i][j][k] ),
            .addr  ( trace_misd_addr  [i][j][k] ),
            .data  ( trace_misd_data  [i][j][k] ),
            .r3    ( trace_r3_misd    [i][j][k] )
          );

          riscv_trace_monitor #(
            .XLEN           ( XLEN ),
            .TERM_CROSS_NUM ( NODES ),
            .ID             ( (i-1)*(j-1)*(k-1)-1 )
          )
          trace_monitor_misd (
            .termination     (                            ),
            .termination_all ( termination_misd           ),

            .clk             ( HCLK ),

            .enable          ( trace_misd_valid [i][j][k] ),
            .wb_pc           ( trace_misd_pc    [i][j][k] ),
            .wb_insn         ( trace_misd_insn  [i][j][k] ),
            .r3              ( trace_r3_misd    [i][j][k] )
          );
        end
      end
    end
  endgenerate

  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          riscv_r3_checker #(
            .XLEN (XLEN)
          )
          r3_checker_simd (
            .clk   ( HCLK ),

            .valid ( trace_simd_valid [i][j][k] ),
            .we    ( trace_simd_we    [i][j][k] ),
            .addr  ( trace_simd_addr  [i][j][k] ),
            .data  ( trace_simd_data  [i][j][k] ),
            .r3    ( trace_r3_simd    [i][j][k] )
          );

          riscv_trace_monitor #(
            .XLEN           ( XLEN ),
            .TERM_CROSS_NUM ( NODES ),
            .ID             ( (i-1)*(j-1)*(k-1)-1 )
          )
          trace_monitor_simd (
            .termination     (                            ),
            .termination_all ( termination_simd           ),

            .clk             ( HCLK ),

            .enable          ( trace_simd_valid [i][j][k] ),
            .wb_pc           ( trace_simd_pc    [i][j][k] ),
            .wb_insn         ( trace_simd_insn  [i][j][k] ),
            .r3              ( trace_r3_simd    [i][j][k] )
          );
        end
      end
    end
  endgenerate

  //Hookup Debug Unit
  riscv_dbg_bfm #(
    .XLEN ( XLEN ),
    .PLEN ( PLEN ),

    .X ( X ),
    .Y ( Y ),
    .Z ( Z ),

    .CORES_PER_TILE ( CORES_PER_TILE )
  )
  dbg_ctrl (
    .rstn ( HRESETn ),
    .clk  ( HCLK    ),

    .cpu_bp_i    ( dbg_bp    ),
    .cpu_stall_o ( dbg_stall ),
    .cpu_stb_o   ( dbg_strb  ),
    .cpu_we_o    ( dbg_we    ),
    .cpu_adr_o   ( dbg_addr  ),
    .cpu_dat_o   ( dbg_dati  ),
    .cpu_dat_i   ( dbg_dato  ),
    .cpu_ack_i   ( dbg_ack   )
  );

  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          for (t=0; t < CORES_PER_MISD; t++) begin
            assign dbg_bp    [i][j][k][t] = dbg_misd_bp    [i][j][k][t];
            assign dbg_dato  [i][j][k][t] = dbg_misd_dato  [i][j][k][t];
            assign dbg_ack   [i][j][k][t] = dbg_misd_ack   [i][j][k][t];

            assign dbg_misd_stall [i][j][k][t] = dbg_stall [i][j][k][t];
            assign dbg_misd_strb  [i][j][k][t] = dbg_strb  [i][j][k][t];
            assign dbg_misd_we    [i][j][k][t] = dbg_we    [i][j][k][t];
            assign dbg_misd_addr  [i][j][k][t] = dbg_addr  [i][j][k][t];
            assign dbg_misd_dati  [i][j][k][t] = dbg_dati  [i][j][k][t];
          end

          for (t=0; t < CORES_PER_SIMD; t++) begin
            assign dbg_bp    [i][j][k][t+CORES_PER_MISD] = dbg_simd_bp    [i][j][k][t];
            assign dbg_dato  [i][j][k][t+CORES_PER_MISD] = dbg_simd_dato  [i][j][k][t];
            assign dbg_ack   [i][j][k][t+CORES_PER_MISD] = dbg_simd_ack   [i][j][k][t];

            assign dbg_simd_stall [i][j][k][t+CORES_PER_MISD] = dbg_stall [i][j][k][t];
            assign dbg_simd_strb  [i][j][k][t+CORES_PER_MISD] = dbg_strb  [i][j][k][t];
            assign dbg_simd_we    [i][j][k][t+CORES_PER_MISD] = dbg_we    [i][j][k][t];
            assign dbg_simd_addr  [i][j][k][t+CORES_PER_MISD] = dbg_addr  [i][j][k][t];
            assign dbg_simd_dati  [i][j][k][t+CORES_PER_MISD] = dbg_dati  [i][j][k][t];
          end
        end
      end
    end
  endgenerate

  //bus MISD <-> memory model connections
  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          for (t=0; t < CORES_PER_MISD; t++) begin
            assign mem_htrans [0][i][j][k][t] = mins_misd_HTRANS [i][j][k][t];
            assign mem_hburst [0][i][j][k][t] = mins_misd_HBURST [i][j][k][t];
            assign mem_haddr  [0][i][j][k][t] = mins_misd_HADDR  [i][j][k][t];
            assign mem_hwrite [0][i][j][k][t] = mins_misd_HWRITE [i][j][k][t];
            assign mem_hsize  [0][i][j][k][t] = 'b0;
            assign mem_hwdata [0][i][j][k][t] = 'b0;

            assign mem_htrans [1][i][j][k][t] = mdat_misd_HTRANS [i][j][k][t];
            assign mem_hburst [1][i][j][k][t] = mdat_misd_HBURST [i][j][k][t];
            assign mem_haddr  [1][i][j][k][t] = mdat_misd_HADDR  [i][j][k][t];
            assign mem_hwrite [1][i][j][k][t] = mdat_misd_HWRITE [i][j][k][t];
            assign mem_hsize  [1][i][j][k][t] = mdat_misd_HSIZE  [i][j][k][t];
            assign mem_hwdata [1][i][j][k][t] = mdat_misd_HWDATA [i][j][k][t];
          end
        end
      end
    end
  endgenerate

  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          for (t=0; t < CORES_PER_MISD; t++) begin
            assign mins_misd_HRDATA [i][j][k][t] = mem_hrdata [0][i][j][k][t];
            assign mins_misd_HREADY [i][j][k][t] = mem_hready [0][i][j][k][t];
            assign mins_misd_HRESP  [i][j][k][t] = mem_hresp  [0][i][j][k][t];

            assign mdat_misd_HRDATA [i][j][k][t] = mem_hrdata [1][i][j][k][t];
            assign mdat_misd_HREADY [i][j][k][t] = mem_hready [1][i][j][k][t];
            assign mdat_misd_HRESP  [i][j][k][t] = mem_hresp  [1][i][j][k][t];
          end
        end
      end
    end
  endgenerate

  //bus SIMD <-> memory model connections
  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          for (t=0; t < CORES_PER_SIMD; t++) begin
            assign mem_htrans [0][i][j][k][t+CORES_PER_MISD] = mins_simd_HTRANS [i][j][k][t];
            assign mem_hburst [0][i][j][k][t+CORES_PER_MISD] = mins_simd_HBURST [i][j][k][t];
            assign mem_haddr  [0][i][j][k][t+CORES_PER_MISD] = mins_simd_HADDR  [i][j][k][t];
            assign mem_hwrite [0][i][j][k][t+CORES_PER_MISD] = mins_simd_HWRITE [i][j][k][t];
            assign mem_hsize  [0][i][j][k][t+CORES_PER_MISD] = 'b0;
            assign mem_hwdata [0][i][j][k][t+CORES_PER_MISD] = 'b0;

            assign mem_htrans [1][i][j][k][t+CORES_PER_MISD] = mdat_simd_HTRANS [i][j][k][t];
            assign mem_hburst [1][i][j][k][t+CORES_PER_MISD] = mdat_simd_HBURST [i][j][k][t];
            assign mem_haddr  [1][i][j][k][t+CORES_PER_MISD] = mdat_simd_HADDR  [i][j][k][t];
            assign mem_hwrite [1][i][j][k][t+CORES_PER_MISD] = mdat_simd_HWRITE [i][j][k][t];
            assign mem_hsize  [1][i][j][k][t+CORES_PER_MISD] = mdat_simd_HSIZE  [i][j][k][t];
            assign mem_hwdata [1][i][j][k][t+CORES_PER_MISD] = mdat_simd_HWDATA [i][j][k][t];
          end
        end
      end
    end
  endgenerate

  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          for (t=0; t < CORES_PER_SIMD; t++) begin
            assign mins_simd_HRDATA [i][j][k][t] = mem_hrdata [0][i][j][k][t+CORES_PER_MISD];
            assign mins_simd_HREADY [i][j][k][t] = mem_hready [0][i][j][k][t+CORES_PER_MISD];
            assign mins_simd_HRESP  [i][j][k][t] = mem_hresp  [0][i][j][k][t+CORES_PER_MISD];

            assign mdat_simd_HRDATA [i][j][k][t] = mem_hrdata [1][i][j][k][t+CORES_PER_MISD];
            assign mdat_simd_HREADY [i][j][k][t] = mem_hready [1][i][j][k][t+CORES_PER_MISD];
            assign mdat_simd_HRESP  [i][j][k][t] = mem_hresp  [1][i][j][k][t+CORES_PER_MISD];
          end
        end
      end
    end
  endgenerate

  //Data Model Memory
  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          for (t=0; t < CORES_PER_MISD; t++) begin
            assign dat_HSEL      [i][j][k][t] = mdat_misd_HSEL      [i][j][k][t];
            assign dat_HADDR     [i][j][k][t] = mdat_misd_HADDR     [i][j][k][t];
            assign dat_HWDATA    [i][j][k][t] = mdat_misd_HWDATA    [i][j][k][t];
            assign dat_HRDATA    [i][j][k][t] = mdat_misd_HRDATA    [i][j][k][t];
            assign dat_HWRITE    [i][j][k][t] = mdat_misd_HWRITE    [i][j][k][t];
            assign dat_HSIZE     [i][j][k][t] = mdat_misd_HSIZE     [i][j][k][t];
            assign dat_HBURST    [i][j][k][t] = mdat_misd_HBURST    [i][j][k][t];
            assign dat_HPROT     [i][j][k][t] = mdat_misd_HPROT     [i][j][k][t];
            assign dat_HTRANS    [i][j][k][t] = mdat_misd_HTRANS    [i][j][k][t];
            assign dat_HMASTLOCK [i][j][k][t] = mdat_misd_HMASTLOCK [i][j][k][t];
            assign dat_HREADY    [i][j][k][t] = mdat_misd_HREADY    [i][j][k][t];
            assign dat_HRESP     [i][j][k][t] = mdat_misd_HRESP     [i][j][k][t];
          end

          for (t=0; t < CORES_PER_SIMD; t++) begin
            assign dat_HSEL      [i][j][k][t+CORES_PER_MISD] = mdat_simd_HSEL      [i][j][k][t];
            assign dat_HADDR     [i][j][k][t+CORES_PER_MISD] = mdat_simd_HADDR     [i][j][k][t];
            assign dat_HWDATA    [i][j][k][t+CORES_PER_MISD] = mdat_simd_HWDATA    [i][j][k][t];
            assign dat_HRDATA    [i][j][k][t+CORES_PER_MISD] = mdat_simd_HRDATA    [i][j][k][t];
            assign dat_HWRITE    [i][j][k][t+CORES_PER_MISD] = mdat_simd_HWRITE    [i][j][k][t];
            assign dat_HSIZE     [i][j][k][t+CORES_PER_MISD] = mdat_simd_HSIZE     [i][j][k][t];
            assign dat_HBURST    [i][j][k][t+CORES_PER_MISD] = mdat_simd_HBURST    [i][j][k][t];
            assign dat_HPROT     [i][j][k][t+CORES_PER_MISD] = mdat_simd_HPROT     [i][j][k][t];
            assign dat_HTRANS    [i][j][k][t+CORES_PER_MISD] = mdat_simd_HTRANS    [i][j][k][t];
            assign dat_HMASTLOCK [i][j][k][t+CORES_PER_MISD] = mdat_simd_HMASTLOCK [i][j][k][t];
            assign dat_HREADY    [i][j][k][t+CORES_PER_MISD] = mdat_simd_HREADY    [i][j][k][t];
            assign dat_HRESP     [i][j][k][t+CORES_PER_MISD] = mdat_simd_HRESP     [i][j][k][t];
          end
        end
      end
    end
  endgenerate

  //bus MISD <-> mux
  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          for (t=0; t < CORES_PER_MISD; t++) begin
            assign mdat_misd_HSEL      [i][j][k][t] = sdat_misd_HSEL      [i][j][k];
            assign mdat_misd_HADDR     [i][j][k][t] = sdat_misd_HADDR     [i][j][k];
            assign mdat_misd_HWDATA    [i][j][k][t] = sdat_misd_HWDATA    [i][j][k];
            assign mdat_misd_HWRITE    [i][j][k][t] = sdat_misd_HWRITE    [i][j][k];
            assign mdat_misd_HSIZE     [i][j][k][t] = sdat_misd_HSIZE     [i][j][k];
            assign mdat_misd_HBURST    [i][j][k][t] = sdat_misd_HBURST    [i][j][k];
            assign mdat_misd_HPROT     [i][j][k][t] = sdat_misd_HPROT     [i][j][k];
            assign mdat_misd_HTRANS    [i][j][k][t] = sdat_misd_HTRANS    [i][j][k];
            assign mdat_misd_HMASTLOCK [i][j][k][t] = sdat_misd_HMASTLOCK [i][j][k];
          end
        end
      end
    end
  endgenerate

  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          assign sdat_misd_HRDATA [i][j][k] = mdat_misd_HRDATA [i][j][k][granted_simd_master_idx[i][j][k]];
          assign sdat_misd_HREADY [i][j][k] = mdat_misd_HREADY [i][j][k][granted_simd_master_idx[i][j][k]];
          assign sdat_misd_HRESP  [i][j][k] = mdat_misd_HRESP  [i][j][k][granted_simd_master_idx[i][j][k]];
        end
      end
    end
  endgenerate

  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          //get highest priority from selected masters
          assign requested_misd_priority_lvl[i][j][k] = highest_misd_requested_priority(mdat_misd_HSEL[i][j][k]);

          //get pending masters for the highest priority requested
          assign priority_misd_masters[i][j][k] = requesters_misd(mdat_misd_HSEL[i][j][k], requested_misd_priority_lvl[i][j][k]);

          //get last granted master for the priority requested
          assign last_granted_misd_master[i][j][k] = last_granted_misd_masters[i][j][k][requested_misd_priority_lvl[i][j][k]];

          //get next master to serve
          assign pending_misd_master[i][j][k] = nxt_misd_master(priority_misd_masters[i][j][k], last_granted_misd_master[i][j][k], granted_misd_master[i][j][k]);

          //select new master
          always @(posedge HCLK, negedge HRESETn) begin
            if      ( !HRESETn                 ) granted_misd_master[i][j][k] <= 'h1;
            else if ( !sdat_misd_HSEL[i][j][k] ) granted_misd_master[i][j][k] <= pending_misd_master[i][j][k];
          end

          //store current master (for this priority level)
          always @(posedge HCLK, negedge HRESETn) begin
            if      ( !HRESETn                 ) last_granted_misd_masters[i][j][k][requested_misd_priority_lvl[i][j][k]] <= 'h1;
            else if ( !sdat_misd_HSEL[i][j][k] ) last_granted_misd_masters[i][j][k][requested_misd_priority_lvl[i][j][k]] <= pending_misd_master[i][j][k];
          end

          //get signals from current requester
          always @(posedge HCLK, negedge HRESETn) begin
            if      ( !HRESETn                 ) granted_misd_master_idx[i][j][k] <= 'h0;
            else if ( !sdat_misd_HSEL[i][j][k] ) granted_misd_master_idx[i][j][k] <= onehot2int_misd(pending_misd_master[i][j][k]);
          end
        end
      end
    end
  endgenerate

  //bus SIMD <-> mux
  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          for (t=0; t < CORES_PER_SIMD; t++) begin
            assign mins_simd_HSEL      [i][j][k][t] = sins_simd_HSEL      [i][j][k];
            assign mins_simd_HADDR     [i][j][k][t] = sins_simd_HADDR     [i][j][k];
            assign mins_simd_HWDATA    [i][j][k][t] = sins_simd_HWDATA    [i][j][k];
            assign mins_simd_HWRITE    [i][j][k][t] = sins_simd_HWRITE    [i][j][k];
            assign mins_simd_HSIZE     [i][j][k][t] = sins_simd_HSIZE     [i][j][k];
            assign mins_simd_HBURST    [i][j][k][t] = sins_simd_HBURST    [i][j][k];
            assign mins_simd_HPROT     [i][j][k][t] = sins_simd_HPROT     [i][j][k];
            assign mins_simd_HTRANS    [i][j][k][t] = sins_simd_HTRANS    [i][j][k];
            assign mins_simd_HMASTLOCK [i][j][k][t] = sins_simd_HMASTLOCK [i][j][k];
          end
        end
      end
    end
  endgenerate

  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          assign sins_simd_HRDATA [i][j][k] = mins_simd_HRDATA [i][j][k][granted_simd_master_idx[i][j][k]];
          assign sins_simd_HREADY [i][j][k] = mins_simd_HREADY [i][j][k][granted_simd_master_idx[i][j][k]];
          assign sins_simd_HRESP  [i][j][k] = mins_simd_HRESP  [i][j][k][granted_simd_master_idx[i][j][k]];
        end
      end
    end
  endgenerate

  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          //get highest priority from selected masters
          assign requested_simd_priority_lvl[i][j][k] = highest_simd_requested_priority(mins_simd_HSEL[i][j][k]);

          //get pending masters for the highest priority requested
          assign priority_simd_masters[i][j][k] = requesters_simd(mins_simd_HSEL[i][j][k], requested_simd_priority_lvl[i][j][k]);

          //get last granted master for the priority requested
          assign last_granted_simd_master[i][j][k] = last_granted_simd_masters[i][j][k][requested_simd_priority_lvl[i][j][k]];

          //get next master to serve
          assign pending_simd_master[i][j][k] = nxt_simd_master(priority_simd_masters[i][j][k], last_granted_simd_master[i][j][k], granted_simd_master[i][j][k]);

          //select new master
          always @(posedge HCLK, negedge HRESETn) begin
            if      ( !HRESETn                 ) granted_simd_master[i][j][k] <= 'h1;
            else if ( !sins_simd_HSEL[i][j][k] ) granted_simd_master[i][j][k] <= pending_simd_master[i][j][k];
          end

          //store current master (for this priority level)
          always @(posedge HCLK, negedge HRESETn) begin
            if      ( !HRESETn                 ) last_granted_simd_masters[i][j][k][requested_simd_priority_lvl[i][j][k]] <= 'h1;
            else if ( !sins_simd_HSEL[i][j][k] ) last_granted_simd_masters[i][j][k][requested_simd_priority_lvl[i][j][k]] <= pending_simd_master[i][j][k];
          end

          //get signals from current requester
          always @(posedge HCLK, negedge HRESETn) begin
            if      ( !HRESETn                 ) granted_simd_master_idx[i][j][k] <= 'h0;
            else if ( !sins_simd_HSEL[i][j][k] ) granted_simd_master_idx[i][j][k] <= onehot2int_simd(pending_simd_master[i][j][k]);
          end
        end
      end
    end
  endgenerate

  //hookup memory model
  riscv_memory_model #(
    .XLEN ( XLEN ),
    .PLEN ( PLEN ),

    .BASE ( BASE ),

    .MEM_LATENCY ( MEM_LATENCY ),

    .LATENCY ( 1 ),
    .BURST   ( 8 ),

    .INIT_FILE ( INIT_FILE ),

    .X ( X ),
    .Y ( Y ),
    .Z ( Z ),

    .CORES_PER_TILE ( CORES_PER_TILE )
  )
  unified_memory (
    .HRESETn ( HRESETn   ),
    .HCLK   ( HCLK       ),
    .HTRANS ( mem_htrans ),
    .HREADY ( mem_hready ),
    .HRESP  ( mem_hresp  ),
    .HADDR  ( mem_haddr  ),
    .HWRITE ( mem_hwrite ),
    .HSIZE  ( mem_hsize  ),
    .HBURST ( mem_hburst ),
    .HWDATA ( mem_hwdata ),
    .HRDATA ( mem_hrdata )
  );

  //Front-End Server
  generate
    if (HTIF) begin
      //Old HTIF interface
      riscv_htif #(XLEN)
      htif_frontend (
        .rstn              ( HRESETn           ),
        .clk               ( HCLK              ),
        .host_csr_req      ( host_csr_req      ),
        .host_csr_ack      ( host_csr_ack      ),
        .host_csr_we       ( host_csr_we       ),
        .host_csr_tohost   ( host_csr_tohost   ),
        .host_csr_fromhost ( host_csr_fromhost )
      );
    end
    else begin
      //New MMIO interface
      riscv_mmio_if #(
        XLEN, PLEN, TOHOST, UART_TX, X, Y, Z, CORES_PER_TILE
      )
      mmio_if (
        .HRESETn   ( HRESETn    ),
        .HCLK      ( HCLK       ),
        .HTRANS    ( dat_HTRANS ),
        .HWRITE    ( dat_HWRITE ),
        .HSIZE     ( dat_HSIZE  ),
        .HBURST    ( dat_HBURST ),
        .HADDR     ( dat_HADDR  ),
        .HWDATA    ( dat_HWDATA ),
        .HRDATA    (            ),
        .HREADYOUT (            ),
        .HRESP     (            )
      );
    end
  endgenerate

  //Generate clock
  always #1 HCLK = ~HCLK;

  initial begin
    $display("\n");
    $display ("                                                                                                         ");
    $display ("                                                                                                         ");
    $display ("                                                              ***                     ***          **    ");
    $display ("                                                            ** ***    *                ***          **   ");
    $display ("                                                           **   ***  ***                **          **   ");
    $display ("                                                           **         *                 **          **   ");
    $display ("    ****    **   ****                                      **                           **          **   ");
    $display ("   * ***  *  **    ***  *    ***       ***    ***  ****    ******   ***        ***      **      *** **   ");
    $display ("  *   ****   **     ****    * ***     * ***    **** **** * *****     ***      * ***     **     ********* ");
    $display (" **    **    **      **    *   ***   *   ***    **   ****  **         **     *   ***    **    **   ****  ");
    $display (" **    **    **      **   **    *** **    ***   **    **   **         **    **    ***   **    **    **   ");
    $display (" **    **    **      **   ********  ********    **    **   **         **    ********    **    **    **   ");
    $display (" **    **    **      **   *******   *******     **    **   **         **    *******     **    **    **   ");
    $display (" **    **    **      **   **        **          **    **   **         **    **          **    **    **   ");
    $display ("  *******     ******* **  ****    * ****    *   **    **   **         **    ****    *   **    **    **   ");
    $display ("   ******      *****   **  *******   *******    ***   ***  **         *** *  *******    *** *  *****     ");
    $display ("       **                   *****     *****      ***   ***  **         ***    *****      ***    ***      ");
    $display ("       **                                                                                                ");
    $display ("       **                                                                                                ");
    $display ("        **                                                                                               ");
    $display ("- RISC-V Regression TestBench ---------------------------------------------------------------------------");
    $display ("  XLEN | PRIV | MMU | FPU | RVA | RVM | MULLAT");
    $display ("  %4d | M%C%C%C | %3d | %3d | %3d | %3d | %6d", 
              XLEN, HAS_H > 0 ? "H" : " ", HAS_S > 0 ? "S" : " ", HAS_U > 0 ? "U" : " ",
              HAS_MMU, HAS_FPU, HAS_RVA, HAS_RVM, MULLAT);
    $display ("------------------------------------------------------------------------------");
    $display ("  CORES | NODES | X | Y | Z | CORES_PER_TILE | CORES_PER_MISD | CORES_PER_SIMD");
    $display ("  %5d | %5d | %1d | %1d | %1d | %14d | %14d | %14d   ", 
              CORES, NODES, X, Y, Z, CORES_PER_TILE, CORES_PER_MISD, CORES_PER_SIMD);
    $display ("------------------------------------------------------------------------------");
    $display ("  Test   = %s", INIT_FILE);
    $display ("  ICache = %0dkB", ICACHE_SIZE);
    $display ("  DCache = %0dkB", DCACHE_SIZE);
    $display ("------------------------------------------------------------------------------");
  end

  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          for (t=0; t < CORES_PER_TILE; t++) begin
            initial begin

              `ifdef WAVES
              $shm_open("waves");
              $shm_probe("AS",riscv_testbench,"AS");
              $display("INFO: Signal dump enabled ...\n");
              `endif

              //unified_memory.read_elf2hex(INIT_FILE);
              unified_memory.read_ihex(INIT_FILE);
              //unified_memory.dump;

              HCLK  = 'b0;

              HRESETn = 'b1;
              repeat (5) @(negedge HCLK);
              HRESETn = 'b0;
              repeat (5) @(negedge HCLK);
              HRESETn = 'b1;

              #112;
              //stall CPU
              dbg_ctrl.stall;

              //Enable BREAKPOINT to call external debugger
              //dbg_ctrl.write('h0004,'h0008);

              //Enable Single Stepping
              dbg_ctrl.write('h0000,'h0001);

              //single step through 10 instructions
              repeat (100) begin
                while (!dbg_ctrl.stall_cpu[i][j][k][t]) @(posedge HCLK);
                repeat(15) @(posedge HCLK);
                dbg_ctrl.write('h0001,'h0000); //clear single-step-hit
                dbg_ctrl.unstall;
              end

              //last time ...
              @(posedge HCLK);
              while (!dbg_ctrl.stall_cpu[i][j][k][t]) @(posedge HCLK);
              //disable Single Stepping
              dbg_ctrl.write('h0000,'h0000);
              dbg_ctrl.write('h0001,'h0000);
              dbg_ctrl.unstall;
            end
          end
        end
      end
    end
  endgenerate
endmodule

//MMIO Interface
module riscv_mmio_if #(
  parameter HDATA_SIZE    = 32,
  parameter HADDR_SIZE    = 32,
  parameter CATCH_TEST    = 80001000,
  parameter CATCH_UART_TX = 80001080,
  parameter X             = 8,
  parameter Y             = 8,
  parameter Z             = 8,
  parameter PORTS         = 8
)
  (
    input                       HRESETn,
    input                       HCLK,

    input      [X-1:0][Y-1:0][Z-1:0][PORTS-1:0][           1:0] HTRANS,
    input      [X-1:0][Y-1:0][Z-1:0][PORTS-1:0][HADDR_SIZE-1:0] HADDR,
    input      [X-1:0][Y-1:0][Z-1:0][PORTS-1:0]                 HWRITE,
    input      [X-1:0][Y-1:0][Z-1:0][PORTS-1:0][           2:0] HSIZE,
    input      [X-1:0][Y-1:0][Z-1:0][PORTS-1:0][           2:0] HBURST,
    input      [X-1:0][Y-1:0][Z-1:0][PORTS-1:0][HDATA_SIZE-1:0] HWDATA,
    output reg [X-1:0][Y-1:0][Z-1:0][PORTS-1:0][HDATA_SIZE-1:0] HRDATA,

    output reg [X-1:0][Y-1:0][Z-1:0][PORTS-1:0]                 HREADYOUT,
    output     [X-1:0][Y-1:0][Z-1:0][PORTS-1:0]                 HRESP
  );

  // Variables
  logic [X-1:0][Y-1:0][Z-1:0][PORTS-1:0][HDATA_SIZE-1:0] data_reg;
  logic [X-1:0][Y-1:0][Z-1:0][PORTS-1:0]                 catch_test,
                                                         catch_uart_tx;

  logic [X-1:0][Y-1:0][Z-1:0][PORTS-1:0][           1:0] dHTRANS;
  logic [X-1:0][Y-1:0][Z-1:0][PORTS-1:0][HADDR_SIZE-1:0] dHADDR;
  logic [X-1:0][Y-1:0][Z-1:0][PORTS-1:0]                 dHWRITE;

  // Functions
  function string hostcode_to_string;
    input integer hostcode;

    case (hostcode)
      1337: hostcode_to_string = "OTHER EXCEPTION";
    endcase
  endfunction

  // Module body
  genvar i, j, k, p;
  //Generate watchdog counter
  integer watchdog_cnt;
  always @(posedge HCLK,negedge HRESETn) begin
    if (!HRESETn) watchdog_cnt <= 0;
    else          watchdog_cnt <= watchdog_cnt + 1;
  end

  generate
    for (i=0; i < X; i++) begin
      for (j=0; j < Y; j++) begin
        for (k=0; k < Z; k++) begin
          for (p=0; p < PORTS; p++) begin
            //Catch write to host address
            assign HRESP[i][j][k][p] = `HRESP_OKAY;

            always @(posedge HCLK) begin
              dHTRANS <= HTRANS;
              dHADDR  <= HADDR;
              dHWRITE <= HWRITE;
            end

            always @(posedge HCLK,negedge HRESETn) begin
              if (!HRESETn) begin
                HREADYOUT[i][j][k][p] <= 1'b1;
              end
              else if (HTRANS[i][j][k][p] == `HTRANS_IDLE) begin
              end
            end

            always @(posedge HCLK,negedge HRESETn) begin
              if (!HRESETn) begin
                catch_test    [i][j][k][p] <= 1'b0;
                catch_uart_tx [i][j][k][p] <= 1'b0;
              end
              else begin
                catch_test    [i][j][k][p] <= dHTRANS[i][j][k][p] == `HTRANS_NONSEQ && dHWRITE[i][j][k][p] && dHADDR[i][j][k][p] == CATCH_TEST;
                catch_uart_tx [i][j][k][p] <= dHTRANS[i][j][k][p] == `HTRANS_NONSEQ && dHWRITE[i][j][k][p] && dHADDR[i][j][k][p] == CATCH_UART_TX;
                data_reg      [i][j][k][p] <= HWDATA [i][j][k][p];
              end
            end
            //Generate output

            //Simulated UART Tx (prints characters on screen)
            always @(posedge HCLK) begin
              if (catch_uart_tx[i][j][k][p]) $write ("%0c", data_reg[i][j][k][p]);
            end
            //Tests ...
            always @(posedge HCLK) begin
              if (watchdog_cnt > 1000_000 || catch_test[i][j][k][p]) begin
                $display("\n");
                $display("-------------------------------------------------------------");
                $display("* RISC-V test bench finished");
                if (data_reg[i][j][k][p][0] == 1'b1) begin
                  if (~|data_reg[i][j][k][p][HDATA_SIZE-1:1])
                    $display("* PASSED %0d", data_reg[i][j][k][p]);
                  else
                    $display ("* FAILED: code: 0x%h (%0d: %s)", data_reg[i][j][k][p] >> 1, data_reg[i][j][k][p] >> 1, hostcode_to_string(data_reg[i][j][k][p] >> 1) );
                end
                else
                  $display ("* FAILED: watchdog count reached (%0d) @%0t", watchdog_cnt, $time);
                $display("-------------------------------------------------------------");
                $display("\n");

                $finish();
              end
            end
          end
        end
      end
    end
  endgenerate
endmodule

//HTIF Interface
module riscv_htif #(
  parameter XLEN=32
)
  (
    input             rstn,
    input             clk,

    output            host_csr_req,
    input             host_csr_ack,
    output            host_csr_we,
    input  [XLEN-1:0] host_csr_tohost,
    output [XLEN-1:0] host_csr_fromhost
  );
  function string hostcode_to_string;
    input integer hostcode;

    case (hostcode)
      1337: hostcode_to_string = "OTHER EXCEPTION";
    endcase
  endfunction

  //Generate watchdog counter
  integer watchdog_cnt;
  always @(posedge clk,negedge rstn) begin
    if (!rstn) watchdog_cnt <= 0;
    else       watchdog_cnt <= watchdog_cnt + 1;
  end

  always @(posedge clk) begin
    if (watchdog_cnt > 200_000 || host_csr_tohost[0] == 1'b1) begin
      $display("\n");
      $display("*****************************************************");
      $display("* RISC-V test bench finished");
      if (host_csr_tohost[0] == 1'b1) begin
        if (~|host_csr_tohost[XLEN-1:1])
          $display("* PASSED %0d", host_csr_tohost);
        else
          $display ("* FAILED: code: 0x%h (%0d: %s)", host_csr_tohost >> 1, host_csr_tohost >> 1, hostcode_to_string(host_csr_tohost >> 1) );
      end
      else
        $display ("* FAILED: watchdog count reached (%0d) @%0t", watchdog_cnt, $time);
      $display("*****************************************************");
      $display("\n");

      $finish();
    end
  end
endmodule
