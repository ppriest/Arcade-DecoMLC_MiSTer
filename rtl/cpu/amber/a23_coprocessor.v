//////////////////////////////////////////////////////////////////
//                                                              //
//  Co-processor module for Amber 2 Core                        //
//                                                              //
//  This file is part of the Amber project                      //
//  http://www.opencores.org/project,amber                      //
//                                                              //
//  Description                                                 //
//  Co_processor 15 registers and control signals               //                                                           //
//  Author(s):                                                  //
//      - Conor Santifort, csantifort.amber@gmail.com           //
//                                                              //
//////////////////////////////////////////////////////////////////
//                                                              //
// Copyright (C) 2010 Authors and OPENCORES.ORG                 //
//                                                              //
// This source file may be used and distributed without         //
// restriction provided that this copyright statement is not    //
// removed from the file and that any derivative work contains  //
// the original copyright notice and the associated disclaimer. //
//                                                              //
// This source file is free software; you can redistribute it   //
// and/or modify it under the terms of the GNU Lesser General   //
// Public License as published by the Free Software Foundation; //
// either version 2.1 of the License, or (at your option) any   //
// later version.                                               //
//                                                              //
// This source is distributed in the hope that it will be       //
// useful, but WITHOUT ANY WARRANTY; without even the implied   //
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR      //
// PURPOSE.  See the GNU Lesser General Public License for more //
// details.                                                     //
//                                                              //
// You should have received a copy of the GNU Lesser General    //
// Public License along with this source; if not, download it   //
// from http://www.opencores.org/lgpl.shtml                     //
//                                                              //
//////////////////////////////////////////////////////////////////


module a23_coprocessor
(
input                       i_clk,
input                       i_reset,
input                       i_fetch_stall,    // stall all stages of the cpu at the same time
input       [2:0]           i_copro_opcode1,
input       [2:0]           i_copro_opcode2,
input       [3:0]           i_copro_crn,      // Register Number 
input       [3:0]           i_copro_crm,
input       [3:0]           i_copro_num,
input       [1:0]           i_copro_operation,
input       [31:0]          i_copro_write_data,

input                       i_fault,          // high to latch the fault address and status
input       [7:0]           i_fault_status,
input       [31:0]          i_fault_address,  // the address that caused the fault

output reg  [31:0]          o_copro_read_data,
output                      o_cache_enable,
output                      o_cache_flush,
output      [31:0]          o_cacheable_area,
output                      o_busy             // DecoMLC: coprocessor 0 working
);

// Bit 0 - Cache on(1)/off
// Bit 1 - Shared (1) or seperate User/Supervisor address space
// Bit 2 - address monitor mode(1)
reg [2:0]  cache_control = 3'b000;

// Bit 0 - 2MB memory from 0 to 0x01fffff cacheable(1)/not cachable
// Bit 1 - next 2MB region etc.
reg [31:0] cacheable_area = 32'h0;

// Marks memory regions as read only so writes are ignored by the cache
// Bit 0 - 2MB memory from 0 to 0x01fffff updateable(1)/not updateable
// Bit 1 - next 2MB region etc.
reg [31:0] updateable_area = 32'h0;

// Accesses to a region with a flag set in this register cause the
// cache to flush
// Bit 0 - 2MB memory from 0 to 0x01fffff
// Bit 1 - next 2MB region etc.
reg [31:0] disruptive_area = 32'h0;


reg [31:0] cp0 [0:15];              // DecoMLC: the DE156's coprocessor 0 (below)

reg [7:0]  fault_status  = 'd0;
reg [31:0] fault_address = 'd0;  // the address that caused the fault

wire       copro15_reg1_write;


// ---------------------------
// Outputs
// ---------------------------
assign o_cache_enable   = cache_control[0];
assign o_cache_flush    = copro15_reg1_write;
assign o_cacheable_area = cacheable_area;
              
// ---------------------------
// Capture an access fault address and status
// ---------------------------
always @ ( posedge i_clk )
    if (i_reset) begin
       fault_status  <= 'd0;
       fault_address <= 'd0;
    end else if ( !i_fetch_stall )
        begin
        if ( i_fault )
            begin
            
            `ifdef A23_COPRO15_DEBUG    
            $display ("Fault status  set to 0x%08x", i_fault_status);
            $display ("Fault address set to 0x%08x", i_fault_address);
            `endif        
            fault_status    <= i_fault_status;
            fault_address   <= i_fault_address;
            end
        end


// ---------------------------
// Register Writes
// ---------------------------
always @ ( posedge i_clk )
    if (i_reset) begin
       cache_control   <= 3'b000;
       cacheable_area  <= 32'h0;
       updateable_area <= 32'h0;
       disruptive_area <= 32'h0;
    end else 
    if ( !i_fetch_stall )         
        begin
        if ( i_copro_operation == 2'd2 && i_copro_num == 4'd15 )
            case ( i_copro_crn )
                4'd2: cache_control   <= i_copro_write_data[2:0];
                4'd3: cacheable_area  <= i_copro_write_data[31:0];
                4'd4: updateable_area <= i_copro_write_data[31:0];
                4'd5: disruptive_area <= i_copro_write_data[31:0];
            endcase
        end

