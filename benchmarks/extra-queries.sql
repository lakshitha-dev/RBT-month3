-- ============================================================
-- Extra benchmark cases (not part of the 10 challenge queries)
-- Same "-- ── Query <id>:" markers as lakshitha-month3-queries.sql
-- so run_benchmark.py can split them.
-- ============================================================


-- ── Query 11: Brief example - one user's orders with all columns ──

SELECT *
FROM orders o
JOIN order_items      oi ON o.id = oi.order_id
JOIN product_variants pv ON oi.variant_id = pv.id
JOIN products         p  ON pv.product_id = p.id
WHERE o.user_id = 123;


-- ── Query 11b: Brief example rewritten - named columns, newest first ──

SELECT
  o.id          AS order_id,
  o.created_at,
  o.status,
  p.name        AS product,
  pv.sku,
  oi.quantity,
  oi.unit_price
FROM orders o
JOIN order_items      oi ON o.id = oi.order_id
JOIN product_variants pv ON oi.variant_id = pv.id
JOIN products         p  ON pv.product_id = p.id
WHERE o.user_id = 123
ORDER BY o.created_at DESC;


-- ── Query 6b: Query 6 with work_mem raised to 16MB ──
-- Same SQL as Query 6. The LEAD() window sorts ~100K history rows,
-- which spills to disk at the default work_mem of 4MB.

SET work_mem = '16MB';
WITH recent_orders AS (
  SELECT id, status, total_amount
  FROM orders
  WHERE created_at >= CURRENT_DATE - INTERVAL '90 days'
),
time_in_status AS (
  SELECT
    h.to_status                                             AS status,
    LEAD(h.changed_at) OVER (PARTITION BY h.order_id
                             ORDER BY h.changed_at) - h.changed_at AS duration
  FROM order_status_history h
  JOIN recent_orders ro ON ro.id = h.order_id
),
avg_time AS (
  SELECT status, AVG(duration) AS avg_duration
  FROM time_in_status
  WHERE duration IS NOT NULL
  GROUP BY status
)
SELECT
  ro.status,
  COUNT(*)                                                  AS order_count,
  SUM(ro.total_amount)                                      AS total_revenue,
  ROUND(AVG(ro.total_amount), 2)                            AS avg_order_value,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)        AS percentage,
  ROUND((EXTRACT(EPOCH FROM at.avg_duration) / 3600)::NUMERIC, 1)
                                                            AS avg_hours_before_next_status
FROM recent_orders ro
LEFT JOIN avg_time at ON at.status = ro.status
GROUP BY ro.status, at.avg_duration
ORDER BY order_count DESC;
