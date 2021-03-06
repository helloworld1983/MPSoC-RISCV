# MPSoC-RISCV WIKI

A Multi-Processor System on Chip (MPSoC) is a System on Chip (SoC) which includes multiple Processing Units (PU). As such, it is a Multi-Core System-on-Chip. All PUs are linked to each other by a Network on Chip (NoC). These technologies meet the performance needs of multimedia applications, telecommunication architectures or network security.

The RISC-V implementation has a 32/64/128 bit Microarchitecture, 6 stages data pipeline and an Instruction Set Architecture based on Reduced Instruction Set Computer. Compatible with AMBA and Wishbone Buses. For Researching and Developing.

| Processing Unit              | Module description               |
| ---------------------------- | -------------------------------- |
| riscv_pu                     | Processing Unit                  |
|...riscv_core                 | Core                             |
|...riscv_imem_ctrl            | Instruction Memory Access Block  |
|...riscv_biu - imem           | Bus Interface Unit (Instruction) |
|...riscv_dmem_ctrl            | Data Memory Access Block         |
|...riscv_biu - dmem           | Bus Interface Unit (Data)        |


## CORE-RISCV

### CORE-RISCV Organization

The CORE-RISCV is based on the Harvard architecture, which is a computer architecture with separate storage and signal pathways for instructions and data. A Harvard architecture machine has distinct code and data address spaces: instruction address zero is not the same as data address zero. Instruction address zero might identify a twenty-four-bit value, while data address zero might indicate an eight-bit byte that is not part of that twenty-four-bit value.

| Core                         | Module description                 |
| ---------------------------- | ---------------------------------- |
| riscv_core                   | Core                               |
|...riscv_if                   | Instruction Fetch                  |
|...riscv_id                   | Instruction Decoder                |
|...riscv_execution            | Execution Unit                     |
|.....riscv_alu                | Arithmetic & Logical Unit          |
|.....riscv_lsu                | Load Store Unit                    |
|.....riscv_bu                 | Branch Unit                        |
|.....riscv_mul                | Multiplier Unit                    |
|.....riscv_div                | Division Unit                      |
|...riscv_memory               | Memory Unit                        |
|...riscv_wb                   | Data Memory Access (Write Back)    |
|...riscv_state                | State Unit                         |
|...riscv_rf                   | Register File                      |
|...riscv_bp                   | Correlating Branch Prediction Unit |
|.....riscv_ram_1r1w           | RAM 1RW1                           |
|.......riscv_ram_1r1w_generic | RAM 1RW1 Generic                   |
|...riscv_du                   | Debug Unit                         |

In a Harvard architecture, there is no need to make the two memories share characteristics. In particular, the word width, timing, implementation technology, and memory address structure can differ. In some systems, instructions for pre-programmed tasks can be stored in read-only memory while data memory generally requires read-write memory. In some systems, there is much more instruction memory than data memory so instruction addresses are wider than data addresses.


### Instruction INPUTS/OUTPUTS Bus

| Port          |  Size  | Direction | Description        |
| ------------- | ------ | --------- | ------------------ |
| `ins_stb`     |    1   |   Input   | Strobe             |
| `ins_stb_ack` |    1   |   Output  | Strobe acknowledge |
| `ins_d_ack`   |    1   |   Output  | Data acknowledge   |
| `ins_adri`    | `PLEN` |   Input   | Start address      |
| `ins_adro`    | `PLEN` |   Output  | Response address   |
| `ins_size`    |    3   |   Input   | Syze               |
| `ins_type`    |    3   |   Input   | Type               |
| `ins_prot`    |    3   |   Input   | Protection         |
| `ins_lock`    |    1   |   Input   | Locked access      |
| `ins_d`       | `XLEN` |   Input   | Write data         |
| `ins_q`       | `XLEN` |   Output  | Read data          |
| `ins_ack`     |    1   |   Output  | Acknowledge        |
| `ins_err`     |    1   |   Output  | Error              |


### Data INPUTS/OUTPUTS Bus

