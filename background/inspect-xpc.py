"""Decode the observed ObjC XPC protocol selector references in Freeform 5.0 (656.1.2).
Input is the unmodified arm64e slice, produced by xcrun lipo -thin arm64e.
Addresses are specific to that build. This never contacts an XPC service.
"""
import struct, json, sys
from pathlib import Path
b = Path(sys.argv[1]).read_bytes()
n = struct.unpack_from('<I', b, 16)[0]
off = 32
segments = []
for _ in range(n):
    cmd, size = struct.unpack_from('<II', b, off)
    if cmd == 0x19:
        vm, sz, fo, fs = struct.unpack_from('<QQQQ', b, off + 24)
        segments.append((vm, fs, fo))
    off += size

def offset(vm):
    for v, size, f in segments:
        if v <= vm < v + size:
            return f + vm - v
    raise ValueError(hex(vm))

def selector(ref):
    ptr = struct.unpack_from('<Q', b, offset(ref))[0]
    # These selector references use chained image-relative rebases in this slice.
    start = offset(0x100000000 + (ptr & 0xffffffff))
    return b[start:b.index(b'\0', start)].decode()

refs = {
    'CRLUSDRenderingExtensionAPIEndpointProtocol': [0x1019a1230, 0x1019a56a0, 0x10199faa8],
    'RealitySnapshotExtensionXPCProtocol': [0x1019b8e58, 0x10199dd08, 0x10199dd00, 0x10199d330],
    '_CRLUSDAsyncRenderingXPC': [0x1019a12b8, 0x1019a5428, 0x1019b17d0, 0x1019aa650, 0x1019b0818, 0x10199dd08, 0x10199dd00, 0x10199d330],
}
print(json.dumps({name: [selector(ref) for ref in items] for name, items in refs.items()}, indent=2))
