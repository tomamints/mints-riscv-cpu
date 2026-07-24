import eei::*;

module pmp_checker (
    input PrivMode priv_mode,
    input Addr access_start,
    input UIntX access_size,
    input logic is_write,
    input UIntX pmpcfg0,
    input UIntX pmpaddr0,
    input UIntX pmpaddr1,
    input UIntX pmpaddr2,
    input UIntX pmpaddr3,
    output logic allow
);

    function automatic logic pmp_range_overlaps(
        input Addr access_start,
        input UIntX access_size,
        input Addr region_start,
        input Addr region_end
    );
        if (access_size == 0 || region_start >= region_end) begin
            return 1'b0;
        end
        if (access_start >= region_start) begin
            return access_start < region_end;
        end
        return access_size > region_start - access_start;
    endfunction

    function automatic logic pmp_range_contains(
        input Addr access_start,
        input UIntX access_size,
        input Addr region_start,
        input Addr region_end
    );
        if (access_size == 0 || region_start >= region_end) begin
            return 1'b0;
        end
        return access_start >= region_start &&
               access_start < region_end &&
               access_size <= region_end - access_start;
    endfunction

    task automatic pmp_napot_check(
        input Addr access_start,
        input UIntX access_size,
        input Addr pmpaddr,
        output logic overlaps,
        output logic contains
    );
        logic found_zero;
        int zero_bit_index;
        Addr region_start;
        Addr region_size;
        Addr offset;

        overlaps = 1'b0;
        contains = 1'b0;
        found_zero = 1'b0;
        zero_bit_index = 0;
        for (int bit_index = 0; bit_index < XLEN; bit_index++) begin
            if (!pmpaddr[bit_index] && !found_zero) begin
                found_zero = 1'b1;
                zero_bit_index = bit_index;
                break;
            end
        end

        if (access_size == 0) begin
            overlaps = 1'b0;
            contains = 1'b0;
        end else if ((pmpaddr & PMPADDR_WMASK) == PMPADDR_WMASK) begin
            overlaps = 1'b1;
            contains = 1'b1;
        end else if (!found_zero || zero_bit_index + 3 >= XLEN) begin
            overlaps = 1'b1;
            contains = 1'b1;
        end else begin
            region_size = Addr'(1) << (zero_bit_index + 3);
            region_start = (pmpaddr << 2) & ~(region_size - 1);

            if (access_start >= region_start) begin
                offset = access_start - region_start;
                overlaps = offset < region_size;
                contains = overlaps && access_size <= region_size - offset;
            end else begin
                overlaps = access_size > region_start - access_start;
                contains = 1'b0;
            end
        end
    endtask

    always_comb begin
        logic matched;
        logic entry_overlaps;
        logic entry_contains;
        logic permission_ok;
        logic [7:0] cfg [0:3];
        Addr addr [0:3];
        Addr tor_start;
        Addr tor_end;

        if (priv_mode == M) begin
            allow = 1'b1;
        end else begin
            cfg[0] = pmpcfg0[7:0];
            cfg[1] = pmpcfg0[15:8];
            cfg[2] = pmpcfg0[23:16];
            cfg[3] = pmpcfg0[31:24];
            addr[0] = pmpaddr0;
            addr[1] = pmpaddr1;
            addr[2] = pmpaddr2;
            addr[3] = pmpaddr3;

            matched = 1'b0;
            allow = 1'b0;
            for (int pmp_index = 0; pmp_index < 4; pmp_index++) begin
                entry_overlaps = 1'b0;
                entry_contains = 1'b0;
                permission_ok = is_write ? cfg[pmp_index][1] : cfg[pmp_index][0];

                unique case (cfg[pmp_index][4:3])
                    2'b01: begin
                        tor_start = (pmp_index == 0) ? Addr'(0) : (addr[pmp_index - 1] << 2);
                        tor_end = addr[pmp_index] << 2;
                        entry_overlaps = pmp_range_overlaps(access_start, access_size, tor_start, tor_end);
                        entry_contains = pmp_range_contains(access_start, access_size, tor_start, tor_end);
                    end
                    2'b11: begin
                        pmp_napot_check(access_start, access_size, addr[pmp_index], entry_overlaps, entry_contains);
                    end
                    default: begin
                        entry_overlaps = 1'b0;
                        entry_contains = 1'b0;
                    end
                endcase

                if (!matched && entry_overlaps) begin
                    matched = 1'b1;
                    allow = entry_contains && permission_ok;
                end
            end
        end
    end
endmodule : pmp_checker
