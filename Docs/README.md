# Documentation

The current validated targets are Linux/BusyBox in Verilator and an interactive
Linux/BusyBox UART shell on DE0-CV at 20 MHz. Board and simulator settings are
separate; use the appropriate profile when building.

| Read this for | Document |
|---|---|
| Project overview | [Repository README](../readme.md) |
| Supported configurations and limits | [Current status](CURRENT_STATUS.md) |
| Physical board wiring, build and boot (Japanese) | [DE0-CV Linux guide](../fpga/de0-cv/soc/README.md) |
| Linux profiles and software stack | [Linux setup](LINUX_SETUP.md) |
| Dependencies and recovery after deleting build outputs | [Rebuild from clean](REBUILD_FROM_CLEAN.md) |
| What was actually tested | [Test status](TEST_STATUS.md) |
| Meaning of the Linux boot milestones | [Linux validation scope](LINUX_MILESTONES.md) |
| Simulation correctness / performance workloads | [Linux baseline](LINUX_BASELINE.md) |
| Linux UIO / switch-button input / LED control | [Board GPIO API and apps](../examples/boardctl/README.md) |
| Standalone C application and elapsed-time workload | [MiNTs Life](../examples/life/README.md) |
| Simulation performance counter definitions | [Performance counters](PERFORMANCE_COUNTERS.md) |
| Frontend prediction and historical measurements | [Frontend branch BTB](FRONTEND_BRANCH_BTB.md) |
| Source locations | [RTL layout](RTL_LAYOUT.md) |
| Optional simulator DMA peripheral | [DMA](DMA.md) |
| Architectural capability boundaries | [RVA23 scope checklist](RVA23_CHECKLIST.md) |
| Supported and unsupported platform features | [Platform scope](ROADMAP.md) |
| Board component examples | [DE0-CV board support](../fpga/de0-cv/README.md) |

Performance figures in the baseline/frontend documents are historical simulator
measurements. They are not current FPGA benchmark scores or promises that the
latest checkout reproduces an identical instruction count. Build and run commands
must be executed in the documented host/container environment.
