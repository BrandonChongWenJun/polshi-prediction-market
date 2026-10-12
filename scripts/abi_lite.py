"""Minimal Ethereum ABI encoder/decoder + JSON-RPC client (Python stdlib only).

Used by the demo seeding script. Function selectors are computed with `cast sig` (Python's hashlib has no
keccak-256) and cached. `selftest()` cross-checks the encoder against `cast calldata`.
"""

from __future__ import annotations

import json
import subprocess
import urllib.request
from functools import lru_cache


# ----------------------------------------------------------------------------------------------- types


def _split_top(s: str) -> list[str]:
    """Split 'a,(b,c),d[]' into top-level components."""
    parts, depth, cur = [], 0, ""
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    if cur:
        parts.append(cur)
    return parts


def _tuple_components(t: str) -> list[str]:
    assert t.startswith("(") and t.endswith(")"), t
    return _split_top(t[1:-1])


def _is_dynamic(t: str) -> bool:
    if t in ("string", "bytes") or t.endswith("[]"):
        return True
    if t.startswith("("):
        return any(_is_dynamic(c) for c in _tuple_components(t))
    return False


def _static_size(t: str) -> int:
    if t.startswith("("):
        return sum(_static_size(c) for c in _tuple_components(t))
    return 32


def _word(v: int) -> bytes:
    if v < 0:
        v += 1 << 256
    return int(v).to_bytes(32, "big")


def _encode_single(t: str, v) -> bytes:
    if t.endswith("[]"):
        inner = t[:-2]
        return _word(len(v)) + encode([inner] * len(v), list(v))
    if t.startswith("("):
        return encode(_tuple_components(t), list(v))
    if t == "string" or t == "bytes":
        b = v.encode() if isinstance(v, str) and t == "string" else (bytes.fromhex(v[2:]) if isinstance(v, str) else v)
        pad = (32 - len(b) % 32) % 32
        return _word(len(b)) + b + b"\x00" * pad
    if t == "address":
        return b"\x00" * 12 + bytes.fromhex(v[2:].rjust(40, "0"))
    if t == "bool":
        return _word(1 if v else 0)
    if t.startswith("uint") or t.startswith("int"):
        return _word(int(v))
    if t == "bytes32":
        return bytes.fromhex(v[2:]).ljust(32, b"\x00")
    raise ValueError(f"unsupported type {t}")


def encode(types: list[str], values: list) -> bytes:
    head_size = sum(32 if _is_dynamic(t) else _static_size(t) for t in types)
    heads, tails, tail_len = [], [], 0
    for t, v in zip(types, values):
        if _is_dynamic(t):
            heads.append(_word(head_size + tail_len))
            enc = _encode_single(t, v)
            tails.append(enc)
            tail_len += len(enc)
        else:
            heads.append(_encode_single(t, v))
    return b"".join(heads) + b"".join(tails)


def arg_types(signature: str) -> list[str]:
    inner = signature[signature.index("(") + 1 : signature.rindex(")")]
    return _split_top(inner) if inner else []


@lru_cache(maxsize=None)
def selector(signature: str) -> str:
    return subprocess.check_output(["cast", "sig", signature], text=True).strip()


def calldata(signature: str, *args) -> str:
    return selector(signature) + encode(arg_types(signature), list(args)).hex()


# ----------------------------------------------------------------------------------------------- decoding


def _read_word(data: bytes, off: int) -> int:
    return int.from_bytes(data[off : off + 32], "big")


def decode_uint(data: bytes, index: int = 0) -> int:
    return _read_word(data, 32 * index)


def decode_uint_array(data: bytes, index: int = 0) -> list[int]:
    off = _read_word(data, 32 * index)
    n = _read_word(data, off)
    return [_read_word(data, off + 32 + 32 * i) for i in range(n)]


# ----------------------------------------------------------------------------------------------- RPC


class RpcError(Exception):
    pass


class Rpc:
    def __init__(self, url: str):
        self.url = url
        self._id = 0

    def __call__(self, method: str, params: list | None = None):
        self._id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params or []}).encode()
        req = urllib.request.Request(self.url, data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            out = json.loads(resp.read())
        if "error" in out:
            raise RpcError(json.dumps(out["error"]))
        return out["result"]

    def call(self, to: str, signature: str, *args) -> bytes:
        res = self("eth_call", [{"to": to, "data": calldata(signature, *args)}, "latest"])
        return bytes.fromhex(res[2:])


# ----------------------------------------------------------------------------------------------- self-test


def selftest() -> None:
    cases = [
        (
            "createMarket((string,string,string[],uint64,uint64,address,address,uint256,uint16[],uint16))",
            [
                (
                    "Will BTC close above $150,000 (UTC)?",
                    "Crypto",
                    ["Yes", "No"],
                    1790000000,
                    1790086400,
                    "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
                    "0x5FbDB2315678afecb367f032d93F642f64180aa3",
                    5_000_000_000,
                    [4000, 6000],
                    200,
                )
            ],
            '("Will BTC close above $150,000 (UTC)?","Crypto",["Yes","No"],1790000000,1790086400,'
            "0x90F79bf6EB2c4f870365E785982E1f101E93b906,0x5FbDB2315678afecb367f032d93F642f64180aa3,"
            "5000000000,[4000,6000],200)",
        ),
        ("buy(uint256,uint8,uint256,uint256)", [3, 1, 10**18, 0], None),
        ("placeOrder(uint256,uint8,uint8,uint16,uint256,uint64)", [1, 0, 1, 3600, 150 * 10**6, 0], None),
    ]
    for sig, args, cast_arg in cases:
        mine = calldata(sig, *args)
        cast_args = [cast_arg] if cast_arg is not None else [str(a) for a in args]
        ref = subprocess.check_output(["cast", "calldata", sig, *cast_args], text=True).strip()
        assert mine == ref, f"ABI mismatch for {sig}\n mine={mine}\n cast={ref}"
    print("abi_lite selftest ok")


if __name__ == "__main__":
    selftest()