| Port          |  Size  | Direction | Description        |
| ------------- | ------ | --------- | ------------------ |
| `dat_stb`     |    1   |   Input   | Strobe             |
| `dat_stb_ack` |    1   |   Output  | Strobe acknowledge |
| `dat_d_ack`   |    1   |   Output  | Data acknowledge   |
| `dat_adri`    | `PLEN` |   Input   | Start address      |
| `dat_adro`    | `PLEN` |   Output  | Response address   |
| `dat_size`    |    3   |   Input   | Syze               |
| `dat_type`    |    3   |   Input   | Type               |
| `dat_prot`    |    3   |   Input   | Protection         |
| `dat_lock`    |    1   |   Input   | Locked access      |
| `dat_d`       | `XLEN` |   Input   | Write data         |
| `dat_q`       | `XLEN` |   Output  | Read data          |
| `dat_ack`     |    1   |   Output  | Acknowledge        |
| `dat_err`     |    1   |   Output  | Error              |


### RISC PIPELINE

In computer science, instruction pipelining is a technique for implementing instruction-level parallelism within a PU. Pipelining attempts to keep every part of the processor busy with some instruction by dividing incoming instructions into a series of sequential steps performed by different PUs with different parts of instructions processed in parallel. It allows faster PU throughput than would otherwise be possible at a given clock rate.

| Typical    | Modified   | Module          |
| ---------- | ---------- | --------------- |
| FETCH      | FETCH      | riscv_if        |
| ...        | PRE-DECODE | riscv_id        |
| DECODE     | DECODE     | riscv_id        |
| EXECUTE    | EXECUTE    | riscv_execution |
| MEMORY     | MEMORY     | riscv_memory    |
| WRITE-BACK | WRITE-BACK | riscv_wb        |

- IF – Instruction Fetch Unit : Send out the PC and fetch the instruction from memory into the Instruction Register (IR); increment the PC to address the next sequential instruction. The IR is used to hold the next instruction that will be needed on subsequent clock cycles; likewise the register NPC is used to hold the next sequential PC.

- ID – Instruction Decode Unit : Decode the instruction and access the register file to read the registers. This unit gets instruction from IF, and extracts opcode and operand from that instruction. It also retrieves register values if requested by the operation.

- EX – Execution Unit : The ALU operates on the operands prepared in prior cycle, performing one functions depending on instruction type.

- MEM – Memory Access Unit: Instructions active in this unit are loads, stores and branches.

- WB – WriteBack Unit : Write the result into the register file, whether it comes from the memory system or from the ALU.


## INSTRUCTION & DATA CACHE

A PU cache is a hardware cache used by the PU to reduce the average cost (time or energy) to access instruction/data from the main memory. A cache is a smaller, faster memory, closer to a core, which stores copies of the data from frequently used main memory locations. Most CPUs have different independent caches, including instruction and data caches.


### Instruction Organization

| Instruction Memory          | Module description                 |
| --------------------------- | ---------------------------------- |
| riscv_imem_ctrl             | Instruction Memory Access Block    |
|...riscv_membuf              | Memory Access Buffer               |
|.....riscv_ram_queue         | Fall-through Queue                 |
|...riscv_memmisaligned       | Misalignment Check                 |
|...riscv_mmu                 | Memory Management Unit             |
|...riscv_pmachk              | Physical Memory Attributes Checker |
|...riscv_pmpchk              | Physical Memory Protection Checker |
|...riscv_icache_core         | Instruction Cache (Write Back)     |
|.....riscv_ram_1rw           | RAM 1RW                            |
|.......riscv_ram_1rw_generic | RAM 1RW Generic                    |
|...riscv_dext                | Data External Access Logic         |
|...riscv_ram_queue           | Fall-through Queue                 |
|...riscv_mux                 | Bus-Interface-Unit Mux             |
| riscv_biu                   | Bus Interface Unit                 |


### Instruction INPUTS/OUTPUTS AMBA3 AHB-Lite Bus

| Port         |  Size  | Direction | Description                                           |
| ------------ | ------ | --------- | ----------------------------------------------------- |
| `HRESETn`    |    1   |   Input   | Asynchronous active low reset                         |
| `HCLK`       |    1   |   Input   | System clock input                                    |
|              |        |           |                                                       |
| `IHSEL`      |    1   |   Output  | Provided for AHB-Lite compatibility – tied high ('1') |
| `IHADDR`     | `PLEN` |   Output  | Instruction address                                   |
| `IHRDATA`    | `XLEN` |   Input   | Instruction read data                                 |
| `IHWDATA`    | `XLEN` |   Output  | Instruction write data                                |
| `IHWRITE`    |    1   |   Output  | Instruction write                                     |
| `IHSIZE`     |    3   |   Output  | Transfer size                                         |
| `IHBURST`    |    3   |   Output  | Transfer burst size                                   |
| `IHPROT`     |    4   |   Output  | Transfer protection level                             |
| `IHTRANS`    |    2   |   Output  | Transfer type                                         |
| `IHMASTLOCK` |    1   |   Output  | Transfer master lock                                  |
| `IHREADY`    |    1   |   Input   | Slave Ready Indicator                                 |
| `IHRESP`     |    1   |   Input   | Instruction Transfer Response                         |


