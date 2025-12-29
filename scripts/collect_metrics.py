import argparse
import base64
import csv
import json
import ssl
import time
import uuid
from dataclasses import dataclass
from datetime import datetime
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
    recovery_codes: list[str]
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


def get_json(base_url: str, path: str, context: ssl.SSLContext | None) -> dict:
    with request.urlopen(f"{base_url}{path}", timeout=10, context=context) as resp:
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
            "device_label": "Experiment Device",
            "platform": "android",
            "rp_id": rp_id,
            "rp_display_name": "Experiment RP",
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
            "issuer": "Experiment",
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
        recovery_codes=register_resp["recovery_codes"],
        private_key=private_key,
    )


def current_otp(secret: str) -> str:
    return pyotp.TOTP(secret).now()


def otp_with_drift(secret: str, drift_seconds: int) -> str:
    now = int(time.time())
    return pyotp.TOTP(secret).at(now - drift_seconds)


def sign_payload(private_key: Ed25519PrivateKey, nonce: str, device_id: str, rp_id: str, otp: str) -> str:
    message = f"{nonce}|{device_id}|{rp_id}|{otp}".encode("utf-8")
    signature = private_key.sign(message)
    return base64.b64encode(signature).decode("utf-8")


def zt_verify(
    base_url: str,
    enrollment: Enrollment,
    otp: str,
    key: Ed25519PrivateKey,
    context: ssl.SSLContext | None,
) -> Tuple[bool, str, float]:
    started = time.perf_counter()
    challenge = post_json(
        base_url,
        "/zt/challenge",
        {"device_id": enrollment.device_id, "rp_id": enrollment.rp_id},
        context,
    )
    nonce = challenge["nonce"]
    signature = sign_payload(key, nonce, enrollment.device_id, enrollment.rp_id, otp)
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
    elapsed_ms = (time.perf_counter() - started) * 1000
    return resp.get("status") == "ok", resp.get("reason") or "", elapsed_ms


def totp_verify(
    base_url: str,
    enrollment: Enrollment,
    otp: str,
    context: ssl.SSLContext | None,
) -> Tuple[bool, str, float]:
    started = time.perf_counter()
    resp = post_json(
        base_url,
        "/totp/verify",
        {"user_id": enrollment.user_id, "rp_id": enrollment.rp_id, "otp": otp},
        context,
    )
    elapsed_ms = (time.perf_counter() - started) * 1000
    return resp.get("status") == "ok", resp.get("reason") or "", elapsed_ms


def login_recover(
    base_url: str,
    email: str,
    code: str,
    context: ssl.SSLContext | None,
) -> Tuple[bool, str, float]:
    started = time.perf_counter()
    resp = post_json(
        base_url,
        "/login/recover",
        {"email": email, "recovery_code": code},
        context,
    )
    elapsed_ms = (time.perf_counter() - started) * 1000
    return resp.get("status") == "ok", resp.get("reason") or "", elapsed_ms


