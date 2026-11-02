-- ============================================================
-- ShopFlow E-Commerce Platform - Complex Queries
-- Dialect: PostgreSQL
-- ============================================================


-- ── Query 1: Top Selling Products by Category ────────────────

SELECT
  c.name                              AS category,
  p.name                              AS product,
  SUM(oi.quantity)                    AS total_units_sold,
  SUM(oi.quantity * oi.unit_price)    AS revenue
FROM order_items oi
JOIN orders           o  ON oi.order_id   = o.id
JOIN product_variants pv ON oi.variant_id = pv.id
JOIN products         p  ON pv.product_id = p.id
JOIN categories       c  ON p.category_id = c.id
WHERE o.status      = 'delivered'
  AND o.created_at >= CURRENT_DATE - INTERVAL '30 days'
GROUP BY c.id, c.name, p.id, p.name
ORDER BY revenue DESC
LIMIT 10;


-- ── Query 2: Customer Lifetime Value ─────────────────────────

WITH customer_stats AS (
  SELECT
    u.id,
    u.first_name || ' ' || u.last_name   AS full_name,
    u.email,
    COUNT(o.id)                           AS total_orders,
    SUM(o.total_amount)                   AS lifetime_value,
    AVG(o.total_amount)                   AS avg_order_value,
    MIN(o.created_at)                     AS first_order_at,
    MAX(o.created_at)                     AS last_order_at
  FROM users u
  JOIN orders o ON o.user_id = u.id
  WHERE o.status NOT IN ('cancelled', 'refunded')
  GROUP BY u.id, u.first_name, u.last_name, u.email
)
SELECT
  full_name,
  email,
  total_orders,
  lifetime_value,
  ROUND(avg_order_value, 2)                        AS avg_order_value,
  first_order_at::DATE                             AS first_order,
  last_order_at::DATE                              AS last_order,
  RANK() OVER (ORDER BY lifetime_value DESC)       AS clv_rank
FROM customer_stats
ORDER BY lifetime_value DESC
LIMIT 20;


-- ── Query 3: Inventory Low Stock Alert ───────────────────────

SELECT
  p.name                                        AS product,
  pv.sku,
  pv.size,
  pv.color,
  i.quantity_in_stock,
  i.quantity_reserved,
  (i.quantity_in_stock - i.quantity_reserved)   AS available_stock,
  i.low_stock_threshold
FROM inventory i
JOIN product_variants pv ON i.variant_id  = pv.id
JOIN products         p  ON pv.product_id = p.id
WHERE (i.quantity_in_stock - i.quantity_reserved) <= i.low_stock_threshold
  AND pv.is_active = true
  AND p.is_active  = true
ORDER BY available_stock ASC;


-- ── Query 4: Review Statistics by Product ────────────────────
-- Each product vs the average rating of its category. The category
-- averages are computed once in a CTE and joined. The first version
-- used a correlated subquery that re-scanned all reviews per output
-- row (kept in benchmarks/baseline-queries.sql); this form reads
-- 98% fewer pages (optimization report, section 3.4).

WITH category_avg AS (
  SELECT p.category_id, AVG(r.rating) AS avg_rating
  FROM reviews r
  JOIN products p ON p.id = r.product_id
  GROUP BY p.category_id
)
SELECT
  p.name                                                        AS product,
  c.name                                                        AS category,
  COUNT(r.id)                                                   AS total_reviews,
  ROUND(AVG(r.rating), 2)                                       AS avg_rating,
  ROUND(AVG(r.rating) - ca.avg_rating, 2)                       AS vs_category_avg,
  COUNT(r.id) FILTER (WHERE r.rating = 5)                       AS five_star,
  COUNT(r.id) FILTER (WHERE r.rating = 4)                       AS four_star,
  COUNT(r.id) FILTER (WHERE r.rating = 3)                       AS three_star,
  COUNT(r.id) FILTER (WHERE r.rating <= 2)                      AS low_ratings,
  COUNT(r.id) FILTER (WHERE r.is_verified = true)               AS verified_reviews
FROM products p
JOIN categories c        ON c.id = p.category_id
LEFT JOIN category_avg ca ON ca.category_id = p.category_id
LEFT JOIN reviews r      ON r.product_id = p.id
WHERE p.is_active = true
GROUP BY p.id, p.name, c.name, ca.avg_rating
HAVING COUNT(r.id) >= 3
ORDER BY avg_rating DESC, total_reviews DESC
LIMIT 20;

-- ── Query 5: Cart Abandonment Analysis ───────────────────────
-- Carts active in the last 7 days with no order placed after the
-- cart was last updated. NOT EXISTS is planned as a real anti-join;
-- the first version (LEFT JOIN ... WHERE o.id IS NULL, kept in
-- benchmarks/baseline-queries.sql) was misestimated at 1 row and
-- read 98% more pages (optimization report, section 3.3).

SELECT
  u.email,
  u.first_name || ' ' || u.last_name         AS full_name,
  COUNT(ci.id)                                AS items_in_cart,
  SUM(ci.quantity)                            AS total_quantity,
  SUM(ci.quantity * (
    p.base_price + pv.price_modifier
  ))                                          AS estimated_cart_value,
  c.updated_at                                AS last_activity
