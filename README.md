# ShopFlow E-Commerce Database (Month 3)

PostgreSQL database for an online marketplace. It covers schema design, versioned migrations, seed data, 10 analytical queries, and a measured query-optimization study.

**Author:** Lakshitha Wijerathne · **Track:** Engineer, Month 3: Database Design & Optimization

## Deliverables

| # | Deliverable | File |
|---|---|---|
| 1 | ERD diagram | [`lakshitha-month3-erd.png`](lakshitha-month3-erd.png), editable in Draw.io: [`lakshitha-month3-erd.drawio`](lakshitha-month3-erd.drawio) |
| 2 | Migration scripts | [`lakshitha-month3-migrations.sql`](lakshitha-month3-migrations.sql), rollback: [`lakshitha-month3-rollback.sql`](lakshitha-month3-rollback.sql) |
| 3 | Query optimization report | [`lakshitha-month3-optimization-report.md`](lakshitha-month3-optimization-report.md) |
| 4 | Seed data script | [`lakshitha-month3-seed.sql`](lakshitha-month3-seed.sql) |
| | Complex queries (10) | [`lakshitha-month3-queries.sql`](lakshitha-month3-queries.sql) |
| | Design decisions | [`lakshitha-month3-design-decisions.md`](lakshitha-month3-design-decisions.md) |

## Quick start

Needs PostgreSQL 14+ (tested on 18.6) and `psql`.

```bash
createdb shopflow
psql -d shopflow -v ON_ERROR_STOP=1 -f lakshitha-month3-migrations.sql   # 15 tables, V000-V004
psql -d shopflow -v ON_ERROR_STOP=1 -f lakshitha-month3-seed.sql         # ~53K rows, prints a row count summary
psql -d shopflow -f lakshitha-month3-queries.sql                         # the 10 queries
```

The migrations and queries are plain SQL and also run in pgAdmin or DBeaver. The seed script needs `psql`, because it uses `\set` scale variables.

| Task | Command |
|---|---|
| Larger dataset (~1.25M rows) | `psql -d shopflow -v users=50000 -v products=10000 -v orders=100000 -v reviews=60000 -f lakshitha-month3-seed.sql` |
| Roll back all migrations | `psql -d shopflow -f lakshitha-month3-rollback.sql` (or run its sections top-down to stop at a version) |
| Re-run the before/after benchmark | `python benchmarks/run_benchmark.py --db shopflow_perf` (creates and seeds a new database) |
| Regenerate the ERD from a live database | `python tools/build_erd.py --db shopflow` (needs Pillow) |

## Schema at a glance

15 tables in 3NF/BCNF, covering every business requirement in the brief:

| Area | Tables |
|---|---|
| Catalog | `categories` (self-referencing tree), `products`, `product_variants`, `inventory` (1:1 with variant) |
| Customers | `users`, `addresses`, `payment_methods` (provider token only, never card numbers) |
| Shopping | `carts` (1:1 with user), `cart_items`, `wishlist_items` (both M:N user to variant) |
| Orders | `orders`, `order_items` (price snapshot), `order_status_history` (written by trigger) |
| Engagement | `reviews` (one per user per product), `promotions` |

The database itself enforces the business rules. CHECK constraints keep `total = subtotal − discount + tax` and `line total = qty × price`, stop reserved stock from exceeding stock in hand, and keep promotion windows and caps valid. Partial unique indexes allow one default address and one default payment method per user. Delete rules are chosen per relationship: orders are never deleted by cascade. See the [design decisions](lakshitha-month3-design-decisions.md) for the reasoning behind each choice.

**Migration versions:** V000 version table · V001 schema and constraints · V002 indexes · V003 triggers · V004 drops 2 indexes that the measurements showed no query used.

## Query optimization: headline results

Measured on 100K orders / 300K order items, before vs after V002 (full method and every plan are in the [report](lakshitha-month3-optimization-report.md)):

| Change | Result |
|---|---|
| Index `orders(user_id, created_at)`, Q8 purchase history | 40.8 → 1.0 ms (**−97.6%**), 2,506 → 24 pages |
| Same index, the brief's example query | 33.9 → 2.9 ms (**−91.6%**) |
| Q5 anti-join rewritten as `NOT EXISTS` (row estimate was 1, actual 9,259) | 1,206 → 398 ms (**−67%**), −98% pages |
| Q6 `work_mem` 4MB → 16MB (sort no longer spills to disk) | 880 → 607 ms (**−31%**) |
| Q4 correlated subquery → CTE | −98% pages |

The report also shows where indexes did **not** help (full-table aggregates), one index that **increased** I/O, and why page counts are used as the primary metric on a busy laptop.

## Repository layout

```
lakshitha-month3-*.sql / .md / .png   deliverables (above)
benchmarks/
  run_benchmark.py                    before/after harness (EXPLAIN ANALYZE, 15 runs per query)
  baseline-queries.sql                first-draft Q4 and Q5, measured as the "before" versions
  extra-queries.sql                   the brief's example query and the work_mem experiment
  before/  after/                     raw EXPLAIN (ANALYZE, BUFFERS) output for every query
  results.json  results.md            all measured numbers
tools/build_erd.py                    builds the ERD (PNG + Draw.io) from the live schema
```
