import base64
import json
from datetime import datetime, timedelta, timezone
from io import BytesIO
from uuid import UUID

import time

from asyncpg import UniqueViolationError
from fastapi import APIRouter, Form, HTTPException, Request, Response
from fastapi.encoders import jsonable_encoder

from app import db
from app.enrollment import EnrollmentRequest, EnrollmentResponse, enroll
from app.totp_models import (
    RecoveryVerifyRequest,
    RecoveryVerifyResponse,
    TotpRegisterRequest,
    TotpRegisterResponse,
    TotpVerifyRequest,
    TotpVerifyResponse,
)
from app.totp_service import (
    current_totp,
    decrypt_secret,
    register_totp,
    verify_recovery_code,
    verify_totp,
)
from app.crypto_utils import hash_otp
from app.verification import (
    LoginApproveRequest,
    LoginDenyRequest,
    LoginPendingResponse,
    LoginRecoveryRequest,
    LoginRecoveryResponse,
    LoginRequest,
    LoginResponse,
    LoginStartResponse,
    LoginStatusResponse,
    VerifyRequest,
    VerifyResponse,
)
from app.zt_models import (
    ChallengeRequest,
    ChallengeResponse,
    DeviceKeyRotateRequest,
    DeviceKeyRotateResponse,
    ZtVerifyRequest,
    ZtVerifyResponse,
)
import qrcode
from app.zt_service import (
    device_key_exists,
    get_device_key as get_device_key_for_rp,
    issue_challenge,
    verify_device_proof,
)
from app.zt_service import generate_nonce
from app.models import (
    DeviceCreate,
    DeviceKeyCreate,
    DeviceKeyOut,
    DeviceOut,
    RelyingPartyCreate,
    RelyingPartyOut,
    UserCreate,
    UserOut,
)
from app.repositories import (
    challenges,
    device_keys,
    devices,
    login_challenges,
    relying_parties,
    totp,
    users,
)
import logging
from time import monotonic

router = APIRouter()
logger = logging.getLogger("app.audit")


@router.post("/users", response_model=UserOut)
async def create_user(payload: UserCreate) -> UserOut:
    pool = await db.connect()
    try:
        return await users.create(pool, payload)
    except UniqueViolationError:
        raise HTTPException(status_code=409, detail="email already exists")


@router.get("/users/{user_id}", response_model=UserOut)
async def get_user(user_id: UUID) -> UserOut:
    pool = await db.connect()
    user = await users.get_by_id(pool, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="user not found")
    return user


@router.post("/devices", response_model=DeviceOut)
async def create_device(payload: DeviceCreate) -> DeviceOut:
    pool = await db.connect()
    return await devices.create(pool, payload)


@router.get("/devices/{device_id}", response_model=DeviceOut)
async def get_device(device_id: UUID) -> DeviceOut:
    pool = await db.connect()
    device = await devices.get_by_id(pool, device_id)
    if device is None:
        raise HTTPException(status_code=404, detail="device not found")
    return device


@router.post("/relying-parties", response_model=RelyingPartyOut)
async def create_relying_party(payload: RelyingPartyCreate) -> RelyingPartyOut:
    pool = await db.connect()
    try:
        return await relying_parties.create(pool, payload)
    except UniqueViolationError:
        raise HTTPException(status_code=409, detail="rp_id already exists")


@router.post("/enroll", response_model=EnrollmentResponse)
async def enroll_device(payload: EnrollmentRequest) -> EnrollmentResponse:
    try:
        return await enroll(payload)
    except UniqueViolationError:
        raise HTTPException(status_code=409, detail="enrollment conflict")


@router.post("/verify", response_model=VerifyResponse)
async def verify(payload: VerifyRequest) -> VerifyResponse:
    # Placeholder until ZT-TOTP verification is implemented.
    raise HTTPException(status_code=501, detail="verification not implemented yet")


