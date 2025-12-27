import argparse
import csv
from collections import defaultdict
from statistics import median


def percentile(values, p):
    if not values:
        return None
    values = sorted(values)
    k = int(round((p / 100) * (len(values) - 1)))
    return values[k]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", default="experiments/results.csv")
    args = parser.parse_args()

    counts = defaultdict(lambda: {"ok": 0, "total": 0})
    latencies = defaultdict(list)

    with open(args.input, newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            key = (row["scenario"], row["mode"])
            success = row["success"].lower() == "true"
            counts[key]["total"] += 1
            if success:
                counts[key]["ok"] += 1
                try:
                    latencies[key].append(float(row["latency_ms"]))
                except ValueError:
                    pass

    print("Success rates:")
    for key, stats in sorted(counts.items()):
        total = stats["total"]
        ok = stats["ok"]
        rate = (ok / total * 100) if total else 0
        print(f"{key[0]} | {key[1]}: {ok}/{total} ({rate:.1f}%)")

    print("\nLatency (ms) for successful attempts:")
    for key, values in sorted(latencies.items()):
        med = median(values) if values else None
        p95 = percentile(values, 95)
        print(f"{key[0]} | {key[1]}: median={med:.1f} p95={p95:.1f}")

    print("\nFalse rejection rate (scenario=false_rejection):")
    for mode in ["standard_totp", "zt_totp"]:
        stats = counts.get(("false_rejection", mode), {"ok": 0, "total": 0})
        total = stats["total"]
        ok = stats["ok"]
        rejected = total - ok
        rate = (rejected / total * 100) if total else 0
        print(f"{mode}: {rejected}/{total} ({rate:.1f}%)")

    print("\nRecovery rebind time (scenario=rebind_time):")
    stats = latencies.get(("rebind_time", "zt_totp"), [])
    if stats:
        med = median(stats)
        p95 = percentile(stats, 95)
        print(f"zt_totp: median={med:.1f} p95={p95:.1f}")
    else:
        print("zt_totp: no data")


if __name__ == "__main__":
    main()
