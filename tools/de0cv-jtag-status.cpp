// Read-only SLD virtual JTAG status reader using openFPGALoader's transport.
// Requires one Cyclone V A4 and one virtual JTAG node (instance index zero).
#include "jtag.hpp"
#include <cstdio>
#include <stdexcept>

static void instruction(Jtag &j, uint16_t value) {
    uint8_t bytes[2]={uint8_t(value),uint8_t(value>>8)};
    if(j.shiftIR(bytes,nullptr,10)<0) throw std::runtime_error("IR scan failed");
}
static uint32_t dr(Jtag &j, uint64_t value, unsigned bits) {
    uint8_t tx[8]={},rx[8]={};
    for(unsigned i=0;i<8;i++) tx[i]=uint8_t(value>>(8*i));
    if(j.shiftDR(tx,rx,int(bits))<0) throw std::runtime_error("DR scan failed");
    return uint32_t(rx[0]) | uint32_t(rx[1])<<8 | uint32_t(rx[2])<<16 | uint32_t(rx[3])<<24;
}
static uint32_t info(Jtag &j) {
    uint32_t result=0;
    for(unsigned i=0;i<8;i++) result|=(dr(j,0,4)&15)<<(4*i);
    return result;
}
int main(int argc,char **argv) {
    try {
        jtag_pins_conf_t pins{};
        Jtag j(cable_list.at("usb-blaster"),&pins,"","",24000000,0,"",0);
        auto ids=j.get_devices_list();
        if(ids.size()!=1 || ids[0]!=0x02b050dd) throw std::runtime_error("expected single Cyclone V A4");
        j.device_select(0);
        j.go_test_logic_reset();
        instruction(j,0x00e); dr(j,0,64);
        instruction(j,0x00c);
        uint32_t hub=info(j);
        unsigned nodes=(hub>>19)&255, m=hub&255;
        if(((hub>>8)&2047)!=0x06e || nodes!=1 || m<2 || m>16)
            throw std::runtime_error("expected one SLD node with supported VIR width");
        uint32_t node=info(j);
        if(((node>>19)&255)!=8 || (node&255)!=0)
            throw std::runtime_error("expected virtual JTAG node instance zero");
        unsigned reg=0;
        if(argc==2) reg=unsigned(std::stoul(argv[1]));
        if(argc>2 || reg>3) throw std::runtime_error("register must be 0..3");
        instruction(j,0x00e); dr(j,(uint64_t(1)<<m)|reg,m+1);
        instruction(j,0x00c);
        uint32_t status=0;
        // Allow the two status synchronizer stages to settle in the TCK domain.
        for(int i=0;i<3;i++) status=dr(j,0,32);
        std::printf("{\"hub\":\"%08x\",\"node\":\"%08x\",\"status\":\"%08x\"}\n",hub,node,status);
        j.go_test_logic_reset();
        return reg!=0 || (status>>16)==0x5d4d ? 0 : 2;
    } catch(const std::exception &e) {
        std::fprintf(stderr,"JTAG status: %s\n",e.what()); return 1;
    }
}
