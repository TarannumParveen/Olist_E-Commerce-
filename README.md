# Olist_E-Commerce-
Olist E-Commerce Analytics Dashboard

End-to-end analytics pipeline on 100K+ orders from Olist, a Brazilian
e-commerce marketplace — taken from raw CSVs through Excel, PostgreSQL,
and Power BI to a 4-page interactive dashboard.

Why this project

Most portfolio projects stop at one tool. This one deliberately spans
three, in the order a real analytics workflow usually goes: quick
exploration in Excel, a proper relational model in SQL once the
questions get more complex, and a polished, interactive report in
Power BI for anyone who isn't going to open a spreadsheet or write a
query. Along the way I hit — and fixed — several real data-quality and
data-modeling bugs, documented below, because that debugging process
is as much a part of this project as the final dashboard.

Dataset

Olist Brazilian E-Commerce Public Dataset
(Kaggle) — 9 relational CSVs covering ~100K orders placed between
2016 and 2018. Not included in this repo (110MB+); download it
directly from Kaggle if you want to run the pipeline yourself.

Pipeline

1. Excel — clean, merge, first-pass exploration


Merged orders, order_items, order_payments, order_reviews,
customers, and products (+ category translation) into a single
order-level fact table (99,441 rows)
Built formula-driven summary tables (SUMIFS / COUNTIFS /
AVERAGEIFS) for monthly revenue, revenue by state, and category
performance — with matching charts
Deliberately left the 1M-row geolocation table out of this stage —
it needs aggregation before it's usable, which is a SQL job


📁 excel/olist_excel_stage.xlsx

2. PostgreSQL — relational model + analysis views


Normalized schema: 9 tables, proper primary/foreign key constraints,
~1.4M rows total
5 business-ready views built on top of the raw tables:

v_order_facts — one row per order, joined across all 9 source tables
v_geolocation — 1,000,163 raw location samples collapsed to
19,015 clean zip-level coordinates (avg lat/lng)
v_seller_performance — revenue, order volume, and delivery delay
per seller
v_reviews_clean — deduplicated review scores (source data has
orders reviewed more than once)
v_date_dim — calendar table for time intelligence





📁 sql/01_schema_and_load.sql ·
sql/02_views.sql

3. Power BI — interactive 4-page dashboard


Overview — revenue trend, top categories, revenue by state
Delivery Performance — on-time vs. late breakdown, delay by
state, delay trend over time
Customer & Reviews — review score distribution, repeat customer
rate, review score by category
Sellers & Products — top sellers, seller location map, worst
delivery-delay offenders


15+ custom DAX measures, conditional formatting on delivery KPIs, and
geographic maps built from the SQL-cleaned coordinate data.

📁 powerbi/olist_dashboard.pbix

Screenshots

OverviewDelivery PerformanceShow ImageShow Image

Customer & ReviewsSellers & ProductsShow ImageShow Image

Key findings


93.2% on-time delivery rate across 99,441 orders (Oct 2016 – Oct 2018)
R$15.84M total revenue, average review score 4.09 / 5
Late deliveries are strongly linked to lower review scores — the
single clearest insight in the dataset, visible on the Delivery
Performance page
Top revenue categories: bed_bath_table, health_beauty, and
sports_leisure
A small number of sellers account for a disproportionate share of
late deliveries, isolated using a minimum-order-count threshold to
avoid flagging sellers with just one unlucky shipment


Data-quality issues found and fixed

Real datasets are messy — these are worth mentioning because finding
and fixing them was a real part of the work, not a footnote:


review_id is not unique in the source data (98,410 distinct
values across 99,224 rows) — used a surrogate key instead of
trusting it as a primary key
order_estimated_delivery_date has no time component — comparing
full timestamps directly mislabeled same-day deliveries as "late";
fixed by using whole-day delay instead, verified consistent between
the Excel and SQL stages (93.2% either way)
Encoding mismatch on import — psql's client encoding defaulted
to WIN1252 on Windows, breaking on UTF-8 characters in Portuguese
review text; fixed with SET client_encoding = 'UTF8'
Many-to-many relationship bug in Power BI — joining a daily
calendar table to the order fact table on a non-unique year_month
column caused fan-out, inflating a rate measure above 100% on
low-volume months; fixed by removing the relationship and using the
fact table's own date column directly
Seller delay metric was inverted — an early SQL view averaged
delivery delay across all of a seller's orders (including early
ones), which skewed negative for nearly every seller since Olist's
estimates run conservative; fixed by averaging only over genuinely
late deliveries


How to run this yourself


Download the dataset from Kaggle
Create a PostgreSQL database: createdb olist
From the folder containing the 9 CSVs, run:


   psql -d olist -f sql/01_schema_and_load.sql
   psql -d olist -f sql/02_views.sql


Open powerbi/olist_dashboard.pbix in Power BI Desktop and point
the PostgreSQL connection at your local database (localhost,
database olist)


Tools

Excel (Power Query, PivotTables, formulas) · PostgreSQL · Power BI
(DAX, data modeling)