FROM carts c
JOIN users            u  ON c.user_id     = u.id
JOIN cart_items       ci ON ci.cart_id    = c.id
JOIN product_variants pv ON ci.variant_id = pv.id
JOIN products         p  ON pv.product_id = p.id
WHERE c.updated_at >= CURRENT_DATE - INTERVAL '7 days'
  AND NOT EXISTS (
    SELECT 1 FROM orders o
    WHERE o.user_id = u.id
      AND o.created_at > c.updated_at
  )
GROUP BY u.id, u.email, u.first_name, u.last_name, c.updated_at
ORDER BY estimated_cart_value DESC;


-- ── Query 6: Order Status Breakdown ──────────────────────────
-- Last 90 days: volume and revenue per status, share of all orders
-- (window over the grouped rows), and how long orders sit in each
-- status before moving on (from order_status_history).

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

-- ── Query 7: Category Hierarchy with Product Counts ──────────
-- Products sit in leaf categories, so parents get their counts by
-- rolling up every descendant (ancestors array from the recursive CTE).

WITH RECURSIVE category_tree AS (
  SELECT
    id,
    name,
    parent_id,
    0           AS depth,
    name::TEXT  AS path,
    ARRAY[id]   AS ancestors
  FROM categories
  WHERE parent_id IS NULL

  UNION ALL

  SELECT
    c.id,
    c.name,
    c.parent_id,
    ct.depth + 1,
    ct.path || ' > ' || c.name,
    ct.ancestors || c.id
  FROM categories c
  JOIN category_tree ct ON c.parent_id = ct.id
),
direct_counts AS (
  SELECT
    category_id,
    COUNT(*)                                AS products,
    COUNT(*) FILTER (WHERE is_active)       AS active_products
  FROM products
  GROUP BY category_id
),
rollup AS (
  SELECT
    anc.id                                  AS category_id,
    SUM(dc.products)                        AS products,
    SUM(dc.active_products)                 AS active_products
  FROM category_tree d
  CROSS JOIN LATERAL unnest(d.ancestors) AS anc(id)
  JOIN direct_counts dc ON dc.category_id = d.id
  GROUP BY anc.id
)
SELECT
  ct.path,
  ct.depth,
  COALESCE(dc.products, 0)                  AS direct_products,
  COALESCE(r.products, 0)                   AS total_products,
  COALESCE(r.active_products, 0)            AS total_active_products
FROM category_tree ct
LEFT JOIN direct_counts dc ON dc.category_id = ct.id
LEFT JOIN rollup        r  ON r.category_id  = ct.id
ORDER BY ct.path;

-- ── Query 8: User Purchase History ───────────────────────────
-- One customer's order history (the "My orders" page), with a
-- running total and the change from their previous order.

WITH user_orders AS (
  SELECT
    u.id                                              AS user_id,
    u.first_name || ' ' || u.last_name               AS full_name,
    o.id                                              AS order_id,
    o.status,
    o.total_amount,
    o.created_at
  FROM users u
  JOIN orders o ON o.user_id = u.id
  WHERE u.id = 123
    AND o.status NOT IN ('cancelled', 'refunded')
)
SELECT
  full_name,
  order_id,
  status,
  total_amount,
  created_at::DATE                                    AS order_date,
  SUM(total_amount)  OVER (PARTITION BY user_id
                           ORDER BY created_at)       AS running_total,
  ROW_NUMBER()       OVER (PARTITION BY user_id
                           ORDER BY created_at)       AS order_number,
  total_amount - LAG(total_amount) OVER (PARTITION BY user_id
                           ORDER BY created_at)       AS change_vs_previous
FROM user_orders
ORDER BY created_at DESC;

-- ── Query 9: Promotion Usage Report ──────────────────────────
-- RIGHT JOIN keeps every promotion, including ones never used.

SELECT
  pr.code,
  pr.discount_type,
  pr.discount_value,
  pr.max_uses,
  COUNT(o.id)                                       AS times_used,
  CASE
    WHEN pr.max_uses IS NULL THEN NULL
    ELSE ROUND(COUNT(o.id) * 100.0 / pr.max_uses, 2)
  END                                               AS usage_percentage,
  COALESCE(SUM(o.discount_amount), 0)               AS total_discount_given,
  COALESCE(SUM(o.total_amount), 0)                  AS revenue_with_promo,
  pr.expires_at::DATE                               AS expires_on
FROM orders o
RIGHT JOIN promotions pr ON o.promotion_id = pr.id
                        AND o.status NOT IN ('cancelled', 'refunded')
GROUP BY pr.id, pr.code, pr.discount_type, pr.discount_value,
         pr.max_uses, pr.expires_at
ORDER BY times_used DESC;

-- ── Query 10: Revenue by Time Period ─────────────────────────

WITH monthly_revenue AS (
  SELECT
    DATE_TRUNC('month', created_at)   AS month,
    COUNT(*)                           AS order_count,
    SUM(total_amount)                  AS revenue,
    SUM(discount_amount)               AS total_discounts
  FROM orders
  WHERE status NOT IN ('cancelled', 'refunded')
  GROUP BY DATE_TRUNC('month', created_at)
)
SELECT
  TO_CHAR(month, 'YYYY-MM')           AS month,
  order_count,
  revenue,
  total_discounts,
  ROUND(
    (revenue - LAG(revenue) OVER (ORDER BY month))
    * 100.0
    / NULLIF(LAG(revenue) OVER (ORDER BY month), 0),
  2)                                  AS mom_growth_pct
FROM monthly_revenue
ORDER BY month;
