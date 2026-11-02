-- ============================================================
-- ShopFlow E-Commerce Platform - Seed Data
-- Dialect: PostgreSQL (run with psql, it uses psql variables)
--
-- Default scale (challenge brief counts, ~53K rows in all tables):
--   psql -d shopflow -v ON_ERROR_STOP=1 -f lakshitha-month3-seed.sql
--
-- Performance scale (used for the optimization report, ~1M rows):
--   psql -d shopflow -v ON_ERROR_STOP=1 -v users=50000 -v products=10000 \
--        -v orders=100000 -v reviews=60000 -f lakshitha-month3-seed.sql
--
-- Re-runnable: it truncates every table first. setseed() keeps the
-- data close to identical between runs (counts can differ by a few
-- rows, so it is not exactly reproducible).
-- ============================================================

-- ── Scale knobs (override with psql -v name=value) ───────────

\if :{?users}
\else
  \set users 1000
\endif
\if :{?products}
\else
  \set products 500
\endif
\if :{?variants_per_product}
\else
  \set variants_per_product 4
\endif
\if :{?orders}
\else
  \set orders 5000
\endif
\if :{?reviews}
\else
  \set reviews 3000
\endif

\echo 'Seeding: users=' :users ' products=' :products ' variants/product=' :variants_per_product ' orders=' :orders ' reviews=' :reviews

DO $$ BEGIN PERFORM setseed(0.42); END $$;

BEGIN;

TRUNCATE categories, users, addresses, payment_methods, products, product_variants,
         inventory, promotions, carts, cart_items, wishlist_items, orders,
         order_items, order_status_history, reviews
  RESTART IDENTITY CASCADE;

-- Seed writes status history and updated_at itself, with historical
-- timestamps, so the V003 triggers are switched off until COMMIT.
ALTER TABLE orders DISABLE TRIGGER USER;


-- ── 1. categories (53: 10 roots, 40 children, 3 grandchildren) ──

INSERT INTO categories (name, slug, description, created_at)
VALUES
  ('Electronics',   'electronics', 'Electronic devices and accessories', NOW() - INTERVAL '3 years'),
  ('Clothing',      'clothing',    'Men and women apparel',              NOW() - INTERVAL '3 years'),
  ('Home & Garden', 'home-garden', 'Home decor and garden tools',        NOW() - INTERVAL '3 years'),
  ('Sports',        'sports',      'Sports and outdoor equipment',       NOW() - INTERVAL '3 years'),
  ('Books',         'books',       'Books and literature',               NOW() - INTERVAL '3 years'),
  ('Toys',          'toys',        'Toys and games for all ages',        NOW() - INTERVAL '3 years'),
  ('Beauty',        'beauty',      'Beauty and personal care',           NOW() - INTERVAL '3 years'),
  ('Automotive',    'automotive',  'Car parts and accessories',          NOW() - INTERVAL '3 years'),
  ('Food & Drinks', 'food-drinks', 'Groceries and beverages',            NOW() - INTERVAL '3 years'),
  ('Health',        'health',      'Health and wellness products',       NOW() - INTERVAL '3 years');

-- Parents are looked up by slug, so this never depends on id values.
INSERT INTO categories (parent_id, name, slug, description, created_at)
SELECT parent.id, v.name, v.slug, v.description, NOW() - INTERVAL '3 years'
FROM (VALUES
  ('Phones',          'phones',           'Smartphones and accessories',     'electronics'),
  ('Laptops',         'laptops',          'Laptops and notebooks',           'electronics'),
  ('Cameras',         'cameras',          'Digital cameras and lenses',      'electronics'),
  ('Headphones',      'headphones',       'Wired and wireless headphones',   'electronics'),
  ('Smart Home',      'smart-home',       'Smart home devices',              'electronics'),
  ('Men Clothing',    'men-clothing',     'Clothing for men',                'clothing'),
  ('Women Clothing',  'women-clothing',   'Clothing for women',              'clothing'),
  ('Kids Clothing',   'kids-clothing',    'Clothing for kids',               'clothing'),
  ('Shoes',           'shoes',            'Footwear for all',                'clothing'),
  ('Accessories',     'accessories',      'Bags, belts, and wallets',        'clothing'),
  ('Furniture',       'furniture',        'Indoor and outdoor furniture',    'home-garden'),
  ('Kitchen',         'kitchen',          'Kitchen appliances and tools',    'home-garden'),
  ('Bedding',         'bedding',          'Sheets, pillows, and blankets',   'home-garden'),
  ('Garden Tools',    'garden-tools',     'Tools for gardening',             'home-garden'),
  ('Lighting',        'lighting',         'Indoor and outdoor lighting',     'home-garden'),
  ('Football',        'football',         'Football gear and equipment',     'sports'),
  ('Gym Equipment',   'gym-equipment',    'Weights and machines',            'sports'),
  ('Cycling',         'cycling',          'Bikes and cycling gear',          'sports'),
  ('Swimming',        'swimming',         'Swimwear and pool accessories',   'sports'),
  ('Outdoor',         'outdoor',          'Camping and hiking gear',         'sports'),
  ('Fiction',         'fiction',          'Fiction novels and stories',      'books'),
  ('Non-Fiction',     'non-fiction',      'Educational and informational',   'books'),
  ('Children Books',  'children-books',   'Books for children',              'books'),
  ('Comics',          'comics',           'Comics and graphic novels',       'books'),
  ('Textbooks',       'textbooks',        'Academic and study books',        'books'),
  ('Action Figures',  'action-figures',   'Action figures and collectibles', 'toys'),
  ('Board Games',     'board-games',      'Family board games',              'toys'),
  ('Puzzles',         'puzzles',          'Jigsaw and brain puzzles',        'toys'),
  ('Outdoor Toys',    'outdoor-toys',     'Outdoor play equipment',          'toys'),
  ('Educational',     'educational-toys', 'Learning toys for kids',          'toys'),
  ('Skincare',        'skincare',         'Face and body skincare',          'beauty'),
  ('Haircare',        'haircare',         'Shampoos and styling products',   'beauty'),
  ('Makeup',          'makeup',           'Cosmetics and makeup tools',      'beauty'),
  ('Fragrances',      'fragrances',       'Perfumes and colognes',           'beauty'),
  ('Car Audio',       'car-audio',        'Speakers and car stereos',        'automotive'),
  ('Car Care',        'car-care',         'Cleaning and maintenance',        'automotive'),
  ('Snacks',          'snacks',           'Chips, nuts, and snacks',         'food-drinks'),
  ('Coffee & Tea',    'coffee-tea',       'Coffee beans and teas',           'food-drinks'),
  ('Vitamins',        'vitamins',         'Vitamins and supplements',        'health'),
  ('Fitness',         'fitness',          'Fitness trackers and gear',       'health')
) AS v(name, slug, description, parent_slug)
JOIN categories parent ON parent.slug = v.parent_slug;

