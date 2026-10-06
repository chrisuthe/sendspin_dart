"""Generate Noise_KKpsk2_25519_ChaChaPoly_SHA256 known-answer vectors.

Uses the `noiseprotocol` package (the library aiosendspin builds on) with
fixed static and ephemeral keys so the output is deterministic.
"""
import json

from cryptography.hazmat.primitives import serialization as s
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from noise.connection import Keypair, NoiseConnection

NAME = b"Noise_KKpsk2_25519_ChaChaPoly_SHA256"


def pub(priv: bytes) -> bytes:
    return (
        X25519PrivateKey.from_private_bytes(priv)
        .public_key()
        .public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)
    )


def run(prologue: bytes, psk: bytes, p1: bytes, p2: bytes, transport):
    init_s = bytes(range(0x00, 0x20))
    resp_s = bytes(range(0x20, 0x40))
    init_e = bytes(range(0x40, 0x60))
    resp_e = bytes(range(0x60, 0x80))

    i = NoiseConnection.from_name(NAME)
    i.set_as_initiator()
    i.set_prologue(prologue)
    i.set_psks(psk)
    i.set_keypair_from_private_bytes(Keypair.STATIC, init_s)
    i.set_keypair_from_public_bytes(Keypair.REMOTE_STATIC, pub(resp_s))
    i.set_keypair_from_private_bytes(Keypair.EPHEMERAL, init_e)
    i.start_handshake()

    r = NoiseConnection.from_name(NAME)
    r.set_as_responder()
    r.set_prologue(prologue)
    r.set_psks(psk)
    r.set_keypair_from_private_bytes(Keypair.STATIC, resp_s)
    r.set_keypair_from_public_bytes(Keypair.REMOTE_STATIC, pub(init_s))
    r.set_keypair_from_private_bytes(Keypair.EPHEMERAL, resp_e)
    r.start_handshake()

    m1 = bytes(i.write_message(p1))
    assert bytes(r.read_message(m1)) == p1
    m2 = bytes(r.write_message(p2))
    assert bytes(i.read_message(m2)) == p2
    assert i.handshake_finished and r.handshake_finished
    h = bytes(i.get_handshake_hash())
    assert h == bytes(r.get_handshake_hash())

    msgs = []
    for direction, plaintext in transport:
        sender, receiver = (i, r) if direction == "i2r" else (r, i)
        ct = bytes(sender.encrypt(plaintext))
        assert bytes(receiver.decrypt(ct)) == plaintext
        msgs.append(
            {"direction": direction, "plaintext": plaintext.hex(), "ciphertext": ct.hex()}
        )

    return {
        "prologue": prologue.hex(),
        "psk": psk.hex(),
        "initiator_static_private": init_s.hex(),
        "initiator_static_public": pub(init_s).hex(),
        "responder_static_private": resp_s.hex(),
        "responder_static_public": pub(resp_s).hex(),
        "initiator_ephemeral_private": init_e.hex(),
        "responder_ephemeral_private": resp_e.hex(),
        "payload_1": p1.hex(),
        "payload_2": p2.hex(),
        "message_1": m1.hex(),
        "message_2": m2.hex(),
        "handshake_hash": h.hex(),
        "transport": msgs,
    }


import hashlib

sentinel = hashlib.sha256(b"sendspin-sentinel-psk-v1").digest()
vectors = [
    run(
        b'{"type":"client/init"}{"type":"server/init"}',
        sentinel,
        b'{"psk_id":"GFsV9tLaSQm9HcFWpKsgYQOr7wFTvNUtkmFwuVz3zoo","psk_category":"sn"}',
        b"{}",
        [
            ("i2r", b"\x00" + b'{"type":"server/hello","payload":{"name":"S"}}'),
            ("r2i", b"\x00" + b'{"type":"client/hello","payload":{}}'),
            ("i2r", b"\x04" + bytes(range(40))),
            ("i2r", b""),
            ("r2i", b"\x00{}"),
        ],
    ),
    run(b"", bytes(range(0xE0, 0x100)), b"", b"", [("r2i", b"x"), ("i2r", b"y")]),
]
print(json.dumps(vectors, indent=1))
