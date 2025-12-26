from typing import List
from uuid import UUID

from pydantic import BaseModel, Field


class TotpRegisterRequest(BaseModel):
    user_id: UUID
    rp_id: str = Field(..., min_length=1, max_length=255)
    account_name: str = Field(..., min_length=1, max_length=255)
    issuer: str = Field(..., min_length=1, max_length=255)


class TotpRegisterResponse(BaseModel):
    otpauth_uri: str
    recovery_codes: List[str]


class TotpVerifyRequest(BaseModel):
    user_id: UUID
    rp_id: str = Field(..., min_length=1, max_length=255)
    otp: str = Field(..., min_length=6, max_length=8)


class TotpVerifyResponse(BaseModel):
    status: str
    reason: str | None = None


class RecoveryVerifyRequest(BaseModel):
    user_id: UUID
    code: str = Field(..., min_length=4, max_length=64)


class RecoveryVerifyResponse(BaseModel):
    status: str
    reason: str | None = None