### Instruction INPUTS/OUTPUTS Wishbone Bus

| Port    |  Size  | Direction | Description                     |
| ------- | ------ | --------- | ------------------------------- |
| `rst`   |    1   |   Input   | Synchronous, active high        |
| `clk`   |    1   |   Input   | Master clock                    |
|         |        |           |                                 |
| `iadr`  | `PLEN` |   Input   | Lower address bits              |
| `idati` | `XLEN` |   Input   | Data towards the core           |
| `idato` | `XLEN` |   Output  | Data from the core              |
| `isel`  |    4   |   Input   | Byte select signals             |
| `iwe`   |    1   |   Input   | Write enable input              |
| `istb`  |    1   |   Input   | Strobe signal/Core select input |
| `icyc`  |    1   |   Input   | Valid bus cycle input           |
| `iack`  |    1   |   Output  | Bus cycle acknowledge output    |
| `ierr`  |    1   |   Output  | Bus cycle error output          |
| `iint`  |    1   |   Output  | Interrupt signal output         |


### Data Organization

| Data Memory                 | Module description                 |
| --------------------------- | ---------------------------------- |
| riscv_dmem_ctrl             | Data Memory Access Block           |
|...riscv_membuf              | Memory Access Buffer               |
|.....riscv_ram_queue         | Fall-through Queue                 |
|...riscv_memmisaligned       | Misalignment Check                 |
|...riscv_mmu                 | Memory Management Unit             |
|...riscv_pmachk              | Physical Memory Attributes Checker |
|...riscv_pmpchk              | Physical Memory Protection Checker |
|...riscv_dcache_core         | Data Cache (Write Back)            |
|.....riscv_ram_1rw           | RAM 1RW                            |
|.......riscv_ram_1rw_generic | RAM 1RW Generic                    |
|...riscv_dext                | Data External Access Logic         |
|...riscv_mux                 | Bus-Interface-Unit Mux             |
| riscv_biu                   | Bus Interface Unit                 |


### Data INPUTS/OUTPUTS AMBA3 AHB-Lite Bus

| Port         |  Size  | Direction | Description                                           |
| ------------ | ------ | --------- | ----------------------------------------------------- |
| `HRESETn`    |    1   |   Input   | Asynchronous active low reset                         |
| `HCLK`       |    1   |   Input   | System clock input                                    |
|              |        |           |                                                       |
| `DHSEL`      |    1   |   Output  | Provided for AHB-Lite compatibility – tied high ('1') |
| `DHADDR`     | `PLEN` |   Output  | Data address                                          |
| `DHRDATA`    | `XLEN` |   Input   | Data read data                                        |
| `DHWDATA`    | `XLEN` |   Output  | Data write data                                       |
| `DHWRITE`    |    1   |   Output  | Data write                                            |
| `DHSIZE`     |    3   |   Output  | Transfer size                                         |
| `DHBURST`    |    3   |   Output  | Transfer burst size                                   |
| `DHPROT`     |    4   |   Output  | Transfer protection level                             |
| `DHTRANS`    |    2   |   Output  | Transfer type                                         |
| `DHMASTLOCK` |    1   |   Output  | Transfer master lock                                  |
| `DHREADY`    |    1   |   Input   | Slave Ready Indicator                                 |
| `DHRESP`     |    1   |   Input   | Data Transfer Response                                |


### Data INPUTS/OUTPUTS Wishbone Bus

