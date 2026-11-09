"""Convert a binary to little-endian words for SystemVerilog $readmemh."""
import argparse
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bytes_per_word", type=int)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    if args.bytes_per_word <= 0:
        parser.error("bytes_per_word must be positive")
    data = args.binary.read_bytes()
    for offset in range(0, len(data), args.bytes_per_word):
        word = data[offset:offset + args.bytes_per_word]
        print(word.ljust(args.bytes_per_word, b"\0")[::-1].hex())


if __name__ == "__main__":
    main()
