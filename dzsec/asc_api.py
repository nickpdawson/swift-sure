#!/usr/bin/env python3
"""Minimal App Store Connect API client: stdlib + openssl only (no pyjwt).
Usage: asc_api.py GET /v1/bundleIds?filter[identifier]=com.shifthuman.sure
       asc_api.py POST /v1/bundleIds '{"data":{...}}'
Key path: $ASC_KEY_PATH (default ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8)
Never prints the key."""
import base64, json, os, subprocess, sys, tempfile, time, urllib.request, urllib.error

KEY_ID = os.environ.get("ASC_KEY_ID", "3LGR8HYV5P")
ISSUER = os.environ.get("ASC_ISSUER_ID", "69a6de7c-da83-47e3-e053-5b8c7c11a4d1")
KEY_PATH = os.path.expanduser(os.environ.get("ASC_KEY_PATH",
    f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8"))
if not os.path.exists(KEY_PATH):
    alt = os.path.expanduser("~/private/asc_key.p8")
    if os.path.exists(alt): KEY_PATH = alt

def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def der_to_raw(der):
    # ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER } -> r||s (32 bytes each)
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7f)
    out = b""
    for _ in range(2):
        assert der[i] == 0x02; i += 1
        ln = der[i]; i += 1
        val = der[i:i+ln]; i += ln
        out += val.lstrip(b"\x00").rjust(32, b"\x00")
    return out

def token():
    now = int(time.time())
    hdr = b64u(json.dumps({"alg":"ES256","kid":KEY_ID,"typ":"JWT"}).encode())
    pl = b64u(json.dumps({"iss":ISSUER,"iat":now,"exp":now+1200,"aud":"appstoreconnect-v1"}).encode())
    signing = f"{hdr}.{pl}".encode()
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(signing); tmp = f.name
    try:
        der = subprocess.check_output(["openssl","dgst","-sha256","-sign",KEY_PATH,tmp])
    finally:
        os.unlink(tmp)
    return f"{hdr}.{pl}.{b64u(der_to_raw(der))}"

def call(method, path, body=None):
    url = path if path.startswith("http") else "https://api.appstoreconnect.apple.com" + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            txt = r.read().decode()
            return r.status, (json.loads(txt) if txt else {})
    except urllib.error.HTTPError as e:
        txt = e.read().decode()
        try: return e.code, json.loads(txt)
        except Exception: return e.code, {"raw": txt}

if __name__ == "__main__":
    m, p = sys.argv[1], sys.argv[2]
    b = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    st, js = call(m, p, b)
    print(st); print(json.dumps(js, indent=1))
