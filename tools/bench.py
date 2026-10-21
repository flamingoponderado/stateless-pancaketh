#!/usr/bin/env python3
"""Benchmark one or two guests over an EEST manifest.

The first guest is the software/reference build.  ``--elf2`` adds an
accelerated-build column.  Every variant is run under Spike for its
instruction count and under ziskemu ``-X`` for ZisK STEPS, TOTAL COST, and
PRECOMPILED COST.  Only fixtures whose Spike output matches the manifest are
counted in the totals.

With ``--json``, the software metrics retain the historical top-level fields
used by tools/bench_compare.py.  A paired run additionally stores the
accelerated metrics under each fixture's ``variants`` object.
"""
import argparse
import csv
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPIKE_RUN = os.environ.get("SPIKE_RUN", os.path.join(ROOT, "tools/spike/spike_run"))
SPIKE_PROF = os.environ.get("SPIKE_PROF", os.path.join(ROOT, "tools/spike_prof/spike_prof"))
PROF_PY = os.path.join(ROOT, "tools/spike_prof/prof.py")
ZISKEMU = os.environ.get("ZISKEMU", os.path.expanduser("~/.zisk/bin/ziskemu"))

METRICS = ("spike_instr", "zisk_steps", "zisk_total_cost", "zisk_precompiled_cost")


def resolve_input_path(path, manifest_dir):
    if os.path.isfile(path):
        return path
    return os.path.join(manifest_dir, os.path.basename(path))


def read_profile(elf, hist):
    proc = subprocess.run(
        [sys.executable, PROF_PY, elf, hist, "--top", "15", "--csv"],
        capture_output=True, text=True)
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip() or "unknown error"
        raise RuntimeError(f"prof.py failed: {detail}")
    return list(csv.DictReader(proc.stdout.splitlines()))


def print_profile(label, rows, total_cost):
    print(f"  profile: {label}")
    print(f"    {'function':60s} {'instructions':>12s} {'instr%':>8s} "
          f"{'est_zisk_cost':>14s} {'est_zisk_cost%':>14s}")
    for row in rows:
        name = row["function"]
        count = int(row["instructions"])
        instruction_share = float(row["instruction_share_pct"])
        if total_cost >= 0:
            estimated_cost = int(total_cost * instruction_share / 100 + 0.5)
            estimated_share = instruction_share
            cost_text = f"{estimated_cost:,}"
            share_text = f"{estimated_share:6.2f}%"
        else:
            cost_text = "?"
            share_text = "?"
        print(f"    {name[:60]:60s} {count:12d} {instruction_share:7.2f}% "
              f"{cost_text:>14s} {share_text:>14s}")


def grab_metric(text, label):
    """Read an integer from a ziskemu stats line such as ``TOTAL COST: N``."""
    for pattern in (
            rf"(?im)^\s*{label}\s*[:=]\s*([0-9][0-9,]*)\b",
            rf"(?im)^\s*{label}\s+([0-9][0-9,]*)\b"):
        match = re.search(pattern, text)
        if match:
            return int(match.group(1).replace(",", ""))
    return -1


