# ShopFlow Database - Design Decisions

Companion to `lakshitha-month3-erd.png` and `lakshitha-month3-migrations.sql`.
It covers why the schema looks the way it does: normalization, relationships, constraints, delete rules, deliberate denormalization, and the index strategy.

## 1. Requirements to tables

| Business requirement | Tables |
|---|---|
| Product catalog with categories and variants | `categories` (self-referencing tree), `products`, `product_variants` |
| User accounts with addresses and payment methods | `users`, `addresses`, `payment_methods` |
| Shopping cart and wishlist | `carts`, `cart_items`, `wishlist_items` |
| Order management with status tracking | `orders`, `order_items`, `order_status_history` |
| Inventory management | `inventory` |
| Reviews and ratings | `reviews` |
| Promotions and discounts | `promotions` (+ `orders.promotion_id`) |

That gives 15 tables, plus `schema_migrations` for versioning.

## 2. Normalization

**1NF.** Every column holds one atomic value. Repeating groups became their own tables: one row per address, per payment method, per cart line, per order line, and per status change. Nothing is stored as a comma list or an array.

**2NF.** Every table has a single-column surrogate key (`SERIAL id`), so partial dependencies on part of a composite key cannot occur. Natural composite keys still exist as `UNIQUE` constraints, for example `cart_items(cart_id, variant_id)`. The non-key columns of those tables (`quantity`, `added_at`) depend on the whole pair.

**3NF / BCNF.** No non-key column depends on another non-key column:
- A product's category name lives in `categories`, not in `products`.
- Variant attributes (size, colour, SKU, price modifier) live in `product_variants`. Stock levels live in `inventory`.
- An order points at `addresses.id` instead of copying the street and city into `orders`.
- The only other determinants are the `UNIQUE` columns (`users.email`, `products.slug`, `product_variants.sku`, `promotions.code`, `payment_methods.provider_token`). Each of them is a candidate key, which is what BCNF requires.

## 3. Relationships

| Type | Where | How |
|---|---|---|
| 1:1 | `product_variants` - `inventory` | `inventory.variant_id` is `UNIQUE` + FK |
| 1:1 (optional) | `users` - `carts` | `carts.user_id` is `UNIQUE` + FK: at most one active cart per user |
| 1:N | users to addresses / payment_methods / orders / reviews; products to variants; orders to order_items / order_status_history; categories to products | plain FK on the child |
| 1:N recursive | `categories.parent_id` to `categories.id` | unlimited depth; read with `WITH RECURSIVE` (Query 7). `CHECK (parent_id <> id)` blocks the trivial self-loop |
| M:N | users to product_variants | resolved by `cart_items` (through `carts`) and `wishlist_items`, each with a `UNIQUE` pair so the same variant cannot be listed twice |
| M:N | orders to product_variants | resolved by `order_items`, `UNIQUE (order_id, variant_id)` (buying 3 of something is quantity 3, not 3 rows) |
| M:N | users to products (reviews) | `reviews` with `UNIQUE (user_id, product_id)`: one review per product per user |

**Why variants, not products, are what you buy.** Carts, wishlists, orders and stock all reference `product_variants`, because "Blue / M" and "Black / L" are different stock-keeping units with their own stock and price. Reviews reference `products`, because people review the product, not one size of it.

## 4. Constraints: data integrity in the database

The database rejects bad data even if application code has a bug:

- **Money and quantities:** `base_price >= 0`, `quantity > 0`, `discount_value > 0`, and percentage discounts `<= 100`.
- **Arithmetic invariants:** `order_items.total_price = quantity * unit_price` and `orders.total_amount = subtotal - discount_amount + tax_amount`, with `discount_amount <= subtotal`. Reports can trust these columns without recomputing them.
- **Stock:** `quantity_reserved <= quantity_in_stock`, with both `>= 0`, so stock can never be oversold into negative numbers.
- **Promotions:** `expires_at > starts_at`, and `used_count <= max_uses` when there is a cap.
- **Enumerations** (`status`, `type`, `discount_type`, `method_type`) use `CHECK (x IN (...))` rather than Postgres `ENUM` types. Adding a value to a `CHECK` is a quick `ALTER TABLE`, while removing an `ENUM` value is not supported at all.
- **"Exactly one default" rules** use partial unique indexes: `UNIQUE (user_id, type) WHERE is_default` on addresses and `UNIQUE (user_id) WHERE is_default` on payment methods.
- **Card data:** `payment_methods` stores only a provider token, the last 4 digits and the expiry date, never the card number (PCI scope). A `CHECK` requires the last 4 and expiry for cards only.

Not enforced in the database (documented trade-off): that `payment_methods.billing_address_id` and `orders.address_id` belong to the same user as the row. Enforcing it would need composite FKs `(id, user_id)`, which adds a lot of extra keys for little gain. The application checks it instead.

## 5. ON DELETE rules

| FK | Rule | Reason |
|---|---|---|
| `orders.user_id`, `orders.address_id`, `order_items.variant_id` | `RESTRICT` | Orders are financial records. You must not lose them by deleting a customer, address or variant; deactivate those with `is_active` instead |
| `addresses.user_id`, `payment_methods.user_id`, `carts.user_id`, `cart_items.*`, `wishlist_items.*`, `reviews.*` | `CASCADE` | These rows mean nothing without their parent |
| `order_items.order_id`, `order_status_history.order_id` | `CASCADE` | Part of the order aggregate; they go only if the order itself is purged |
| `products.category_id`, `categories.parent_id`, `orders.promotion_id`, `orders.payment_method_id`, `payment_methods.billing_address_id` | `SET NULL` | Removing a category or promo code should not delete products or orders |

