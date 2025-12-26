import base64
from uuid import UUID

import time

from asyncpg import UniqueViolationError
from fastapi import APIRouter, HTTPException, Request

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
from app.verification import VerifyRequest, VerifyResponse
from app.zt_models import (
    ChallengeRequest,
    ChallengeResponse,
    DeviceKeyRotateRequest,
    DeviceKeyRotateResponse,
    ZtVerifyRequest,
    ZtVerifyResponse,
)
from app.zt_service import (
    device_key_exists,
    get_device_key as get_device_key_for_rp,
    issue_challenge,
    verify_device_proof,
)
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
from app.repositories import challenges, device_keys, devices, relying_parties, totp, users
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
