from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field


class ChallengeRequest(BaseModel):
    device_id: UUID
    rp_id: str = Field(..., min_length=1, max_length=255)


class ChallengeResponse(BaseModel):
    nonce: str
    expires_in: int


class DeviceProof(BaseModel):
    nonce: str = Field(..., min_length=1)
    signature: str = Field(..., min_length=1)


class ZtVerifyRequest(BaseModel):
    user_id: UUID
    device_id: UUID
    rp_id: str = Field(..., min_length=1, max_length=255)
    otp: str = Field(..., min_length=6, max_length=8)
    device_proof: DeviceProof


class ZtVerifyResponse(BaseModel):
    status: str
    reason: Optional[str] = None


class DeviceKeyRotateRequest(BaseModel):
    device_id: UUID
    rp_id: str = Field(..., min_length=1, max_length=255)
    key_type: str = Field(..., min_length=1, max_length=32)
    public_key: str = Field(..., min_length=1)


class DeviceKeyRotateResponse(BaseModel):
    status: str
    reason: Optional[str] = None