def run_variant(elf, label, inp, expected_hex, index, variant, out_dir,
                profile):
    stem = f"{variant}-{index:05d}"
    out = os.path.join(out_dir, stem + ".out")
    zisk_out = os.path.join(out_dir, stem + ".zisk.out")
    hist = os.path.join(out_dir, stem + ".hist")

    spike_env = dict(os.environ)
    if profile:
        spike_env["SPIKE_PC_HIST"] = hist
        if os.path.exists(hist):
            os.remove(hist)
    sp = subprocess.run([SPIKE_RUN, elf, inp, out], capture_output=True,
                        text=True, env=spike_env)
    match = re.search(r"\bsteps=(\d+)", sp.stderr)
    spike = int(match.group(1)) if match else -1
    actual = ""
    if os.path.exists(out):
        actual = open(out, "rb").read()[:len(expected_hex) // 2].hex()
    ok = actual == expected_hex

    zisk = subprocess.run(
        [ZISKEMU, "-e", elf, "-i", inp, "-o", zisk_out, "-X"],
        capture_output=True, text=True)
    zisk_text = zisk.stdout + zisk.stderr
    steps = grab_metric(zisk_text, r"STEPS")
    total_cost = grab_metric(zisk_text, r"TOTAL\s+COST")
    precompiled_cost = grab_metric(
        zisk_text, r"PRECOMPILE(?:D|S)?\s+COST")

    result = {
        "label": label,
        "ok": ok,
        "spike_instr": spike,
        "zisk_steps": steps,
        "zisk_total_cost": total_cost,
        "zisk_precompiled_cost": precompiled_cost,
        "zisk_rc": zisk.returncode,
    }
    if profile:
        try:
            print_profile(f"{variant}/{label}", read_profile(elf, hist), total_cost)
        except (OSError, RuntimeError, ValueError, KeyError) as exc:
            print(f"  profile unavailable ({variant}/{label}): {exc}")
    return result


def format_metric(value):
    return f"{value:,}" if value >= 0 else "n/a"


def totals_for(fixtures):
    selected = [fixture for fixture in fixtures if fixture["ok"]]
    return {
        "fixtures": len(fixtures),
        "ok": len(selected),
        **{metric: sum(fixture[metric] for fixture in selected)
           for metric in METRICS},
    }


def print_totals(variant, totals):
    print(f"{variant} OK {totals['ok']}/{totals['fixtures']}  "
          f"spike_instr={format_metric(totals['spike_instr'])}  "
          f"zisk_steps={format_metric(totals['zisk_steps'])}  "
          f"zisk_total_cost={format_metric(totals['zisk_total_cost'])}  "
          f"zisk_precompiled_cost={format_metric(totals['zisk_precompiled_cost'])}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("elf", help="software/reference guest ELF")
    ap.add_argument("manifest")
    ap.add_argument("--elf2", metavar="ELF",
                    help="accelerated guest ELF; print paired columns")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--filter", default="")
    ap.add_argument("--profile", action="store_true",
                    help="profile each fixture and print its top 15 functions")
    ap.add_argument("--json", metavar="FILE",
                    help="write per-fixture and total metrics as JSON")
    args = ap.parse_args()

    if args.profile and not os.path.isfile(SPIKE_PROF):
        ap.error(f"--profile requires {SPIKE_PROF}; run tools/spike_prof/build.sh")
    if args.elf2 and not os.path.isfile(args.elf2):
        ap.error(f"accelerated ELF not found: {args.elf2}")

    manifest_path = os.path.abspath(args.manifest)
    manifest_dir = os.path.dirname(manifest_path)
    with open(manifest_path) as manifest:
        rows = [line.rstrip("\n").split("\t") for line in manifest
                if line.strip()]
    for row in rows:
        row[1] = resolve_input_path(row[1], manifest_dir)
    if args.filter:
        rows = [row for row in rows if args.filter in row[0]]
    if args.limit:
        rows = rows[:args.limit]

    out_dir = os.path.join(ROOT, "work/bench")
    os.makedirs(out_dir, exist_ok=True)
    variants = [("software", args.elf)]
    if args.elf2:
        variants.append(("accelerated", args.elf2))

    metric_headers = {
        "software": ("software_spike", "software_STEPS", "software_TOTAL",
                     "software_PRECOMPILES"),
        "accelerated": ("accelerated_spike", "accelerated_STEPS",
                        "accelerated_TOTAL", "accelerated_PRECOMPILES"),
    }
    header = f"{'fixture':60s} {'ok':>3s}"
    for name, _ in variants:
        for column in metric_headers[name]:
            header += f" {column:>14s}"
    print(header)

    fixtures = []
    by_variant = {name: [] for name, _ in variants}
    for index, (label, inp, expected_hex, *_) in enumerate(rows):
        results = {}
        for name, elf in variants:
            results[name] = run_variant(
                elf, label, inp, expected_hex, index, name, out_dir,
                args.profile)
            by_variant[name].append(results[name])

        primary = results["software"]
        row_text = f"{label[:60]:60s} {('y' if primary['ok'] else 'n'):>3s}"
        for name, _ in variants:
            result = results[name]
            row_text += " " + " ".join(
                f"{format_metric(result[metric]):>14s}"
                for metric in METRICS)
        print(row_text)

        fixture = {
            "label": label,
            "ok": primary["ok"],
            # Keep the historical names for bench_compare.py.
            "spike_instr": primary["spike_instr"],
            "zisk_steps": primary["zisk_steps"],
            "zisk_cost": primary["zisk_total_cost"],
            "zisk_precompiled_cost": primary["zisk_precompiled_cost"],
        }
        if args.elf2:
            fixture["variants"] = {
                name: {metric: result[metric] for metric in METRICS}
                for name, result in results.items()
            }
        fixtures.append(fixture)

    totals = {name: totals_for(values)
              for name, values in by_variant.items()}
    for name, _ in variants:
        print_totals(name, totals[name])

    if args.json:
        json_path = os.path.abspath(args.json)
        os.makedirs(os.path.dirname(json_path), exist_ok=True)
        snapshot = {
            "version": 2 if args.elf2 else 1,
            "guest": os.path.relpath(os.path.abspath(args.elf), ROOT),
            "manifest": os.path.relpath(manifest_path, ROOT),
            "fixtures": fixtures,
            "totals": {
                "fixtures": totals["software"]["fixtures"],
                "ok": totals["software"]["ok"],
                "spike_instr": totals["software"]["spike_instr"],
                "zisk_steps": totals["software"]["zisk_steps"],
                "zisk_cost": totals["software"]["zisk_total_cost"],
                "zisk_precompiled_cost": totals["software"]["zisk_precompiled_cost"],
            },
        }
        if args.elf2:
            snapshot["variants"] = {
                name: os.path.relpath(os.path.abspath(elf), ROOT)
                for name, elf in variants
            }
            snapshot["variant_totals"] = totals
        with open(json_path, "w") as output:
            json.dump(snapshot, output, indent=2, sort_keys=True)
            output.write("\n")


if __name__ == "__main__":
    main()
