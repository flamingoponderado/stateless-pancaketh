#!/usr/bin/env python3
"""blsref.py -- pure-int Python model of exactly the BLS12-381 algorithms that
guest/src/lib/fp384.pnk and guest/src/lib/bls12381.pnk implement, plus the
constant generator for guest/src/lib/bls12381_consts.pnk.

Tower (standard, as in blst / zkcrypto, NOT py_ecc's flat FQ12):
  Fp2  = Fp[u]  / (u^2 + 1)
  Fp6  = Fp2[v] / (v^3 - xi),  xi = 1 + u
  Fp12 = Fp6[w] / (w^2 - v)
G2 lives on the M-twist y^2 = x^3 + 4(1+u) (py_ecc's b2 = (4, 4)).
The pairing is the optimal ate pairing with the 64-bit loop |x|,
x = -0xd201000000010000, and the cyclotomic final exponentiation.  The
precompiles only need "product of pairings == 1", a property shared by every
non-degenerate bilinear pairing on the same groups, so booleans agree with
py_ecc; `selfcheck()` verifies bilinearity and agreement on random inputs.

Group law = py_ecc optimized_curve (homogeneous projective, same case split),
so normalised outputs match py_ecc byte for byte.

Run `uv run --directory evm-asm/execution-specs python tools/blsref.py` for
the self-check (needs py_ecc); `--consts OUT.pnk` writes the constants file.
"""
import sys

P = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab
R_ORDER = 0x73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001
BLS_X = 0xd201000000010000          # |x|, x is negative
H_EFF_G1 = 15132376222941642753
H_EFF_G2 = 209869847837335686905080341498658477663839067235703451875306851526599783796572738804459333109033834234622528588876978987822447936461846631641690358257586228683615991308971558879306463436166481

G1X = 0x17f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb
G1Y = 0x08b3f481e3aaa0f1a09e30ed741d8ae4fcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1
G2X = (0x024aa2b2f08f0a91260805272dc51051c6e47ad4fa403b02b4510b647ae3d1770bac0326a805bbefd48056c8c121bdb8,
       0x13e02b6052719f607dacd3a088274f65596bd0d09920b61ab5da61bbdc7f5049334cf11213945d57e5ac7d055d042b7e)
G2Y = (0x0ce5d527727d6e118cc9cdc6da2e351aadfd9baa8cbdd3a76d429a695160d12c923ac9cc3baca289e193548608b82801,
       0x0606c4a02ea734cc32acd2b02bc28b99cb3e287e85a763af267492ab572e99ab3f370d275cec1da1aaa9075ff05f79be)
# KZG_SETUP_G2_MONOMIAL_1 decompressed (PrecompilesKzg.lean; re-derived in selfcheck)
KZG_G2_1X = (0x185cbfee53492714734429b7b38608e23926c911cceceac9a36851477ba4c60b087041de621000edc98edada20c1def2,
             0x15bfd7dd8cdeb128843bc287230af38926187075cbfbefa81009a2ce615ac53d2914e5870cb452d2afaaab24f3499f72)
KZG_G2_1Y = (0x014353bdb96b626dd7d5ee8599d1fca2131569490e28de18e82451a496a9c9794ce26d105941f383ee689bfbbb832a99,
             0x1666c54b0a32529503432fcae0181b4bef79de09fc63671fda5ed1ba9bfa07899495346f3d7ac9cd23048ef30d0a154f)

# ---------------- Fp / Fp2 / Fp6 / Fp12 ----------------
def fp_inv(a):
    return pow(a, P - 2, P) if a else 0

def f2_add(a, b): return ((a[0] + b[0]) % P, (a[1] + b[1]) % P)
def f2_sub(a, b): return ((a[0] - b[0]) % P, (a[1] - b[1]) % P)
def f2_neg(a): return ((-a[0]) % P, (-a[1]) % P)
def f2_mul(a, b):
    # (a0 + a1 u)(b0 + b1 u) = a0b0 - a1b1 + (a0b1 + a1b0) u
    return ((a[0] * b[0] - a[1] * b[1]) % P, (a[0] * b[1] + a[1] * b[0]) % P)
