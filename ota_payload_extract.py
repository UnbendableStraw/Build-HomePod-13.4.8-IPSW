#!/usr/bin/env python3
"""Extract a pre-AppleArchive OTA payloadv2 chunk (iOS/tvOS/audioOS 10-13).

Each chunk is a pbzx stream of records:
    +0   u16  record type (0x1001 / 0x1002 seen)
    +2   u64  data size (big-endian)
    +10  u64  mtime (big-endian, seconds)
    +18  u32  unknown
    +22  u16  name length
    +24  u16  uid
    +26  u16  gid
    +28  u16  mode (st_mode: type + permissions)
    +30  name, then data (file contents, or the link target for a symlink)

Usage: ota_payload_extract.py DESTDIR CHUNK [CHUNK ...]
Run as root to keep ownership; otherwise ownership is skipped with a warning.
Layout worked out from the 17M61 OTA on 2026-11-25. Not an Apple tool.
"""
import lzma, os, struct, sys

def pbzx(f):
    if f.read(4) != b'pbzx':
        raise SystemExit('not a pbzx stream')
    f.read(8)
    while True:
        h = f.read(16)
        if len(h) < 16:
            return
        _flags, ln = struct.unpack('>QQ', h)
        d = f.read(ln)
        yield lzma.decompress(d) if d[:6] == b'\xfd7zXZ\x00' else d

class Stream:
    def __init__(self, gen):
        self.g, self.b = gen, b''
    def read(self, n):
        while len(self.b) < n:
            try:
                self.b += next(self.g)
            except StopIteration:
                break
        r, self.b = self.b[:n], self.b[n:]
        return r

def extract(chunk, dest, dirs, root):
    st = Stream(pbzx(open(chunk, 'rb')))
    n = 0
    while True:
        h = st.read(30)
        if not h:
            break
        if len(h) < 30:
            raise SystemExit('%s: truncated record header' % chunk)
        size, mtime = struct.unpack('>QQ', h[2:18])
        nl, uid, gid, mode = struct.unpack('>HHHH', h[22:30])
        name = st.read(nl).decode('utf-8')
        if name.startswith('/') or '..' in name.split('/'):
            raise SystemExit('refusing path %r' % name)
        path = os.path.join(dest, name)
        kind = mode & 0xF000
        if kind == 0x4000:
            os.makedirs(path, exist_ok=True)
            if size:
                st.read(size)
            dirs.append((path, mode & 0o7777, uid, gid, mtime))
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            if os.path.lexists(path):
                os.unlink(path)
            if kind == 0xA000:
                os.symlink(st.read(size).decode('utf-8'), path)
            elif kind == 0x8000:
                with open(path, 'wb') as o:
                    left = size
                    while left:
                        c = st.read(min(left, 1 << 20))
                        if not c:
                            raise SystemExit('%s: truncated data for %s' % (chunk, name))
                        o.write(c)
                        left -= len(c)
                os.chmod(path, mode & 0o7777)
                os.utime(path, (mtime, mtime))
            else:
                raise SystemExit('%s: unhandled file type %o for %s' % (chunk, mode, name))
            if root:
                os.lchown(path, uid, gid)
        n += 1
    return n

def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    dest = sys.argv[1]
    root = os.geteuid() == 0
    if not root:
        print('warning: not root, ownership will not be applied', file=sys.stderr)
    os.makedirs(dest, exist_ok=True)
    dirs, total = [], 0
    for chunk in sys.argv[2:]:
        n = extract(chunk, dest, dirs, root)
        print('%s: %d entries' % (os.path.basename(chunk), n))
        total += n
    for path, perm, uid, gid, mtime in reversed(dirs):
        if root:
            os.chown(path, uid, gid)
        os.chmod(path, perm)
        os.utime(path, (mtime, mtime))
    print('total %d entries' % total)

if __name__ == '__main__':
    main()
