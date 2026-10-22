# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 htjulia
import struct, sys
# Print the size of .gnu.linkonce.this_module (== sizeof(struct module) the module was built for)
for path in sys.argv[1:]:
    d = open(path, 'rb').read()
    shoff, = struct.unpack_from('<Q', d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3A)
    def sh(i): return struct.unpack_from('<IIQQQQIIQQ', d, shoff + i * shentsize)
    stroff = sh(shstrndx)[4]
    for i in range(shnum):
        s = sh(i)
        name = d[stroff + s[0]:d.index(b'\0', stroff + s[0])].decode()
        if name == '.gnu.linkonce.this_module':
            print('%-50s 0x%x' % (path, s[5]))
