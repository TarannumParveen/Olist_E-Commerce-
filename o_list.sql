-- Clean slate if re-running
DROP TABLE IF EXISTS order_reviews, order_payments, order_items, orders,
                      products, sellers, customers, geolocation,
                      product_category_name_translation CASCADE;
 
-- ---------------------------------------------------------
-- Reference / dimension tables (no dependencies)
-- ---------------------------------------------------------
 
CREATE TABLE customers (
    customer_id varchar(64) PRIMARY KEY,
    customer_unique_id varchar(64) NOT NULL,
    customer_zip_code_prefix  varchar(10),
    customer_city varchar(100),
    customer_state varchar(2)
);
 
CREATE TABLE sellers (
    seller_id varchar(64) PRIMARY KEY,
    seller_zip_code_prefix varchar(10),
    seller_city  varchar(100),
    seller_state varchar(2)
);
 
CREATE TABLE product_category_name_translation (
    product_category_name varchar(100) PRIMARY KEY,
    product_category_name_english varchar(100)
);
 
CREATE TABLE products (
    product_id  varchar(64) PRIMARY KEY,
    product_category_name varchar(100),
    product_name_lenght int,
    product_description_lenght int,
    product_photos_qty  int,
    product_weight_g numeric,
    product_length_cm  numeric,
    product_height_cm  numeric,
    product_width_cm numeric
);
 
-- Raw geolocation: NO primary key on purpose — the source data has many
-- duplicate rows per zip prefix (multiple lat/lng samples). We dedupe
-- this into a view later (v_geolocation) rather than fighting it here.
CREATE TABLE geolocation (
    geolocation_zip_code_prefix  varchar(10),
    geolocation_lat numeric,
    geolocation_lng  numeric,
    geolocation_city  varchar(100),
    geolocation_state  varchar(2)
);
 Select * from geolocation;
-- ---------------------------------------------------------
-- Core transactional tables (depend on the above)
-- ---------------------------------------------------------
 
CREATE TABLE orders (
    order_id   varchar(64) PRIMARY KEY,
    customer_id  varchar(64) REFERENCES customers(customer_id),
    order_status  varchar(20),
    order_purchase_timestamp timestamp,
    order_approved_at  timestamp,
    order_delivered_carrier_date timestamp,
    order_delivered_customer_date timestamp,
    order_estimated_delivery_date  timestamp
);
 
CREATE TABLE order_items (
    order_id varchar(64) REFERENCES orders(order_id),
    order_item_id   int,
    product_id varchar(64) REFERENCES products(product_id),
    seller_id varchar(64) REFERENCES sellers(seller_id),
    shipping_limit_date  timestamp,
    price  numeric(10,2),
    freight_value numeric(10,2),
    PRIMARY KEY (order_id, order_item_id)
);
 
CREATE TABLE order_payments (
    order_id varchar(64) REFERENCES orders(order_id),
    payment_sequential int,
    payment_type varchar(20),
    payment_installments int,
    payment_value numeric(10,2),
    PRIMARY KEY (order_id, payment_sequential)
);
 
-- Note: review_id is NOT unique in the source data (a small number of
-- orders were reviewed more than once under the same review_id), so we
-- use a surrogate key instead of trusting review_id as PK.
CREATE TABLE order_reviews (
    review_pk   serial PRIMARY KEY,
    review_id  varchar(64),
    order_id varchar(64) REFERENCES orders(order_id),
    review_score int,
    review_comment_title text,
    review_comment_message  text,
    review_creation_date timestamp,
    review_answer_timestamp timestamp
);


SELECT * FROM customers;
SELECT * FROM sellers;
SELECT * FROM order_items; 
SELECT * FROM order_payments;
SELECT * FROM order_reviews; --
SELECT * FROM orders;
SELECT * FROM product_category_name_translation;
SELECT * FROM products;

--------------------------------------------------------------------------------------------------------------------------------------
-- 1. v_geolocation
-- Collapses ~1M raw geolocation samples down to ONE row per
-- zip prefix (average lat/lng). This is the step that made
-- geolocation unusable in Excel but trivial in SQL.
-- ---------------------------------------------------------
CREATE VIEW v_geolocation AS
SELECT
    geolocation_zip_code_prefix AS zip_code_prefix,
    ROUND(AVG(geolocation_lat), 6) AS lat,
    ROUND(AVG(geolocation_lng), 6) AS lng,
    MODE() WITHIN GROUP (ORDER BY geolocation_city) AS city,
    MODE() WITHIN GROUP (ORDER BY geolocation_state) AS state
FROM geolocation
GROUP BY geolocation_zip_code_prefix;
 