## 6. Deliberate denormalization

| Column | Duplicates | Why it is worth it |
|---|---|---|
| `order_items.unit_price`, `total_price` | `products.base_price + product_variants.price_modifier` | A historical snapshot. Prices change, but what the customer paid must not. This is a correctness requirement, not just a speed-up |
| `orders.subtotal`, `discount_amount`, `tax_amount`, `total_amount` | sum of `order_items` | Revenue reports (Q2, Q6, Q10) read one row per order instead of joining and summing the line items. `CHECK` constraints keep the columns consistent |
| `promotions.used_count` | `COUNT(*)` of orders with that promotion | Checking whether a code is still valid at checkout is a single-row read, with no count over 100K orders |

Everything else stays normalized. Further steps, such as a monthly-revenue summary table or materialized view, are only worth adding when Q10 becomes a bottleneck, and the optimization report shows it is not yet one.

## 7. Index strategy

- **The baseline (V001) has only constraint indexes:** primary keys and `UNIQUE` constraints. That is the "before" state in the optimization report.
- **V002 adds indexes for two reasons:**
  1. *FK support.* Postgres does not index FK columns automatically. Without an index on e.g. `orders.address_id`, every `DELETE` on `addresses` scans the whole `orders` table to check the `RESTRICT`.
  2. *Query patterns.* Each one is tied to a specific query and measured: `orders(user_id, created_at)`, `orders(status, created_at)`, `orders(created_at)`, the partial `orders(promotion_id) WHERE promotion_id IS NOT NULL`, `order_items(variant_id) INCLUDE (quantity, unit_price)`, and the partial low-stock index on `inventory`.
- **V004 removes what the measurements did not justify.** No query plan used `orders(status, created_at)` or the `INCLUDE` columns on `order_items(variant_id)`. The first is dropped; the second becomes a plain FK index. Indexes are added for measured reasons and removed for measured reasons.
- **Redundant indexes are not created.** The first draft had `idx_users_email`, `idx_products_slug`, `idx_variants_sku`, `idx_promotions_code`, `idx_carts_user` and `idx_inventory_variant`. Each duplicated an index that the `UNIQUE` constraint already creates, doubling the write cost for zero read benefit.
- **Leading columns are reused.** A composite `UNIQUE (cart_id, variant_id)` already serves lookups by `cart_id`, so only `variant_id` needs its own index.
- **Partial indexes are used where a query always filters the same way.** The low-stock index uses exactly Query 3's predicate (`quantity_in_stock - quantity_reserved <= low_stock_threshold`), so it holds only the few rows that are actually low on stock. The first draft's `WHERE quantity_in_stock <= 10` never matched the query and was never used.
- **Boolean flags such as `is_active` get no standalone index.** About 95% of rows are `true`, so an index on them is less selective than a sequential scan.

## 8. Other choices

- **`SERIAL` keys** as in the brief. For a new system, `GENERATED ALWAYS AS IDENTITY` is the SQL-standard equivalent and blocks accidental manual ids.
- **`DECIMAL`, never `FLOAT`, for money.** Order-level amounts are `DECIMAL(12,2)`, because a total is quantity times price and needs more headroom than one price (`DECIMAL(10,2)`, max 99,999,999.99).
- **`TIMESTAMP` (no time zone)** to match the brief. A multi-region deployment should switch to `TIMESTAMPTZ`.
- **Status history in its own table** instead of `shipped_at` / `delivered_at` columns on `orders`. New statuses need no schema change, and every transition is kept, including refunds after delivery. A trigger (V003) writes the history automatically, so application code cannot forget to.
- **`updated_at` trigger** (V003). It sets the timestamp on every `UPDATE` unless the statement set it explicitly (the seed script uses that to write historical times).
- **Migrations are versioned**, and each version runs inside `BEGIN ... COMMIT`. Postgres DDL is transactional, so a failing version rolls back completely, and `schema_migrations` records what has been applied.
- **Every version can be rolled back.** `lakshitha-month3-migrations-down.sql` has one section per version, newest first. Each section runs only if `schema_migrations` lists its version, so it is safe to re-run and cannot undo a version that was never applied. Tested: rolling back V004 → V002 gives exactly the V001-only schema with all data intact, and re-applying gives back an identical schema and an identical ERD.

## 9. Alternatives considered

| Alternative | Why not (for now) |
|---|---|
| Single `wishlists` table plus `wishlist_items` (named lists) | The requirement is one wishlist per user; `wishlist_items(user_id, variant_id)` covers it. Easy to add a parent table later |
| `ltree` or a closure table for categories | The tree has about 50 rows, and the whole of Query 7 (recursive CTE plus roll-up) runs in about 6 ms; adjacency list is simplest to maintain |
| JSONB `attributes` on variants instead of `size` / `color` columns | More flexible for varied product types, but loses type checking and simple B-tree indexing; revisit if categories need very different attributes |
| Postgres `ENUM` for status | See section 4: harder to change than a `CHECK` |
| Storing guest carts | Out of scope; would need `carts.user_id` nullable plus a `session_id` |
