import argparse
import base64
import csv
import json
import ssl
import time
import uuid
from dataclasses import dataclass
from typing import Tuple
from urllib import parse, request

import pyotp
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


@dataclass
class Enrollment:
    user_id: str
    device_id: str
    rp_id: str
    secret: str
    private_key: Ed25519PrivateKey


def post_json(base_url: str, path: str, payload: dict, context: ssl.SSLContext | None) -> dict:
    data = json.dumps(payload).encode("utf-8")
    req = request.Request(
        f"{base_url}{path}",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with request.urlopen(req, timeout=10, context=context) as resp:
        return json.loads(resp.read().decode("utf-8"))


def generate_keypair() -> Tuple[Ed25519PrivateKey, str]:
    private_key = Ed25519PrivateKey.generate()
    public_key = private_key.public_key()
    public_bytes = public_key.public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    public_b64 = base64.b64encode(public_bytes).decode("utf-8")
    return private_key, public_b64


def enroll(base_url: str, email: str, rp_id: str, context: ssl.SSLContext | None) -> Enrollment:
    private_key, public_b64 = generate_keypair()
    enroll_resp = post_json(
        base_url,
        "/enroll",
        {
            "email": email,
            "device_label": "FRR Device",
            "platform": "android",
            "rp_id": rp_id,
            "rp_display_name": "FRR RP",
            "key_type": "ed25519",
            "public_key": public_b64,
        },
        context,
    )
    user_id = enroll_resp["user"]["id"]
    device_id = enroll_resp["device"]["id"]

    register_resp = post_json(
        base_url,
        "/totp/register",
        {
            "user_id": user_id,
            "rp_id": rp_id,
            "account_name": email,
            "issuer": "FRR",
        },
        context,
    )
    otpauth_uri = register_resp["otpauth_uri"]
    parsed = parse.urlparse(otpauth_uri)
    query = parse.parse_qs(parsed.query)
    secret = (query.get("secret") or [""])[0]
    return Enrollment(
        user_id=user_id,
        device_id=device_id,
        rp_id=rp_id,
        secret=secret,
        private_key=private_key,
    )


def otp_with_drift(secret: str, drift_seconds: int) -> str:
    now = int(time.time())
    return pyotp.TOTP(secret).at(now - drift_seconds)


def totp_verify(base_url: str, enrollment: Enrollment, otp: str, context: ssl.SSLContext | None) -> bool:
    resp = post_json(
        base_url,
        "/totp/verify",
        {"user_id": enrollment.user_id, "rp_id": enrollment.rp_id, "otp": otp},
        context,
    )
    return resp.get("status") == "ok"


def zt_verify(base_url: str, enrollment: Enrollment, otp: str, context: ssl.SSLContext | None) -> bool:
    challenge = post_json(
        base_url,
        "/zt/challenge",
        {"device_id": enrollment.device_id, "rp_id": enrollment.rp_id},
        context,
    )
    nonce = challenge["nonce"]
    message = f"{nonce}|{enrollment.device_id}|{enrollment.rp_id}|{otp}".encode("utf-8")
    signature = base64.b64encode(enrollment.private_key.sign(message)).decode("utf-8")
    resp = post_json(
        base_url,
        "/zt/verify",
        {
            "user_id": enrollment.user_id,
            "device_id": enrollment.device_id,
            "rp_id": enrollment.rp_id,
            "otp": otp,
            "device_proof": {"nonce": nonce, "signature": signature},
        },
        context,
    )
    return resp.get("status") == "ok"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="https://localhost:8000")
    parser.add_argument("--insecure", action="store_true", help="Disable TLS verification (dev only).")
    parser.add_argument("--trials", type=int, default=30)
    parser.add_argument("--drifts", default="0,15,30,60,90,120")
    parser.add_argument("--output", default="experiments/frr_sweep.csv")
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")
    drifts = [int(x.strip()) for x in args.drifts.split(",") if x.strip()]

    run_id = uuid.uuid4().hex[:8]
    email = f"frr-{run_id}@example.com"
    rp_id = f"frr-{run_id}.com"
    context = ssl._create_unverified_context() if args.insecure else None
    enrollment = enroll(base_url, email, rp_id, context)

    rows = []
    for drift in drifts:
        ok_totp = 0
        ok_zt = 0
        for _ in range(args.trials):
            otp = otp_with_drift(enrollment.secret, drift)
            if totp_verify(base_url, enrollment, otp, context):
                ok_totp += 1
            if zt_verify(base_url, enrollment, otp, context):
                ok_zt += 1
        rows.append((drift, ok_totp, ok_zt, args.trials))

    with open(args.output, "w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["drift_seconds", "standard_totp_ok", "zt_totp_ok", "total"])
        for drift, ok_totp, ok_zt, total in rows:
            writer.writerow([drift, ok_totp, ok_zt, total])

    print(f"Wrote FRR sweep to {args.output}")


if __name__ == "__main__":
    main()
