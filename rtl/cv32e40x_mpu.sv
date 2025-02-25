// Copyright 2021 Silicon Labs, Inc.
//   
// This file, and derivatives thereof are licensed under the
// Solderpad License, Version 2.0 (the "License");
// Use of this file means you agree to the terms and conditions
// of the license and are in full compliance with the License.
// You may obtain a copy of the License at
//   
//     https://solderpad.org/licenses/SHL-2.0/
//   
// Unless required by applicable law or agreed to in writing, software
// and hardware implementations thereof
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, EITHER EXPRESSED OR IMPLIED.
// See the License for the specific language governing permissions and
// limitations under the License.

////////////////////////////////////////////////////////////////////////////////
//                                                                            //
// Authors:        Oivind Ekelund - oivind.ekelund@silabs.com                 //
//                                                                            //
// Description:    MPU (Memory Protection Unit)                               //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////

module cv32e40x_mpu import cv32e40x_pkg::*;
  #(  parameter type         RESP_TYPE = inst_resp_t, // TODO: use this to separate between instuction and data side
      parameter int unsigned PMA_NUM_REGIONS = 1,
      parameter pma_region_t PMA_CFG[PMA_NUM_REGIONS-1:0] = '{PMA_R_DEFAULT})
  (
   input logic         clk,
   input logic         rst_n,
   
   input logic         speculative_access_i, // Indicate that ongoing access is speculative           
   input logic         atomic_access_i,      // Indicate that ongoing access is atomic                
   input logic         execute_access_i,     // Indicate that ongoing access is intended for execution

   // Interface towards bus interface
   input logic         bus_trans_ready_i,
   output logic [31:0] bus_trans_addr_o,
   output logic        bus_trans_valid_o,
   output logic        bus_trans_cacheable_o,
   output logic        bus_trans_bufferable_o,
   input logic         bus_resp_valid_i,
   input               obi_inst_resp_t bus_resp_i,

   // Interface towards core
   input logic [31:0]  core_trans_addr_i,
   input logic         core_trans_we_i,
   input logic         core_trans_valid_i,
   output logic        core_trans_ready_o,
   output logic        core_resp_valid_o,
   output              inst_resp_t core_inst_resp_o,

   // Indication from the core that there will be one pending transaction in the next cycle
   input logic         core_one_txn_pend_n
   );
  
  logic        pma_err;
  logic        pmp_err;
  logic        mpu_err;
  logic        mpu_block_core;
  logic        mpu_block_obi;
  logic        mpu_err_trans_valid;
  mpu_status_e mpu_status;
  mpu_state_e state_q, state_n;
  

  // FSM that will "consume" transfers failing PMA or PMP checks.
  // Upon failing checks, this FSM will prevent the transfer from going out on the OBI bus
  // and wait for all in flight OBI transactions to complete while blocking new transfers.
  // When all in flight transactions are complete, it will respond with the correct status before
  // allowing new transfers to go through.
  // The input signal core_one_txn_pend_n indicates that there, from the core's point of view,
  // will be one pending transaction in the next cycle. Upon MPU error, this transaction
  // will be completed by this FSM
  always_comb begin

    state_n        = state_q;
    mpu_status     = MPU_OK;
    mpu_block_core = 1'b0;
    mpu_block_obi  = 1'b0;
    mpu_err_trans_valid = 1'b0;
    
    case(state_q)
      MPU_IDLE: begin
        if (mpu_err && core_trans_valid_i && bus_trans_ready_i) begin

          // Block transfer from going out on the bus.
          mpu_block_obi  = 1'b1;

          if(core_trans_we_i) begin
            // MPU error on write
            state_n = core_one_txn_pend_n ? MPU_WR_ERR_RESP : MPU_WR_ERR_WAIT;
          end
          else begin
            // MPU error on read
            state_n = core_one_txn_pend_n ? MPU_RE_ERR_RESP : MPU_RE_ERR_WAIT;
          end
        end
      end
      MPU_RE_ERR_WAIT, MPU_WR_ERR_WAIT: begin

        // Block new transfers while waiting for in flight transfers to complete
        mpu_block_obi  = 1'b1;
        mpu_block_core = 1'b1;
        
        if (core_one_txn_pend_n) begin
          state_n = (state_q == MPU_RE_ERR_WAIT) ? MPU_RE_ERR_RESP : MPU_WR_ERR_RESP;
        end
      end
      MPU_RE_ERR_RESP, MPU_WR_ERR_RESP: begin
        
        // Keep blocking new transfers
        mpu_block_obi  = 1'b1;
        mpu_block_core = 1'b1;

        // Set up MPU error response towards the core
        mpu_err_trans_valid = 1'b1;
        mpu_status = (state_q == MPU_RE_ERR_RESP) ? MPU_RE_FAULT : MPU_WR_FAULT;

        state_n = MPU_IDLE;
        
      end
      default: ;
    endcase
  end
  
  always_ff @(posedge clk, negedge rst_n) begin
    if (rst_n == 1'b0) begin
      state_q     <= MPU_IDLE;
    end
    else begin
      state_q <= state_n;
    end
  end

  // Signals towards OBI interface (TODO:OE add remainig signals for data side, e.g. we)
  assign bus_trans_valid_o = core_trans_valid_i && !mpu_block_obi;
  assign bus_trans_addr_o  = core_trans_addr_i;
  
  // Signals towards core
  assign core_trans_ready_o          = bus_trans_ready_i && !mpu_block_core; 
  assign core_resp_valid_o           = bus_resp_valid_i || mpu_err_trans_valid;
  assign core_inst_resp_o.bus_resp   = bus_resp_i;
  assign core_inst_resp_o.mpu_status = mpu_status;
  
  // PMA - Physical Memory Attribution
  cv32e40x_pma
    #(.PMA_NUM_REGIONS(PMA_NUM_REGIONS),
      .PMA_CFG(PMA_CFG))
  pma_i
    (.trans_addr_i(core_trans_addr_i),
     .speculative_access_i(speculative_access_i),
     .atomic_access_i(atomic_access_i),
     .execute_access_i(execute_access_i),
     .pma_err_o(pma_err),
     .pma_bufferable_o(bus_trans_bufferable_o),
     .pma_cacheable_o(bus_trans_cacheable_o));

  
  assign pmp_err = 1'b0; // TODO connect to PMP
  assign mpu_err = pmp_err || pma_err;
  
endmodule
