import struct

MASK = (1 << 64) - 1


def _key(klen, i, seed):
    b = bytearray(klen)
    if i < 64:
        b[i >> 3] = 128 >> (i & 7)
        return bytes(b)
    x = (seed ^ (i * 2654435761)) & MASK
    for j in range(klen):
        x = (x * 6364136223846793005 + 1442695040888963407) & MASK
        b[j] = (x >> 56) & 255
    return bytes(b)


def _case(klen, seed, words):
    t = {}
    order = []

    def set_(k, v):
        if k not in t:
            order.append(k)
        t[k] = v

    def del_(k):
        if k not in t:
            return
        pos = order.index(k)
        order[pos] = order[-1]
        order.pop()
        del t[k]

    for i in range(128):
        k = (i * 37) & 127
        set_(_key(klen, k, seed), k + 1000)
    words.append(len(t))

    for i in range(128):
        if (i & 1) == 0:
            del_(_key(klen, i, seed))

    for i in range(128):
        if i % 4 == 2:
            set_(_key(klen, i, seed), i + 5000)
        if i % 8 == 3:
            set_(_key(klen, i, seed), i + 5000)

    for i in range(128):
        k = _key(klen, i, seed)
        words.append((1 | (t[k] << 8)) if k in t else 0)

    n = len(t)
    words.append(n)
    for k in order:
        words.append(int.from_bytes(k[:8], "little"))
        words.append(t[k])

    for i in range(128, 144):
        set_(_key(klen, i, seed), 7000 + i)
    while len(order) > n:
        k = order.pop()
        del t[k]
    words.append(len(t))
    for i in range(128, 144):
        words.append(0)  # every appended key was truncated away
    for i in range(4):
        k = _key(klen, i, seed)
        words.append((1 | (t[k] << 8)) if k in t else 0)

    c = dict(t)
    corder = list(order)
    while c:
        k = corder[0]
        pos = corder.index(k)
        corder[pos] = corder[-1]
        corder.pop()
        del c[k]
    words.append(len(c))
    words.append(len(t))

    while order:
        k = order[0]
        pos = order.index(k)
        order[pos] = order[-1]
        order.pop()
        del t[k]
    words.append(len(t))

    k = _key(klen, 127, seed)
    set_(k, 9999)
    words.append(1 | (9999 << 8))
    words.append(len(t))


def expected(blob):
    seed = int.from_bytes(blob[:8], "little") if len(blob) >= 8 else 0
    words = []
    for n, klen in enumerate((20, 28, 32, 52, 60)):
        _case(klen, seed + n, words)
    return b"".join(struct.pack("<Q", w & MASK) for w in words)
