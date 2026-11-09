package require ::quartus::sta
package require ::quartus::project
set failures 0
proc fail {message} { global failures; incr failures; post_message -type error "CHECK FAIL: $message" }
proc expect_count {label objects expected} {
    set actual [get_collection_size $objects]
    if {$actual != $expected} { fail "$label expected $expected, found $actual" }
}
project_open de0_cv_sdram_test
create_timing_netlist
read_sdc
update_timing_netlist
set dq [get_ports {DRAM_DQ[*]}]
set outputs [get_ports {DRAM_ADDR[*] DRAM_BA[*] DRAM_DQ[*] DRAM_RAS_N DRAM_CAS_N DRAM_WE_N DRAM_CS_N DRAM_CKE DRAM_LDQM DRAM_UDQM}]
expect_count {SDRAM data pins} $dq 16
expect_count {SDRAM command/data outputs} $outputs 38
expect_count {forwarded SDRAM clock} [get_clocks {*generic_pll2~PLL_OUTPUT_COUNTER|divclk}] 1
expect_count {external SDRAM clock} [get_clocks {SDRAM_CLK}] 1
expect_count {all clocks} [get_clocks {*}] 6
expect_count {restart first stage} [get_registers {*key_meta}] 1
expect_count {restart second stage} [get_registers {*key_sync}] 1
foreach_in_collection oc [get_available_operating_conditions] {
    set_operating_conditions $oc
    update_timing_netlist
    set corner [get_operating_conditions_info -display_name $oc]
    foreach kind {setup hold} {
        foreach {label extra} [list global {} read [list -from $dq] output [list -to $outputs] restart [list -from [get_registers {*key_meta}] -to [get_registers {*key_sync}]]] {
            set paths [get_timing_paths -$kind -npaths 1 {*}$extra]
            if {[get_collection_size $paths] == 0} { fail "$corner $label has no $kind path" }
            foreach_in_collection path $paths {
                set slack [get_path_info -slack $path]
                post_message -type info "CHECK $corner $label $kind slack=$slack"
                if {$slack < 0} { fail "$corner $label $kind slack=$slack" }
            }
        }
    }
    foreach kind {recovery removal} {
        set paths [get_timing_paths -$kind -npaths 1]
        if {[get_collection_size $paths] == 0} { fail "$corner has no $kind path" }
        foreach_in_collection path $paths {
            set slack [get_path_info -slack $path]
            post_message -type info "CHECK $corner global $kind slack=$slack"
            if {$slack < 0} { fail "$corner $kind slack=$slack" }
        }
    }
}
report_ucp -file check_constraints_ucp.rpt
set stream [open check_constraints_ucp.rpt r]
set unconstrained [read $stream]
close $stream
foreach line [split $unconstrained "\n"] {
    if {[string match {*No input delay*} $line] || [string match {*No output delay*} $line]} {
        set port [string trim [lindex [split $line ";"] 1]]
        if {$port ni {altera_reserved_tdi altera_reserved_tms altera_reserved_tdo}} {
            fail "unexpected unconstrained port: $port"
        }
    }
}
if {![regexp {; Unconstrained Clocks[ ]+; 0[ ]+; 0[ ]+;} $unconstrained]} {
    fail "unconstrained clock summary missing or nonzero"
}
report_clocks -file check_constraints_clocks.rpt
delete_timing_netlist
project_close
if {$failures} { qexit -error }
post_message -type info "check_constraints: all checks passed"
qexit -success
