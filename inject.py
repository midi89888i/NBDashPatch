#!/usr/bin/env python3
"""Inject a dylib load command into an unencrypted arm64 Mach-O executable.

Adds LC_LOAD_DYLIB (@executable_path/<dylibname>) using zero padding after the
existing load commands, then rewrites the binary in place. Verified for
NinebotDash v1.3.1 which ships without encryption or signature.
"""
import struct
import sys

def parse_macho(data):
    magic = struct.unpack('<I', data[:4])[0]
    if magic != 0xfeedfacf:
        raise SystemExit('not a 64-bit Mach-O (fat binaries unsupported)')
    ncmds, sizeofcmds = struct.unpack('<II', data[16:24])
    return ncmds, sizeofcmds

def inject(binary_path, dylib_name):
    data = bytearray(open(binary_path, 'rb').read())
    ncmds, sizeofcmds = parse_macho(data)
    end = 32 + sizeofcmds

    name = f'@executable_path/{dylib_name}'.encode() + b'\x00'
    # LC_LOAD_DYLIB = 0xc: cmd, cmdsize, name offset, timestamp, current, compat
    cmdsize = (24 + len(name) + 7) & ~7
    # verify slack: need cmdsize zero bytes at end
    slack = data[end:end + cmdsize]
    if any(b != 0 for b in slack):
        raise SystemExit(f'no header slack at {hex(end)} (need {cmdsize} bytes)')

    lc = struct.pack('<IIIIII', 0xc, cmdsize, 24, 2, 0, 0)
    cmd = bytearray(lc + name)
    cmd.extend(b'\x00' * (cmdsize - len(cmd)))
    data[end:end + cmdsize] = cmd

    # update header: ncmds +1, sizeofcmds +cmdsize
    data[16:20] = struct.pack('<I', ncmds + 1)
    data[20:24] = struct.pack('<I', sizeofcmds + cmdsize)

    open(binary_path, 'wb').write(bytes(data))
    print(f'injected LC_LOAD_DYLIB {dylib_name} ({cmdsize} bytes) at {hex(end)}; ncmds {ncmds}->{ncmds+1}')

if __name__ == '__main__':
    inject(sys.argv[1], sys.argv[2])
