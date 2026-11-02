"""Before/after index benchmark for the ShopFlow queries.

Steps:
  1. create a new database (refuses to touch one that already exists)
  2. apply migrations V000, V001, V003 - everything except the V002 indexes
  3. seed at performance scale, VACUUM ANALYZE
  4. "before": per query, 1 warm-up, N timed runs with
     EXPLAIN (ANALYZE, BUFFERS, TIMING OFF), then 1 fully timed
     EXPLAIN (ANALYZE, BUFFERS) whose plan is saved for analysis
  5. apply V002, VACUUM ANALYZE
  6. "after": same runs again
  7. write plans to benchmarks/before|after/, numbers to benchmarks/results.{json,md}

Timed runs use TIMING OFF because per-node timing reads the clock for
every row; on Windows that overhead changed some results by up to 2x
and favoured plans with fewer nodes. TIMING OFF matches plain execution.

A query block may start with "SET name = value;" lines; they are sent
before the EXPLAIN in the same session (used for work_mem experiments).

Usage (from the repo root):
  python benchmarks/run_benchmark.py --db shopflow_perf
  python benchmarks/run_benchmark.py --db shopflow_perf --reuse
--reuse keeps the seeded data and only drops / recreates the V002 indexes.
Connection settings come from the usual PG* environment variables
(defaults here: PGHOST=localhost, PGUSER=postgres).
"""

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BENCH = ROOT / "benchmarks"
MIGRATIONS = ROOT / "lakshitha-month3-migrations.sql"
SEED = ROOT / "lakshitha-month3-seed.sql"
QUERIES = ROOT / "lakshitha-month3-queries.sql"
BASELINE_QUERIES = BENCH / "baseline-queries.sql"
EXTRA_QUERIES = BENCH / "extra-queries.sql"

PERF_SCALE = {"users": 50000, "products": 10000, "variants_per_product": 4,
              "orders": 100000, "reviews": 60000}

ENV = {**os.environ, "PGCLIENTENCODING": "UTF8"}
ENV.setdefault("PGHOST", "localhost")
ENV.setdefault("PGUSER", "postgres")


def psql(db, sql=None, file=None, variables=None, tuples_only=False):
    cmd = ["psql", "-X", "-q", "-w", "-d", db, "-v", "ON_ERROR_STOP=1"]
    for name, value in (variables or {}).items():
        cmd += ["-v", f"{name}={value}"]
    if tuples_only:
        cmd += ["-A", "-t"]
    cmd += ["-f", str(file) if file else "-"]
    result = subprocess.run(cmd, input=sql, capture_output=True, text=True,
                            encoding="utf-8", env=ENV)
    if result.returncode != 0:
        sys.exit(f"psql failed:\n{result.stderr}")
    return result.stdout


def migration_sections():
    """Split the migrations file into {'V000': sql, 'V001': sql, ...}."""
    text = MIGRATIONS.read_text(encoding="utf-8")
    parts = re.split(r"^-- \[(V\d{3})\].*$", text, flags=re.M)
    return dict(zip(parts[1::2], parts[2::2]))


def parse_queries(path):
    """Return [(id, title, sql)] split on '-- ── Query <id>: <title>' markers."""
    text = path.read_text(encoding="utf-8")
    return [(qid, title.strip(), body.strip()) for qid, title, body in
            re.findall(r"^-- ── Query (\w+): (.+?)\s*─*$\n(.*?)(?=^-- ── Query |\Z)",
                       text, flags=re.M | re.S)]


def load_queries():
    """The 10 challenge queries, plus extra cases.

    Where baseline-queries.sql has a first-draft version of a query, that
    version is measured under the plain id (4) and the optimized one from
    the main file under id + 'b' (4b), so both appear in the results.
    """
    baseline = {q[0]: q for q in parse_queries(BASELINE_QUERIES)}
    queries = []
    for qid, title, sql in parse_queries(QUERIES):
        if qid in baseline:
            queries.append(baseline[qid])
            queries.append((qid + "b", f"{title} (optimized)", sql))
        else:
            queries.append((qid, title, sql))
    return queries + parse_queries(EXTRA_QUERIES)


def split_settings(sql):
    """Separate leading 'SET ...;' lines (and comments) from the query itself."""
    settings = []
    lines = sql.splitlines()
    while lines and (lines[0].startswith("--") or not lines[0].strip()
                     or re.match(r"SET \w+ = .+;$", lines[0])):
        line = lines.pop(0)
        if line.startswith("SET "):
            settings.append(line)
    return "\n".join(settings), "\n".join(lines)


