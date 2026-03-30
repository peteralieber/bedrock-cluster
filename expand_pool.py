#!/usr/bin/env python3
import sys

def expand_octet(o):
    o = o.strip()
    if o == '*':
        return range(1, 256)
    if '-' in o:
        start, end = o.split('-', 1)
        return range(int(start), int(end) + 1)
    return [int(o)]

def expand_ip_pattern(pattern):
    octets = pattern.strip().split('.')
    if len(octets) != 4:
        return []
    ranges = [expand_octet(o) for o in octets]
    for a in ranges[0]:
        for b in ranges[1]:
            for c in ranges[2]:
                for d in ranges[3]:
                    yield f"{a}.{b}.{c}.{d}"

def expand_file(filename):
    with open(filename) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            for ip in expand_ip_pattern(line):
                print(ip)

if __name__ == "__main__":
    expand_file(sys.argv[1])