INSERT INTO categories (parent_id, name, slug, description, created_at)
SELECT parent.id, v.name, v.slug, v.description, NOW() - INTERVAL '2 years'
FROM (VALUES
  ('Gaming Laptops',     'gaming-laptops',     'High-performance gaming laptops', 'laptops'),
  ('Running Shoes',      'running-shoes',      'Road and trail running shoes',    'shoes'),
  ('Mirrorless Cameras', 'mirrorless-cameras', 'Mirrorless camera bodies',        'cameras')
) AS v(name, slug, description, parent_slug)
JOIN categories parent ON parent.slug = v.parent_slug;


-- ── 2. users ─────────────────────────────────────────────────

INSERT INTO users (email, password_hash, first_name, last_name, phone, is_active, created_at, updated_at)
SELECT
  lower(n.first_names[g.fi]) || '.' || lower(n.last_names[g.li]) || g.s || '@' || n.domains[g.di],
  '$2b$10$' || substr(md5(g.s::TEXT) || md5(g.s::TEXT || 'salt'), 1, 53),
  n.first_names[g.fi],
  n.last_names[g.li],
  CASE WHEN random() < 0.15 THEN NULL
       ELSE '+1' || (2000000000 + floor(random() * 7999999999))::BIGINT::TEXT END,
  random() > 0.03,
  g.created_at,
  g.created_at + random() * (NOW() - g.created_at)
FROM (
  SELECT s,
         1 + floor(random() * 30)::INT          AS fi,
         1 + floor(random() * 30)::INT          AS li,
         1 + floor(random() * 5)::INT           AS di,
         NOW() - random() * INTERVAL '1095 days' AS created_at
  FROM generate_series(1, :users) AS s
) g
CROSS JOIN (SELECT
  ARRAY['James','Oliver','Harry','Jack','George','Noah','Charlie','Jacob','Alfie','Freddie',
        'Olivia','Emma','Ava','Sophia','Isabella','Mia','Charlotte','Amelia','Harper','Evelyn',
        'Kasun','Nimal','Dilini','Tharushi','Arjun','Priya','Wei','Yuki','Mateo','Fatima'] AS first_names,
  ARRAY['Smith','Johnson','Williams','Brown','Jones','Garcia','Miller','Davis','Wilson','Moore',
        'Taylor','Anderson','Thomas','Jackson','White','Harris','Martin','Thompson','Young','Lee',
        'Perera','Fernando','Silva','Jayasinghe','Patel','Kumar','Chen','Tanaka','Lopez','Khan'] AS last_names,
  ARRAY['gmail.com','yahoo.com','outlook.com','shopflow.com','example.org'] AS domains
) n;


-- ── 3. addresses ─────────────────────────────────────────────
-- Every user gets a default shipping address; about half also get a
-- default billing address and 1 in 5 a second shipping address.

INSERT INTO addresses (user_id, type, address_line1, address_line2, city, state, postal_code, country, is_default, created_at)
SELECT
  a.user_id,
  a.type,
  (1 + floor(random() * 9999))::TEXT || ' ' || ref.streets[1 + floor(random() * 12)::INT],
  CASE WHEN random() < 0.3 THEN 'Apt ' || (1 + floor(random() * 500))::TEXT END,
  CASE WHEN a.r < 0.05 THEN 'London' ELSE ref.cities[a.ci] END,
  CASE WHEN a.r < 0.05 THEN NULL     ELSE ref.states[a.ci] END,
  CASE WHEN a.r < 0.05 THEN 'SW1A ' || (1 + floor(random() * 9))::TEXT || 'AA'
       ELSE lpad((501 + floor(random() * 99000))::TEXT, 5, '0') END,
  CASE WHEN a.r < 0.05 THEN 'United Kingdom' ELSE 'United States' END,
  a.is_default,
  a.created_at
