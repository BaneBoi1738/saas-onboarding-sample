# SaaS customer data onboarding: a work sample

A customer hands over three exports (CRM, billing and currency rates) and asks for a set of KPIs they can trust. This folder shows how I'd do that: check the data, fix what's broken, consolidate it with SQL, and report the numbers with the caveats that matter.

**The company and data are fictional.** "Northwind Cloud" is a made-up B2B SaaS business. `generate_data.py` creates its exports with the kinds of problems real onboarding data arrives with.

## What was wrong with the data as received

| Source | Issue | Rows | Handling |
|---|---|---|---|
| Billing | Revenue in EUR and INR | 103 | Converted to USD |
| Billing | Customer names not matching CRM exactly ("ACME FOODS", "AcmeFoods", "Acme Foods Inc") | 96 | Matched on a normalised name |
| Billing | $0 free trials | 5 | Excluded from customer counts |
| Billing | Subscription rows exported twice | 4 | Kept one copy |
| Billing | Test and internal accounts | 3 | Excluded from revenue |
| Billing | End month before start month | 3 | Excluded and sent back to the customer to confirm |
| CRM | Duplicate accounts for the same company | 6 | Merged into the earliest account |
| CRM | Accounts with no segment | 8 | Labelled Unknown |

## What the numbers say

- ARR grew to about **$7.2M** with **112** paying customers (Oct 2026).
- Headline **net revenue retention is 107%**, which looks healthy.
- But **gross retention is 83%**, and **SMB kept only 68% of its revenue and lost 44% of its customers** in a year. Enterprise expansion (147% NRR) is covering for SMB churn.

That last point is the one I'd bring to the customer first: a single NRR number would have hidden it.

## How it works

```
data/crm_accounts.csv ─┐
data/billing_subscriptions.csv ─┼─► onboarding.sql (DuckDB) ─► output/*.csv ─► dashboard
data/fx_rates.csv ─┘
```

`onboarding.sql`, in order:
1. **Data quality checks:** counts every issue above before anything is changed
2. **Clean and map:** drops test, trial and duplicate rows, converts currency, and matches billing names to CRM accounts on a normalised key
3. **Monthly MRR per account:** a month × account grid, so churned months show as zero rather than disappearing
4. **MRR movements:** each account-month classed as new, expansion, contraction, churn or reactivation
5. **Retention:** net and gross revenue retention and logo churn over 12 months, overall and by segment

## Run it

```bash
pip install duckdb
python generate_data.py
mkdir -p output
python -c "import duckdb; duckdb.connect().execute(open('onboarding.sql').read())"
```

## Definitions

- **MRR:** monthly recurring revenue in USD. **ARR** = MRR × 12.
- **Net revenue retention:** this month's MRR from customers who were paying 12 months ago, divided by what they paid then. Includes expansion.
- **Gross revenue retention:** the same, with each customer capped at what they paid 12 months ago, so expansion can't hide churn.
