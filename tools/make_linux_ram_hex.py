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
    parser.add_argument("--payload-offset", type=lambda value: int(value, 0), default=0)
    parser.add_argument("--dtb", required=True)
    parser.add_argument("--dtb-offset", type=lambda value: int(value, 0), required=True)
    parser.add_argument("--blob", action="append", default=[], help="Extra blob as OFFSET:PATH")
    parser.add_argument("--reserve", action="append", default=[],
                        help="Range that no region may overlap, as OFFSET:SIZE:NAME "
                             "(e.g. the OpenSBI FDT copy destination); nothing is written there")
    parser.add_argument("--size", type=lambda value: int(value, 0), required=True)
    parser.add_argument("--bytes-per-line", type=int, default=8)
    parser.add_argument("-o", "--output", required=True)
    args = parser.parse_args()

    with open(args.payload, "rb") as f:
        payload = f.read()
    with open(args.dtb, "rb") as f:
        dtb = f.read()

    regions = [(args.payload_offset, payload, args.payload)]
    for blob in args.blob:
        if ":" not in blob:
            raise SystemExit("--blob must be OFFSET:PATH")
        offset_text, path = blob.split(":", 1)
        offset = int(offset_text, 0)
        with open(path, "rb") as f:
            regions.append((offset, f.read(), path))

    regions.append((args.dtb_offset, dtb, args.dtb))

    for start, data, path in regions:
        if start < 0 or start + len(data) > args.size:
            raise SystemExit(f"{path} does not fit in RAM image")

    sorted_regions = sorted(regions, key=lambda region: region[0])
    for index in range(len(sorted_regions) - 1):
        start, data, path = sorted_regions[index]
        next_start, _, next_path = sorted_regions[index + 1]
        if start + len(data) > next_start:
            raise SystemExit(f"{path} overlaps {next_path}")

    if args.dtb_offset + len(dtb) > args.size:
        raise SystemExit("DTB does not fit in RAM image")

    for reserve in args.reserve:
        parts = reserve.split(":", 2)
        if len(parts) != 3:
            raise SystemExit("--reserve must be OFFSET:SIZE:NAME")
        r_start, r_size, r_name = int(parts[0], 0), int(parts[1], 0), parts[2]
        if r_start < 0 or r_size <= 0 or r_start + r_size > args.size:
            raise SystemExit(f"reserved range {r_name} does not fit in RAM image")
        for start, data, path in regions:
            if start < r_start + r_size and r_start < start + len(data):
                raise SystemExit(f"{path} overlaps reserved range {r_name}")

    with open(args.output, "w", encoding="ascii") as f:
        for start, data, _ in sorted_regions:
            write_region(f, start, data, args.bytes_per_line)


if __name__ == "__main__":
    main()
