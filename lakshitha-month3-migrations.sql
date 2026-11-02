-- ============================================================
-- ShopFlow E-Commerce Platform - Migration Scripts
-- Dialect: PostgreSQL (tested on 18.x)
--
-- Versions (each runs in its own transaction, so a failed
-- version leaves no half-applied DDL behind):
--   [V000] schema_migrations  - version tracking table
--   [V001] core schema        - 15 tables, PK / FK / UNIQUE / CHECK / defaults
--   [V002] indexes            - FK + query-pattern indexes (see optimization report)
--   [V003] triggers           - updated_at maintenance + order status history
--   [V004] index pruning      - drop V002 indexes no measured plan used
--
-- V001 creates no secondary indexes on purpose: only the indexes
-- that back PRIMARY KEY / UNIQUE constraints exist after it. That
-- state is the "before" baseline in the optimization report, and
-- V002 is the "after".
--
-- Run on an empty database:
--   psql -d shopflow -v ON_ERROR_STOP=1 -f lakshitha-month3-migrations.sql
--
-- Rollback: lakshitha-month3-rollback.sql has one matching
-- section per version (newest first). It skips versions that are not
-- applied, so it is safe to run more than once.
--
-- Design notes (full reasoning: lakshitha-month3-design-decisions.md)
--   Normalization (3NF / BCNF):
--     - Every column is atomic; repeating data has its own table
--       (addresses, payment_methods, cart/order lines, status history).
--     - Each non-key column depends only on its table's key: category
--       names live in categories, variant attributes in
--       product_variants, stock in inventory; orders reference
--       addresses.id instead of copying address fields.
--     - The only other determinants are UNIQUE candidate keys
--       (users.email, products.slug, product_variants.sku,
--       promotions.code, payment_methods.provider_token).
--   Relationships:
--     1:1   product_variants - inventory, users - carts (UNIQUE FK)
--     1:N   users -> addresses / payment_methods / orders / reviews,
--           products -> product_variants, orders -> order_items /
--           order_status_history, categories -> products
--     1:N recursive   categories.parent_id -> categories.id
--     M:N   users <-> product_variants via cart_items and wishlist_items,
--           orders <-> product_variants via order_items,
--           users <-> products via reviews (one review per pair)
--   Constraints enforce business rules in the database: money and
--   quantity ranges, total = subtotal - discount + tax, line total =
--   quantity x unit_price, reserved <= in stock, promotion windows and
--   usage caps, one default address / payment method per user.
--   Deliberate denormalization: order_items.unit_price (price at
--   purchase time), order money totals (CHECK-guarded), and
--   promotions.used_count (cheap validity check at checkout).
--   Delete rules: RESTRICT protects orders (financial records);
--   CASCADE removes rows that are meaningless without their parent;
--   SET NULL keeps products/orders when a category or promo goes.
-- ============================================================


-- [V000] schema_migrations ===================================

BEGIN;

