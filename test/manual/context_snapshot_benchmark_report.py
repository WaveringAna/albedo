"""Compare offline snapshot runs, including output hashes and measurement ranges."""

import argparse
from collections import defaultdict
import json
from pathlib import Path
import statistics


def measurements(path):
    records = [
        json.loads(line)
        for line in path.read_text().splitlines()
        if line.startswith("{")
    ]
    metadata = records[0]
    groups = defaultdict(list)
    for record in records[1:]:
        key = (record["fixture"], record["count"], record["payload_bytes"])
        groups[key].append(record)
    for key, runs in groups.items():
        if sorted(run["iteration"] for run in runs) != [1, 2, 3, 4, 5]:
            raise ValueError(f"{path}: expected five measured runs for {key}")
    return metadata, groups


def distribution(values):
    return {
        "median": statistics.median(values),
        "min": min(values),
        "max": max(values),
    }


def summarize(runs):
    result = {}
    for field in (
        "capture_retained_binary_bytes",
        "retained_binary_bytes",
        "cleared_binary_bytes",
        "snapshot_term_bytes",
    ):
        result[field] = distribution([run[field] for run in runs])
    result["discarded_payload_reachable"] = sorted(
        {run["discarded_payload_reachable"] for run in runs}
    )
    phases = defaultdict(list)
    for run in runs:
        for phase in run["phases"]:
            phases[phase["phase"]].append(phase)
    result["phases"] = {
        name: {
            "wall_us": distribution([phase["wall_us"] for phase in samples]),
            "reductions": distribution([phase["reductions"] for phase in samples]),
            "sampled_peak": {
                metric: distribution(
                    [phase["sampled_peak"][metric] for phase in samples]
                )
                for metric in set.intersection(
                    *(set(phase["sampled_peak"]) for phase in samples)
                )
            },
        }
        for name, samples in phases.items()
    }
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    baseline_meta, baseline = measurements(args.baseline)
    candidate_meta, candidate = measurements(args.candidate)
    if baseline_meta != candidate_meta or baseline.keys() != candidate.keys():
        raise ValueError("Benchmark versions have different metadata or fixtures")
    fixtures = []
    for key, baseline_runs in baseline.items():
        candidate_runs = candidate[key]
        hashes = {run["output_sha256"] for run in baseline_runs + candidate_runs}
        fixtures.append(
            {
                "fixture": key[0],
                "count": key[1],
                "payload_bytes": key[2],
                "output_sha256": sorted(hashes),
                "outputs_equal": len(hashes) == 1,
                "baseline": summarize(baseline_runs),
                "candidate": summarize(candidate_runs),
            }
        )
    args.output.write_text(
        json.dumps(
            {
                "metadata": baseline_meta,
                "baseline_raw": str(args.baseline),
                "candidate_raw": str(args.candidate),
                "fixtures": fixtures,
            },
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    main()
