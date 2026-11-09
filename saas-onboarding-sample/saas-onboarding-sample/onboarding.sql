-- Northwind Cloud: onboarding three source systems into one set of SaaS KPIs
-- Runs on DuckDB:  duckdb < onboarding.sql   (reads ./data, writes ./output)

-- 1. Load raw sources -------------------------------------------------------
CREATE OR REPLACE TABLE crm  AS SELECT * FROM read_csv_auto('data/crm_accounts.csv', all_varchar=true);
CREATE OR REPLACE TABLE subs AS SELECT * FROM read_csv_auto('data/billing_subscriptions.csv',
    types={'start_month':'DATE','end_month':'DATE','mrr_local':'DOUBLE'});
CREATE OR REPLACE TABLE fx   AS SELECT * FROM read_csv_auto('data/fx_rates.csv');

-- One normalised key per company name, so "ACME FOODS", "Acme Foods Inc" and "AcmeFoods" all meet
CREATE OR REPLACE MACRO norm_name(n) AS
    regexp_replace(regexp_replace(lower(n), '(,?\s*(inc|llc|corp|corporation)\.?)$', ''), '[^a-z0-9]', '', 'g');

-- 2. Data quality checks: what was wrong with the data as received ------------
CREATE OR REPLACE TABLE dq_issues AS
WITH s AS (SELECT *, row_number() OVER (PARTITION BY billing_customer_name, plan, mrr_local, start_month, end_month ORDER BY subscription_id) AS rn FROM subs),
     c AS (SELECT *, count(*) OVER (PARTITION BY norm_name(account_name)) AS n FROM crm)
SELECT 'Billing' AS source, 'Test or internal accounts' AS issue, count(*) AS rows_affected, 'Excluded from revenue' AS handling
  FROM subs WHERE regexp_matches(lower(billing_customer_name), '(^test|internal|demo)')
UNION ALL SELECT 'Billing', 'Free trials at $0 MRR', count(*), 'Excluded from customer counts'
  FROM subs WHERE mrr_local = 0
UNION ALL SELECT 'Billing', 'Duplicate subscription rows (exported twice)', count(*), 'Kept one copy'
  FROM s WHERE rn > 1
UNION ALL SELECT 'Billing', 'End month before start month', count(*), 'Excluded, sent back to customer to confirm'
  FROM subs WHERE end_month < start_month
UNION ALL SELECT 'Billing', 'Revenue in non-USD currencies', count(*), 'Converted to USD at fixed rates'
  FROM subs WHERE currency <> 'USD'
UNION ALL SELECT 'Billing', 'Customer names not matching CRM exactly', count(*), 'Matched on a normalised name'
  FROM (SELECT DISTINCT billing_customer_name FROM subs) b
  WHERE billing_customer_name NOT IN (SELECT account_name FROM crm)
    AND NOT regexp_matches(lower(billing_customer_name), '(^test|internal|demo|^trial)')
UNION ALL SELECT 'CRM', 'Duplicate accounts for the same company', count(*) FILTER (WHERE n > 1) - count(DISTINCT norm_name(account_name)) FILTER (WHERE n > 1), 'Merged into the earliest account'
  FROM c
UNION ALL SELECT 'CRM', 'Accounts with no segment', count(*), 'Labelled Unknown'
  FROM crm WHERE coalesce(segment, '') = '';

-- 3. Clean, convert and map billing to CRM ----------------------------------
CREATE OR REPLACE TABLE accounts AS
SELECT norm_name(account_name) AS key,
       arg_min(account_id, account_id)          AS account_id,
       arg_min(account_name, account_id)        AS account_name,
       coalesce(nullif(max(segment), ''), 'Unknown') AS segment,
       arg_min(region, account_id)              AS region
FROM crm GROUP BY 1;

CREATE OR REPLACE TABLE clean_subs AS
SELECT DISTINCT ON (s.billing_customer_name, s.plan, s.mrr_local, s.start_month, s.end_month)
       a.account_id, a.account_name, a.segment, a.region, s.plan,
       round(s.mrr_local * fx.usd_rate, 2) AS mrr_usd, s.start_month, s.end_month
FROM subs s
JOIN fx USING (currency)
JOIN accounts a ON a.key = norm_name(s.billing_customer_name)
WHERE s.mrr_local > 0
  AND NOT regexp_matches(lower(s.billing_customer_name), '(^test|internal|demo)')
  AND (s.end_month IS NULL OR s.end_month >= s.start_month);

-- 4. Monthly MRR per account ------------------------------------------------
CREATE OR REPLACE TABLE months AS
SELECT unnest(generate_series(DATE '2025-01-01', DATE '2026-10-01', INTERVAL 1 MONTH))::DATE AS month;

