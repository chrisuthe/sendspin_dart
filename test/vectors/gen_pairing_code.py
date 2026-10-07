"""Generate known-answer vectors for Sendspin code-based pairing.

Uses the `cpace` package (the CPACE-X25519-SHA512 implementation the
aiosendspin reference server uses), hashlib and `cryptography`, following
the formulas in the Sendspin 1.0.0-rc1 pairing document. Scalars and nonces
are fixed so the output is deterministic.
"""
import base64
import hashlib
import json

import cpace
from cpace import CPace, CPaceRole
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305


def b32_token(version: str, payload: bytes) -> str:
    body = base64.b32encode(payload).decode().rstrip("=").replace("2", "9")
    return "SP:" + version + body


def side(role, prs, sid, ad, scalar):
    generator = cpace._calculate_generator(prs, b"", sid)
    share = cpace._scalar_mult_vfy(scalar, generator)
    return generator, CPace(role=role, sid=sid, ad=ad, scalar=scalar, public_share=share)


def run(h, pairing_index, round_number, prs, scalar_a, scalar_b, psk, nonce_b):
    sid = (
        b"sendspin-pair-pake-v1"
        + h
        + pairing_index.to_bytes(4, "big")
        + round_number.to_bytes(4, "big")
    )
    generator, a = side(CPaceRole.INITIATOR, prs, sid, b"server", scalar_a)
    _, b = side(CPaceRole.RESPONDER, prs, sid, b"client", scalar_b)
    a.derive(b.public_share, b"client")
    b.derive(a.public_share, b"server")
    assert a.isk == b.isk
    assert b.verify(a.tag()) and a.verify(b.tag())

    def wrap(label, value):
        key = hashlib.sha256(label + sid + b.isk).digest()
        return ChaCha20Poly1305(key).encrypt(bytes(12), value, b"")

    return {
        "handshake_hash": h.hex(),
        "pairing_index": pairing_index,
        "round": round_number,
        "prs": prs.hex(),
        "sid": sid.hex(),
        "generator": generator.hex(),
        "scalar_a": scalar_a.hex(),
        "scalar_b": scalar_b.hex(),
        "ya": a.public_share.hex(),
        "yb": b.public_share.hex(),
        "isk": b.isk.hex(),
        "ta": a.tag().hex(),
        "tb": b.tag().hex(),
        "long_term_psk": psk.hex(),
        "wrapped_psk": wrap(b"sendspin-pair-psk-wrap-v1", psk).hex(),
        "nonce_b": nonce_b.hex(),
        "wrapped_nonce_b": wrap(b"sendspin-pair-nonce-wrap-v1", nonce_b).hex(),
    }


h = bytes(range(0x10, 0x30))
nonce_a = bytes(range(0x80, 0xA0))
nonce_b = bytes(range(0xA0, 0xC0))
digest = hashlib.sha256(b"sendspin-pairing-code-derive-v1" + h + nonce_a + nonce_b).digest()
digits = f"{int.from_bytes(digest, 'big') % 10**6:06d}"
qr_code = digest[:24]
scalar_a = bytes(range(0x01, 0x21))
scalar_b = bytes(range(0x31, 0x51))
psk = bytes(range(0xC0, 0xE0))

out = {
    "code": {
        "handshake_hash": h.hex(),
        "nonce_a": nonce_a.hex(),
        "nonce_b": nonce_b.hex(),
        "commit_b": hashlib.sha256(b"sendspin-pair-commit-v1" + nonce_b).hexdigest(),
        "digits": digits,
        "qr_code": qr_code.hex(),
        "qr_token": b32_token("1", qr_code),
        "spec_reference_qr_token": b32_token("1", bytes(range(0xE0, 0xF8))),
    },
    "cpace": [
        run(h, 1, 1, digits.encode(), scalar_a, scalar_b, psk, nonce_b),
        run(h, 3, 2, qr_code, scalar_a, scalar_b, psk, nonce_b),
        run(bytes(32), 1, 1, b"12345678", scalar_b, scalar_a, psk, nonce_b),
    ],
}
print(json.dumps(out, indent=1))