CREATE TABLE schema_migrations (
  version     VARCHAR(10)  PRIMARY KEY,
  description VARCHAR(255) NOT NULL,
  applied_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO schema_migrations (version, description)
VALUES ('V000', 'schema_migrations version tracking');

COMMIT;


-- [V001] core schema =========================================

BEGIN;

-- ── 1. categories (self-referencing hierarchy) ───────────────

CREATE TABLE categories (
  id          SERIAL PRIMARY KEY,
  parent_id   INTEGER REFERENCES categories(id) ON DELETE SET NULL,
  name        VARCHAR(100) NOT NULL,
  slug        VARCHAR(100) NOT NULL UNIQUE,
  description TEXT,
  is_active   BOOLEAN NOT NULL DEFAULT true,
  created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (parent_id IS NULL OR parent_id <> id)
);


-- ── 2. users ─────────────────────────────────────────────────

CREATE TABLE users (
  id            SERIAL PRIMARY KEY,
  email         VARCHAR(255) NOT NULL UNIQUE,
  password_hash VARCHAR(255) NOT NULL,
  first_name    VARCHAR(100) NOT NULL,
  last_name     VARCHAR(100) NOT NULL,
  phone         VARCHAR(20),
  is_active     BOOLEAN NOT NULL DEFAULT true,
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (email LIKE '%_@_%')
);


-- ── 3. addresses ─────────────────────────────────────────────

CREATE TABLE addresses (
  id            SERIAL PRIMARY KEY,
  user_id       INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type          VARCHAR(20) NOT NULL CHECK (type IN ('shipping', 'billing')),
  address_line1 VARCHAR(255) NOT NULL,
  address_line2 VARCHAR(255),
  city          VARCHAR(100) NOT NULL,
  state         VARCHAR(100),
  postal_code   VARCHAR(20) NOT NULL,
  country       VARCHAR(100) NOT NULL,
  is_default    BOOLEAN NOT NULL DEFAULT false,
  created_at    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- At most one default address per user and address type.
CREATE UNIQUE INDEX uq_addresses_one_default
  ON addresses(user_id, type) WHERE is_default;


-- ── 4. payment_methods ───────────────────────────────────────
-- Stores a payment-provider token only, never a card number.

CREATE TABLE payment_methods (
  id                 SERIAL PRIMARY KEY,
  user_id            INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  billing_address_id INTEGER REFERENCES addresses(id) ON DELETE SET NULL,
  method_type        VARCHAR(20) NOT NULL CHECK (method_type IN ('card', 'paypal', 'bank_transfer')),
  provider           VARCHAR(50) NOT NULL,
  provider_token     VARCHAR(255) NOT NULL UNIQUE,
  last4              CHAR(4) CHECK (last4 ~ '^[0-9]{4}$'),
  exp_month          SMALLINT CHECK (exp_month BETWEEN 1 AND 12),
  exp_year           SMALLINT CHECK (exp_year BETWEEN 2000 AND 2100),
  is_default         BOOLEAN NOT NULL DEFAULT false,
  created_at         TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (method_type <> 'card'
         OR (last4 IS NOT NULL AND exp_month IS NOT NULL AND exp_year IS NOT NULL))
);

CREATE UNIQUE INDEX uq_payment_methods_one_default
  ON payment_methods(user_id) WHERE is_default;


-- ── 5. products ──────────────────────────────────────────────

CREATE TABLE products (
  id          SERIAL PRIMARY KEY,
  category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
  name        VARCHAR(255) NOT NULL,
  slug        VARCHAR(255) NOT NULL UNIQUE,
  description TEXT,
  base_price  DECIMAL(10,2) NOT NULL CHECK (base_price >= 0),
  is_active   BOOLEAN NOT NULL DEFAULT true,
  created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- ── 6. product_variants ──────────────────────────────────────

CREATE TABLE product_variants (
  id             SERIAL PRIMARY KEY,
  product_id     INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  sku            VARCHAR(100) NOT NULL UNIQUE,
  size           VARCHAR(50),
  color          VARCHAR(50),
  price_modifier DECIMAL(10,2) NOT NULL DEFAULT 0.00,
  is_active      BOOLEAN NOT NULL DEFAULT true,
  created_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- ── 7. inventory (1:1 with product_variants) ─────────────────

CREATE TABLE inventory (
  id                  SERIAL PRIMARY KEY,
  variant_id          INTEGER NOT NULL UNIQUE REFERENCES product_variants(id) ON DELETE CASCADE,
  quantity_in_stock   INTEGER NOT NULL DEFAULT 0 CHECK (quantity_in_stock >= 0),
  quantity_reserved   INTEGER NOT NULL DEFAULT 0 CHECK (quantity_reserved >= 0),
  low_stock_threshold INTEGER NOT NULL DEFAULT 10 CHECK (low_stock_threshold >= 0),
  updated_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (quantity_reserved <= quantity_in_stock)
);


-- ── 8. promotions ────────────────────────────────────────────

CREATE TABLE promotions (
  id               SERIAL PRIMARY KEY,
  code             VARCHAR(50) NOT NULL UNIQUE,
  description      TEXT,
  discount_type    VARCHAR(20) NOT NULL CHECK (discount_type IN ('percentage', 'fixed')),
  discount_value   DECIMAL(10,2) NOT NULL CHECK (discount_value > 0),
  min_order_amount DECIMAL(10,2) NOT NULL DEFAULT 0.00 CHECK (min_order_amount >= 0),
  max_uses         INTEGER CHECK (max_uses > 0),
  used_count       INTEGER NOT NULL DEFAULT 0 CHECK (used_count >= 0),
  starts_at        TIMESTAMP NOT NULL,
  expires_at       TIMESTAMP,
  is_active        BOOLEAN NOT NULL DEFAULT true,
  created_at       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (discount_type <> 'percentage' OR discount_value <= 100),
  CHECK (expires_at IS NULL OR expires_at > starts_at),
  CHECK (max_uses IS NULL OR used_count <= max_uses)
);


-- ── 9. carts (1:1 with users) ────────────────────────────────

CREATE TABLE carts (
  id         SERIAL PRIMARY KEY,
  user_id    INTEGER NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- ── 10. cart_items (carts M:N product_variants) ──────────────

CREATE TABLE cart_items (
  id         SERIAL PRIMARY KEY,
  cart_id    INTEGER NOT NULL REFERENCES carts(id) ON DELETE CASCADE,
  variant_id INTEGER NOT NULL REFERENCES product_variants(id) ON DELETE CASCADE,
  quantity   INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
  added_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (cart_id, variant_id)
);


-- ── 11. wishlist_items (users M:N product_variants) ──────────

CREATE TABLE wishlist_items (
  id         SERIAL PRIMARY KEY,
  user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  variant_id INTEGER NOT NULL REFERENCES product_variants(id) ON DELETE CASCADE,
  added_at   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (user_id, variant_id)
);


-- ── 12. orders ───────────────────────────────────────────────
-- Money columns are DECIMAL(12,2): an order total is a sum of
-- quantity x price, so it needs more headroom than a single price.

CREATE TABLE orders (
  id                SERIAL PRIMARY KEY,
  user_id           INTEGER NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  address_id        INTEGER NOT NULL REFERENCES addresses(id) ON DELETE RESTRICT,
  payment_method_id INTEGER REFERENCES payment_methods(id) ON DELETE SET NULL,
  promotion_id      INTEGER REFERENCES promotions(id) ON DELETE SET NULL,
  status            VARCHAR(30) NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'confirmed', 'shipped', 'delivered', 'cancelled', 'refunded')),
  subtotal          DECIMAL(12,2) NOT NULL DEFAULT 0.00 CHECK (subtotal >= 0),
  discount_amount   DECIMAL(12,2) NOT NULL DEFAULT 0.00 CHECK (discount_amount >= 0),
  tax_amount        DECIMAL(12,2) NOT NULL DEFAULT 0.00 CHECK (tax_amount >= 0),
  total_amount      DECIMAL(12,2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0),
  notes             TEXT,
  created_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (discount_amount <= subtotal),
  CHECK (total_amount = subtotal - discount_amount + tax_amount)
);


-- ── 13. order_items ──────────────────────────────────────────
-- unit_price is a snapshot of the price at purchase time, so later
-- price changes do not rewrite order history.

CREATE TABLE order_items (
  id          SERIAL PRIMARY KEY,
  order_id    INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  variant_id  INTEGER NOT NULL REFERENCES product_variants(id) ON DELETE RESTRICT,
  quantity    INTEGER NOT NULL CHECK (quantity > 0),
  unit_price  DECIMAL(10,2) NOT NULL CHECK (unit_price >= 0),
  total_price DECIMAL(12,2) NOT NULL CHECK (total_price >= 0),
  UNIQUE (order_id, variant_id),
  CHECK (total_price = quantity * unit_price)
);


-- ── 14. order_status_history ─────────────────────────────────

CREATE TABLE order_status_history (
  id          SERIAL PRIMARY KEY,
  order_id    INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  from_status VARCHAR(30)
                CHECK (from_status IN ('pending', 'confirmed', 'shipped', 'delivered', 'cancelled', 'refunded')),
  to_status   VARCHAR(30) NOT NULL
                CHECK (to_status IN ('pending', 'confirmed', 'shipped', 'delivered', 'cancelled', 'refunded')),
  changed_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  note        TEXT,
  CHECK (from_status IS DISTINCT FROM to_status)
);


-- ── 15. reviews ──────────────────────────────────────────────

CREATE TABLE reviews (
  id          SERIAL PRIMARY KEY,
  user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  product_id  INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  rating      SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  title       VARCHAR(255),
  body        TEXT,
  is_verified BOOLEAN NOT NULL DEFAULT false,
  created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (user_id, product_id)
);

INSERT INTO schema_migrations (version, description)
VALUES ('V001', 'core schema: 15 tables with keys and constraints');

COMMIT;


-- [V002] indexes =============================================
-- Columns already covered by a PK / UNIQUE index are not indexed
-- again (users.email, products.slug, carts.user_id, the leading
-- column of cart_items/order_items/reviews/wishlist_items UNIQUEs).

BEGIN;

-- FK support: speeds up joins, and the parent-side checks Postgres
-- runs on DELETE / UPDATE of the referenced row.
CREATE INDEX idx_categories_parent       ON categories(parent_id);
CREATE INDEX idx_addresses_user          ON addresses(user_id);
CREATE INDEX idx_payment_methods_user    ON payment_methods(user_id);
CREATE INDEX idx_products_category       ON products(category_id);
CREATE INDEX idx_variants_product        ON product_variants(product_id);
CREATE INDEX idx_cart_items_variant      ON cart_items(variant_id);
CREATE INDEX idx_wishlist_items_variant  ON wishlist_items(variant_id);
CREATE INDEX idx_orders_address          ON orders(address_id);
CREATE INDEX idx_orders_payment_method   ON orders(payment_method_id);
CREATE INDEX idx_reviews_product         ON reviews(product_id);

-- Query-pattern indexes (each one is measured in the optimization report).

-- Q2, Q8, Q11: one user's orders, newest first.
CREATE INDEX idx_orders_user_created     ON orders(user_id, created_at);

-- Q1: status = X AND created_at in a recent range.
CREATE INDEX idx_orders_status_created   ON orders(status, created_at);

-- Q6, Q10: date-range reports across all statuses.
CREATE INDEX idx_orders_created_at       ON orders(created_at);

-- Q9: only ~1 in 5 orders has a promotion, so a partial index stays small.
CREATE INDEX idx_orders_promotion        ON orders(promotion_id)
  WHERE promotion_id IS NOT NULL;

-- Q1: lets the join read quantity/unit_price straight from the index.
CREATE INDEX idx_order_items_variant     ON order_items(variant_id)
  INCLUDE (quantity, unit_price);

-- Q6: status history per order in time order.
CREATE INDEX idx_order_status_history_order
  ON order_status_history(order_id, changed_at);

-- Q3: the predicate matches the query exactly, so only low-stock rows are indexed.
CREATE INDEX idx_inventory_low_stock     ON inventory(variant_id)
  WHERE (quantity_in_stock - quantity_reserved) <= low_stock_threshold;

-- Q5: carts touched in the last N days.
CREATE INDEX idx_carts_updated_at        ON carts(updated_at);

INSERT INTO schema_migrations (version, description)
VALUES ('V002', 'FK and query-pattern indexes');

COMMIT;


-- [V003] triggers ============================================

BEGIN;

-- Bump updated_at on every UPDATE, unless the statement set it itself.
CREATE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  IF NEW.updated_at IS NOT DISTINCT FROM OLD.updated_at THEN
    NEW.updated_at := CURRENT_TIMESTAMP;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_updated_at     BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_products_updated_at  BEFORE UPDATE ON products
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_inventory_updated_at BEFORE UPDATE ON inventory
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_carts_updated_at     BEFORE UPDATE ON carts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_orders_updated_at    BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Record every order status change in order_status_history.
CREATE FUNCTION log_order_status_change() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO order_status_history (order_id, from_status, to_status, changed_at)
    VALUES (NEW.id, NULL, NEW.status, NEW.created_at);
  ELSE
    INSERT INTO order_status_history (order_id, from_status, to_status)
    VALUES (NEW.id, OLD.status, NEW.status);
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_orders_status_insert AFTER INSERT ON orders
  FOR EACH ROW EXECUTE FUNCTION log_order_status_change();
CREATE TRIGGER trg_orders_status_update AFTER UPDATE OF status ON orders
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION log_order_status_change();

INSERT INTO schema_migrations (version, description)
VALUES ('V003', 'updated_at and order status history triggers');

COMMIT;


-- [V004] prune unused indexes ================================
-- After measuring V002 (see lakshitha-month3-optimization-report.md),
-- no query plan used these two. Every index costs write time and
-- disk, so they go:
--   idx_orders_status_created: Q1 preferred idx_orders_created_at,
--     because status = 'delivered' is not selective (~55% of the
--     last 30 days' orders, ~80% overall).
--   idx_order_items_variant INCLUDE (...): nothing used the covering
--     columns. A plain index is kept for FK checks when a variant is
--     deleted (order_items.variant_id is ON DELETE RESTRICT).

BEGIN;

DROP INDEX idx_orders_status_created;
DROP INDEX idx_order_items_variant;
CREATE INDEX idx_order_items_variant ON order_items(variant_id);

INSERT INTO schema_migrations (version, description)
VALUES ('V004', 'drop indexes unused by measured query plans');

COMMIT;