FROM (
  SELECT x.*, random() AS r, 1 + floor(random() * 18)::INT AS ci
  FROM (
    SELECT id AS user_id, 'shipping' AS type, true  AS is_default, created_at FROM users
    UNION ALL
    SELECT id, 'billing',  true,  created_at FROM users WHERE random() < 0.5
    UNION ALL
    SELECT id, 'shipping', false, created_at + random() * (NOW() - created_at) FROM users WHERE random() < 0.2
  ) x
) a
CROSS JOIN (SELECT
  ARRAY['Main St','Oak Ave','Elm Rd','Park Blvd','Cedar Ln','Maple Dr',
        'Pine St','Lake Rd','Hill Ave','River Rd','Sunset Blvd','Broadway'] AS streets,
  ARRAY['New York','Los Angeles','Chicago','Houston','Phoenix','Philadelphia','San Antonio','San Diego',
        'Dallas','San Jose','Austin','Jacksonville','Columbus','Charlotte','Indianapolis','Denver',
        'Seattle','Atlanta'] AS cities,
  ARRAY['NY','CA','IL','TX','AZ','PA','TX','CA','TX','CA','TX','FL','OH','NC','IN','CO','WA','GA'] AS states
) ref;


-- ── 4. payment_methods ───────────────────────────────────────
-- 85% of users have a default card; 25% also have PayPal (default
-- only when they have no card).

INSERT INTO payment_methods (user_id, billing_address_id, method_type, provider, provider_token,
                             last4, exp_month, exp_year, is_default, created_at)
SELECT
  u.id,
  COALESCE(b.id, s.id),
  'card',
  (ARRAY['Visa','Mastercard','Amex','Discover'])[1 + floor(random() * 4)::INT],
  'tok_card_' || md5(u.id::TEXT || '-card-' || random()::TEXT),
  lpad(floor(random() * 10000)::INT::TEXT, 4, '0'),
  1 + floor(random() * 12)::INT,
  2026 + floor(random() * 6)::INT,
  true,
  u.created_at + random() * (NOW() - u.created_at)
FROM users u
LEFT JOIN addresses b ON b.user_id = u.id AND b.type = 'billing'  AND b.is_default
LEFT JOIN addresses s ON s.user_id = u.id AND s.type = 'shipping' AND s.is_default
WHERE random() < 0.85;

INSERT INTO payment_methods (user_id, method_type, provider, provider_token, is_default, created_at)
SELECT
  u.id,
  'paypal',
  'PayPal',
  'tok_pp_' || md5(u.id::TEXT || '-paypal-' || random()::TEXT),
  NOT EXISTS (SELECT 1 FROM payment_methods pm WHERE pm.user_id = u.id),
  u.created_at + random() * (NOW() - u.created_at)
FROM users u
WHERE random() < 0.25;


-- ── 5. products (leaf categories only) ───────────────────────
-- Prices are skewed: most products are cheap, a few are expensive.

WITH leaf AS (
  SELECT c.id, c.name, row_number() OVER (ORDER BY c.id) AS rn
  FROM categories c
  WHERE NOT EXISTS (SELECT 1 FROM categories ch WHERE ch.parent_id = c.id)
),
g AS (
  SELECT
    s,
    1 + floor(random() * (SELECT count(*) FROM leaf))::INT AS rn,
    (ARRAY['Premium','Ultra','Pro','Smart','Eco','Classic','Deluxe','Slim',
           'Turbo','Elite','Urban','Compact'])[1 + floor(random() * 12)::INT] AS adj,
    (ARRAY['X','Plus','Max','Lite','Air','Mini','Neo','One'])[1 + floor(random() * 8)::INT] AS line,
    power(random(), 4)                       AS price_r,
    NOW() - random() * INTERVAL '1000 days'  AS created_at
  FROM generate_series(1, :products) AS s
)
INSERT INTO products (category_id, name, slug, description, base_price, is_active, created_at, updated_at)
SELECT
  leaf.id,
  g.adj || ' ' || leaf.name || ' ' || g.line || ' ' || g.s,
  lower(regexp_replace(g.adj || '-' || leaf.name || '-' || g.line || '-' || g.s, '[^a-zA-Z0-9]+', '-', 'g')),
  CASE WHEN random() < 0.1 THEN NULL
       ELSE 'High quality ' || lower(leaf.name) || ' from the ' || g.adj || ' ' || g.line || ' range.' END,
  ROUND((4.99 + g.price_r * 995)::NUMERIC, 2),
  random() > 0.05,
  g.created_at,
  g.created_at + random() * (NOW() - g.created_at)
FROM g
JOIN leaf ON leaf.rn = g.rn;


