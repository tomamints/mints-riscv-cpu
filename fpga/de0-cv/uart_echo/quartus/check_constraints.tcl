# Post-compile constraint audit for de0_cv_uart_echo.
# Usage (from the quartus directory): quartus_sta -t check_constraints.tcl
# Exits non-zero if any expectation fails. Unconstrained-path reporting alone is
# not relied upon, because an empty collection silently drops an exception.
package require ::quartus::sta
package require ::quartus::project

set failures 0
proc fail {msg} {
    global failures
    post_message -type error "CHECK FAIL: $msg"
    incr failures
}
proc ok {msg} {
    post_message -type info "CHECK OK: $msg"
}
proc expect_count {what coll n} {
    set c [get_collection_size $coll]
    if {$c != $n} { fail "$what: expected $n, found $c" } else { ok "$what: $c" }
}
# API checked against Quartus 20.1 help (build/fpga/qhelp/sta_help.log):
#   get_path_info [-slack] <path_ref>   (options first, path object last)
#   get_timing_paths [-setup|-hold] [-npaths N] [-from names] [-to names]
proc worst_slack {kind from_coll to_coll} {
    set paths [get_timing_paths -$kind -npaths 1 -from $from_coll -to $to_coll]
    set slack ""
    foreach_in_collection p $paths { set slack [get_path_info -slack $p] }
    return $slack
}

project_open de0_cv_uart_echo
create_timing_netlist
read_sdc
update_timing_netlist

# Objects named by the SDC exceptions must exist exactly once each.
expect_count {port KEY0_N}          [get_ports {KEY0_N}] 1
expect_count {port UART_RXD}        [get_ports {UART_RXD}] 1
expect_count {port UART_TXD}        [get_ports {UART_TXD}] 1
expect_count {ports LEDR[*]}        [get_ports {LEDR[*]}] 10
expect_count {reset sync registers} [get_registers {*reset_meta* *reset_n*}] 2
expect_count {rx sync stage 1}      [get_registers {*u_rx|rxd_meta}] 1
expect_count {rx sync stage 2}      [get_registers {*u_rx|rxd_sync}] 1
expect_count {tx output register}   [get_registers {*u_tx|txd}] 1

# Timing checks for every available operating condition (corner).
foreach_in_collection oc [get_available_operating_conditions] {
    set_operating_conditions $oc
    update_timing_netlist
    set corner [get_operating_conditions_info -display_name $oc]

    # The synchronizer flop-to-flop stages must remain timed (not cut): both the
    # setup and the hold check must exist with non-negative slack for each stage.
    foreach {name from to} {
        {reset_meta->reset_n} {*reset_meta} {*reset_n}
        {rxd_meta->rxd_sync}  {*u_rx|rxd_meta} {*u_rx|rxd_sync}
    } {
        foreach kind {setup hold} {
            set s [worst_slack $kind [get_registers $from] [get_registers $to]]
            if {$s eq ""} {
                fail "$corner: $name has no timed $kind path"
            } elseif {$s < 0} {
                fail "$corner: $name $kind slack $s"
            } else {
                ok "$corner: $name timed, $kind slack $s"
            }
        }
    }

    # Whole-design worst setup/hold slack.
    foreach kind {setup hold} {
        set s ""
        foreach_in_collection p [get_timing_paths -$kind -npaths 1] { set s [get_path_info -slack $p] }
        if {$s eq ""} {
            fail "$corner: no $kind paths reported"
        } elseif {$s < 0} {
            fail "$corner: worst $kind slack $s"
        } else {
            ok "$corner: worst $kind slack $s"
        }
    }
}

report_ucp -file check_constraints_ucp.rpt
delete_timing_netlist
project_close

if {$failures > 0} {
    post_message -type error "check_constraints: $failures failure(s)"
    qexit -error
}
post_message -type info "check_constraints: all checks passed"
qexit -success
