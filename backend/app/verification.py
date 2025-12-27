from typing import Optional
from uuid import UUID

from pydantic import BaseModel, EmailStr, Field


class VerifyRequest(BaseModel):
    user_id: UUID
    device_id: UUID
    rp_id: str = Field(..., min_length=1, max_length=255)
    otp: str = Field(..., min_length=6, max_length=8)
    device_proof: str = Field(..., min_length=1)


class VerifyResponse(BaseModel):
    status: str
    reason: Optional[str] = None


class LoginRequest(BaseModel):
    email: EmailStr
    otp: str = Field(..., min_length=6, max_length=8)


class LoginResponse(BaseModel):
    status: str
    reason: Optional[str] = None


class LoginStartResponse(BaseModel):
    status: str
    login_id: Optional[UUID] = None
    expires_in: Optional[int] = None
    reason: Optional[str] = None


class LoginStatusResponse(BaseModel):
    status: str
    reason: Optional[str] = None


class LoginPendingResponse(BaseModel):
    status: str
    login_id: Optional[UUID] = None
    nonce: Optional[str] = None
    rp_id: Optional[str] = None
    device_id: Optional[UUID] = None
    expires_in: Optional[int] = None


class LoginApproveRequest(BaseModel):
    login_id: UUID
    device_id: UUID
    rp_id: str = Field(..., min_length=1, max_length=255)
    otp: str = Field(..., min_length=6, max_length=8)
    nonce: str = Field(..., min_length=1)
    signature: str = Field(..., min_length=1)


class LoginRecoveryRequest(BaseModel):
    email: EmailStr
    recovery_code: str = Field(..., min_length=4, max_length=64)


class LoginRecoveryResponse(BaseModel):
    status: str
    reason: Optional[str] = None


class LoginDenyRequest(BaseModel):
    login_id: UUID
    reason: str = Field(..., min_length=1, max_length=100)