-- ── 6. product_variants ──────────────────────────────────────
-- Size/colour come from the variant number, so combinations are
-- distinct within a product. Variant 1 is always the base price.

INSERT INTO product_variants (product_id, sku, size, color, price_modifier, is_active, created_at)
SELECT
  p.id,
  'SKU-' || lpad(p.id::TEXT, 6, '0') || '-' || v,
  CASE WHEN random() < 0.03 THEN NULL
       ELSE (ARRAY['XS','S','M','L','XL','XXL','One Size'])[1 + (p.id + v * 3) % 7] END,
  CASE WHEN random() < 0.03 THEN NULL
       ELSE (ARRAY['Black','White','Red','Blue','Green','Yellow','Grey',
                   'Navy','Pink','Purple','Orange','Brown'])[1 + (p.id * 7 + v) % 12] END,
  CASE WHEN v = 1 THEN 0.00
       ELSE GREATEST(-p.base_price, ROUND((random() * 40 - 10)::NUMERIC, 2)) END,
  random() > 0.08,
  p.created_at
FROM products p
CROSS JOIN generate_series(1, :variants_per_product) AS v;


-- ── 7. inventory (1:1 with variants) ─────────────────────────

INSERT INTO inventory (variant_id, quantity_in_stock, quantity_reserved, low_stock_threshold, updated_at)
SELECT
  id,
  stock,
  LEAST(stock, floor(random() * 10)::INT),
  5 + floor(random() * 16)::INT,
  NOW() - random() * INTERVAL '30 days'
FROM (
  SELECT id, CASE WHEN random() < 0.05 THEN 0 ELSE floor(random() * 200)::INT END AS stock
  FROM product_variants
) v;


-- ── 8. promotions (25) ───────────────────────────────────────
-- Windows are relative to NOW() so orders spread over the last two
-- years always have some promotions that were live at the time.

INSERT INTO promotions (code, description, discount_type, discount_value, min_order_amount,
                        max_uses, starts_at, expires_at, is_active, created_at)
SELECT code, description, discount_type, discount_value, min_order_amount, max_uses,
       NOW() - starts_ago, NOW() - expires_ago, is_active, NOW() - starts_ago - INTERVAL '7 days'
FROM (VALUES
  ('SAVE10',      '10% off all orders',         'percentage', 10.00,   0.00, NULL, INTERVAL '60 days',  INTERVAL '-30 days',  true),
  ('SAVE20',      '20% off orders over $50',    'percentage', 20.00,  50.00, 2000, INTERVAL '30 days',  INTERVAL '-60 days',  true),
  ('FLAT5',       '$5 off any order',           'fixed',       5.00,   0.00, NULL, INTERVAL '90 days',  INTERVAL '-90 days',  true),
  ('FLAT15',      '$15 off orders over $100',   'fixed',      15.00, 100.00, 300,  INTERVAL '10 days',  INTERVAL '-20 days',  true),
  ('WELCOME',     'Welcome discount 15%',       'percentage', 15.00,   0.00, NULL, INTERVAL '180 days', INTERVAL '-180 days', true),
  ('SUMMER25',    'Summer sale 25% off',        'percentage', 25.00,  75.00, 800,  INTERVAL '45 days',  INTERVAL '-15 days',  true),
  ('FLASH30',     '30% flash sale',             'percentage', 30.00,  20.00, 25,   INTERVAL '6 days',   INTERVAL '-3 days',   true),
  ('BULK50',      '$50 off orders over $300',   'fixed',      50.00, 300.00, 200,  INTERVAL '20 days',  INTERVAL '-40 days',  true),
  ('NEWUSER',     'New user 12% discount',      'percentage', 12.00,   0.00, NULL, INTERVAL '365 days', INTERVAL '-365 days', true),
  ('WEEKEND',     'Weekend special 8% off',     'percentage',  8.00,   0.00, 500,  INTERVAL '3 days',   INTERVAL '-4 days',   true),
  ('VIP20',       'VIP member 20% off',         'percentage', 20.00, 150.00, 250,  INTERVAL '15 days',  INTERVAL '-75 days',  true),
  ('HOLIDAY',     'Holiday season discount',    'percentage', 18.00,  50.00, 1000, INTERVAL '5 days',   INTERVAL '-25 days',  true),
  ('FREESHIP',    '$10 off for free shipping',  'fixed',      10.00,  30.00, NULL, INTERVAL '60 days',  INTERVAL '-60 days',  true),
  ('REFER10',     'Referral 10% bonus',         'percentage', 10.00,   0.00, NULL, INTERVAL '120 days', NULL,                 true),
  ('APP15',       'App-only 15% discount',      'percentage', 15.00,  25.00, 600,  INTERVAL '30 days',  INTERVAL '-30 days',  true),
  ('EXPIRED5',    'Expired promo',              'fixed',       5.00,   0.00, 100,  INTERVAL '60 days',  INTERVAL '10 days',   false),
  ('OLDCODE',     'Old seasonal code',          'percentage', 20.00,   0.00, 200,  INTERVAL '90 days',  INTERVAL '30 days',   false),
  ('LAUNCH',      'Launch event discount',      'percentage', 22.00, 100.00, 500,  INTERVAL '200 days', INTERVAL '170 days',  false),
  ('EARLYBIRD',   'Early bird 5% off',          'percentage',  5.00,   0.00, 1000, INTERVAL '300 days', INTERVAL '270 days',  false),
  ('BLACKFRI-Y1', 'Black Friday last year',     'percentage', 30.00,  50.00, NULL, INTERVAL '340 days', INTERVAL '335 days',  false),
  ('CYBERMON-Y1', 'Cyber Monday last year',     'percentage', 25.00,  40.00, NULL, INTERVAL '334 days', INTERVAL '332 days',  false),
  ('XMAS-Y1',     'Christmas last year',        'fixed',      20.00, 120.00, NULL, INTERVAL '320 days', INTERVAL '300 days',  false),
  ('BLACKFRI-Y2', 'Black Friday two years ago', 'percentage', 30.00,  50.00, NULL, INTERVAL '705 days', INTERVAL '700 days',  false),
  ('SPRING-Y2',   'Spring sale two years ago',  'percentage', 15.00,   0.00, NULL, INTERVAL '600 days', INTERVAL '540 days',  false),
  ('BTS-Y2',      'Back to school',             'fixed',      10.00,  60.00, NULL, INTERVAL '450 days', INTERVAL '420 days',  false)
) AS v(code, description, discount_type, discount_value, min_order_amount, max_uses, starts_ago, expires_ago, is_active);


