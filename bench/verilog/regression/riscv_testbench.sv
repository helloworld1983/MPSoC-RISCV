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

  parameter CORES_PER_SIMD     = 4;
  parameter CORES_PER_MISD     = 4;

  //noc parameters
  parameter CHANNELS           = 7;
  parameter PCHANNELS          = 1;
  parameter VCHANNELS          = 7;

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

  parameter ADDR_WIDTH     = 32;
  parameter DATA_WIDTH     = 32;
  parameter CPU_ADDR_WIDTH = 32;
  parameter CPU_DATA_WIDTH = 32;
  parameter DATAREG_LEN    = 64;

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
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][PDATA_SIZE     -1:0] gpio_misd_i;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][PDATA_SIZE     -1:0] gpio_misd_o;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][PDATA_SIZE     -1:0] gpio_misd_oe;

  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][PDATA_SIZE     -1:0] gpio_simd_i;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][PDATA_SIZE     -1:0] gpio_simd_o;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][PDATA_SIZE     -1:0] gpio_simd_oe;

  //Host Interface
  logic                       host_csr_req,
                              host_csr_ack,
                              host_csr_we;
  logic [XLEN           -1:0] host_csr_tohost,
                              host_csr_fromhost;

  // JTAG signals
  logic                    ahb3_misd_tck_i;
  logic                    ahb3_misd_tdi_i;
  logic                    ahb3_misd_tdo_o;

  logic                    ahb3_simd_tck_i;
  logic                    ahb3_simd_tdi_i;
  logic                    ahb3_simd_tdo_o;

  // TAP states
  logic                    ahb3_misd_tlr_i;
  logic                    ahb3_misd_shift_dr_i;
  logic                    ahb3_misd_pause_dr_i;
  logic                    ahb3_misd_update_dr_i;
  logic                    ahb3_misd_capture_dr_i;

  logic                    ahb3_simd_tlr_i;
  logic                    ahb3_simd_shift_dr_i;
  logic                    ahb3_simd_pause_dr_i;
  logic                    ahb3_simd_update_dr_i;
  logic                    ahb3_simd_capture_dr_i;

  // Instructions
  logic                    ahb3_misd_debug_select_i;

  logic                    ahb3_simd_debug_select_i;

  // AHB Master Interface Signals

  logic                    dbg_misd_HSEL;
  logic [ADDR_WIDTH  -1:0] dbg_misd_HADDR;
  logic [DATA_WIDTH  -1:0] dbg_misd_HWDATA;
  logic [DATA_WIDTH  -1:0] dbg_misd_HRDATA;
  logic                    dbg_misd_HWRITE;
  logic [             2:0] dbg_misd_HSIZE;
  logic [             2:0] dbg_misd_HBURST;
  logic [             3:0] dbg_misd_HPROT;
  logic [             1:0] dbg_misd_HTRANS;
  logic                    dbg_misd_HMASTLOCK;
  logic                    dbg_misd_HREADY;
  logic                    dbg_misd_HRESP;

  logic                    dbg_simd_HSEL;
  logic [ADDR_WIDTH  -1:0] dbg_simd_HADDR;
  logic [DATA_WIDTH  -1:0] dbg_simd_HWDATA;
  logic [DATA_WIDTH  -1:0] dbg_simd_HRDATA;
  logic                    dbg_simd_HWRITE;
  logic [             2:0] dbg_simd_HSIZE;
  logic [             2:0] dbg_simd_HBURST;
  logic [             3:0] dbg_simd_HPROT;
  logic [             1:0] dbg_simd_HTRANS;
  logic                    dbg_simd_HMASTLOCK;
  logic                    dbg_simd_HREADY;
  logic                    dbg_simd_HRESP;

  // APB Slave Interface Signals (JTAG Serial Port)
  logic                    PRESETn;
  logic                    PCLK;

  logic                    jsp_misd_PSEL;
  logic                    jsp_misd_PENABLE;
  logic                    jsp_misd_PWRITE;
  logic [             2:0] jsp_misd_PADDR;
  logic [             7:0] jsp_misd_PWDATA;
  logic [             7:0] jsp_misd_PRDATA;
  logic                    jsp_misd_PREADY;
  logic                    jsp_misd_PSLVERR;

  logic                    jsp_simd_PSEL;
  logic                    jsp_simd_PENABLE;
  logic                    jsp_simd_PWRITE;
  logic [             2:0] jsp_simd_PADDR;
  logic [             7:0] jsp_simd_PWDATA;
  logic [             7:0] jsp_simd_PRDATA;
  logic                    jsp_simd_PREADY;
  logic                    jsp_simd_PSLVERR;

  logic                    int_misd_o;

  logic                    int_simd_o;

  // CPU/Thread debug ports
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][CPU_ADDR_WIDTH-1:0] ahb3_misd_cpu_addr_o;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][CPU_DATA_WIDTH-1:0] ahb3_misd_cpu_data_i;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0][CPU_DATA_WIDTH-1:0] ahb3_misd_cpu_data_o;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                     ahb3_misd_cpu_bp_i;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                     ahb3_misd_cpu_stall_o;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                     ahb3_misd_cpu_stb_o;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                     ahb3_misd_cpu_we_o;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_MISD-1:0]                     ahb3_misd_cpu_ack_i;

  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][CPU_ADDR_WIDTH-1:0] ahb3_simd_cpu_addr_o;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][CPU_DATA_WIDTH-1:0] ahb3_simd_cpu_data_i;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0][CPU_DATA_WIDTH-1:0] ahb3_simd_cpu_data_o;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                     ahb3_simd_cpu_bp_i;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                     ahb3_simd_cpu_stall_o;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                     ahb3_simd_cpu_stb_o;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                     ahb3_simd_cpu_we_o;
  logic [X-1:0][Y-1:0][Z-1:0][CORES_PER_SIMD-1:0]                     ahb3_simd_cpu_ack_i;

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

  //DBG MISD AHB3
  mpsoc_dbg_top_ahb3 #(
    .X              ( X              ),
    .Y              ( Y              ),
    .Z              ( Z              ),
    .CORES_PER_TILE ( CORES_PER_MISD ),
    .ADDR_WIDTH     ( 32             ),
    .DATA_WIDTH     ( 32             ),
    .CPU_ADDR_WIDTH ( 32             ),
    .CPU_DATA_WIDTH ( 32             ),
    .DATAREG_LEN    ( DATAREG_LEN    )
  )
  top_misd_ahb3 (
    // JTAG signals
    .tck_i ( ahb3_misd_tck_i ),
    .tdi_i ( ahb3_misd_tdi_i ),
    .tdo_o ( ahb3_misd_tdo_i ),

    // TAP states
    .tlr_i        ( ahb3_misd_tlr_i        ),
    .shift_dr_i   ( ahb3_misd_shift_dr_i   ),
    .pause_dr_i   ( ahb3_misd_pause_dr_i   ),
    .update_dr_i  ( ahb3_misd_update_dr_i  ),
    .capture_dr_i ( ahb3_misd_capture_dr_i ),

    // Instructions
    .debug_select_i ( ahb3_misd_debug_select_i ),

    // AHB Master Interface Signals
    .HCLK          ( HCLK               ),
    .HRESETn       ( HRESETn            ),
    .dbg_HSEL      ( dbg_misd_HSEL      ),
    .dbg_HADDR     ( dbg_misd_HADDR     ),
    .dbg_HWDATA    ( dbg_misd_HWDATA    ),
    .dbg_HRDATA    ( dbg_misd_HRDATA    ),
    .dbg_HWRITE    ( dbg_misd_HWRITE    ),
    .dbg_HSIZE     ( dbg_misd_HSIZE     ),
    .dbg_HBURST    ( dbg_misd_HBURST    ),
    .dbg_HPROT     ( dbg_misd_HPROT     ),
    .dbg_HTRANS    ( dbg_misd_HTRANS    ),
    .dbg_HMASTLOCK ( dbg_misd_HMASTLOCK ),
    .dbg_HREADY    ( dbg_misd_HREADY    ),
    .dbg_HRESP     ( dbg_misd_HRESP     ),

    // APB Slave Interface Signals (JTAG Serial Port)
    .PRESETn     ( PRESETn          ),
    .PCLK        ( PCLK             ),
    .jsp_PSEL    ( jsp_misd_PSEL    ),
    .jsp_PENABLE ( jsp_misd_PENABLE ),
    .jsp_PWRITE  ( jsp_misd_PWRITE  ),
    .jsp_PADDR   ( jsp_misd_PADDR   ),
    .jsp_PWDATA  ( jsp_misd_PWDATA  ),
    .jsp_PRDATA  ( jsp_misd_PRDATA  ),
    .jsp_PREADY  ( jsp_misd_PREADY  ),
    .jsp_PSLVERR ( jsp_misd_PSLVERR ),
  
    .int_o ( int_misd_o ),

    //CPU/Thread debug ports
    .cpu_clk_i   ( ahb3_misd_cpu_clk_i   ),
    .cpu_rstn_i  ( ahb3_misd_cpu_rstn_i  ),
    .cpu_addr_o  ( ahb3_misd_cpu_addr_o  ),
    .cpu_data_i  ( ahb3_misd_cpu_data_i  ),
    .cpu_data_o  ( ahb3_misd_cpu_data_o  ),
    .cpu_bp_i    ( ahb3_misd_cpu_bp_i    ),
    .cpu_stall_o ( ahb3_misd_cpu_stall_o ),
    .cpu_stb_o   ( ahb3_misd_cpu_stb_o   ),
    .cpu_we_o    ( ahb3_misd_cpu_we_o    ),
    .cpu_ack_i   ( ahb3_misd_cpu_ack_i   )
  );

  //DBG SIMD AHB3
  mpsoc_dbg_top_ahb3 #(
    .X              ( X              ),
    .Y              ( Y              ),
    .Z              ( Z              ),
    .CORES_PER_TILE ( CORES_PER_SIMD ),
    .ADDR_WIDTH     ( 32             ),
    .DATA_WIDTH     ( 32             ),
    .CPU_ADDR_WIDTH ( 32             ),
    .CPU_DATA_WIDTH ( 32             ),
    .DATAREG_LEN    ( DATAREG_LEN    )
  )
  top_simd_ahb3 (
    // JTAG signals
    .tck_i ( ahb3_simd_tck_i ),
    .tdi_i ( ahb3_simd_tdi_i ),
    .tdo_o ( ahb3_simd_tdo_i ),

    // TAP states
    .tlr_i        ( ahb3_simd_tlr_i        ),
    .shift_dr_i   ( ahb3_simd_shift_dr_i   ),
    .pause_dr_i   ( ahb3_simd_pause_dr_i   ),
    .update_dr_i  ( ahb3_simd_update_dr_i  ),
    .capture_dr_i ( ahb3_simd_capture_dr_i ),

    // Instructions
    .debug_select_i ( ahb3_simd_debug_select_i ),

    // AHB Master Interface Signals
    .HCLK          ( HCLK               ),
    .HRESETn       ( HRESETn            ),
    .dbg_HSEL      ( dbg_simd_HSEL      ),
    .dbg_HADDR     ( dbg_simd_HADDR     ),
    .dbg_HWDATA    ( dbg_simd_HWDATA    ),
    .dbg_HRDATA    ( dbg_simd_HRDATA    ),
    .dbg_HWRITE    ( dbg_simd_HWRITE    ),
    .dbg_HSIZE     ( dbg_simd_HSIZE     ),
    .dbg_HBURST    ( dbg_simd_HBURST    ),
    .dbg_HPROT     ( dbg_simd_HPROT     ),
    .dbg_HTRANS    ( dbg_simd_HTRANS    ),
    .dbg_HMASTLOCK ( dbg_simd_HMASTLOCK ),
    .dbg_HREADY    ( dbg_simd_HREADY    ),
    .dbg_HRESP     ( dbg_simd_HRESP     ),

    // APB Slave Interface Signals (JTAG Serial Port)
    .PRESETn     ( PRESETn          ),
    .PCLK        ( PCLK             ),
    .jsp_PSEL    ( jsp_simd_PSEL    ),
    .jsp_PENABLE ( jsp_simd_PENABLE ),
    .jsp_PWRITE  ( jsp_simd_PWRITE  ),
    .jsp_PADDR   ( jsp_simd_PADDR   ),
    .jsp_PWDATA  ( jsp_simd_PWDATA  ),
    .jsp_PRDATA  ( jsp_simd_PRDATA  ),
    .jsp_PREADY  ( jsp_simd_PREADY  ),
    .jsp_PSLVERR ( jsp_simd_PSLVERR ),
  
    .int_o ( int_simd_o ),

    //CPU/Thread debug ports
    .cpu_clk_i   ( ahb3_simd_cpu_clk_i   ),
    .cpu_rstn_i  ( ahb3_simd_cpu_rstn_i  ),
    .cpu_addr_o  ( ahb3_simd_cpu_addr_o  ),
    .cpu_data_i  ( ahb3_simd_cpu_data_i  ),
    .cpu_data_o  ( ahb3_simd_cpu_data_o  ),
    .cpu_bp_i    ( ahb3_simd_cpu_bp_i    ),
    .cpu_stall_o ( ahb3_simd_cpu_stall_o ),
    .cpu_stb_o   ( ahb3_simd_cpu_stb_o   ),
    .cpu_we_o    ( ahb3_simd_cpu_we_o    ),
    .cpu_ack_i   ( ahb3_simd_cpu_ack_i   )
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