| Port    |  Size  | Direction | Description                     |
| ------- | ------ | --------- | ------------------------------- |
| `rst`   |    1   |   Input   | Synchronous, active high        |
| `clk`   |    1   |   Input   | Master clock                    |
|         |        |           |                                 |
| `dadr`  | `PLEN` |   Input   | Lower address bits              |
| `ddati` | `XLEN` |   Input   | Data towards the core           |
| `ddato` | `XLEN` |   Output  | Data from the core              |
| `dsel`  |    4   |   Input   | Byte select signals             |
| `dwe`   |    1   |   Input   | Write enable input              |
| `dstb`  |    1   |   Input   | Strobe signal/Core select input |
| `dcyc`  |    1   |   Input   | Valid bus cycle input           |
| `dack`  |    1   |   Output  | Bus cycle acknowledge output    |
| `derr`  |    1   |   Output  | Bus cycle error output          |
| `dint`  |    1   |   Output  | Interrupt signal output         |


### Parameters

| Parameter               | Type     | Default        | Description                                                     |
| ----------------------- | -------- | -------------- | --------------------------------------------------------------- |
| `JEDEC_BANK`            |`Integer` |0x0A            |JEDEC Bank                                                       |
| `JEDEC_MANUFACTURER_ID` |`Integer` |0x6E            |JEDEC Manufacturer ID                                            |
| `XLEN`                  |`Integer` |64              |Data Path Width                                                  |
| `PLEN`                  |`Integer` |64              |Physical Memory Address Size                                     |
| `PMP_CNT`               |`Integer` |16              |Number of Physical Memory Protection Entries                     |
| `PMA_CNT`               |`Integer` |16              |Number of Physical Menory Attribute Entries                      |
| `HAS_USER`              |`Integer` |1               |User Mode Enable                                                 |
| `HAS_SUPER`             |`Integer` |1               |Supervisor Mode Enable                                           |
| `HAS_HYPER`             |`Integer` |1               |Hypervisor Mode Enable                                           |
| `HAS_RVM`               |`Integer` |1               |"M" Extension Enable                                             |
| `HAS_RVA`               |`Integer` |1               |"A" Extension Enable                                             |
| `HAS_RVC`               |`Integer` |1               |"C" Extension Enable                                             |
| `HAS_BPU`               |`Integer` |1               |Branch Prediction Unit Control Enable                            |
| `IS_RV32E`              |`Integer` |0               |RV32E Base Integer Instruction Set Enable                        |
| `MULT_LATENCY`          |`Integer` |1               |Hardware Multiplier Latency (if "M" Extension enabled)           |
| `ICACHE_SIZE`           |`Integer` |16              |Instruction Cache size in Kbytes                                 |
| `ICACHE_BLOCK_SIZE`     |`Integer` |64              |Instruction Cache block length in bytes                          |
| `ICACHE_WAYS`           |`Integer` |2               |Instruction Cache associativity                                  |
| `ICACHE_REPLACE_ALG`    |`Integer` |0               |Instruction Cache replacement algorithm 0: Random 1: FIFO 2: LRU |
| `DCACHE_SIZE`           |`Integer` |16              |Data Cache size in Kbytes                                        |
| `DCACHE_BLOCK_SIZE`     |`Integer` |64              |Data Cache block length in bytes                                 |
| `DCACHE_WAYS`           |`Integer` |2               |Data Cache associativity                                         |
| `DCACHE_REPLACE_ALG`    |`Integer` |0               |Data Cache replacement algorithm 0: Random 1: FIFO 2: LRU        |
| `HARTID`                |`Integer` |0               |Hart Identifier                                                  |
| `PC_INIT`               |`Address` |`'h200`         |Program Counter Initialisation Vector                            |
| `MNMIVEC_DEFAULT`       |`Address` |`PC_INIT-'h004` |Machine Mode Non-Maskable Interrupt vector address               |
| `MTVEC_DEFAULT`         |`Address` |`PC_INIT-'h040` |Machine Mode Interrupt vector address                            |
| `HTVEC_DEFAULT`         |`Address` |`PC_INIT-'h080` |Hypervisor Mode Interrupt vector address                         |
| `STVEC_DEFAULT`         |`Address` |`PC_INIT-'h0C0` |Supervisor Mode Interrupt vector address                         |
| `UTVEC_DEFAULT`         |`Address` |`PC_INIT-'h100` |User Mode Interrupt vector address                               |
| `BP_LOCAL_BITS`         |`Integer` |10              |Number of local predictor bits                                   |
| `BP_GLOBAL_BITS`        |`Integer` |2               |Number of global predictor bits                                  |
| `BREAKPOINTS`           |`Integer` |3               |Number of hardware breakpoints                                   |
| `TECHNOLOGY`            |`String`  |`GENERIC`       |Target Silicon Technology                                        |