-- ── 9. carts (about half of users) ───────────────────────────

INSERT INTO carts (user_id, created_at, updated_at)
SELECT id, c, c + random() * (NOW() - c)
FROM (
  SELECT id, NOW() - random() * INTERVAL '60 days' AS c
  FROM users
  WHERE random() < 0.5
) x;


-- ── Shared pool of orderable variants ────────────────────────
-- The LATERAL subqueries below reference the outer row (n_items),
-- which forces Postgres to re-run them per row. An uncorrelated
-- LATERAL ... ORDER BY random() LIMIT 3 is evaluated once, giving
-- every cart/order the same 3 variants.
-- power(random(), 2) skews picks toward lower ids, so some products
-- sell far more than others, as in a real shop.

CREATE TEMP TABLE variant_pool ON COMMIT DROP AS
SELECT array_agg(pv.id ORDER BY pv.id) AS ids, count(*)::INT AS n
FROM product_variants pv
JOIN products p ON p.id = pv.product_id
WHERE pv.is_active AND p.is_active;


-- ── 10. cart_items (0-4 per cart; empty carts are an edge case) ──

INSERT INTO cart_items (cart_id, variant_id, quantity, added_at)
SELECT DISTINCT ON (c.id, li.variant_id)
  c.id, li.variant_id, 1 + floor(random() * 3)::INT,
  c.created_at + random() * (c.updated_at - c.created_at)
FROM (SELECT id, created_at, updated_at, floor(random() * 5)::INT AS n_items FROM carts) c
CROSS JOIN variant_pool vp
CROSS JOIN LATERAL (
  SELECT vp.ids[1 + floor(power(random(), 2) * vp.n)::INT] AS variant_id
  FROM generate_series(1, c.n_items)
) li;


-- ── 11. wishlist_items (30% of users, 1-6 items) ─────────────

INSERT INTO wishlist_items (user_id, variant_id, added_at)
SELECT DISTINCT ON (u.id, li.variant_id)
  u.id, li.variant_id, u.created_at + random() * (NOW() - u.created_at)
FROM (SELECT id, created_at, 1 + floor(random() * 6)::INT AS n_items FROM users WHERE random() < 0.3) u
CROSS JOIN variant_pool vp
CROSS JOIN LATERAL (
  SELECT vp.ids[1 + floor(random() * vp.n)::INT] AS variant_id
  FROM generate_series(1, u.n_items)
) li;


-- ── 12. orders ───────────────────────────────────────────────
-- Status depends on order age, so it matches the status history
-- below (an order placed today cannot be delivered yet).
-- Money columns start at 0 and are filled in step 14, once the
-- line items exist.

