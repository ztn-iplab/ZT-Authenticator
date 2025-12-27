# ZT-TOTP Data Collection Guide

This guide provides repeatable steps to generate data for the paper tables.

## What gets measured

**Table I (success rates)**:
- Legitimate login
- Seed compromise
- Relay phishing
- Offline degraded

**Table II (latency)**:
- Standard TOTP (`/totp/verify`)
- ZT-TOTP (`/zt/challenge` + `/zt/verify`)

**Additional metrics**:
- False rejection rate (clock drift)
- Recovery rebind time (key rotation + first successful ZT verify)

## Run the collection script

Start backend first:

```bash
cd /Users/patrick-m/Documents/ZT-Authenticator/backend
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Then collect data:

```bash
cd /Users/patrick-m/Documents/ZT-Authenticator
source backend/.venv/bin/activate
python scripts/collect_metrics.py --base-url http://localhost:8000 --trials 30 --recovery-trials 8 --drift-trials 20 --drift-seconds 120 --output experiments/results.csv
```

## Summarize results

```bash
python scripts/summarize_metrics.py --input experiments/results.csv
```

This prints:
- success rates per scenario
- median and p95 latency for successful attempts
- false rejection rate (scenario=false_rejection)
- recovery rebind time (scenario=rebind_time)

## FRR drift sweep (plot-ready)

```bash
python scripts/collect_frr_sweep.py --base-url http://localhost:8000 --trials 30 --drifts 0,15,30,60,90,120 --output experiments/frr_sweep.csv
```

This produces `experiments/frr_sweep.csv` for plotting FRR vs. drift.

## Notes

- The script enrolls a synthetic user and performs trials automatically.
- Offline degraded scenario uses recovery codes (one-time use).
- Results are stored under `experiments/` which is ignored by git.