-- ---------------------------------------------------------
-- 2. v_reviews_clean
-- One review score per order (some orders were reviewed more
-- than once in the raw data — we keep the most recent one).
-- ---------------------------------------------------------
CREATE VIEW v_reviews_clean AS
SELECT DISTINCT ON (order_id)
    order_id,
    review_score,
    review_creation_date
FROM order_reviews
ORDER BY order_id, review_creation_date DESC;
 
-- ---------------------------------------------------------
-- 3. v_order_facts
-- The main fact table: one row per order, with customer,
-- geography, delivery, revenue, category and review info.
-- This is the table Power BI's "Overview" and "Delivery"
-- pages will be built on.
-- ---------------------------------------------------------
CREATE VIEW v_order_facts AS
WITH item_agg AS (
    SELECT
        oi.order_id,
        COUNT(*)                              AS items_count,
        SUM(oi.price)                         AS items_price_total,
        SUM(oi.freight_value)                 AS freight_total,
        MODE() WITHIN GROUP (ORDER BY COALESCE(t.product_category_name_english, p.product_category_name, 'unknown'))
                                               AS main_category
    FROM order_items oi
    LEFT JOIN products p ON oi.product_id = p.product_id
    LEFT JOIN product_category_name_translation t ON p.product_category_name = t.product_category_name
    GROUP BY oi.order_id
),
payment_agg AS (
    SELECT
        order_id,
        SUM(payment_value) AS payment_value_total,
        MAX(payment_installments) AS payment_installments_max,
        MODE() WITHIN GROUP (ORDER BY payment_type) AS payment_type
    FROM order_payments
    GROUP BY order_id
)
SELECT
    o.order_id,
    o.customer_id,
    c.customer_unique_id,
    c.customer_city,
    c.customer_state,
    c.customer_zip_code_prefix,
    o.order_status,
    o.order_purchase_timestamp,
    TO_CHAR(o.order_purchase_timestamp, 'YYYY-MM')     AS order_month,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,
    EXTRACT(DAY FROM (o.order_delivered_customer_date - o.order_purchase_timestamp))::int
                                                          AS delivery_days,
    EXTRACT(DAY FROM (o.order_delivered_customer_date - o.order_estimated_delivery_date))::int
                                                          AS delivery_delay_days,
    -- Based on whole-day delay (matches the Excel-stage definition):
    -- a delivery on the estimated day itself counts as on-time, even if
    -- it arrived a few hours after midnight.
    CASE
        WHEN o.order_delivered_customer_date IS NULL THEN NULL
        WHEN EXTRACT(DAY FROM (o.order_delivered_customer_date - o.order_estimated_delivery_date)) > 0 THEN 1
        ELSE 0
    END                                                   AS is_late,
    ia.items_count,
    ia.main_category,
    ia.items_price_total,
    ia.freight_total,
    COALESCE(ia.items_price_total, 0) + COALESCE(ia.freight_total, 0) AS total_order_value,
    pa.payment_type,
    pa.payment_installments_max,
    pa.payment_value_total,
    r.review_score
FROM orders o
LEFT JOIN customers c   ON o.customer_id = c.customer_id
LEFT JOIN item_agg ia   ON o.order_id = ia.order_id
LEFT JOIN payment_agg pa ON o.order_id = pa.order_id
LEFT JOIN v_reviews_clean r ON o.order_id = r.order_id;
 