def run_suite(db, label, queries, runs):
    out_dir = BENCH / label
    out_dir.mkdir(parents=True, exist_ok=True)
    results = {}
    for qid, title, sql in queries:
        settings, query_sql = split_settings(sql)
        timed_sql = f"{settings}\nEXPLAIN (ANALYZE, BUFFERS, TIMING OFF)\n{query_sql}"
        psql(db, timed_sql, tuples_only=True)  # warm-up: fills the buffer cache
        timings = []
        for _ in range(runs):
            plan = psql(db, timed_sql, tuples_only=True)
            timings.append(float(re.search(r"Execution Time: ([\d.]+) ms", plan).group(1)))
        timings.sort()
        median_ms = timings[len(timings) // 2]
        # The root node's Buffers line is the total for the whole query.
        # Unlike time, it does not depend on machine load.
        root_buffers = re.search(r"^\s*Buffers: (.*)$", plan, flags=re.M).group(1)
        buffers = {f"{kind}_{op}": int(n) for kind, ops in re.findall(r"(shared|temp) ([a-z=0-9 ]+)", root_buffers)
                   for op, n in re.findall(r"(\w+)=(\d+)", ops)}
        pages = buffers.get("shared_hit", 0) + buffers.get("shared_read", 0)
        full_plan = psql(db, f"{settings}\nEXPLAIN (ANALYZE, BUFFERS)\n{query_sql}", tuples_only=True)
        (out_dir / f"q{qid.zfill(3)}.txt").write_text(
            f"-- Query {qid}: {title}\n"
            f"-- {runs} runs (TIMING OFF): median {median_ms:.3f} ms, min {timings[0]:.3f} ms\n"
            f"-- all runs (ms): {', '.join(f'{t:.3f}' for t in timings)}\n"
            f"-- buffers (whole query): {root_buffers}\n"
            f"-- plan below: one extra run with per-node timing (adds overhead)\n\n{full_plan}",
            encoding="utf-8")
        results[qid] = {"title": title, "median_ms": median_ms, "min_ms": timings[0],
                        "runs_ms": timings, "pages": pages, "buffers": buffers}
        print(f"  [{label}] Q{qid:<4} median {median_ms:9.3f} ms  min {timings[0]:9.3f} ms  "
              f"pages {pages:7d}  {title}")
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default="shopflow_perf")
    parser.add_argument("--runs", type=int, default=9)
    parser.add_argument("--reuse", action="store_true",
                        help="reuse an already seeded --db; only drop/recreate the V002 indexes")
    args = parser.parse_args()

    sections = migration_sections()
    existing = psql("postgres", "SELECT datname FROM pg_database", tuples_only=True).split()
    if args.reuse:
        if args.db not in existing:
            sys.exit(f"--reuse: database {args.db} does not exist.")
        indexes = re.findall(r"CREATE INDEX (\w+)", sections["V002"])
        print(f"Dropping the {len(indexes)} V002 indexes (data is kept)...")
        psql(args.db, f"DROP INDEX IF EXISTS {', '.join(indexes)};\n"
                      "DELETE FROM schema_migrations WHERE version = 'V002';")
    else:
        if args.db in existing:
            sys.exit(f"Database {args.db} already exists. Use --reuse, drop it yourself, or pass another --db.")
        subprocess.run(["createdb", "-w", args.db], check=True, env=ENV)
        print("Applying V000, V001, V003 (no V002 indexes)...")
        for version in ("V000", "V001", "V003"):
            psql(args.db, sections[version])
        print(f"Seeding at performance scale {PERF_SCALE}...")
        print(psql(args.db, file=SEED, variables=PERF_SCALE))
    psql(args.db, "VACUUM ANALYZE;")

    queries = load_queries()
    print(f"Running {len(queries)} queries, {args.runs} timed runs each...")
    before = run_suite(args.db, "before", queries, args.runs)

    print("Applying V002 indexes...")
    psql(args.db, sections["V002"])
    psql(args.db, "VACUUM ANALYZE;")
    after = run_suite(args.db, "after", queries, args.runs)

    env_info = psql(args.db, """
        SELECT 'version', version()
        UNION ALL SELECT name, setting || COALESCE(' ' || unit, '') FROM pg_settings
        WHERE name IN ('shared_buffers', 'work_mem', 'effective_cache_size', 'random_page_cost',
                       'max_parallel_workers_per_gather', 'jit')
        UNION ALL SELECT 'db_size', pg_size_pretty(pg_database_size(current_database()));
    """, tuples_only=True)
    sizes = psql(args.db, """
        SELECT relname || '|' || n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC;
    """, tuples_only=True)

    def pct(b, a):
        return round((b - a) / b * 100, 1) if b else 0.0

    rows = []
    for qid, title, _ in queries:
        b, a = before[qid], after[qid]
        rows.append({"id": qid, "title": title,
                     "before_ms": b["median_ms"], "after_ms": a["median_ms"],
                     "improvement_pct": pct(b["median_ms"], a["median_ms"]),
                     "before_min_ms": b["min_ms"], "after_min_ms": a["min_ms"],
                     "min_improvement_pct": pct(b["min_ms"], a["min_ms"]),
                     "before_pages": b["pages"], "after_pages": a["pages"],
                     "pages_reduction_pct": pct(b["pages"], a["pages"])})

    (BENCH / "results.json").write_text(json.dumps(
        {"scale": PERF_SCALE, "runs": args.runs, "environment": env_info.strip().splitlines(),
         "table_rows": sizes.strip().splitlines(), "queries": rows,
         "before": before, "after": after}, indent=2), encoding="utf-8")

    lines = ["| Query | Description | Median before | Median after | Change | Min before | Min after | "
             "Change | Pages before | Pages after | Change |",
             "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for r in rows:
        lines.append(f"| Q{r['id']} | {r['title']} | {r['before_ms']:.1f} | {r['after_ms']:.1f} | "
                     f"{r['improvement_pct']:.1f}% | {r['before_min_ms']:.1f} | {r['after_min_ms']:.1f} | "
                     f"{r['min_improvement_pct']:.1f}% | {r['before_pages']} | {r['after_pages']} | "
                     f"{r['pages_reduction_pct']:.1f}% |")
    (BENCH / "results.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
