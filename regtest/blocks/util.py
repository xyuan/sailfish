import argparse
import sys

def parse_cmd_line():
    parser = argparse.ArgumentParser()
    parser.add_argument('--block_size', metavar='N', type=int, default=64,
            help='CUDA block size')
    args, remaining = parser.parse_known_args()
    # Remove processed arguments, but keep everything else in sys.argv.
    del sys.argv[1:]
    sys.argv.extend(remaining)
    return args