CREATE OR REPLACE TABLE account_mrr AS
SELECT m.month, a.account_id, a.segment,
       coalesce(sum(cs.mrr_usd), 0) AS mrr
FROM months m CROSS JOIN accounts a
LEFT JOIN clean_subs cs ON cs.account_id = a.account_id
     AND cs.start_month <= m.month AND (cs.end_month IS NULL OR cs.end_month > m.month)
GROUP BY ALL;

-- 5. MRR movements: new, expansion, contraction, churn, reactivation --------
CREATE OR REPLACE TABLE movements AS
WITH x AS (
  SELECT *, lag(mrr, 1, 0) OVER (PARTITION BY account_id ORDER BY month) AS prev,
         max(mrr) OVER (PARTITION BY account_id ORDER BY month ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS ever
  FROM account_mrr)
SELECT month, account_id, segment, mrr, prev,
  CASE WHEN prev = 0 AND mrr > 0 AND coalesce(ever, 0) = 0 THEN 'New'
       WHEN prev = 0 AND mrr > 0 THEN 'Reactivation'
       WHEN prev > 0 AND mrr = 0 THEN 'Churn'
       WHEN mrr > prev THEN 'Expansion'
       WHEN mrr < prev THEN 'Contraction' END AS movement,
  mrr - prev AS delta
FROM x;

-- 6. Outputs for the dashboard ----------------------------------------------
COPY (
  SELECT strftime(month, '%Y-%m') AS month,
         round(sum(mrr)) AS mrr, round(sum(mrr) * 12) AS arr,
         count(*) FILTER (WHERE mrr > 0) AS customers,
         round(sum(delta) FILTER (WHERE movement = 'New')) AS new_mrr,
         round(sum(delta) FILTER (WHERE movement = 'Expansion')) AS expansion_mrr,
         round(sum(delta) FILTER (WHERE movement = 'Reactivation')) AS reactivation_mrr,
         round(sum(delta) FILTER (WHERE movement = 'Contraction')) AS contraction_mrr,
         round(sum(delta) FILTER (WHERE movement = 'Churn')) AS churned_mrr,
         count(*) FILTER (WHERE movement = 'Churn') AS churned_customers
  FROM movements GROUP BY month ORDER BY month
) TO 'output/monthly_kpis.csv' (HEADER);

-- Net and gross revenue retention, trailing 12 months, for customers active a year earlier
COPY (
  WITH base AS (SELECT account_id, mrr AS mrr_then FROM account_mrr WHERE month = DATE '2025-10-01' AND mrr > 0),
       now  AS (SELECT account_id, mrr AS mrr_now  FROM account_mrr WHERE month = DATE '2026-10-01')
  SELECT count(*) AS base_customers,
         round(sum(mrr_then)) AS base_mrr,
         round(sum(mrr_now)) AS same_customers_mrr_now,
         round(sum(mrr_now) / sum(mrr_then), 4) AS nrr,
         round(sum(least(mrr_now, mrr_then)) / sum(mrr_then), 4) AS grr,
         round(count(*) FILTER (WHERE mrr_now = 0) / count(*), 4) AS logo_churn_12m
  FROM base JOIN now USING (account_id)
) TO 'output/retention.csv' (HEADER);

COPY (
  SELECT segment, count(*) FILTER (WHERE mrr > 0) AS customers, round(sum(mrr)) AS mrr,
         round(sum(mrr) / nullif(count(*) FILTER (WHERE mrr > 0), 0)) AS arpa
  FROM account_mrr WHERE month = DATE '2026-10-01' GROUP BY segment ORDER BY mrr DESC
) TO 'output/segments.csv' (HEADER);

COPY (SELECT * FROM dq_issues ORDER BY source, rows_affected DESC) TO 'output/data_quality.csv' (HEADER);

-- Same retention view, split by segment: where is the churn coming from?
COPY (
  WITH base AS (SELECT account_id, segment, mrr AS mrr_then FROM account_mrr WHERE month = DATE '2025-10-01' AND mrr > 0),
       now  AS (SELECT account_id, mrr AS mrr_now  FROM account_mrr WHERE month = DATE '2026-10-01')
  SELECT segment, count(*) AS base_customers,
         round(sum(mrr_now) / sum(mrr_then), 4) AS nrr,
         round(sum(least(mrr_now, mrr_then)) / sum(mrr_then), 4) AS grr,
         round(count(*) FILTER (WHERE mrr_now = 0) / count(*), 4) AS logo_churn_12m
  FROM base JOIN now USING (account_id) GROUP BY segment ORDER BY base_customers DESC
) TO 'output/retention_by_segment.csv' (HEADER);
