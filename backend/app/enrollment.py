from pydantic import BaseModel, EmailStr, Field

from app import db
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
from app.repositories import device_keys, devices, relying_parties, users


class EnrollmentRequest(BaseModel):
    email: EmailStr
    device_label: str = Field(..., min_length=1, max_length=100)
    platform: str = Field(..., min_length=1, max_length=32)
    rp_id: str = Field(..., min_length=1, max_length=255)
    rp_display_name: str = Field(..., min_length=1, max_length=100)
    key_type: str = Field(..., min_length=1, max_length=32)
    public_key: str = Field(..., min_length=1)


class EnrollmentResponse(BaseModel):
    user: UserOut
    device: DeviceOut
    relying_party: RelyingPartyOut
    device_key: DeviceKeyOut


async def enroll(payload: EnrollmentRequest) -> EnrollmentResponse:
    pool = await db.connect()

    # This is a placeholder flow to exercise the data model end-to-end.
    user = await users.get_by_email(pool, payload.email)
    if user is None:
        user = await users.create(pool, UserCreate(email=payload.email))

    device = await devices.create(
        pool,
        DeviceCreate(
            user_id=user.id,
            device_label=payload.device_label,
            platform=payload.platform,
        ),
    )
    rp = await relying_parties.get_by_rp_id(pool, payload.rp_id)
    if rp is None:
        rp = await relying_parties.create(
            pool,
            RelyingPartyCreate(rp_id=payload.rp_id, display_name=payload.rp_display_name),
        )
    device_key = await device_keys.create(
        pool,
        DeviceKeyCreate(
            device_id=device.id,
            rp_id=rp.id,
            key_type=payload.key_type,
            public_key=payload.public_key,
        ),
    )

    return EnrollmentResponse(
        user=user,
        device=device,
        relying_party=rp,
        device_key=device_key,
    )
