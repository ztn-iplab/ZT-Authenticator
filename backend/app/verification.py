from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field


class VerifyRequest(BaseModel):
    user_id: UUID
    device_id: UUID
    rp_id: str = Field(..., min_length=1, max_length=255)
    otp: str = Field(..., min_length=6, max_length=8)
    device_proof: str = Field(..., min_length=1)


class VerifyResponse(BaseModel):
    status: str
    reason: Optional[str] = None