WITH buyers AS (
  SELECT array_agg(u.id ORDER BY u.id) AS ids, count(*)::INT AS n
  FROM users u
  WHERE EXISTS (SELECT 1 FROM addresses a
                WHERE a.user_id = u.id AND a.type = 'shipping' AND a.is_default)
),
picked AS (
  SELECT b.ids[1 + floor(power(random(), 1.5) * b.n)::INT] AS user_id,
         random() AS r_age, random() AS r_status, random() AS r_promo
  FROM generate_series(1, :orders)
  CROSS JOIN buyers b
),
placed AS (
  SELECT p.user_id, a.id AS address_id, pm.id AS payment_method_id, p.r_status, p.r_promo,
         u.created_at + p.r_age * (NOW() - u.created_at) AS created_at
  FROM picked p
  JOIN users u ON u.id = p.user_id
  JOIN addresses a ON a.user_id = p.user_id AND a.type = 'shipping' AND a.is_default
  LEFT JOIN payment_methods pm ON pm.user_id = p.user_id AND pm.is_default
)
INSERT INTO orders (user_id, address_id, payment_method_id, promotion_id, status, notes, created_at, updated_at)
SELECT
  pl.user_id,
  pl.address_id,
  pl.payment_method_id,
  -- Candidate promotion that was live when the order was placed. It is
  -- correlated on pl.created_at, so it is re-evaluated per order.
  CASE WHEN pl.r_promo < 0.25 THEN (
    SELECT pr.id FROM promotions pr
    WHERE pr.starts_at <= pl.created_at
      AND (pr.expires_at IS NULL OR pr.expires_at > pl.created_at)
    ORDER BY random()
    LIMIT 1
  ) END,
  CASE
    WHEN NOW() - pl.created_at < INTERVAL '1 day'  THEN CASE WHEN pl.r_status < 0.05 THEN 'cancelled' ELSE 'pending'   END
    WHEN NOW() - pl.created_at < INTERVAL '3 days' THEN CASE WHEN pl.r_status < 0.05 THEN 'cancelled' ELSE 'confirmed' END
    WHEN NOW() - pl.created_at < INTERVAL '10 days' THEN CASE WHEN pl.r_status < 0.05 THEN 'cancelled' ELSE 'shipped' END
    WHEN pl.r_status < 0.08 THEN 'cancelled'
    WHEN pl.r_status < 0.15 AND NOW() - pl.created_at > INTERVAL '30 days' THEN 'refunded'
    ELSE 'delivered'
  END,
  CASE WHEN random() < 0.05
       THEN (ARRAY['Leave at the front door','Gift - please remove price tags',
                   'Call before delivery','Deliver after 5pm'])[1 + floor(random() * 4)::INT] END,
  pl.created_at,
  pl.created_at
FROM placed pl
ORDER BY pl.created_at;   -- ids follow time, as they would in production


-- ── 13. order_items (1-5 lines per order) ────────────────────
-- unit_price snapshots the current variant price; total_price is
-- computed from the same quantity, so total = quantity x unit_price.

INSERT INTO order_items (order_id, variant_id, quantity, unit_price, total_price)
SELECT DISTINCT ON (o.id, li.variant_id)
  o.id,
  li.variant_id,
  li.qty,
  p.base_price + pv.price_modifier,
  li.qty * (p.base_price + pv.price_modifier)
FROM (SELECT id, 1 + floor(random() * 5)::INT AS n_items FROM orders) o
CROSS JOIN variant_pool vp
CROSS JOIN LATERAL (
  SELECT vp.ids[1 + floor(power(random(), 2) * vp.n)::INT] AS variant_id,
         CASE WHEN random() < 0.7 THEN 1 ELSE 2 + floor(random() * 3)::INT END AS qty
  FROM generate_series(1, o.n_items)
) li
JOIN product_variants pv ON pv.id = li.variant_id
JOIN products p         ON p.id  = pv.product_id;


-- ── 14. order_status_history ─────────────────────────────────
-- Each final status has a fixed path. Step time windows do not
-- overlap, so changed_at always increases along the path.

INSERT INTO order_status_history (order_id, from_status, to_status, changed_at)
SELECT
  o.id,
  path.from_status,
  path.to_status,
  LEAST(NOW(), o.created_at + (path.min_hours + random() * path.span_hours) * INTERVAL '1 hour')
FROM orders o
JOIN (VALUES
  ('pending',   1, NULL::VARCHAR, 'pending',     0,   0),
  ('confirmed', 1, NULL,          'pending',     0,   0),
  ('confirmed', 2, 'pending',     'confirmed',   1,  23),
  ('shipped',   1, NULL,          'pending',     0,   0),
  ('shipped',   2, 'pending',     'confirmed',   1,  23),
  ('shipped',   3, 'confirmed',   'shipped',    24,  48),
  ('delivered', 1, NULL,          'pending',     0,   0),
  ('delivered', 2, 'pending',     'confirmed',   1,  23),
  ('delivered', 3, 'confirmed',   'shipped',    24,  48),
  ('delivered', 4, 'shipped',     'delivered',  72, 168),
  ('refunded',  1, NULL,          'pending',     0,   0),
  ('refunded',  2, 'pending',     'confirmed',   1,  23),
  ('refunded',  3, 'confirmed',   'shipped',    24,  48),
  ('refunded',  4, 'shipped',     'delivered',  72, 168),
  ('refunded',  5, 'delivered',   'refunded',  288, 432),
  ('cancelled', 1, NULL,          'pending',     0,   0),
  ('cancelled', 2, 'pending',     'cancelled',   0,  24)
) AS path(final_status, step, from_status, to_status, min_hours, span_hours)
  ON path.final_status = o.status
ORDER BY o.id, path.step;


-- ── 15. order totals, promotion eligibility, updated_at ──────
-- A candidate promotion is kept only if the subtotal meets
-- min_order_amount and the code still had uses left (first come,
-- first served by created_at). Tax is 8% of the discounted subtotal.

