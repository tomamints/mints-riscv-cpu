// ------------------------------
// svutil package (DPI-C 直ラッパ)
// ------------------------------
`ifndef SYNTHESIS
package svutil;

    // --- get_env の C関数 ---
    import "DPI-C" context function string get_env_value(input string key);

    function string get_env(input string name);
        return get_env_value(name);
    endfunction


    // --- get_input の C関数 ---
    import "DPI-C" context function longint get_input_dpic();

    function longint get_input();
        return get_input_dpic();
    endfunction

endpackage : svutil
`endif



// ------------------------------
// util package (svutil の高レベルラッパ)
// ------------------------------
package util;

`ifndef SYNTHESIS
    function string get_env(input string name);
        return svutil::get_env(name);
    endfunction

    function longint get_input();
        return svutil::get_input();
    endfunction
`else
    // Synthesis: no host environment or input (board builds use parameters
    // and the physical UART).
    function string get_env(input string name);
        return "";
    endfunction

    function longint get_input();
        return 0;
    endfunction
`endif

endpackage : util