@router.post("/login", response_model=LoginStartResponse)
async def login(payload: LoginRequest, request: Request) -> LoginStartResponse:
    pool = await db.connect()
    await login_challenges.prune_expired(pool)

    user = await users.get_by_email(pool, payload.email)
    if user is None:
        return LoginStartResponse(status="denied", reason="user_not_found")

    device = await devices.get_latest_for_user(pool, user.id)
    if device is None:
        return LoginStartResponse(status="denied", reason="device_not_found")

    secret_row = await totp.get_latest_secret_for_user(pool, user.id)
    if secret_row is None:
        return LoginStartResponse(status="denied", reason="totp_not_registered")

    rp_id = secret_row["rp_id"]
    rp = await relying_parties.get_by_rp_id(pool, rp_id)
    if rp is None:
        return LoginStartResponse(status="denied", reason="rp_not_found")

    device_key = await device_keys.get_by_device_and_rp(pool, device.id, rp.id)
    if device_key is None:
        return LoginStartResponse(status="denied", reason="device_not_enrolled")

    settings = request.app.state.settings
    secret = decrypt_secret(secret_row["secret_encrypted"], settings.master_key)
    if not verify_totp(secret, payload.otp):
        return LoginStartResponse(status="denied", reason="invalid_otp")

    nonce = generate_nonce()
    otp_hash = hash_otp(payload.otp, settings.recovery_pepper)
    expires_at = datetime.now(timezone.utc) + timedelta(seconds=120)
    challenge = await login_challenges.insert(
        pool=pool,
        user_id=user.id,
        device_id=device.id,
        rp_id=rp_id,
        nonce=nonce,
        otp_hash=otp_hash,
        expires_at=expires_at,
    )
    expires_in = int((challenge["expires_at"] - challenge["created_at"]).total_seconds())
    return LoginStartResponse(status="pending", login_id=challenge["id"], expires_in=expires_in)


