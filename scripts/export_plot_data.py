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
    parser.add_argument("--output", default="experiments/plot_data.csv")
    parser.add_argument("--latency-scenario", default="legitimate_login")
    args = parser.parse_args()

    counts = defaultdict(lambda: {"ok": 0, "total": 0})
    latencies = defaultdict(list)

    with open(args.input, newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            scenario = row["scenario"]
            mode = row["mode"]
            success = row["success"].lower() == "true"
            counts[(scenario, mode)]["total"] += 1
            if success:
                counts[(scenario, mode)]["ok"] += 1
                try:
                    latencies[(scenario, mode)].append(float(row["latency_ms"]))
                except ValueError:
                    pass

    scenarios = sorted({key[0] for key in counts.keys()})
    modes = ["standard_totp", "zt_totp"]

    with open(args.output, "w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "scenario",
                "standard_totp_rate",
                "zt_totp_rate",
                "standard_totp_median_ms",
                "standard_totp_p95_ms",
                "zt_totp_median_ms",
                "zt_totp_p95_ms",
            ]
        )

        for scenario in scenarios:
            rates = {}
            for mode in modes:
                stats = counts.get((scenario, mode), {"ok": 0, "total": 0})
                total = stats["total"]
                ok = stats["ok"]
                rates[mode] = (ok / total * 100) if total else 0

            def latency_for(mode):
                values = latencies.get((args.latency_scenario, mode), [])
                return median(values) if values else None, percentile(values, 95)

            std_median, std_p95 = latency_for("standard_totp")
            zt_median, zt_p95 = latency_for("zt_totp")

            writer.writerow(
                [
                    scenario,
                    f"{rates['standard_totp']:.1f}",
                    f"{rates['zt_totp']:.1f}",
                    f"{std_median:.1f}" if std_median is not None else "",
                    f"{std_p95:.1f}" if std_p95 is not None else "",
                    f"{zt_median:.1f}" if zt_median is not None else "",
                    f"{zt_p95:.1f}" if zt_p95 is not None else "",
                ]
            )

    print(f"Wrote plot data to {args.output}")


if __name__ == "__main__":
    main()