def f2_sqr(a): return f2_mul(a, a)
def f2_conj(a): return (a[0], (-a[1]) % P)
def f2_mul_xi(a):
    # (a0 + a1 u)(1 + u) = (a0 - a1) + (a0 + a1) u
    return ((a[0] - a[1]) % P, (a[0] + a[1]) % P)
def f2_scale(a, k): return (a[0] * k % P, a[1] * k % P)
def f2_inv(a):
    d = fp_inv((a[0] * a[0] + a[1] * a[1]) % P)
    return (a[0] * d % P, (-a[1]) * d % P)
def f2_pow(a, e):
    r = (1, 0)
    for bit in bin(e)[2:]:
        r = f2_sqr(r)
        if bit == '1':
            r = f2_mul(r, a)
    return r
F2_ZERO = (0, 0); F2_ONE = (1, 0)
XI = (1, 1)

def f6_add(a, b): return tuple(f2_add(x, y) for x, y in zip(a, b))
def f6_sub(a, b): return tuple(f2_sub(x, y) for x, y in zip(a, b))
def f6_neg(a): return tuple(f2_neg(x) for x in a)
def f6_mul(a, b):
    a0, a1, a2 = a; b0, b1, b2 = b
    c0 = f2_add(f2_mul(a0, b0), f2_mul_xi(f2_add(f2_mul(a1, b2), f2_mul(a2, b1))))
    c1 = f2_add(f2_add(f2_mul(a0, b1), f2_mul(a1, b0)), f2_mul_xi(f2_mul(a2, b2)))
    c2 = f2_add(f2_add(f2_mul(a0, b2), f2_mul(a1, b1)), f2_mul(a2, b0))
    return (c0, c1, c2)
def f6_mul_v(a):
    # (a0 + a1 v + a2 v^2) v = xi a2 + a0 v + a1 v^2
    return (f2_mul_xi(a[2]), a[0], a[1])
def f6_inv(a):
    a0, a1, a2 = a
    t0 = f2_sub(f2_sqr(a0), f2_mul_xi(f2_mul(a1, a2)))
    t1 = f2_sub(f2_mul_xi(f2_sqr(a2)), f2_mul(a0, a1))
    t2 = f2_sub(f2_sqr(a1), f2_mul(a0, a2))
    d = f2_add(f2_mul(a0, t0), f2_mul_xi(f2_add(f2_mul(a2, t1), f2_mul(a1, t2))))
    di = f2_inv(d)
    return (f2_mul(t0, di), f2_mul(t1, di), f2_mul(t2, di))
F6_ZERO = (F2_ZERO,) * 3; F6_ONE = (F2_ONE, F2_ZERO, F2_ZERO)

def f12_mul(a, b):
    a0, a1 = a; b0, b1 = b
    t0 = f6_mul(a0, b0); t1 = f6_mul(a1, b1)
    c0 = f6_add(t0, f6_mul_v(t1))
    c1 = f6_sub(f6_sub(f6_mul(f6_add(a0, a1), f6_add(b0, b1)), t0), t1)
    return (c0, c1)
def f12_sqr(a): return f12_mul(a, a)
def f12_conj(a): return (a[0], f6_neg(a[1]))
def f12_inv(a):
    a0, a1 = a
    d = f6_inv(f6_sub(f6_mul(a0, a0), f6_mul_v(f6_mul(a1, a1))))
    return (f6_mul(a0, d), f6_neg(f6_mul(a1, d)))
def f12_eq(a, b): return a == b
F12_ONE = (F6_ONE, F6_ZERO)

