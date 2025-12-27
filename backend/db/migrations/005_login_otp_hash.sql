ALTER TABLE login_challenges
ADD COLUMN IF NOT EXISTS otp_hash TEXT;
