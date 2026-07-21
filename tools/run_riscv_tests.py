import argparse
import os
import subprocess

try:
    from elftools.elf.elffile import ELFFile
except ModuleNotFoundError:
    ELFFile = None


def is_elf(filepath):
    try:
        with open(filepath, "rb") as f:
            return f.read(4) == b"\x7fELF"
    except OSError:
        return False


def read_u16(data, offset, endian):
    return int.from_bytes(data[offset:offset + 2], endian)


def read_u32(data, offset, endian):
    return int.from_bytes(data[offset:offset + 4], endian)


def read_u64(data, offset, endian):
    return int.from_bytes(data[offset:offset + 8], endian)


def get_c_string(data, offset):
    end = data.find(b"\x00", offset)
    if end < 0:
        return ""
    return data[offset:end].decode("utf-8", errors="replace")


def get_section_address_with_pyelftools(filepath, section_name):
    if ELFFile is None:
        return 0

    try:
        with open(filepath, "rb") as f:
            elffile = ELFFile(f)
            for section in elffile.iter_sections():
                if section.name == section_name:
                    return section.header["sh_addr"]
    except Exception:
        return 0

    return 0


def get_section_address_fallback(filepath, section_name):
    try:
        with open(filepath, "rb") as f:
            data = f.read()
    except OSError:
        return 0

    if len(data) < 64 or data[:4] != b"\x7fELF":
        return 0

    elf_class = data[4]
    endian_tag = data[5]
    if endian_tag == 1:
        endian = "little"
    elif endian_tag == 2:
        endian = "big"
    else:
        return 0

    if elf_class == 1:
        e_shoff = read_u32(data, 32, endian)
        e_shentsize = read_u16(data, 46, endian)
        e_shnum = read_u16(data, 48, endian)
        e_shstrndx = read_u16(data, 50, endian)
        sh_addr_off = 12
        sh_offset_off = 16
        sh_size_off = 20
    elif elf_class == 2:
        e_shoff = read_u64(data, 40, endian)
        e_shentsize = read_u16(data, 58, endian)
        e_shnum = read_u16(data, 60, endian)
        e_shstrndx = read_u16(data, 62, endian)
        sh_addr_off = 16
        sh_offset_off = 24
        sh_size_off = 32
    else:
        return 0

    if e_shoff == 0 or e_shentsize == 0 or e_shnum == 0 or e_shstrndx >= e_shnum:
        return 0

    shstr_header = e_shoff + e_shentsize * e_shstrndx
    if elf_class == 1:
        shstr_offset = read_u32(data, shstr_header + sh_offset_off, endian)
        shstr_size = read_u32(data, shstr_header + sh_size_off, endian)
    else:
        shstr_offset = read_u64(data, shstr_header + sh_offset_off, endian)
        shstr_size = read_u64(data, shstr_header + sh_size_off, endian)
    shstr = data[shstr_offset:shstr_offset + shstr_size]

    for index in range(e_shnum):
        header = e_shoff + e_shentsize * index
        name_offset = read_u32(data, header, endian)
        name = get_c_string(shstr, name_offset)
        if name == section_name:
            if elf_class == 1:
                return read_u32(data, header + sh_addr_off, endian)
            return read_u64(data, header + sh_addr_off, endian)

    return 0


def get_symbol_address_from_dump(filepath, symbol_name):
    dump_path = filepath + ".dump"
    if not os.path.exists(dump_path):
        return 0

    marker = f"<{symbol_name.lstrip('.')}>:"
    try:
        with open(dump_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if marker in line:
                    return int(line.split()[0], 16)
    except Exception:
        return 0

    return 0


def get_debug_address(filepath, label, ram_base):
    addr = get_section_address_with_pyelftools(filepath, label)
    if addr == 0:
        addr = get_section_address_fallback(filepath, label)
    if addr == 0:
        addr = get_symbol_address_from_dump(filepath, label)
    if addr != 0 and addr < ram_base:
        addr += ram_base
    return addr


def iter_tests(test_dir, filters, recursive):
    for entry in os.scandir(test_dir):
        if entry.is_dir():
            if recursive:
                yield from iter_tests(entry.path, filters, recursive)
            continue
        if not entry.is_file() or not is_elf(entry.path):
            continue
        if not filters:
            yield entry.path
            continue
        if any(filter_text in entry.name for filter_text in filters):
            yield entry.path


def run_test(args, dbg_addr, rom_hex, ram_hex):
    result_file_path = os.path.join(args.output_dir, ram_hex.replace(os.sep, "_") + ".txt")
    env = os.environ.copy()
    env["DBG_ADDR"] = str(dbg_addr)
    cmd = [args.sim_path, rom_hex, ram_hex, "0"]

    success = False
    with open(result_file_path, "w") as f:
        try:
            p = subprocess.Popen(cmd, stdout=f, stderr=f, env=env)
            p.wait(None if args.time_limit == 0 else args.time_limit)
            success = p.returncode == 0
        except subprocess.TimeoutExpired:
            success = False
        finally:
            if p.poll() is None:
                p.terminate()
                p.kill()

    print(("PASS" if success else "FAIL") + " : " + ram_hex)
    return ram_hex, success


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("sim_path", help="path to simulator")
    parser.add_argument("dir", help="directory containing tests")
    parser.add_argument("files", nargs="*", help="test file name filters")
    parser.add_argument("-r", "--recursive", action="store_true", help="search recursively")
    parser.add_argument("-e", "--extension", default=".bin.hex", help="hex file extension")
    parser.add_argument("-d", "--debug_label", default=".tohost", help="debug device label")
    parser.add_argument("-o", "--output_dir", default="results", help="result output directory")
    parser.add_argument("-t", "--time_limit", type=float, default=10, help="execution time limit; 0 means no limit")
    parser.add_argument("--rom", default="core/test/bootrom.hex", help="ROM hex file")
    parser.add_argument("--ram_base", type=lambda value: int(value, 0), default=0x80000000, help="RAM base address")
    return parser.parse_args()


def main():
    args = parse_args()
    os.makedirs(args.output_dir, exist_ok=True)

    results = []
    for elf_path in iter_tests(args.dir, args.files, args.recursive):
        ram_hex = elf_path + args.extension
        if not os.path.exists(ram_hex):
            print("SKIP : " + elf_path)
            continue

        dbg_addr = get_debug_address(elf_path, args.debug_label, args.ram_base)
        result = run_test(args, dbg_addr, os.path.abspath(args.rom), os.path.abspath(ram_hex))
        results.append(result)

    result_lines = sorted(("PASS" if status else "FAIL") + " : " + file_path for file_path, status in results)
    pass_count = sum(status for _, status in results)
    status_text = "Test Result : " + str(pass_count) + " / " + str(len(results))

    with open(os.path.join(args.output_dir, "result.txt"), "w", encoding="utf-8") as f:
        f.write(status_text + "\n")
        f.write("\n".join(result_lines))

    print(status_text)
    if pass_count != len(results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
