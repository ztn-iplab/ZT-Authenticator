from datetime import datetime
from uuid import UUID

from typing import Optional

from pydantic import BaseModel, EmailStr, Field


class FeedbackRequest(BaseModel):
    email: Optional[EmailStr] = None
    subject: str = Field(..., min_length=3, max_length=120)
    category: Optional[str] = Field(default=None, max_length=32)
    message: str = Field(..., min_length=10, max_length=2000)
    source: Optional[str] = Field(default=None, max_length=64)


class FeedbackResponse(BaseModel):
    status: str


class UserCreate(BaseModel):
    email: EmailStr


class UserOut(BaseModel):
    id: UUID
    email: EmailStr
    created_at: datetime


class DeviceCreate(BaseModel):
    user_id: UUID
    device_label: str = Field(..., min_length=1, max_length=100)
    platform: str = Field(..., min_length=1, max_length=32)


class DeviceOut(BaseModel):
    id: UUID
    user_id: UUID
    device_label: str
    platform: str
    created_at: datetime


class RelyingPartyCreate(BaseModel):
    rp_id: str = Field(..., min_length=1, max_length=255)
    display_name: str = Field(..., min_length=1, max_length=100)


class RelyingPartyOut(BaseModel):
    id: UUID
    rp_id: str
    display_name: str
    created_at: datetime


class DeviceKeyCreate(BaseModel):
    device_id: UUID
    rp_id: UUID
    key_type: str = Field(..., min_length=1, max_length=32, description="e.g., ed25519")
    public_key: str = Field(..., min_length=1)


class DeviceKeyOut(BaseModel):
    id: UUID
    device_id: UUID
    rp_id: UUID
    key_type: str
    public_key: str
    created_at: datetime