WITH sub AS (
  SELECT order_id, SUM(total_price) AS subtotal
  FROM order_items
  GROUP BY order_id
),
eligible AS (
  SELECT o.id, pr.id AS promotion_id, pr.max_uses,
         row_number() OVER (PARTITION BY pr.id ORDER BY o.created_at, o.id) AS use_no
  FROM orders o
  JOIN sub s        ON s.order_id = o.id
  JOIN promotions pr ON pr.id = o.promotion_id
  WHERE s.subtotal >= pr.min_order_amount
),
priced AS (
  SELECT
    s.order_id,
    s.subtotal,
    pr.id AS promotion_id,
    COALESCE(CASE pr.discount_type
               WHEN 'percentage' THEN ROUND(s.subtotal * pr.discount_value / 100, 2)
               WHEN 'fixed'      THEN LEAST(pr.discount_value, s.subtotal)
             END, 0) AS discount
  FROM sub s
  LEFT JOIN eligible e   ON e.id = s.order_id AND (e.max_uses IS NULL OR e.use_no <= e.max_uses)
  LEFT JOIN promotions pr ON pr.id = e.promotion_id
),
last_change AS (
  SELECT order_id, MAX(changed_at) AS changed_at
  FROM order_status_history
  GROUP BY order_id
)
UPDATE orders o
SET promotion_id    = p.promotion_id,
    subtotal        = p.subtotal,
    discount_amount = p.discount,
    tax_amount      = ROUND((p.subtotal - p.discount) * 0.08, 2),
    total_amount    = p.subtotal - p.discount + ROUND((p.subtotal - p.discount) * 0.08, 2),
    updated_at      = lc.changed_at
FROM priced p
JOIN last_change lc ON lc.order_id = p.order_id
WHERE o.id = p.order_id;

UPDATE promotions pr
SET used_count = u.n
FROM (SELECT promotion_id, count(*) AS n
      FROM orders WHERE promotion_id IS NOT NULL
      GROUP BY promotion_id) u
WHERE u.promotion_id = pr.id;


-- ── 16. reviews ──────────────────────────────────────────────
-- 80% come from real purchases (is_verified = true, written after
-- the order); the rest are unverified. Verified ratings skew positive.

INSERT INTO reviews (user_id, product_id, rating, title, body, is_verified, created_at)
SELECT
  b.user_id,
  b.product_id,
  b.rating,
  CASE WHEN random() < 0.05 THEN NULL
       WHEN b.rating >= 4 THEN (ARRAY['Great product!','Highly recommend','Exceeded expectations','Would buy again','Perfect gift'])[1 + floor(random() * 5)::INT]
       WHEN b.rating = 3  THEN (ARRAY['Average quality','Does the job','Could be better'])[1 + floor(random() * 3)::INT]
       ELSE                    (ARRAY['Disappointed','Not worth the price','Broke quickly'])[1 + floor(random() * 3)::INT]
  END,
  CASE WHEN random() < 0.1 THEN NULL
       WHEN b.rating >= 4 THEN (ARRAY['Really happy with this purchase. Quality is top notch.',
                                      'Works perfectly, exactly what I needed.',
                                      'Would definitely recommend to friends and family.'])[1 + floor(random() * 3)::INT]
       WHEN b.rating = 3  THEN (ARRAY['Average product, nothing special.',
                                      'Good product but slightly overpriced for what it is.'])[1 + floor(random() * 2)::INT]
       ELSE                    (ARRAY['Not as good as the photos suggest.',
                                      'Stopped working after two weeks.'])[1 + floor(random() * 2)::INT]
  END,
  true,
  LEAST(NOW(), b.bought_at + (3 + random() * 27) * INTERVAL '1 day')
FROM (
  -- Weighted pick: 45% 5-star, 30% 4, 10% 3, 10% 2, 5% 1. It is done
  -- out here because a random() column next to ORDER BY random() is
  -- matched as the same expression, so LIMIT would keep only low values.
  SELECT x.*,
         (ARRAY[5,5,5,5,5,5,5,5,5,4,4,4,4,4,4,3,3,2,2,1])[1 + floor(random() * 20)::INT] AS rating
  FROM (
    SELECT o.user_id, pv.product_id, MAX(o.created_at) AS bought_at
    FROM orders o
    JOIN order_items oi      ON oi.order_id = o.id
    JOIN product_variants pv ON pv.id = oi.variant_id
    WHERE o.status IN ('delivered', 'refunded')
    GROUP BY o.user_id, pv.product_id
    ORDER BY random()
    LIMIT (:reviews * 8 / 10)
  ) x
) b;

INSERT INTO reviews (user_id, product_id, rating, title, body, is_verified, created_at)
SELECT u.id, r.product_id, r.rating,
       CASE WHEN r.rating >= 4 THEN 'Looks great' WHEN r.rating = 3 THEN 'It is okay' ELSE 'Not for me' END,
       NULL,
       false,
       u.created_at + random() * (NOW() - u.created_at)
FROM (
  SELECT 1 + floor(random() * (SELECT max(id) FROM users))::INT    AS user_id,
         1 + floor(random() * (SELECT max(id) FROM products))::INT AS product_id,
         1 + floor(random() * 5)::INT                               AS rating
  FROM generate_series(1, :reviews - (SELECT count(*) FROM reviews)::INT)
) r
JOIN users u ON u.id = r.user_id
ON CONFLICT (user_id, product_id) DO NOTHING;


