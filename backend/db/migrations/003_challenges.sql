-- Device-bound challenge nonces for ZT-TOTP proof

CREATE TABLE IF NOT EXISTS device_challenges (
    id UUID PRIMARY KEY,
    device_id UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    rp_id TEXT NOT NULL,
    nonce TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_device_challenges_lookup
    ON device_challenges (device_id, rp_id, expires_at);
