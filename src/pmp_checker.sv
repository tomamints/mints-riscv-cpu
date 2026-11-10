import eei::*;

// PMP permission check for one access against the 8 decoded entries.
// The entry ranges come from pmp_region_decode (shared per core); this module
// only compares the access [access_start, access_end) with them, using a
// 65-bit access_end computed once:
//   overlaps = access_start < end && access_end > start
//   contains = access_start >= start && access_end <= end
// which equal the original subtraction-based checks for every non-empty access
// and non-empty region. A whole-space NAPOT entry keeps the original rule (it
// matches and contains any non-zero-sized access). Priority: lowest matching
// entry decides. Equivalence with the original checker: tools/test-pmp-prefix.sh.
// CARRY_COMPARE=1 computes each 65-bit compare as the borrow of a subtraction,
// which maps onto carry chains (shorter delay, more area): use it only on
// timing-critical instances. The result is identical for both settings.
module pmp_checker #(
    parameter bit CARRY_COMPARE = 1'b0
) (
    input PrivMode priv_mode,
    input Addr access_start,
    input UIntX access_size,
    input PmpAccessType access_type,
    input UIntX pmpcfg0,                 // R/W/X permission bits
    input PmpRegion [7:0] pmp_regions,
    output logic allow
);
    // a < b on 65-bit unsigned values
    function automatic logic lt65(input logic [XLEN:0] a, input logic [XLEN:0] b);
        logic [XLEN+1:0] d;
        if (CARRY_COMPARE) begin
            d = {1'b0, a} - {1'b0, b};
            return d[XLEN+1];
        end else begin
            return a < b;
        end
    endfunction

    always_comb begin
        logic matched;
        logic [XLEN:0] access_end;
        logic size_nonzero;

        if (priv_mode == M) begin
            allow = 1'b1;
        end else begin
            size_nonzero = access_size != 0;
            access_end = {1'b0, access_start} + {1'b0, access_size};
            matched = 1'b0;
            allow = 1'b0;
            for (int pmp_index = 0; pmp_index < 8; pmp_index++) begin
                logic permission_ok;
                logic entry_overlaps;
                logic entry_contains;
                PmpRegion r;
                r = pmp_regions[pmp_index];
                unique case (access_type)
                    PMP_ACCESS_READ:  permission_ok = pmpcfg0[pmp_index*8 + 0];
                    PMP_ACCESS_WRITE: permission_ok = pmpcfg0[pmp_index*8 + 1];
                    PMP_ACCESS_EXEC:  permission_ok = pmpcfg0[pmp_index*8 + 2];
                    default:          permission_ok = 1'b0;
                endcase
                entry_overlaps = size_nonzero && r.valid &&
                    (r.all || (lt65({1'b0, access_start}, r.end_addr) && lt65({1'b0, r.start}, access_end)));
                entry_contains = size_nonzero && r.valid &&
                    (r.all || (!lt65({1'b0, access_start}, {1'b0, r.start}) && !lt65(r.end_addr, access_end)));
                if (!matched && entry_overlaps) begin
                    matched = 1'b1;
                    allow = entry_contains && permission_ok;
                end
            end
        end
    end
endmodule : pmp_checker