@router.get("/login-form")
async def login_form() -> Response:
    html = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ZT-TOTP Login</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background:#0f0f0f; color:#f2f2f2; }
    .card { max-width:420px; margin:8vh auto; background:#1a1a1a; padding:24px; border-radius:16px; box-shadow:0 12px 30px rgba(0,0,0,0.4); }
    label { display:block; margin:12px 0 6px; }
    input { width:100%; padding:12px; border-radius:10px; border:1px solid #333; background:#111; color:#f2f2f2; }
    button { width:100%; margin-top:16px; padding:12px; border:none; border-radius:10px; background:#3b82f6; color:#fff; font-weight:600; }
    .status { margin-top:12px; color:#b0b0b0; white-space:pre-wrap; }
  </style>
</head>
<body>
  <div class="card">
    <h2>ZT-TOTP Login</h2>
    <form id="login-form">
      <label>Email</label>
      <input type="email" name="email" required />
      <label>One-Time Password</label>
      <input type="text" name="otp" inputmode="numeric" />
      <label>Recovery Code (optional)</label>
      <input type="text" name="recovery" />
      <button type="submit">Verify</button>
    </form>
    <div class="status" id="status">Ready.</div>
  </div>
  <script>
    const form = document.getElementById('login-form');
    const status = document.getElementById('status');
    let pollTimer = null;

    function setStatus(text) {
      status.textContent = text;
    }

    async function pollStatus(loginId) {
      if (pollTimer) clearInterval(pollTimer);
      pollTimer = setInterval(async () => {
        const res = await fetch(`/login/status?login_id=${loginId}`);
        const data = await res.json();
        if (data.status === 'pending') {
          setStatus('Pending device approval...');
          return;
        }
        clearInterval(pollTimer);
        setStatus(JSON.stringify(data));
      }, 1000);
    }

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      setStatus('Submitting...');
      const formData = new FormData(form);
      const payload = {
        email: formData.get('email'),
        otp: formData.get('otp'),
        recovery_code: formData.get('recovery'),
      };
      const res = await fetch('/login-form/submit', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      const data = await res.json();
      if (data.status === 'pending' && data.login_id) {
        setStatus('Pending device approval...');
        pollStatus(data.login_id);
        return;
      }
      setStatus(JSON.stringify(data));
    });
  </script>
</body>
</html>
"""
    return Response(content=html.strip(), media_type="text/html")


@router.post("/login-form/submit")
async def login_form_submit(payload: dict, request: Request) -> Response:
    email = (payload.get("email") or "").strip()
    otp = (payload.get("otp") or "").strip()
    recovery_code = (payload.get("recovery_code") or "").strip()
    if not email:
        return Response(
            content=json.dumps({"status": "denied", "reason": "missing_fields"}),
            media_type="application/json",
            status_code=400,
        )
    if recovery_code:
        recovery = await login_recovery(LoginRecoveryRequest(email=email, recovery_code=recovery_code), request)
        return Response(content=json.dumps(jsonable_encoder(recovery)), media_type="application/json")
    if not otp:
        return Response(
            content=json.dumps({"status": "denied", "reason": "missing_fields"}),
            media_type="application/json",
            status_code=400,
        )

    start = await login(LoginRequest(email=email, otp=otp), request)
    return Response(
        content=json.dumps(jsonable_encoder(start)),
        media_type="application/json",
    )


@router.get("/login/status", response_model=LoginStatusResponse)
async def login_status(login_id: UUID) -> LoginStatusResponse:
    pool = await db.connect()
    challenge = await login_challenges.get_by_id(pool, login_id)
    if challenge is None:
        return LoginStatusResponse(status="denied", reason="not_found")
    return LoginStatusResponse(status=challenge["status"], reason=challenge["denied_reason"])


@router.get("/login/pending", response_model=LoginPendingResponse)
async def login_pending(user_id: UUID) -> LoginPendingResponse:
    pool = await db.connect()
    challenge = await login_challenges.get_pending_for_user(pool, user_id)
    if challenge is None:
        return LoginPendingResponse(status="none")
    expires_in = int((challenge["expires_at"] - challenge["created_at"]).total_seconds())
    return LoginPendingResponse(
        status="pending",
        login_id=challenge["id"],
        nonce=challenge["nonce"],
        rp_id=challenge["rp_id"],
        device_id=challenge["device_id"],
        expires_in=expires_in,
    )


@router.post("/login/approve", response_model=LoginResponse)
async def login_approve(payload: LoginApproveRequest, request: Request) -> LoginResponse:
    pool = await db.connect()
    challenge = await login_challenges.get_by_id(pool, payload.login_id)
    if challenge is None or challenge["status"] != "pending":
        return LoginResponse(status="denied", reason="not_pending")
    if challenge["device_id"] != payload.device_id or challenge["rp_id"] != payload.rp_id:
        await login_challenges.mark_denied(pool, payload.login_id, "mismatch")
        return LoginResponse(status="denied", reason="mismatch")

    rp = await relying_parties.get_by_rp_id(pool, payload.rp_id)
    if rp is None:
        await login_challenges.mark_denied(pool, payload.login_id, "rp_not_found")
        return LoginResponse(status="denied", reason="rp_not_found")

    device_key = await device_keys.get_by_device_and_rp(pool, payload.device_id, rp.id)
    if device_key is None:
        await login_challenges.mark_denied(pool, payload.login_id, "device_not_enrolled")
        return LoginResponse(status="denied", reason="device_not_enrolled")

    secret_row = await totp.get_secret(pool, challenge["user_id"], payload.rp_id)
    if secret_row is None:
        await login_challenges.mark_denied(pool, payload.login_id, "totp_not_registered")
        return LoginResponse(status="denied", reason="totp_not_registered")

    settings = request.app.state.settings
    secret = decrypt_secret(secret_row["secret_encrypted"], settings.master_key)
    if not verify_totp(secret, payload.otp):
        await login_challenges.mark_denied(pool, payload.login_id, "invalid_otp")
        return LoginResponse(status="denied", reason="invalid_otp")

    expected_hash = hash_otp(payload.otp, settings.recovery_pepper)
    if challenge["otp_hash"] != expected_hash:
        await login_challenges.mark_denied(pool, payload.login_id, "otp_mismatch")
        return LoginResponse(status="denied", reason="otp_mismatch")

    proof_ok = verify_device_proof(
        key_type=device_key.key_type,
        public_key=device_key.public_key,
        nonce=payload.nonce,
        device_id=payload.device_id,
        rp_id=payload.rp_id,
        otp=payload.otp,
        signature=payload.signature,
    )
    if not proof_ok:
        await login_challenges.mark_denied(pool, payload.login_id, "invalid_device_proof")
        return LoginResponse(status="denied", reason="invalid_device_proof")

    await login_challenges.mark_approved(pool, payload.login_id)
    return LoginResponse(status="ok", reason=None)


@router.post("/login/deny", response_model=LoginResponse)
async def login_deny(payload: LoginDenyRequest) -> LoginResponse:
    pool = await db.connect()
    challenge = await login_challenges.get_by_id(pool, payload.login_id)
    if challenge is None:
        return LoginResponse(status="denied", reason="not_found")
    if challenge["status"] != "pending":
        return LoginResponse(status=challenge["status"], reason=challenge["denied_reason"])
    await login_challenges.mark_denied(pool, payload.login_id, payload.reason)
    return LoginResponse(status="denied", reason=payload.reason)


@router.post("/login/recover", response_model=LoginRecoveryResponse)
async def login_recovery(payload: LoginRecoveryRequest, request: Request) -> LoginRecoveryResponse:
    pool = await db.connect()
    user = await users.get_by_email(pool, payload.email)
    if user is None:
        return LoginRecoveryResponse(status="denied", reason="user_not_found")
    settings = request.app.state.settings
    ok = await verify_recovery_code(
        pool=pool,
        user_id=user.id,
        code=payload.recovery_code,
        recovery_pepper=settings.recovery_pepper,
    )
    if not ok:
        return LoginRecoveryResponse(status="denied", reason="invalid_recovery_code")
    return LoginRecoveryResponse(status="ok", reason=None)


@router.post("/zt/challenge", response_model=ChallengeResponse)
async def zt_challenge(payload: ChallengeRequest) -> ChallengeResponse:
    pool = await db.connect()
    challenge = await issue_challenge(pool, payload.device_id, payload.rp_id)
    ttl = int((challenge["expires_at"] - challenge["created_at"]).total_seconds())
    return ChallengeResponse(nonce=challenge["nonce"], expires_in=ttl)


@router.post("/zt/verify", response_model=ZtVerifyResponse)
async def zt_verify(payload: ZtVerifyRequest, request: Request) -> ZtVerifyResponse:
    pool = await db.connect()
    started = monotonic()
    if not await device_key_exists(pool, payload.device_id, payload.rp_id):
        logger.info("zt_verify denied reason=device_not_enrolled")
        return ZtVerifyResponse(status="denied", reason="device_not_enrolled")

    secret_row = await totp.get_secret(pool, payload.user_id, payload.rp_id)
    if secret_row is None:
        logger.info("zt_verify denied reason=totp_not_registered")
        return ZtVerifyResponse(status="denied", reason="totp_not_registered")

    secret = decrypt_secret(secret_row["secret_encrypted"], request.app.state.settings.master_key)
    if not verify_totp(secret, payload.otp):
        logger.info("zt_verify denied reason=invalid_otp")
        return ZtVerifyResponse(status="denied", reason="invalid_otp")

    challenge = await challenges.get_valid_challenge(
        pool,
        payload.device_id,
        payload.rp_id,
        payload.device_proof.nonce,
    )
    if challenge is None:
        logger.info("zt_verify denied reason=invalid_or_expired_nonce")
        return ZtVerifyResponse(status="denied", reason="invalid_or_expired_nonce")

    device_key = await get_device_key_for_rp(pool, payload.device_id, payload.rp_id)
    if device_key is None:
        logger.info("zt_verify denied reason=device_not_enrolled")
        return ZtVerifyResponse(status="denied", reason="device_not_enrolled")

    proof_ok = verify_device_proof(
        key_type=device_key.key_type,
        public_key=device_key.public_key,
        nonce=payload.device_proof.nonce,
        device_id=payload.device_id,
        rp_id=payload.rp_id,
        otp=payload.otp,
        signature=payload.device_proof.signature,
    )
    if not proof_ok:
        logger.info("zt_verify denied reason=invalid_device_proof")
        return ZtVerifyResponse(status="denied", reason="invalid_device_proof")

    await challenges.consume_challenge(pool, challenge["id"])
    duration_ms = int((monotonic() - started) * 1000)
    logger.info("zt_verify ok duration_ms=%s", duration_ms)
    return ZtVerifyResponse(status="ok", reason=None)


@router.post("/zt/debug-proof")
async def zt_debug_proof(payload: ZtVerifyRequest, request: Request) -> dict:
    settings = request.app.state.settings
    if settings.app_env != "development":
        raise HTTPException(status_code=404, detail="not found")

    pool = await db.connect()
    device_key = await get_device_key_for_rp(pool, payload.device_id, payload.rp_id)
    if device_key is None:
        raise HTTPException(status_code=404, detail="device key not found")

    message = f"{payload.device_proof.nonce}|{payload.device_id}|{payload.rp_id}|{payload.otp}"
    try:
        signature_bytes = base64.b64decode(payload.device_proof.signature)
        signature_len = len(signature_bytes)
    except Exception:
        signature_len = 0
    try:
        public_bytes = base64.b64decode(device_key.public_key)
        public_len = len(public_bytes)
    except Exception:
        public_len = 0

    signature_ok = verify_device_proof(
        key_type=device_key.key_type,
        public_key=device_key.public_key,
        nonce=payload.device_proof.nonce,
        device_id=payload.device_id,
        rp_id=payload.rp_id,
        otp=payload.otp,
        signature=payload.device_proof.signature,
    )
    return {
        "key_type": device_key.key_type,
        "public_key_len": public_len,
        "public_key_format": "raw" if public_len == 32 else "der",
        "signature_len": signature_len,
        "message": message,
        "signature_valid": signature_ok,
    }


@router.post("/totp/register", response_model=TotpRegisterResponse)
async def totp_register(
    payload: TotpRegisterRequest,
    request: Request,
) -> TotpRegisterResponse:
    pool = await db.connect()
    user = await users.get_by_id(pool, payload.user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="user not found")

    settings = request.app.state.settings
    try:
        otpauth_uri, recovery_codes = await register_totp(
            pool=pool,
            user_id=payload.user_id,
            rp_id=payload.rp_id,
            account_name=payload.account_name,
            issuer=payload.issuer,
            master_key=settings.master_key,
            recovery_pepper=settings.recovery_pepper,
        )
    except UniqueViolationError:
        raise HTTPException(status_code=409, detail="totp already registered")

    return TotpRegisterResponse(
        otpauth_uri=otpauth_uri,
        recovery_codes=recovery_codes,
    )


@router.post("/totp/verify", response_model=TotpVerifyResponse)
async def totp_verify(
    payload: TotpVerifyRequest,
    request: Request,
) -> TotpVerifyResponse:
    pool = await db.connect()
    settings = request.app.state.settings
    started = monotonic()

    secret_row = await totp.get_secret(pool, payload.user_id, payload.rp_id)
    if secret_row is None:
        raise HTTPException(status_code=404, detail="totp not registered")

    secret = decrypt_secret(secret_row["secret_encrypted"], settings.master_key)
    ok = verify_totp(secret, payload.otp)
    if not ok:
        logger.info("totp_verify denied reason=invalid_otp")
        return TotpVerifyResponse(status="denied", reason="invalid_otp")
    duration_ms = int((monotonic() - started) * 1000)
    logger.info("totp_verify ok duration_ms=%s", duration_ms)
    return TotpVerifyResponse(status="ok", reason=None)


@router.post("/totp/recovery/verify", response_model=RecoveryVerifyResponse)
async def totp_recovery_verify(
    payload: RecoveryVerifyRequest,
    request: Request,
) -> RecoveryVerifyResponse:
    pool = await db.connect()
    settings = request.app.state.settings
    ok = await verify_recovery_code(
        pool=pool,
        user_id=payload.user_id,
        code=payload.code,
        recovery_pepper=settings.recovery_pepper,
    )
    if not ok:
        logger.info("totp_recovery denied reason=invalid_code")
        return RecoveryVerifyResponse(status="denied", reason="invalid_code")
    logger.info("totp_recovery ok")
    return RecoveryVerifyResponse(status="ok", reason=None)


@router.post("/zt/rotate-key", response_model=DeviceKeyRotateResponse)
async def zt_rotate_key(payload: DeviceKeyRotateRequest) -> DeviceKeyRotateResponse:
    pool = await db.connect()
    rp = await relying_parties.get_by_rp_id(pool, payload.rp_id)
    if rp is None:
        return DeviceKeyRotateResponse(status="denied", reason="rp_not_found")
    await device_keys.upsert_by_device_and_rp(
        pool,
        payload.device_id,
        rp.id,
        payload.key_type,
        payload.public_key,
    )
    logger.info("zt_rotate_key ok device_id=%s rp_id=%s", payload.device_id, payload.rp_id)
    return DeviceKeyRotateResponse(status="ok", reason=None)


@router.get("/enroll/qr")
async def enroll_qr(
    rp_id: str,
    email: str,
    issuer: str,
    account_name: str,
    rp_display_name: str | None = None,
    device_label: str | None = None,
) -> Response:
    payload = {
        "type": "zt_totp_enroll",
        "rp_id": rp_id,
        "rp_display_name": rp_display_name or rp_id,
        "email": email,
        "issuer": issuer,
        "account_name": account_name,
        "device_label": device_label or "Research Phone",
    }
    payload_json = json.dumps(payload, separators=(",", ":"))
    qr = qrcode.QRCode(
        version=3,
        error_correction=qrcode.constants.ERROR_CORRECT_M,
        box_size=8,
        border=2,
    )
    qr.add_data(payload_json)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    buffer = BytesIO()
    img.save(buffer, format="PNG")
    return Response(content=buffer.getvalue(), media_type="image/png")


@router.get("/enroll/qr-page")
async def enroll_qr_page(
    rp_id: str,
    email: str,
    issuer: str,
    account_name: str,
    rp_display_name: str | None = None,
    device_label: str | None = None,
) -> Response:
    params = {
        "rp_id": rp_id,
        "email": email,
        "issuer": issuer,
        "account_name": account_name,
        "rp_display_name": rp_display_name or rp_id,
        "device_label": device_label or "Research Phone",
    }
    query = "&".join(f"{key}={value}" for key, value in params.items())
    html = f"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ZT-TOTP Enrollment QR</title>
  <style>
    body {{
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #0f0f0f;
      color: #f2f2f2;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      margin: 0;
    }}
    .card {{
      background: #1a1a1a;
      padding: 32px;
      border-radius: 16px;
      text-align: center;
      box-shadow: 0 12px 30px rgba(0,0,0,0.4);
    }}
    img {{
      width: 320px;
      height: 320px;
      border-radius: 12px;
      background: #fff;
      padding: 8px;
    }}
    p {{ margin-top: 16px; color: #b0b0b0; }}
  </style>
</head>
<body>
  <div class="card">
    <h2>ZT-TOTP Enrollment</h2>
    <img src="/enroll/qr?{query}" alt="Enrollment QR" />
    <p>Scan this QR with ZT-Authenticator</p>
  </div>
</body>
</html>
"""
    return Response(content=html.strip(), media_type="text/html")


@router.get("/totp/debug-code")
async def totp_debug_code(
    user_id: UUID,
    rp_id: str,
    request: Request,
) -> dict:
    settings = request.app.state.settings
    if settings.app_env != "development":
        raise HTTPException(status_code=404, detail="not found")

    pool = await db.connect()
    secret_row = await totp.get_secret(pool, user_id, rp_id)
    if secret_row is None:
        raise HTTPException(status_code=404, detail="totp not registered")

    secret = decrypt_secret(secret_row["secret_encrypted"], settings.master_key)
    return {"otp": current_totp(secret)}


@router.get("/totp/debug-state")
async def totp_debug_state(
    user_id: UUID,
    rp_id: str,
    request: Request,
) -> dict:
    settings = request.app.state.settings
    if settings.app_env != "development":
        raise HTTPException(status_code=404, detail="not found")

    pool = await db.connect()
    secret_row = await totp.get_secret(pool, user_id, rp_id)
    if secret_row is None:
        raise HTTPException(status_code=404, detail="totp not registered")

    secret = decrypt_secret(secret_row["secret_encrypted"], settings.master_key)
    return {
        "otp": current_totp(secret),
        "server_time": int(time.time()),
    }


@router.get("/totp/debug-secret")
async def totp_debug_secret(
    user_id: UUID,
    rp_id: str,
    request: Request,
) -> dict:
    settings = request.app.state.settings
    if settings.app_env != "development":
        raise HTTPException(status_code=404, detail="not found")

    pool = await db.connect()
    secret_row = await totp.get_secret(pool, user_id, rp_id)
    if secret_row is None:
        raise HTTPException(status_code=404, detail="totp not registered")

    secret = decrypt_secret(secret_row["secret_encrypted"], settings.master_key)
    return {"secret": secret}


@router.get("/relying-parties/{rp_uuid}", response_model=RelyingPartyOut)
async def get_relying_party(rp_uuid: UUID) -> RelyingPartyOut:
    pool = await db.connect()
    rp = await relying_parties.get_by_id(pool, rp_uuid)
    if rp is None:
        raise HTTPException(status_code=404, detail="relying party not found")
    return rp


@router.post("/device-keys", response_model=DeviceKeyOut)
async def create_device_key(payload: DeviceKeyCreate) -> DeviceKeyOut:
    pool = await db.connect()
    return await device_keys.create(pool, payload)


@router.get("/device-keys/{key_id}", response_model=DeviceKeyOut)
async def get_device_key(key_id: UUID) -> DeviceKeyOut:
    pool = await db.connect()
    key = await device_keys.get_by_id(pool, key_id)
    if key is None:
        raise HTTPException(status_code=404, detail="device key not found")
    return key
