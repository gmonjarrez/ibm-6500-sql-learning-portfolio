-- Lecture 2: Intermediate/Advanced BigQuery for GA4
-- GoogleSQL. Run each numbered query separately.
-- Author: Georgia Monjarrez
-- Executed successfully in BigQuery on November 4, 2026.
-- Transcribed from supplied lecture screenshots; ORDER BY typo corrected.

-- ======================================================================
-- Query 1: Total users and new users
-- COUNT(*) includes a NULL identifier group if one exists. These are pseudonymous identifiers, not necessarily unique people.
WITH UserInfo AS (
  SELECT user_pseudo_id,
    MAX(IF(event_name IN ('first_visit', 'first_open'), 1, 0)) AS is_new_user
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20201130'
  GROUP BY user_pseudo_id
)
SELECT COUNT(*) AS total_users, SUM(is_new_user) AS new_users
FROM UserInfo;

-- ======================================================================
-- Query 2: Extract page locations with a scalar subquery
-- Missing page locations return NULL. Without ORDER BY, the selected 50 rows are not guaranteed to appear in the same order across runs.
SELECT
  TIMESTAMP_MICROS(event_timestamp) AS event_time,
  (SELECT value.string_value
   FROM UNNEST(event_params)
   WHERE key = 'page_location' LIMIT 1) AS page_location
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE event_name = 'page_view'
  AND _TABLE_SUFFIX BETWEEN '20201201' AND '20201202'
LIMIT 50;

-- ======================================================================
-- Query 3: Flatten purchase items
-- item_rows counts item records, not units sold, transactions, or revenue. One purchase can contribute multiple rows.
SELECT event_date, item.item_name, COUNT(*) AS item_rows
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*` e,
UNNEST(e.items) AS item
WHERE e.event_name = 'purchase'
  AND _TABLE_SUFFIX BETWEEN '20201201' AND '20201231'
GROUP BY event_date, item.item_name
ORDER BY item_rows DESC
LIMIT 20;

-- ======================================================================
-- Query 4: List distinct event names by day
-- Corrected the lecture typo RDER BY to ORDER BY. The query lists all distinct names for each day; it does not limit the list to a few names.
SELECT event_date,
  STRING_AGG(DISTINCT event_name, ', ' ORDER BY event_name) AS events_seen
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201201' AND '20201203'
GROUP BY event_date
ORDER BY event_date;

-- ======================================================================
-- Query 5: Build an item-name array per user
-- Although the lecture calls this a session list, it groups only by user_pseudo_id and can combine multiple sessions. Duplicate item names remain, array order is unspecified, and NULL item names can cause an ARRAY_AGG result error; if encountered, use ARRAY_AGG(item_name IGNORE NULLS).
SELECT user_pseudo_id,
  ARRAY_AGG(item_name) AS items_added_to_cart
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`,
UNNEST(items) AS item
WHERE event_name = 'add_to_cart'
  AND _TABLE_SUFFIX BETWEEN '20201201' AND '20201231'
GROUP BY user_pseudo_id
ORDER BY user_pseudo_id
LIMIT 10;

-- ======================================================================
-- Query 6: Build a session cart summary
-- The lecture alias total_add_to_cart_events counts flattened item rows, not distinct add-to-cart events. The filter requests 2021, but only existing matching tables contribute; it does not establish that a full year is available. The array contains item records rather than totals aggregated by product.
WITH add_to_cart AS (
  SELECT user_pseudo_id,
    (SELECT value.int_value FROM UNNEST(event_params)
     WHERE key = 'ga_session_id') AS session_id,
    TIMESTAMP_MICROS(event_timestamp) AS event_timestamp,
    i.item_id, i.item_name, i.quantity, i.price
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`,
  UNNEST(items) AS i
  WHERE event_name = 'add_to_cart'
    AND _TABLE_SUFFIX BETWEEN '20210101' AND '20211231'
)
SELECT user_pseudo_id, session_id,
  COUNT(*) AS total_add_to_cart_events,
  ARRAY_AGG(
    STRUCT(item_id, item_name, quantity, price, event_timestamp)
    ORDER BY quantity DESC, event_timestamp ASC
    LIMIT 10
  ) AS cart_items
FROM add_to_cart
WHERE session_id IS NOT NULL
GROUP BY user_pseudo_id, session_id;

-- ======================================================================
-- Query 7: Join daily users and purchases
-- The lecture conversion_rate_pct is transactions per user multiplied by 100. It is not the percentage of users who purchased, because one user may have multiple transactions. The count uses transaction_id string parameters; missing values are excluded. Dates without any events are not created by the join.
WITH daily_users AS (
  SELECT event_date, COUNT(DISTINCT user_pseudo_id) AS users
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201201' AND '20201231'
  GROUP BY event_date
), daily_purchases AS (
  SELECT event_date,
    COUNT(DISTINCT
      (SELECT value.string_value FROM UNNEST(event_params)
       WHERE key = 'transaction_id')
    ) AS purchases
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE event_name = 'purchase'
    AND _TABLE_SUFFIX BETWEEN '20201201' AND '20201231'
  GROUP BY event_date
)
SELECT u.event_date, u.users,
  IFNULL(p.purchases, 0) AS purchases,
  ROUND(IFNULL(p.purchases, 0) / NULLIF(u.users, 0) * 100, 2)
    AS conversion_rate_pct
FROM daily_users u
LEFT JOIN daily_purchases p ON u.event_date = p.event_date
ORDER BY u.event_date;

-- ======================================================================
-- Query 8: Rank the top event types each day
-- Tied counts receive the same rank, so a date can return more than three rows. RANK can skip rank numbers after ties.
WITH daily_event_counts AS (
  SELECT event_date, event_name, COUNT(*) AS events
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201201' AND '20201207'
  GROUP BY event_date, event_name
)
SELECT event_date, event_name, events,
  RANK() OVER (PARTITION BY event_date ORDER BY events DESC) AS rnk
FROM daily_event_counts
QUALIFY rnk <= 3
ORDER BY event_date, rnk;

-- ======================================================================
-- Query 9: Calculate a rolling purchase average
-- This is a seven-row window. It represents seven calendar days only when the dates are consecutive; dates with zero purchase events are absent. The first six output rows use shorter windows. Purchases here are event rows, unlike the distinct transaction count in the join example.
WITH daily_purchases AS (
  SELECT PARSE_DATE('%Y%m%d', event_date) AS dt,
    COUNT(*) AS purchases
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE event_name = 'purchase'
    AND _TABLE_SUFFIX BETWEEN '20201201' AND '20201231'
  GROUP BY dt
)
SELECT dt, purchases,
  AVG(purchases) OVER (
    ORDER BY dt
    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
  ) AS purchases_7d_avg
FROM daily_purchases
ORDER BY dt;

-- ======================================================================
-- Query 10: Estimate distinct users per event type
-- Approximate counts can differ from exact COUNT(DISTINCT ...) results. A user may appear under several event types, so the estimates should not be summed to obtain total users.
SELECT event_name,
  APPROX_COUNT_DISTINCT(user_pseudo_id) AS approx_users
FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
WHERE _TABLE_SUFFIX BETWEEN '20201201' AND '20201231'
GROUP BY event_name
ORDER BY approx_users DESC
LIMIT 15;

