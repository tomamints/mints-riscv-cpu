// dcache unit test against the saved baseline dcache (HEAD e9f95e7, no
// DATA_RAM_STYLE parameter). Use with +define+TB_BASELINE_DCACHE.
// The baseline copy is created/verified by tools/test-dcache-unit.sh.
src/eei.sv
src/core_data_if.sv
build/baseline/dcache-e9f95e7/dcache.sv
tb/unit/cache/tb_dcache.sv
