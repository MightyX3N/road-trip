"""Fail the build if an APK isn't signed with the key in android/debug.keystore.

Android refuses to install an update signed with a different key ("package conflicts
with an existing package"), so every release has to carry the same certificate.

usage: python3 tools/check_signature.py APK EXPECTED_SHA256
EXPECTED_SHA256 is the keystore certificate's SHA-256, colons optional (keytool prints it).
"""
import hashlib
import struct
import sys


def apk_cert_sha256(path):
    data = open(path, "rb").read()
    eocd = data.rfind(b"PK\x05\x06")
    cd_off = struct.unpack("<I", data[eocd + 16:eocd + 20])[0]
    if data[cd_off - 16:cd_off] != b"APK Sig Block 42":
        raise SystemExit("no APK signing block (v2/v3) found")
    size = struct.unpack("<Q", data[cd_off - 24:cd_off - 16])[0]
    block = data[cd_off - size - 8:cd_off - 24]

    def lp(buf, off):  # uint32 length-prefixed field
        n = struct.unpack("<I", buf[off:off + 4])[0]
        return buf[off + 4:off + 4 + n], off + 4 + n

    pos = 8
    while pos < len(block):
        length = struct.unpack("<Q", block[pos:pos + 8])[0]
        pid = struct.unpack("<I", block[pos + 8:pos + 12])[0]
        value = block[pos + 12:pos + 8 + length]
        pos += 8 + length
        if pid in (0x7109871A, 0xF05368C0):  # v2, v3
            signers, _ = lp(value, 0)
            signer, _ = lp(signers, 0)
            signed, _ = lp(signer, 0)
            _, off = lp(signed, 0)            # digests
            certs, _ = lp(signed, off)
            cert, _ = lp(certs, 0)
            return hashlib.sha256(cert).hexdigest()
    raise SystemExit("no v2/v3 signer found")


if __name__ == "__main__":
    apk, expected = sys.argv[1], sys.argv[2].replace(":", "").strip().lower()
    got = apk_cert_sha256(apk)
    print("APK certificate SHA-256:", got)
    if got != expected:
        print("expected:              ", expected)
        raise SystemExit("APK is signed with the wrong key; updates would fail to install")
    print("signed with the Road Trip key")
