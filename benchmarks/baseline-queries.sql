-- ============================================================
-- Baseline (first-draft) versions of Query 4 and Query 5
-- They return the same rows as the optimized versions in
-- lakshitha-month3-queries.sql. run_benchmark.py measures both:
-- these under ids 4 / 5, the optimized ones under ids 4b / 5b.
-- ============================================================


-- ── Query 4: Review Statistics by Product (original) ─────────
-- Correlated subquery: the category average is re-computed per
-- output row.

SELECT
  p.name                                                        AS product,
  c.name                                                        AS category,
  COUNT(r.id)                                                   AS total_reviews,
  ROUND(AVG(r.rating), 2)                                       AS avg_rating,
  ROUND(AVG(r.rating) - (
    SELECT AVG(r2.rating)
    FROM reviews r2
    JOIN products p2 ON p2.id = r2.product_id
    WHERE p2.category_id = p.category_id
  ), 2)                                                         AS vs_category_avg,
  COUNT(r.id) FILTER (WHERE r.rating = 5)                       AS five_star,
  COUNT(r.id) FILTER (WHERE r.rating = 4)                       AS four_star,
  COUNT(r.id) FILTER (WHERE r.rating = 3)                       AS three_star,
  COUNT(r.id) FILTER (WHERE r.rating <= 2)                      AS low_ratings,
  COUNT(r.id) FILTER (WHERE r.is_verified = true)               AS verified_reviews
FROM products p
JOIN categories c ON c.id = p.category_id
LEFT JOIN reviews r ON r.product_id = p.id
WHERE p.is_active = true
GROUP BY p.id, p.name, p.category_id, c.name
HAVING COUNT(r.id) >= 3
ORDER BY avg_rating DESC, total_reviews DESC
LIMIT 20;


-- ── Query 5: Cart Abandonment Analysis (original) ────────────

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
LEFT JOIN orders      o  ON o.user_id     = u.id
                        AND o.created_at  > c.updated_at
WHERE o.id IS NULL
  AND c.updated_at >= CURRENT_DATE - INTERVAL '7 days'
GROUP BY u.id, u.email, u.first_name, u.last_name, c.updated_at
ORDER BY estimated_cart_value DESC;
