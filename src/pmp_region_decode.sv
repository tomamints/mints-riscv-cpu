import eei::*;

// Decodes the 8 PMP entries (pmpcfg0 A fields + pmpaddr0..7) into byte ranges
// once per core; every pmp_checker compares accesses against these ranges.
// The ranges depend only on the PMP CSRs, so sharing them is exact.
//   TOR:   [pmpaddr[i-1] << 2, pmpaddr[i] << 2), valid only if non-empty
//   NAPOT: k trailing ones encode 2**(k+3) bytes; all = whole address space
//   OFF / NA4 (unsupported, as before): not valid
module pmp_region_decode (
    input  UIntX pmpcfg0,
    input  UIntX pmpaddr0,
    input  UIntX pmpaddr1,
    input  UIntX pmpaddr2,
    input  UIntX pmpaddr3,
    input  UIntX pmpaddr4,
    input  UIntX pmpaddr5,
    input  UIntX pmpaddr6,
    input  UIntX pmpaddr7,
    output PmpRegion [7:0] regions
);
    // NAPOT size-1 by prefix AND (no priority encoder / variable shift).
    function automatic Addr napot_mask(input Addr pmpaddr);
        Addr mask;
        logic low_bits_one;
        mask = Addr'(7);
        low_bits_one = 1'b1;
        for (int bit_index = 3; bit_index < XLEN; bit_index++) begin
            low_bits_one = low_bits_one && pmpaddr[bit_index-3];
            mask[bit_index] = low_bits_one;
        end
        return mask;
    endfunction

    always_comb begin
        Addr addr [0:7];
        addr[0] = pmpaddr0;
        addr[1] = pmpaddr1;
        addr[2] = pmpaddr2;
        addr[3] = pmpaddr3;
        addr[4] = pmpaddr4;
        addr[5] = pmpaddr5;
        addr[6] = pmpaddr6;
        addr[7] = pmpaddr7;
        for (int i = 0; i < 8; i++) begin
            Addr mask;
            regions[i] = '0;
            mask = napot_mask(addr[i]);
            unique case (pmpcfg0[i*8 + 3 +: 2])
                2'b01: begin    // TOR
                    regions[i].start = (i == 0) ? Addr'(0) : (addr[i - 1] << 2);
                    regions[i].end_addr = {1'b0, addr[i] << 2};
                    regions[i].valid = {1'b0, regions[i].start} < regions[i].end_addr;
                end
                2'b11: begin    // NAPOT
                    regions[i].valid = 1'b1;
                    regions[i].all = ((addr[i] & PMPADDR_WMASK) == PMPADDR_WMASK) || (&mask);
                    regions[i].start = (addr[i] << 2) & ~mask;
                    regions[i].end_addr = {1'b0, regions[i].start | mask} + 1'b1;
                end
                default: ;
            endcase
        end
    end
endmodule : pmp_region_decode
