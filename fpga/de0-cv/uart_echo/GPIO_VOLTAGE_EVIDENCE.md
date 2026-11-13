# DE0-CV GPIO voltage evidence

Scope: JP1 signal-level and pin-mapping references for the 3.3 V UART setup.

Terasic's official [DE0-CV specification](https://www.terasic.com.tw/cgi-bin/page/archive.pl?CategoryNo=163&Language=China&No=921&PartNo=2)
explicitly specifies both 2x20 GPIO headers as 3.3 V logic.
The manufacturer's [DE0-CV FAQ](https://www.terasic.com.tw/wiki/%E3%80%8ADE0-CV%E6%AF%8F%E6%97%A5%E4%B8%80%E9%97%AE%E3%80%8B)
also states that the GPIO bank voltage is fixed at 3.3 V.
These are manufacturer specification references, not a voltage measurement
on an individual board or a new schematic inspection.

Combined with the Terasic manual's JP1 pin mapping, this supports 3.3-V LVTTL
for JP1-8 (GPIO_0_D7/K22, FPGA TX) and JP1-10 (GPIO_0_D9/M21, FPGA RX).
JP1-12 is GND. Only TX/RX/GND are connected; no adapter power pin is used.
Use a USB-UART adapter with 3.3 V logic levels.

The Quartus bank voltage report alone was not used as evidence of board wiring.
