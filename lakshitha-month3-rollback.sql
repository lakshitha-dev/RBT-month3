-- ============================================================
-- ShopFlow E-Commerce Platform - Rollback (down) Migrations
-- Dialect: PostgreSQL. Plain SQL: runs in psql, pgAdmin or DBeaver.
--
-- Each section undoes one version of lakshitha-month3-migrations.sql,
-- newest first, and removes that version's schema_migrations row.
--
--   Roll back everything:  run this whole file.
--   Roll back to V00x:     run the sections from the top down to,
--                          but not including, [V00x].
--   Re-apply afterwards:   run the matching sections of
--                          lakshitha-month3-migrations.sql, oldest first.
--
-- A section only runs if schema_migrations says its version is
-- applied; otherwise it prints a NOTICE and does nothing. That makes
-- the file safe to run twice and prevents rolling back a version that
-- was never applied. Each section is one DO block, so it is atomic.
--
-- WARNING: [V001] drops every table, so all data is lost.
-- ============================================================


-- [V004] restore pruned indexes ==============================
-- Puts back the two V002 indexes exactly as V002 created them.

DO $$
BEGIN
  IF to_regclass('public.schema_migrations') IS NULL THEN
    RAISE NOTICE 'V004: no schema_migrations table, nothing to roll back';
    RETURN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE version = 'V004') THEN
    RAISE NOTICE 'V004: not applied, skipping';
    RETURN;
  END IF;

  DROP INDEX IF EXISTS idx_order_items_variant;
  CREATE INDEX idx_order_items_variant   ON order_items(variant_id) INCLUDE (quantity, unit_price);
  CREATE INDEX idx_orders_status_created ON orders(status, created_at);

  DELETE FROM schema_migrations WHERE version = 'V004';
  RAISE NOTICE 'V004: rolled back';
END;
$$;


-- [V003] drop triggers =======================================

DO $$
BEGIN
  IF to_regclass('public.schema_migrations') IS NULL THEN
    RAISE NOTICE 'V003: no schema_migrations table, nothing to roll back';
    RETURN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE version = 'V003') THEN
    RAISE NOTICE 'V003: not applied, skipping';
    RETURN;
  END IF;

  DROP TRIGGER IF EXISTS trg_orders_status_update ON orders;
  DROP TRIGGER IF EXISTS trg_orders_status_insert ON orders;
  DROP FUNCTION IF EXISTS log_order_status_change();

  DROP TRIGGER IF EXISTS trg_orders_updated_at    ON orders;
  DROP TRIGGER IF EXISTS trg_carts_updated_at     ON carts;
  DROP TRIGGER IF EXISTS trg_inventory_updated_at ON inventory;
  DROP TRIGGER IF EXISTS trg_products_updated_at  ON products;
  DROP TRIGGER IF EXISTS trg_users_updated_at     ON users;
  DROP FUNCTION IF EXISTS set_updated_at();

  DELETE FROM schema_migrations WHERE version = 'V003';
  RAISE NOTICE 'V003: rolled back';
END;
$$;


-- [V002] drop indexes ========================================
-- Back to the V001 baseline: only PRIMARY KEY / UNIQUE indexes remain.

DO $$
BEGIN
  IF to_regclass('public.schema_migrations') IS NULL THEN
    RAISE NOTICE 'V002: no schema_migrations table, nothing to roll back';
    RETURN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE version = 'V002') THEN
    RAISE NOTICE 'V002: not applied, skipping';
    RETURN;
  END IF;

  DROP INDEX IF EXISTS idx_carts_updated_at;
  DROP INDEX IF EXISTS idx_inventory_low_stock;
  DROP INDEX IF EXISTS idx_order_status_history_order;
  DROP INDEX IF EXISTS idx_order_items_variant;
  DROP INDEX IF EXISTS idx_orders_promotion;
  DROP INDEX IF EXISTS idx_orders_created_at;
  DROP INDEX IF EXISTS idx_orders_status_created;
  DROP INDEX IF EXISTS idx_orders_user_created;

  DROP INDEX IF EXISTS idx_reviews_product;
  DROP INDEX IF EXISTS idx_orders_payment_method;
  DROP INDEX IF EXISTS idx_orders_address;
  DROP INDEX IF EXISTS idx_wishlist_items_variant;
  DROP INDEX IF EXISTS idx_cart_items_variant;
  DROP INDEX IF EXISTS idx_variants_product;
  DROP INDEX IF EXISTS idx_products_category;
  DROP INDEX IF EXISTS idx_payment_methods_user;
  DROP INDEX IF EXISTS idx_addresses_user;
  DROP INDEX IF EXISTS idx_categories_parent;

  DELETE FROM schema_migrations WHERE version = 'V002';
  RAISE NOTICE 'V002: rolled back';
END;
$$;


-- [V001] drop core schema (DESTROYS ALL DATA) ================
-- Children before parents, the reverse of the creation order.

DO $$
BEGIN
  IF to_regclass('public.schema_migrations') IS NULL THEN
    RAISE NOTICE 'V001: no schema_migrations table, nothing to roll back';
    RETURN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE version = 'V001') THEN
    RAISE NOTICE 'V001: not applied, skipping';
    RETURN;
  END IF;

  DROP TABLE IF EXISTS reviews;
  DROP TABLE IF EXISTS order_status_history;
  DROP TABLE IF EXISTS order_items;
  DROP TABLE IF EXISTS orders;
  DROP TABLE IF EXISTS wishlist_items;
  DROP TABLE IF EXISTS cart_items;
  DROP TABLE IF EXISTS carts;
  DROP TABLE IF EXISTS promotions;
  DROP TABLE IF EXISTS inventory;
  DROP TABLE IF EXISTS product_variants;
  DROP TABLE IF EXISTS products;
  DROP TABLE IF EXISTS payment_methods;
  DROP TABLE IF EXISTS addresses;
  DROP TABLE IF EXISTS users;
  DROP TABLE IF EXISTS categories;

  DELETE FROM schema_migrations WHERE version = 'V001';
  RAISE NOTICE 'V001: rolled back';
END;
$$;


-- [V000] drop version tracking ===============================

DROP TABLE IF EXISTS schema_migrations;
