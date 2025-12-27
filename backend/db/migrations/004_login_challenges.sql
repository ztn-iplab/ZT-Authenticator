-- Login approval challenges (classic login with hidden device proof)

CREATE TABLE IF NOT EXISTS login_challenges (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    rp_id TEXT NOT NULL,
    nonce TEXT NOT NULL,
    otp_hash TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,
    approved_at TIMESTAMPTZ,
    denied_reason TEXT
);
