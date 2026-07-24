import argparse


def write_region(f, start_offset, data, bytes_per_line):
    padding = (-len(data)) % bytes_per_line
    data += b"\x00" * padding

    f.write(f"@{start_offset // bytes_per_line:x}\n")
    for offset in range(0, len(data), bytes_per_line):
        chunk = data[offset:offset + bytes_per_line]
        f.write("".join(f"{byte:02x}" for byte in reversed(chunk)))
        f.write("\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--payload", required=True)
    parser.add_argument("--dtb", required=True)
    parser.add_argument("--dtb-offset", type=lambda value: int(value, 0), required=True)
    parser.add_argument("--size", type=lambda value: int(value, 0), required=True)
    parser.add_argument("--bytes-per-line", type=int, default=8)
    parser.add_argument("-o", "--output", required=True)
    args = parser.parse_args()

    with open(args.payload, "rb") as f:
        payload = f.read()
    with open(args.dtb, "rb") as f:
        dtb = f.read()

    if len(payload) > args.dtb_offset:
        raise SystemExit("payload overlaps DTB offset")
    if args.dtb_offset + len(dtb) > args.size:
        raise SystemExit("DTB does not fit in RAM image")

    with open(args.output, "w", encoding="ascii") as f:
        write_region(f, 0, payload, args.bytes_per_line)
        write_region(f, args.dtb_offset, dtb, args.bytes_per_line)


if __name__ == "__main__":
    main()