-- ── 17. Edge cases ───────────────────────────────────────────

-- Inactive, empty root category.
INSERT INTO categories (name, slug, description, is_active)
VALUES ('Seasonal', 'seasonal', NULL, false);

-- Max-length email (255 chars) and names (100 chars), no phone,
-- inactive, and no addresses / orders / cart at all.
INSERT INTO users (email, password_hash, first_name, last_name, phone, is_active)
VALUES (repeat('a', 242) || '@shopflow.com', '$2b$10$edgecase', repeat('F', 100), repeat('L', 100), NULL, false);

-- Shortest names and empty strings ('' is not NULL) in optional
-- columns: phone, address_line2, state, review title and body. Has
-- an address, an empty cart and a rating-only review, but no orders.
WITH u AS (
  INSERT INTO users (email, password_hash, first_name, last_name, phone)
  VALUES ('a@b.co', '$2b$10$edgecase', 'A', 'B', '')
  RETURNING id
), addr AS (
  INSERT INTO addresses (user_id, type, address_line1, address_line2, city, state, postal_code, country, is_default)
  SELECT id, 'shipping', '1 Edge St', '', 'Colombo', '', '00100', 'Sri Lanka', true FROM u
), review AS (
  INSERT INTO reviews (user_id, product_id, rating, title, body, is_verified)
  SELECT u.id, (SELECT min(id) FROM products), 3, '', '', false FROM u
)
INSERT INTO carts (user_id) SELECT id FROM u;

-- 255-char product name, NULL description, free (0.00), one
-- variant with NULL size/colour and zero stock.
WITH p AS (
  INSERT INTO products (category_id, name, slug, description, base_price)
  SELECT id, 'Free Sample ' || repeat('X', 243), 'edge-free-sample', NULL, 0.00
  FROM categories WHERE slug = 'skincare'
  RETURNING id
), v AS (
  INSERT INTO product_variants (product_id, sku, size, color, price_modifier)
  SELECT id, 'SKU-EDGE-FREE', NULL, NULL, 0.00 FROM p
  RETURNING id
)
INSERT INTO inventory (variant_id, quantity_in_stock, quantity_reserved, low_stock_threshold)
SELECT id, 0, 0, 0 FROM v;

-- Max DECIMAL(10,2) price, empty-string description; all stock
-- reserved (available = 0). Inactive so it never lands in an order.
WITH p AS (
  INSERT INTO products (category_id, name, slug, description, base_price, is_active)
  SELECT id, 'Gold Plated Gaming Laptop', 'edge-max-price', '', 99999999.99, false
  FROM categories WHERE slug = 'gaming-laptops'
  RETURNING id
), v AS (
  INSERT INTO product_variants (product_id, sku, size, color)
  SELECT id, 'SKU-EDGE-MAX', 'One Size', 'Gold' FROM p
  RETURNING id
)
INSERT INTO inventory (variant_id, quantity_in_stock, quantity_reserved)
SELECT id, 1, 1 FROM v;

-- Promotion that starts next week: never used (shows up via RIGHT JOIN in Q9).
INSERT INTO promotions (code, description, discount_type, discount_value, max_uses, starts_at, expires_at)
VALUES ('COMINGSOON', 'Starts next week', 'percentage', 100.00, 1,
        NOW() + INTERVAL '7 days', NOW() + INTERVAL '14 days');


ALTER TABLE orders ENABLE TRIGGER USER;

COMMIT;

ANALYZE;


-- ── Summary ──────────────────────────────────────────────────

WITH counts AS (
            SELECT 1 AS ord, 'categories' AS table_name, count(*) AS row_count FROM categories
  UNION ALL SELECT 2,  'users',                count(*) FROM users
  UNION ALL SELECT 3,  'addresses',            count(*) FROM addresses
  UNION ALL SELECT 4,  'payment_methods',      count(*) FROM payment_methods
  UNION ALL SELECT 5,  'products',             count(*) FROM products
  UNION ALL SELECT 6,  'product_variants',     count(*) FROM product_variants
  UNION ALL SELECT 7,  'inventory',            count(*) FROM inventory
  UNION ALL SELECT 8,  'promotions',           count(*) FROM promotions
  UNION ALL SELECT 9,  'carts',                count(*) FROM carts
  UNION ALL SELECT 10, 'cart_items',           count(*) FROM cart_items
  UNION ALL SELECT 11, 'wishlist_items',       count(*) FROM wishlist_items
  UNION ALL SELECT 12, 'orders',               count(*) FROM orders
  UNION ALL SELECT 13, 'order_items',          count(*) FROM order_items
  UNION ALL SELECT 14, 'order_status_history', count(*) FROM order_status_history
  UNION ALL SELECT 15, 'reviews',              count(*) FROM reviews
)
SELECT table_name, row_count FROM (
  SELECT ord, table_name, row_count FROM counts
  UNION ALL
  SELECT 99, 'TOTAL', sum(row_count) FROM counts
) t
ORDER BY ord;