-- ---------------------------------------------------------
-- 4. v_seller_performance
-- One row per seller: revenue, order volume, avg review,
-- avg delivery delay caused on their orders, and location
-- (joined through v_geolocation — this is the view that
-- couldn't exist at the Excel stage).
-- ---------------------------------------------------------
CREATE VIEW v_seller_performance AS
SELECT
    s.seller_id,
    s.seller_city,
    s.seller_state,
    g.lat,
    g.lng,
    COUNT(DISTINCT oi.order_id)              AS orders_count,
    SUM(oi.price + oi.freight_value)         AS revenue,
    ROUND(AVG(r.review_score), 2)            AS avg_review_score,
    ROUND(AVG(
        EXTRACT(DAY FROM (o.order_delivered_customer_date - o.order_estimated_delivery_date))
    ), 1)                                     AS avg_delay_days
FROM sellers s
JOIN order_items oi ON s.seller_id = oi.seller_id
JOIN orders o ON oi.order_id = o.order_id
LEFT JOIN v_reviews_clean r ON o.order_id = r.order_id
LEFT JOIN v_geolocation g ON s.seller_zip_code_prefix = g.zip_code_prefix
GROUP BY s.seller_id, s.seller_city, s.seller_state, g.lat, g.lng;
 
-- ---------------------------------------------------------
-- 5. v_date_dim
-- Calendar table spanning the order date range, for Power BI
-- time intelligence (month/year slicers, YoY comparisons).
-- ---------------------------------------------------------
CREATE VIEW v_date_dim AS
SELECT
    d::date                          AS date,
    EXTRACT(YEAR FROM d)::int        AS year,
    EXTRACT(MONTH FROM d)::int       AS month,
    TO_CHAR(d, 'Mon')                AS month_name,
    TO_CHAR(d, 'YYYY-MM')            AS year_month,
    EXTRACT(QUARTER FROM d)::int     AS quarter,
    EXTRACT(DOW FROM d)::int         AS day_of_week,
    TO_CHAR(d, 'Day')                AS day_name
FROM generate_series(
    (SELECT MIN(order_purchase_timestamp)::date FROM orders),
    (SELECT MAX(order_purchase_timestamp)::date FROM orders),
    interval '1 day'
) AS d;

-----------------------------------------------------------------------------------------
SELECT 'v_order_facts' AS view_name, COUNT(*) FROM v_order_facts
UNION ALL SELECT 'v_geolocation', COUNT(*) FROM v_geolocation
UNION ALL SELECT 'v_seller_performance', COUNT(*) FROM v_seller_performance
UNION ALL SELECT 'v_date_dim', COUNT(*) FROM v_date_dim;

------------------------------------------------------------------------------------------------------------------------------------------

SELECT COUNT(*) FROM order_reviews;
SELECT COUNT(*) FROM geolocation;
SELECT COUNT(*) FROM v_reviews_clean;
SELECT COUNT(*) FROM v_geolocation;


---------------------------------------------------------------------------------------------
DROP VIEW IF EXISTS v_order_facts, v_geolocation, v_seller_performance,
                     v_reviews_clean, v_date_dim CASCADE;
 
-- ---------------------------------------------------------
-- 1. v_geolocation
-- Collapses ~1M raw geolocation samples down to ONE row per
-- zip prefix (average lat/lng). This is the step that made
-- geolocation unusable in Excel but trivial in SQL.
-- ---------------------------------------------------------
CREATE VIEW v_geolocation AS
SELECT
    geolocation_zip_code_prefix AS zip_code_prefix,
    ROUND(AVG(geolocation_lat), 6) AS lat,
    ROUND(AVG(geolocation_lng), 6) AS lng,
    MODE() WITHIN GROUP (ORDER BY geolocation_city) AS city,
    MODE() WITHIN GROUP (ORDER BY geolocation_state) AS state
FROM geolocation
GROUP BY geolocation_zip_code_prefix;
 
-- ---------------------------------------------------------
-- 2. v_reviews_clean
-- One review score per order (some orders were reviewed more
-- than once in the raw data — we keep the most recent one).
-- ---------------------------------------------------------
CREATE VIEW v_reviews_clean AS
SELECT DISTINCT ON (order_id)
    order_id,
    review_score,
    review_creation_date
FROM order_reviews
ORDER BY order_id, review_creation_date DESC;
 
-- ---------------------------------------------------------
-- 3. v_order_facts
-- The main fact table: one row per order, with customer,
-- geography, delivery, revenue, category and review info.
-- This is the table Power BI's "Overview" and "Delivery"
-- pages will be built on.
-- ---------------------------------------------------------
CREATE VIEW v_order_facts AS
WITH item_agg AS (
    SELECT
        oi.order_id,
        COUNT(*)                              AS items_count,
        SUM(oi.price)                         AS items_price_total,
        SUM(oi.freight_value)                 AS freight_total,
        MODE() WITHIN GROUP (ORDER BY COALESCE(t.product_category_name_english, p.product_category_name, 'unknown'))
                                               AS main_category
    FROM order_items oi
    LEFT JOIN products p ON oi.product_id = p.product_id
    LEFT JOIN product_category_name_translation t ON p.product_category_name = t.product_category_name
    GROUP BY oi.order_id
),
payment_agg AS (
    SELECT
        order_id,
        SUM(payment_value) AS payment_value_total,
        MAX(payment_installments) AS payment_installments_max,
        MODE() WITHIN GROUP (ORDER BY payment_type) AS payment_type
    FROM order_payments
    GROUP BY order_id
)
SELECT
    o.order_id,
    o.customer_id,
    c.customer_unique_id,
    c.customer_city,
    c.customer_state,
    c.customer_zip_code_prefix,
    o.order_status,
    o.order_purchase_timestamp,
    TO_CHAR(o.order_purchase_timestamp, 'YYYY-MM')     AS order_month,
    o.order_delivered_customer_date,
    o.order_estimated_delivery_date,
    EXTRACT(DAY FROM (o.order_delivered_customer_date - o.order_purchase_timestamp))::int
                                                          AS delivery_days,
    EXTRACT(DAY FROM (o.order_delivered_customer_date - o.order_estimated_delivery_date))::int
                                                          AS delivery_delay_days,
    -- Based on whole-day delay (matches the Excel-stage definition):
    -- a delivery on the estimated day itself counts as on-time, even if
    -- it arrived a few hours after midnight.
    CASE
        WHEN o.order_delivered_customer_date IS NULL THEN NULL
        WHEN EXTRACT(DAY FROM (o.order_delivered_customer_date - o.order_estimated_delivery_date)) > 0 THEN 1
        ELSE 0
    END                                                   AS is_late,
    ia.items_count,
    ia.main_category,
    ia.items_price_total,
    ia.freight_total,
    COALESCE(ia.items_price_total, 0) + COALESCE(ia.freight_total, 0) AS total_order_value,
    pa.payment_type,
    pa.payment_installments_max,
    pa.payment_value_total,
    r.review_score
FROM orders o
LEFT JOIN customers c   ON o.customer_id = c.customer_id
LEFT JOIN item_agg ia   ON o.order_id = ia.order_id
LEFT JOIN payment_agg pa ON o.order_id = pa.order_id
LEFT JOIN v_reviews_clean r ON o.order_id = r.order_id;
 
-- ---------------------------------------------------------
-- 4. v_seller_performance
-- One row per seller: revenue, order volume, avg review,
-- avg delivery delay caused on their orders, and location
-- (joined through v_geolocation — this is the view that
-- couldn't exist at the Excel stage).
-- ---------------------------------------------------------
CREATE VIEW v_seller_performance AS
SELECT
    s.seller_id,
    s.seller_city,
    s.seller_state,
    g.lat,
    g.lng,
    COUNT(DISTINCT oi.order_id)              AS orders_count,
    SUM(oi.price + oi.freight_value)         AS revenue,
    ROUND(AVG(r.review_score), 2)            AS avg_review_score,
    -- Only averages orders that were actually late — averaging across
    -- ALL orders (including early ones) skews this negative for nearly
    -- every seller, since Olist's estimates run conservative.
    ROUND(AVG(
        CASE WHEN o.order_delivered_customer_date > o.order_estimated_delivery_date
        THEN EXTRACT(DAY FROM (o.order_delivered_customer_date - o.order_estimated_delivery_date))
        END
    ), 1)                                     AS avg_delay_days,
    COUNT(*) FILTER (
        WHERE o.order_delivered_customer_date > o.order_estimated_delivery_date
    )                                          AS late_orders_count
FROM sellers s
JOIN order_items oi ON s.seller_id = oi.seller_id
JOIN orders o ON oi.order_id = o.order_id
LEFT JOIN v_reviews_clean r ON o.order_id = r.order_id
LEFT JOIN v_geolocation g ON s.seller_zip_code_prefix = g.zip_code_prefix
GROUP BY s.seller_id, s.seller_city, s.seller_state, g.lat, g.lng;
 
-- ---------------------------------------------------------
-- 5. v_date_dim
-- Calendar table spanning the order date range, for Power BI
-- time intelligence (month/year slicers, YoY comparisons).
-- ---------------------------------------------------------
CREATE VIEW v_date_dim AS
SELECT
    d::date                          AS date,
    EXTRACT(YEAR FROM d)::int        AS year,
    EXTRACT(MONTH FROM d)::int       AS month,
    TO_CHAR(d, 'Mon')                AS month_name,
    TO_CHAR(d, 'YYYY-MM')            AS year_month,
    EXTRACT(QUARTER FROM d)::int     AS quarter,
    EXTRACT(DOW FROM d)::int         AS day_of_week,
    TO_CHAR(d, 'Day')                AS day_name
FROM generate_series(
    (SELECT MIN(order_purchase_timestamp)::date FROM orders),
    (SELECT MAX(order_purchase_timestamp)::date FROM orders),
    interval '1 day'
) AS d;
 
-- ---------------------------------------------------------
-- Sanity checks
-- ---------------------------------------------------------
SELECT 'v_order_facts' AS view_name, COUNT(*) FROM v_order_facts
UNION ALL SELECT 'v_geolocation', COUNT(*) FROM v_geolocation
UNION ALL SELECT 'v_seller_performance', COUNT(*) FROM v_seller_performance
UNION ALL SELECT 'v_date_dim', COUNT(*) FROM v_date_dim;