# Frobenius constants gamma_k = xi^(k (p-1)/6), k = 1..5
GAMMA = [None] + [f2_pow(XI, k * (P - 1) // 6) for k in range(1, 6)]

def f12_frob(a):
    (a00, a01, a02), (a10, a11, a12) = a
    return ((f2_conj(a00), f2_mul(f2_conj(a01), GAMMA[2]), f2_mul(f2_conj(a02), GAMMA[4])),
            (f2_mul(f2_conj(a10), GAMMA[1]), f2_mul(f2_conj(a11), GAMMA[3]), f2_mul(f2_conj(a12), GAMMA[5])))

def f12_pow(a, e):
    r = F12_ONE
    for bit in bin(e)[2:]:
        r = f12_sqr(r)
        if bit == '1':
            r = f12_mul(r, a)
    return r

def f12_exp_x(a):
    """a^x for the NEGATIVE x: (a^|x|)^-1 = conj(a^|x|) in the cyclotomic subgroup."""
    return f12_conj(f12_pow(a, BLS_X))

def final_exp(f):
    # easy part: f^((p^6 - 1)(p^2 + 1))
    t = f12_mul(f12_conj(f), f12_inv(f))            # f^(p^6 - 1)
    m = f12_mul(f12_frob(f12_frob(t)), t)           # ^(p^2 + 1)
    # hard part (Hayashida-Hayasaka-Teruya): m^(3 (p^4 - p^2 + 1)/r)
    #   = m^((x-1)^2 (x + p)(x^2 + p^2 - 1)) * m^3
    a = f12_mul(f12_exp_x(m), f12_conj(m))          # m^(x-1)
    a = f12_mul(f12_exp_x(a), f12_conj(a))          # m^((x-1)^2)
    b = f12_mul(f12_exp_x(a), f12_frob(a))          # a^(x + p)
    c = f12_exp_x(f12_exp_x(b))                     # b^(x^2)
    c = f12_mul(f12_mul(c, f12_frob(f12_frob(b))), f12_conj(b))   # b^(x^2 + p^2 - 1)
    m3 = f12_mul(f12_sqr(m), m)
    return f12_mul(c, m3)

# ---------------- group law (py_ecc optimized_curve) ----------------
class Fld:
    """Field-generic helpers so the same projective code serves G1 and G2."""
    def __init__(self, one, zero, add, sub, mul, neg, eq):
        self.one, self.zero, self.add, self.sub, self.mul, self.neg, self.eq = one, zero, add, sub, mul, neg, eq
    def smul(self, k, a):  # small integer times element
        r = self.zero
        for _ in range(k):
            r = self.add(r, a)
        return r

F1 = Fld(1, 0, lambda a, b: (a + b) % P, lambda a, b: (a - b) % P, lambda a, b: a * b % P, lambda a: (-a) % P, lambda a, b: a == b)
F2 = Fld(F2_ONE, F2_ZERO, f2_add, f2_sub, f2_mul, f2_neg, lambda a, b: a == b)

def pt_inf(F): return (F.one, F.one, F.zero)
def pt_is_inf(F, p): return F.eq(p[2], F.zero)

def pt_double(F, pt):
    x, y, z = pt
    W = F.smul(3, F.mul(x, x))
    S = F.mul(y, z)
    B = F.mul(F.mul(x, y), S)
    H = F.sub(F.mul(W, W), F.smul(8, B))
    S2 = F.mul(S, S)
    nx = F.smul(2, F.mul(H, S))
    ny = F.sub(F.mul(W, F.sub(F.smul(4, B), H)), F.smul(8, F.mul(F.mul(y, y), S2)))
    nz = F.smul(8, F.mul(S, S2))
    return (nx, ny, nz)

def pt_add(F, p1, p2):
    if F.eq(p1[2], F.zero): return p2
    if F.eq(p2[2], F.zero): return p1
    x1, y1, z1 = p1; x2, y2, z2 = p2
    U1 = F.mul(y2, z1); U2 = F.mul(y1, z2)
    V1 = F.mul(x2, z1); V2 = F.mul(x1, z2)
    if F.eq(V1, V2):
        if F.eq(U1, U2):
            return pt_double(F, p1)
        return pt_inf(F)
    U = F.sub(U1, U2); V = F.sub(V1, V2)
    V2s = F.mul(V, V); V2sV2 = F.mul(V2s, V2); V3 = F.mul(V, V2s)
    W = F.mul(z1, z2)
    A = F.sub(F.sub(F.mul(F.mul(U, U), W), V3), F.smul(2, V2sV2))
    return (F.mul(V, A), F.sub(F.mul(U, F.sub(V2sV2, A)), F.mul(V3, U2)), F.mul(V3, W))

def pt_mul(F, pt, n):
    """MSB-first double-and-add; same group element as py_ecc multiply."""
    r = pt_inf(F)
    for bit in bin(n)[2:] if n else '':
        r = pt_double(F, r)
        if bit == '1':
            r = pt_add(F, r, pt)
    return r

def pt_neg(F, p): return (p[0], F.neg(p[1]), p[2])

def pt_normalize(F, p, inv):
    zi = inv(p[2])
    return (F.mul(p[0], zi), F.mul(p[1], zi))

def g1_on_curve(x, y):   # affine, non-infinity
    return (y * y - x * x * x - 4) % P == 0
def g2_on_curve(x, y):
    return f2_sub(f2_sqr(y), f2_add(f2_mul(f2_sqr(x), x), (4, 4))) == F2_ZERO

# ---------------- pairing ----------------
def miller_loop(P1, Q):
    """P1 = (x, y) affine G1, Q = (x, y) affine G2 (both non-infinity).
    Returns f (unreduced). Standard: R = Q (Jacobian), for each bit of |x| from
    the second-highest: f = f^2 * l_{R,R}(P); R = 2R; if bit: f *= l_{R,Q}(P); R += Q."""
    px, py = P1
    qx, qy = Q
    rx, ry, rz = qx, qy, F2_ONE
    f = F12_ONE
    bits = bin(BLS_X)[2:]
    for i, bit in enumerate(bits):
        if i == 0:
            continue
        f = f12_sqr(f)
        (rx, ry, rz), coeffs = doubling_step(rx, ry, rz)
        f = ell(f, coeffs, px, py)
        if bit == '1':
            (rx, ry, rz), coeffs = addition_step(rx, ry, rz, qx, qy)
            f = ell(f, coeffs, px, py)
    # x < 0: the ate pairing needs f^-1 == conj(f) after final exp; the product
    # check is unaffected, but keep the true pairing value.
    return f12_conj(f)

def doubling_step(rx, ry, rz):
    """Jacobian doubling on E' with line coefficients (Algorithm 26 of
    eprint 2010/354, as in zkcrypto/bls12_381)."""
    tmp0 = f2_sqr(rx)
    tmp1 = f2_sqr(ry)
    tmp2 = f2_sqr(tmp1)
    tmp3 = f2_sub(f2_sub(f2_sqr(f2_add(tmp1, rx)), tmp0), tmp2)
    tmp3 = f2_add(tmp3, tmp3)
    tmp4 = f2_add(f2_add(tmp0, tmp0), tmp0)
    tmp6 = f2_add(rx, tmp4)
    tmp5 = f2_sqr(tmp4)
    zsq = f2_sqr(rz)
    nx = f2_sub(f2_sub(tmp5, tmp3), tmp3)
    nz = f2_sub(f2_sub(f2_sqr(f2_add(rz, ry)), tmp1), zsq)
    ny = f2_mul(f2_sub(tmp3, nx), tmp4)
    tmp2 = f2_add(tmp2, tmp2); tmp2 = f2_add(tmp2, tmp2); tmp2 = f2_add(tmp2, tmp2)
    ny = f2_sub(ny, tmp2)
    tmp3 = f2_mul(tmp4, zsq)
    tmp3 = f2_add(tmp3, tmp3)
    tmp3 = f2_neg(tmp3)
    tmp6 = f2_sub(f2_sub(f2_sqr(tmp6), tmp0), tmp5)
    tmp1 = f2_add(tmp1, tmp1); tmp1 = f2_add(tmp1, tmp1)
    tmp6 = f2_sub(tmp6, tmp1)
    tmp0 = f2_mul(nz, zsq)
    tmp0 = f2_add(tmp0, tmp0)
    return (nx, ny, nz), (tmp0, tmp3, tmp6)

def addition_step(rx, ry, rz, qx, qy):
    """Jacobian mixed addition R + Q with line coefficients (Algorithm 27)."""
    zsq = f2_sqr(rz)
    ysq = f2_sqr(qy)
    t0 = f2_mul(zsq, qx)
    t1 = f2_mul(f2_sub(f2_sub(f2_sqr(f2_add(qy, rz)), ysq), zsq), zsq)
    t2 = f2_sub(t0, rx)
    t3 = f2_sqr(t2)
    t4 = f2_add(t3, t3); t4 = f2_add(t4, t4)
    t5 = f2_mul(t4, t2)
    t6 = f2_sub(f2_sub(t1, ry), ry)
    t9 = f2_mul(t6, qx)
    t7 = f2_mul(t4, rx)
    nx = f2_sub(f2_sub(f2_sub(f2_sqr(t6), t5), t7), t7)
    nz = f2_sub(f2_sub(f2_sqr(f2_add(rz, t2)), zsq), t3)
    t10 = f2_add(qy, nz)
    t8 = f2_mul(f2_sub(t7, nx), t6)
    t0 = f2_mul(ry, t5)
    t0 = f2_add(t0, t0)
    ny = f2_sub(t8, t0)
    t10 = f2_sub(f2_sqr(t10), ysq)
    ztsq = f2_sqr(nz)
    t10 = f2_sub(t10, ztsq)
    t9 = f2_sub(f2_add(t9, t9), t10)
    t10 = f2_add(nz, nz)
    t6 = f2_neg(t6)
    t1 = f2_add(t6, t6)
    return (nx, ny, nz), (t10, t1, t9)

def ell(f, coeffs, px, py):
    """f * (c2 + c1 * px * w^2 + c0 * py * w^3): the line through the untwisted
    T, Q (psi(x, y) = (x w^-2, y w^-3), M-twist) evaluated at P and scaled by
    w^3 (killed by the final exponentiation).  Sparse element with Fp2
    coefficients at w^0, w^2, w^3 = Fp6 slots a0.c0, a0.c1, a1.c1."""
    c0 = f2_scale(coeffs[0], py)
    c1 = f2_scale(coeffs[1], px)
    c2 = coeffs[2]
    line = ((c2, c1, F2_ZERO), (F2_ZERO, c0, F2_ZERO))
    return f12_mul(f, line)

def pairing_raw(p1, q):
    """Raw (pre final-exp) pairing of projective points; one if either is infinity."""
    if pt_is_inf(F1, p1) or pt_is_inf(F2, q):
        return F12_ONE
    pa = pt_normalize(F1, p1, fp_inv)
    qa = pt_normalize(F2, q, f2_inv)
    return miller_loop(pa, qa)

def pairing(p1, q):
    return final_exp(pairing_raw(p1, q))

# ---------------- Montgomery constants ----------------
RM = 1 << 384
def limbs(x, n=6):
    return [(x >> (64 * i)) & ((1 << 64) - 1) for i in range(n)]
def sdec(w):
    """64-bit word as a signed decimal (Pancake has no literals >= 2^63)."""
    return str(w - (1 << 64) if w >= (1 << 63) else w)
def mont(x): return x * RM % P
INV = (-pow(P, -1, 1 << 64)) % (1 << 64)

def selfcheck():
    import random
    from py_ecc.optimized_bls12_381 import optimized_curve as oc, optimized_pairing as opg
    from py_ecc.optimized_bls12_381 import FQ, FQ2, FQ12
    from py_ecc.bls.g2_primitives import signature_to_G2
    from py_ecc.bls.hash_to_curve import map_to_curve_G1, clear_cofactor_G1, map_to_curve_G2, clear_cofactor_G2
    rnd = random.Random(1)
    assert INV * P % (1 << 64) == (1 << 64) - 1
    # Frobenius vs direct power
    f = ((tuple((rnd.randrange(P), rnd.randrange(P)) for _ in range(3))),) * 2
    f = (tuple((rnd.randrange(P), rnd.randrange(P)) for _ in range(3)), tuple((rnd.randrange(P), rnd.randrange(P)) for _ in range(3)))
    assert f12_frob(f) == f12_pow(f, P), "frobenius"
    assert f12_mul(f, f12_inv(f)) == F12_ONE, "inverse"
    # final exponent identity
    assert 3 * ((P ** 4 - P ** 2 + 1) // R_ORDER) == (BLS_X + 1) ** 2 * (P - BLS_X) * (BLS_X ** 2 + P ** 2 - 1) + 3 or True
    x = -BLS_X
    assert 3 * ((P ** 4 - P ** 2 + 1) // R_ORDER) == (x - 1) ** 2 * (x + P) * (x * x + P * P - 1) + 3, "hard part identity"
    # group law vs py_ecc
    G1 = (G1X, G1Y, 1); G2 = (G2X, G2Y, F2_ONE)
    for _ in range(5):
        a, b = rnd.randrange(R_ORDER), rnd.randrange(R_ORDER)
        pa = pt_mul(F1, G1, a); pb = pt_mul(F1, G1, b)
        s = pt_normalize(F1, pt_add(F1, pa, pb), fp_inv)
        ref = oc.normalize(oc.add(oc.multiply(oc.G1, a), oc.multiply(oc.G1, b)))
        assert s == (ref[0].n, ref[1].n), "g1 law"
        qa = pt_mul(F2, G2, a); qb = pt_mul(F2, G2, b)
        s2 = pt_normalize(F2, pt_add(F2, qa, qb), f2_inv)
        ref2 = oc.normalize(oc.add(oc.multiply(oc.G2, a), oc.multiply(oc.G2, b)))
        assert s2 == (tuple(int(c) for c in ref2[0].coeffs), tuple(int(c) for c in ref2[1].coeffs)), "g2 law"
    # pairing: bilinearity, non-degeneracy, order
    e = pairing(G1, G2)
    assert e != F12_ONE, "degenerate"
    assert f12_pow(e, R_ORDER) == F12_ONE, "order r"
    a, b = rnd.randrange(1, R_ORDER), rnd.randrange(1, R_ORDER)
    eab = pairing(pt_mul(F1, G1, a), pt_mul(F2, G2, b))
    assert eab == f12_pow(e, a * b % R_ORDER), "bilinearity"
    # product check agreement with py_ecc (true and false cases)
    for trial in range(4):
        a, b, c = [rnd.randrange(1, R_ORDER) for _ in range(3)]
        d = a * b * pow(c, -1, R_ORDER) % R_ORDER if trial % 2 == 0 else rnd.randrange(1, R_ORDER)
        pairs = [(pt_mul(F1, G1, a), pt_mul(F2, G2, b)), (pt_mul(F1, G1, c), pt_neg(F2, pt_mul(F2, G2, d)))]
        mine = final_exp(f12_mul(pairing_raw(*pairs[0]), pairing_raw(*pairs[1]))) == F12_ONE
        ref = FQ12.one()
        for p1, q in pairs:
            ref *= opg.pairing(to_pyecc_g2(q), to_pyecc_g1(p1))
        assert mine == (ref == FQ12.one()) == (trial % 2 == 0), "product check"
    # KZG setup point
    kz = signature_to_G2(bytes.fromhex("b5bfd7dd8cdeb128843bc287230af38926187075cbfbefa81009a2ce615ac53d2914e5870cb452d2afaaab24f3499f72185cbfee53492714734429b7b38608e23926c911cceceac9a36851477ba4c60b087041de621000edc98edada20c1def2"))
    kzn = oc.normalize(kz)
    assert (tuple(int(c) for c in kzn[0].coeffs), tuple(int(c) for c in kzn[1].coeffs)) == (KZG_G2_1X, KZG_G2_1Y), "kzg g2"
    print("blsref selfcheck OK")

def to_pyecc_g1(p):
    from py_ecc.optimized_bls12_381 import FQ
    return (FQ(p[0]), FQ(p[1]), FQ(p[2]))
def to_pyecc_g2(q):
    from py_ecc.optimized_bls12_381 import FQ2
    return (FQ2(list(q[0])), FQ2(list(q[1])), FQ2(list(q[2])))

# ---------------- constants file ----------------
def gen_consts(out):
    """Emit guest/src/lib/bls12381_consts.pnk: bls_consts_init() writes every
    constant into one heap block; C_* macros name their addresses.  Field
    elements are in Montgomery form (x * 2^384 mod p) in the software build
    and canonical form in the ZISK_ACCEL build; _CAN values and
    exponents/scalars are plain little-endian limbs in both builds."""
    from py_ecc.optimized_bls12_381 import constants as kc
    lines = []
    off = [0]
    defs = []
    stores = []
    def put_words(name, words, accel_words=None):
        defs.append(f"#define {name} (bls_c + {off[0]})")
        if accel_words is None:
            accel_words = words
        if accel_words == words:
            for i, w in enumerate(words):
                stores.append(f"  st bls_c + {off[0] + 8 * i}, {sdec(w)};")
        else:
            stores.append("#ifdef ZISK_ACCEL")
            for i, w in enumerate(accel_words):
                stores.append(f"  st bls_c + {off[0] + 8 * i}, {sdec(w)};")
            stores.append("#else")
            for i, w in enumerate(words):
                stores.append(f"  st bls_c + {off[0] + 8 * i}, {sdec(w)};")
            stores.append("#endif")
        off[0] += 8 * len(words)
    def put_fp(name, x):
        put_words(name, limbs(mont(x % P)), limbs(x % P))
    def put_fp_can(name, x): put_words(name, limbs(x % P))
    def put_fp2(name, c):
        put_words(name, limbs(mont(c[0] % P)) + limbs(mont(c[1] % P)),
                  limbs(c[0] % P) + limbs(c[1] % P))
    def put_scalar(name, x, n): put_words(name, limbs(x, n))
    def fq2(c): return (int(c.coeffs[0]), int(c.coeffs[1]))

    put_fp("C_ONE", 1)
    # The modulus itself is not a field residue reduced modulo P.
    put_words("C_P", limbs(P))
    put_fp_can("C_R2", RM * RM % P)            # to Montgomery: mont_mul(a, R2)
    put_fp_can("C_R3", RM * RM * RM % P)       # inverse fixup: mont_mul(inv_can(aR), R3)
    put_fp_can("C_P_HALF", (P - 1) // 2)       # (2y)//p == 1  <=>  y > (p-1)/2
    put_fp("C_B1", 4)
    put_fp2("C_B2", (4, 4))
    put_fp("C_G1X", G1X); put_fp("C_G1Y", G1Y)
    put_fp2("C_G2X", G2X); put_fp2("C_G2Y", G2Y)
    put_fp2("C_KZG_G2_1X", KZG_G2_1X); put_fp2("C_KZG_G2_1Y", KZG_G2_1Y)
    for k in range(1, 6):
        put_fp2(f"C_GAMMA{k}", GAMMA[k])
    put_scalar("C_ORDER", R_ORDER, 4)
    put_scalar("C_BLS_X", BLS_X, 1)
    put_scalar("C_P_MINUS_2", P - 2, 6)
    put_scalar("C_P_PLUS_1_DIV_4", (P + 1) // 4, 6)
    put_scalar("C_P_MINUS_3_DIV_4", (P - 3) // 4, 6)
    put_scalar("C_P_MINUS_9_DIV_16", (P * P - 9) // 16, 12)
    put_scalar("C_H_EFF_G1", H_EFF_G1, 1)
    put_scalar("C_H_EFF_G2", H_EFF_G2, 10)
    assert kc.P_MINUS_9_DIV_16 == (P * P - 9) // 16 and kc.P_MINUS_3_DIV_4 == (P - 3) // 4
    assert kc.H_EFF_G2 == H_EFF_G2 and 1 <= kc.ISO_11_Z.n == 11
    # SWU / isogeny (G1)
    put_fp("C_ISO_11_A", kc.ISO_11_A.n); put_fp("C_ISO_11_B", kc.ISO_11_B.n)
    put_fp("C_ISO_11_Z", kc.ISO_11_Z.n); put_fp("C_SQRT_MINUS_11_CUBED", kc.SQRT_MINUS_11_CUBED.n)
    for i, poly in enumerate(kc.ISO_11_MAP_COEFFICIENTS):
        defs.append(f"#define C_ISO11_N{i} {len(poly)}")
        put_words(f"C_ISO11_K{i}",
                  sum((limbs(mont(int(c))) for c in poly), []),
                  sum((limbs(int(c) % P) for c in poly), []))
    # SWU / isogeny (G2)
    put_fp2("C_ISO_3_A", fq2(kc.ISO_3_A)); put_fp2("C_ISO_3_B", fq2(kc.ISO_3_B)); put_fp2("C_ISO_3_Z", fq2(kc.ISO_3_Z))
    put_words("C_ETAS",
              sum((limbs(mont(fq2(e)[0])) + limbs(mont(fq2(e)[1])) for e in kc.ETAS), []),
              sum((limbs(fq2(e)[0] % P) + limbs(fq2(e)[1] % P) for e in kc.ETAS), []))
    put_words("C_ROOTS8",
              sum((limbs(mont(fq2(e)[0])) + limbs(mont(fq2(e)[1])) for e in kc.POSITIVE_EIGHTH_ROOTS_OF_UNITY), []),
              sum((limbs(fq2(e)[0] % P) + limbs(fq2(e)[1] % P) for e in kc.POSITIVE_EIGHTH_ROOTS_OF_UNITY), []))
    for i, poly in enumerate(kc.ISO_3_MAP_COEFFICIENTS):
        defs.append(f"#define C_ISO3_N{i} {len(poly)}")
        put_words(f"C_ISO3_K{i}",
                  sum((limbs(mont(fq2(c)[0])) + limbs(mont(fq2(c)[1])) for c in poly), []),
                  sum((limbs(fq2(c)[0] % P) + limbs(fq2(c)[1] % P) for c in poly), []))
    size = off[0]
    with open(out, "w") as fh:
        fh.write("/* lib/bls12381_consts.pnk -- GENERATED by tools/blsref.py --consts; do not edit.\n"
                 "   bls_consts_init() fills one heap block with every BLS12-381 constant the\n"
                 "   library needs; C_* macros are their addresses.  Field elements are in\n"
                 "   Montgomery form in the software build and canonical form in the\n"
                 "   ZISK_ACCEL build; _CAN values and exponents / scalars are plain\n"
                 "   little-endian 64-bit limbs.\n"
                 "   Words >= 2^63 are written as negative decimals (PANCAKE-NOTES). */\n\n")
        fh.write(f"#define FP_INV {sdec(INV)}   /* -p^-1 mod 2^64 */\n")
        for i, w in enumerate(limbs(P)):
            fh.write(f"#define FP_P{i} {sdec(w)}\n")
        def lit(x): return "<" + ", ".join(sdec(w) for w in limbs(x)) + ">"
        fh.write(f"#define FP_P_LIT {lit(P)}\n")
        fh.write("#ifdef ZISK_ACCEL\n")
        fh.write(f"#define FP_ONE_MONT {lit(1)}   /* canonical accelerator build */\n")
        fh.write(f"#define FP_R2_LIT {lit(RM * RM % P)}\n")
        fh.write(f"#define FP_R3_LIT {lit(RM * RM * RM % P)}\n")
        fh.write(f"#define FP_P_HALF_LIT {lit((P - 1) // 2)}\n")
        fh.write("#else\n")
        fh.write(f"#define FP_ONE_MONT {lit(mont(1))}   /* R mod p */\n")
        fh.write(f"#define FP_R2_LIT {lit(RM * RM % P)}\n")
        fh.write(f"#define FP_R3_LIT {lit(RM * RM * RM % P)}\n")
        fh.write(f"#define FP_P_HALF_LIT {lit((P - 1) // 2)}\n")
        fh.write("#endif\n")
        fh.write(f"#define BLS_CONSTS_SIZE {size}\n")
        fh.write("\n".join(defs) + "\n\n")
        fh.write("var 1 bls_c = 0;\n\nfun 1 bls_consts_init() {\n  if bls_c != 0 { return 0; }\n")
        fh.write(f"  bls_c = alloc(BLS_CONSTS_SIZE);\n")
        fh.write("\n".join(stores) + "\n  return 0;\n}\n")
    print(f"wrote {out} ({size} bytes of constants)")

if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--consts":
        gen_consts(sys.argv[2])
    else:
        selfcheck()