// Flush the cache
assign copro15_reg1_write = !i_fetch_stall && i_copro_operation == 2'd2 && i_copro_num == 4'd15 && i_copro_crn == 4'd1;


// ---------------------------
// Register Reads   
// ---------------------------
always @ ( posedge i_clk )        
    if ( !i_fetch_stall )
        if ( i_copro_num == 4'd0 ) o_copro_read_data <= cp0[i_copro_crn];   // DecoMLC
        else
        case ( i_copro_crn )
            // ID Register - [31:24] Company id, [23:16] Manuf id, [15:8] Part type, [7:0] revision
            4'd0:    o_copro_read_data <= 32'h4156_0300;
            4'd2:    o_copro_read_data <= {29'd0, cache_control}; 
            4'd3:    o_copro_read_data <= cacheable_area; 
            4'd4:    o_copro_read_data <= updateable_area; 
            4'd5:    o_copro_read_data <= disruptive_area; 
            4'd6:    o_copro_read_data <= {24'd0, fault_status };
            4'd7:    o_copro_read_data <= fault_address;
            default: o_copro_read_data <= 32'd0;
        endcase



// ========================================================
// DecoMLC local change (PROVENANCE.md): the DE156's coprocessor 0, as MAME's
// de156_cpu_device (arm7.cpp) has it. Sixteen registers. MCR c2 = command: BCD add (0),
// multiply (1) or subtract (3) of c0 and c1 into c5, through 32-bit binary arithmetic and
// eight BCD digits each way (bcd_to_decimal weights a nibble above 9 by its place too).
// CDP: c3 = c0 / c1, c4 = c0 % c1, both 0xffffffff when c1 is 0. MAME's results are
// instant; here an operation takes up to about 80 clocks of i_clk, and o_busy holds the CPU
// through i_system_rdy until it is done. Shifts and adds only.
// ========================================================
localparam  C_IDLE = 3'd0, C_B2D = 3'd1, C_MUL = 3'd2, C_D2B = 3'd3, C_DIV = 3'd4;
reg  [2:0]  c_st = C_IDLE;
reg  [5:0]  c_n;
reg  [1:0]  c_cmd;
reg  [31:0] c_v0, c_v1, c_r, c_q, c_rem, c_a;
reg  [39:0] c_bcd;
wire [32:0] c_rsh = {c_rem, c_a[31]};          // the partial remainder, next bit in
wire [32:0] c_dif = c_rsh - {1'b0, cp0[1]};
wire [39:0] c_dab;
integer     ci;

assign o_busy = c_st != C_IDLE;
assign c_dab  = dabble(c_bcd);

function [39:0] dabble;           // add 3 to every BCD digit of 5 or more
    input [39:0] v;
    integer k;
    begin
        for (k = 0; k < 10; k = k + 1)
            dabble[4*k +: 4] = (v[4*k +: 4] >= 4'd5) ? v[4*k +: 4] + 4'd3 : v[4*k +: 4];
    end
endfunction

always @ ( posedge i_clk )
    if ( i_reset ) begin
        for (ci = 0; ci < 16; ci = ci + 1) cp0[ci] <= 32'd0;
        c_st <= C_IDLE;
    end else begin
        case ( c_st )
        C_IDLE:
            if ( !i_fetch_stall && i_copro_num == 4'd0 ) begin
                if ( i_copro_operation == 2'd2 ) begin
                    cp0[i_copro_crn] <= i_copro_write_data;
                    if ( i_copro_crn == 4'd2 && ( i_copro_write_data == 32'd0 ||
                         i_copro_write_data == 32'd1 || i_copro_write_data == 32'd3 ) ) begin
                        c_cmd <= i_copro_write_data[1:0];
                        c_v0  <= 32'd0;
                        c_v1  <= 32'd0;
                        c_n   <= 6'd0;
                        c_st  <= C_B2D;
                    end
                end
                if ( i_copro_operation == 2'd3 ) begin
                    if ( cp0[1] == 32'd0 ) begin
                        cp0[3] <= 32'hffffffff;
                        cp0[4] <= 32'hffffffff;
                    end else begin
                        c_a   <= cp0[0];
                        c_q   <= 32'd0;
                        c_rem <= 32'd0;
                        c_n   <= 6'd0;
                        c_st  <= C_DIV;
                    end
                end
            end
        // BCD to binary, most significant digit first: v = v * 10 + digit
        C_B2D: begin
            c_v0 <= (c_v0 << 3) + (c_v0 << 1) + {28'd0, cp0[0][31 - 4*c_n[2:0] -: 4]};
            c_v1 <= (c_v1 << 3) + (c_v1 << 1) + {28'd0, cp0[1][31 - 4*c_n[2:0] -: 4]};
            c_n  <= c_n + 6'd1;
            if ( c_n == 6'd7 ) begin
                c_n <= 6'd0;
                if ( c_cmd == 2'd1 ) begin
                    c_r  <= 32'd0;
                    c_st <= C_MUL;
                end else begin
                    c_st <= C_D2B;
                    c_bcd <= 40'd0;
                end
            end
        end
        // the low 32 bits of v0 * v1, a bit of v1 a clock
        C_MUL: begin
            if ( c_n == 6'd32 ) begin
                c_n   <= 6'd0;
                c_bcd <= 40'd0;
                c_st  <= C_D2B;
            end else begin
                if ( c_v1[0] ) c_r <= c_r + c_v0;
                c_v0 <= c_v0 << 1;
                c_v1 <= c_v1 >> 1;
                c_n  <= c_n + 6'd1;
            end
        end
        // binary to BCD by double dabble; the low eight digits are MAME's decimal_to_bcd
        C_D2B: begin
            if ( c_n == 6'd0 && c_cmd != 2'd1 )
                c_r <= c_cmd == 2'd0 ? c_v0 + c_v1 : c_v0 - c_v1;
            if ( c_n == 6'd33 ) begin
                cp0[5] <= c_bcd[31:0];
                c_st   <= C_IDLE;
            end else begin
                if ( c_n != 6'd0 ) begin
                    c_bcd <= {c_dab[38:0], c_r[31]};
                    c_r   <= c_r << 1;
                end
                c_n <= c_n + 6'd1;
            end
        end
        // restoring division, a quotient bit a clock
        C_DIV: begin
            if ( c_n == 6'd32 ) begin
                cp0[3] <= c_q;
                cp0[4] <= c_rem;
                c_st   <= C_IDLE;
            end else begin
                if ( !c_dif[32] ) begin
                    c_rem <= c_dif[31:0];
                    c_q   <= {c_q[30:0], 1'b1};
                end else begin
                    c_rem <= c_rsh[31:0];
                    c_q   <= {c_q[30:0], 1'b0};
                end
                c_a <= c_a << 1;
                c_n <= c_n + 6'd1;
            end
        end
        default: c_st <= C_IDLE;
        endcase
    end


// ========================================================
// Debug code - not synthesizable
// ========================================================

`ifdef A23_COPRO15_DEBUG    
//synopsys translate_off
reg [1:0]  copro_operation_d1;
reg [3:0]  copro_crn_d1;

always @( posedge i_clk )
    if ( !i_fetch_stall )
        begin
        copro_operation_d1  <= i_copro_operation;
        copro_crn_d1        <= i_copro_crn;
        end

always @( posedge i_clk )
    if ( !i_fetch_stall )
        begin
        if ( i_copro_operation == 2'd2 )  // mcr
            case ( i_copro_crn )
                4'd 1: begin `TB_DEBUG_MESSAGE $display ("Write 0x%08h to   Co-Pro 15 #1, Flush Cache", i_copro_write_data); end
                4'd 2: begin `TB_DEBUG_MESSAGE $display ("Write 0x%08h to   Co-Pro 15 #2, Cache Control", i_copro_write_data); end
                4'd 3: begin `TB_DEBUG_MESSAGE $display ("Write 0x%08h to   Co-Pro 15 #3, Cacheable area", i_copro_write_data); end
                4'd 4: begin `TB_DEBUG_MESSAGE $display ("Write 0x%08h to   Co-Pro 15 #4, Updateable area", i_copro_write_data); end
                4'd 5: begin `TB_DEBUG_MESSAGE $display ("Write 0x%08h to   Co-Pro 15 #5, Disruptive area", i_copro_write_data); end
            endcase
            
        if ( copro_operation_d1 == 2'd1 ) // mrc
            case ( copro_crn_d1 )
                4'd 0: begin `TB_DEBUG_MESSAGE $display ("Read  0x%08h from Co-Pro 15 #0, ID Register", o_copro_read_data); end
                4'd 2: begin `TB_DEBUG_MESSAGE $display ("Read  0x%08h from Co-Pro 15 #2, Cache control", o_copro_read_data); end
                4'd 3: begin `TB_DEBUG_MESSAGE $display ("Read  0x%08h from Co-Pro 15 #3, Cacheable area", o_copro_read_data); end
                4'd 4: begin `TB_DEBUG_MESSAGE $display ("Read  0x%08h from Co-Pro 15 #4, Updateable area", o_copro_read_data); end
                4'd 5: begin `TB_DEBUG_MESSAGE $display ("Read  0x%08h from Co-Pro 15 #4, Disruptive area", o_copro_read_data); end
                4'd 6: begin `TB_DEBUG_MESSAGE $display ("Read  0x%08h from Co-Pro 15 #6, Fault Status Register", o_copro_read_data); end
                4'd 7: begin `TB_DEBUG_MESSAGE $display ("Read  0x%08h from Co-Pro 15 #7, Fault Address Register", o_copro_read_data); end
            endcase
    end
//synopsys translate_on
`endif

endmodule

