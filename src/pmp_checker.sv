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
// CARRY_COMPARE=1 shares two signed differences per region instead of four
// independent wide comparisons. With d=B-A, A<B means d>0 and A+size<=B
// means d>=size. The size compares become small when the caller's access size
// is bounded (as for instruction/data/page-table accesses). Full 64-bit sizes
// and addresses, including accesses crossing 2**64, keep the same result.
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
        return a < b;
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
                if (CARRY_COMPARE) begin
                    logic [XLEN+1:0] lo_delta, hi_delta;
                    lo_delta = {2'b0, r.start} - {2'b0, access_start};
                    hi_delta = {1'b0, r.end_addr} - {2'b0, access_start};
                    entry_overlaps = size_nonzero && r.valid &&
                        (r.all || ((!hi_delta[XLEN+1] && |hi_delta[XLEN:0]) &&
                         (lo_delta[XLEN+1] || lo_delta[XLEN:0] < {1'b0, access_size})));
                    entry_contains = size_nonzero && r.valid &&
                        (r.all || ((lo_delta[XLEN+1] || !(|lo_delta[XLEN:0])) &&
                         !hi_delta[XLEN+1] && hi_delta[XLEN:0] >= {1'b0, access_size}));
                end else begin
                    entry_overlaps = size_nonzero && r.valid &&
                        (r.all || (lt65({1'b0, access_start}, r.end_addr) && lt65({1'b0, r.start}, access_end)));
                    entry_contains = size_nonzero && r.valid &&
                        (r.all || (!lt65({1'b0, access_start}, {1'b0, r.start}) && !lt65(r.end_addr, access_end)));
                end
                if (!matched && entry_overlaps) begin
                    matched = 1'b1;
                    allow = entry_contains && permission_ok;
                end
            end
        end
    end
endmodule : pmp_checker