def rotate_key(
    base_url: str,
    enrollment: Enrollment,
    private_key: Ed25519PrivateKey,
    context: ssl.SSLContext | None,
) -> Tuple[bool, str, float]:
    started = time.perf_counter()
    public_key = private_key.public_key()
    public_bytes = public_key.public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    public_b64 = base64.b64encode(public_bytes).decode("utf-8")
    resp = post_json(
        base_url,
        "/zt/rotate-key",
        {
            "device_id": enrollment.device_id,
            "rp_id": enrollment.rp_id,
            "key_type": "ed25519",
            "public_key": public_b64,
        },
        context,
    )
    elapsed_ms = (time.perf_counter() - started) * 1000
    return resp.get("status") == "ok", resp.get("reason") or "", elapsed_ms


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="https://localhost:8000")
    parser.add_argument("--insecure", action="store_true", help="Disable TLS verification (dev only).")
    parser.add_argument("--trials", type=int, default=30)
    parser.add_argument("--recovery-trials", type=int, default=8)
    parser.add_argument("--drift-trials", type=int, default=20)
    parser.add_argument("--drift-seconds", type=int, default=120)
    parser.add_argument("--output", default="experiments/results.csv")
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")
    output_path = args.output

    run_id = uuid.uuid4().hex[:8]
    email = f"experiment-{run_id}@example.com"
    rp_id = f"experiment-{run_id}.com"
    context = ssl._create_unverified_context() if args.insecure else None
    enrollment = enroll(base_url, email, rp_id, context)

    attacker_key, _ = generate_keypair()

    rows = []

    for _ in range(args.trials):
        otp = current_otp(enrollment.secret)
        ok, reason, latency = totp_verify(base_url, enrollment, otp, context)
        rows.append(("legitimate_login", "standard_totp", ok, reason, latency))

        ok, reason, latency = zt_verify(base_url, enrollment, otp, enrollment.private_key, context)
        rows.append(("legitimate_login", "zt_totp", ok, reason, latency))

    for _ in range(args.trials):
        otp = current_otp(enrollment.secret)
        ok, reason, latency = totp_verify(base_url, enrollment, otp, context)
        rows.append(("seed_compromise", "standard_totp", ok, reason, latency))

        ok, reason, latency = zt_verify(base_url, enrollment, otp, attacker_key, context)
        rows.append(("seed_compromise", "zt_totp", ok, reason, latency))

    for _ in range(args.trials):
        otp = current_otp(enrollment.secret)
        ok, reason, latency = totp_verify(base_url, enrollment, otp, context)
        rows.append(("relay_phishing", "standard_totp", ok, reason, latency))

        ok, reason, latency = zt_verify(base_url, enrollment, otp, attacker_key, context)
        rows.append(("relay_phishing", "zt_totp", ok, reason, latency))

    for i in range(args.recovery_trials):
        trial_email = f"recovery-{run_id}-{i}@example.com"
        trial_rp = f"recovery-{run_id}-{i}.com"
        trial_enroll = enroll(base_url, trial_email, trial_rp, context)
        otp = current_otp(trial_enroll.secret)
        ok, reason, latency = totp_verify(base_url, trial_enroll, otp, context)
        rows.append(("offline_degraded", "standard_totp", ok, reason, latency))

        code = trial_enroll.recovery_codes[0]
        ok, reason, latency = login_recover(base_url, trial_email, code, context)
        rows.append(("offline_degraded", "zt_totp", ok, reason, latency))

    for _ in range(args.drift_trials):
        otp = otp_with_drift(enrollment.secret, args.drift_seconds)
        ok, reason, latency = totp_verify(base_url, enrollment, otp, context)
        rows.append(("false_rejection", "standard_totp", ok, reason, latency))

        ok, reason, latency = zt_verify(base_url, enrollment, otp, enrollment.private_key, context)
        rows.append(("false_rejection", "zt_totp", ok, reason, latency))

    # Recovery time: rotate key and verify ZT with the new key
    new_key, _ = generate_keypair()
    ok, reason, rotate_ms = rotate_key(base_url, enrollment, new_key, context)
    if ok:
        otp = current_otp(enrollment.secret)
        ok, reason, verify_ms = zt_verify(base_url, enrollment, otp, new_key, context)
        total_ms = rotate_ms + verify_ms
        rows.append(("rebind_time", "zt_totp", ok, reason, total_ms))
    else:
        rows.append(("rebind_time", "zt_totp", False, reason, rotate_ms))

    with open(output_path, "w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "timestamp",
                "scenario",
                "mode",
                "success",
                "reason",
                "latency_ms",
            ]
        )
        timestamp = datetime.utcnow().isoformat()
        for row in rows:
            writer.writerow([timestamp, *row])

    print(f"Wrote {len(rows)} rows to {output_path}")


if __name__ == "__main__":
    main()
