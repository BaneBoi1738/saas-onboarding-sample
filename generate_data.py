"""Synthetic data for a fictional B2B SaaS company ("Northwind Cloud").
Three source systems a new FP&A customer would hand over, with the messes
real onboarding data has. Fixed seed so results are reproducible."""
import random, csv
from datetime import date
random.seed(42)

MONTHS = [date(2025 + (m // 12), m % 12 + 1, 1) for m in range(22)]  # Jan 2025 - Oct 2026
PLANS = {"Starter": 400, "Growth": 1500, "Scale": 5000}
SEG_PLAN = {"SMB": ["Starter", "Starter", "Growth"], "Mid-Market": ["Growth", "Growth", "Scale"], "Enterprise": ["Scale"]}
REGIONS = {"North America": "USD", "Europe": "EUR", "India": "INR"}
FX = {"USD": 1.0, "EUR": 1.08, "INR": 0.012}
PREFIX = ["Acme", "Blue", "Cobalt", "Delta", "Echo", "Falcon", "Granite", "Harbor", "Iris", "Juniper", "Kestrel", "Lumen",
          "Maple", "Nova", "Orbit", "Pine", "Quartz", "Ridge", "Summit", "Tidal", "Umber", "Vertex", "Willow", "Zephyr"]
SUFFIX = ["Labs", "Systems", "Health", "Logistics", "Retail", "Analytics", "Foods", "Energy", "Media", "Works"]

def add_months(d, n):
    m = d.month - 1 + n
    return date(d.year + m // 12, m % 12 + 1, 1)

names = random.sample([f"{p} {s}" for p in PREFIX for s in SUFFIX], 140)
crm, subs = [], []
sub_n = 1
for i, name in enumerate(names):
    seg = random.choices(["SMB", "Mid-Market", "Enterprise"], [0.55, 0.33, 0.12])[0]
    region = random.choices(list(REGIONS), [0.5, 0.3, 0.2])[0]
    cur = REGIONS[region]
    start = random.choice(MONTHS)
    acct = f"CRM-{1000 + i}"
    crm.append(dict(account_id=acct, account_name=name, segment=seg, region=region,
                    owner=random.choice(["Priya", "Daniel", "Meera", "Tom", "Arjun"]), created_date=start.isoformat()))
    # billing name drifts from CRM name the way real systems do
    bname = random.choice([name, name + " Inc", name.upper(), name.replace(" ", ""), name + ", LLC", name])
    plan = random.choice(SEG_PLAN[seg])
    seats = random.randint(1, 3)
    mrr_usd = PLANS[plan] * seats
    cur_start = start
    churn_p = {"SMB": 0.035, "Mid-Market": 0.02, "Enterprise": 0.01}[seg]
    d = start
    ended = None
    while d <= MONTHS[-1]:
        d = add_months(d, 1)
        if d > MONTHS[-1]:
            break
        r = random.random()
        if r < churn_p:
            ended = d; break
        if r < churn_p + 0.03:          # expansion: new sub replaces old at higher price
            subs.append([sub_n, bname, plan, cur, round(mrr_usd / FX[cur], 2), cur_start, d]); sub_n += 1
            mrr_usd = round(mrr_usd * random.choice([1.3, 1.5, 2.0])); cur_start = d
        elif r < churn_p + 0.04 and mrr_usd > 500:   # contraction
            subs.append([sub_n, bname, plan, cur, round(mrr_usd / FX[cur], 2), cur_start, d]); sub_n += 1
            mrr_usd = round(mrr_usd * 0.7); cur_start = d
    subs.append([sub_n, bname, plan, cur, round(mrr_usd / FX[cur], 2), cur_start, ended]); sub_n += 1

# --- onboarding messes ---
# 1. duplicate CRM accounts (same company entered twice, different casing/punctuation)
for row in random.sample(crm, 6):
    crm.append({**row, "account_id": f"CRM-{1000 + len(crm)}", "account_name": row["account_name"] + " Corp", "owner": "Unassigned"})
# 2. missing segment
for row in random.sample(crm, 8): row["segment"] = ""
# 3. test / internal customers in billing
subs += [[sub_n + k, n, "Scale", "USD", 5000, MONTHS[3], None] for k, n in enumerate(["TEST - Northwind QA", "Internal Demo Account", "test_customer_2"])]
sub_n += 3
# 4. $0 free trials
subs += [[sub_n + k, f"Trial {k}", "Starter", "USD", 0, MONTHS[10], add_months(MONTHS[10], 1)] for k in range(5)]
sub_n += 5
# 5. exact duplicate subscription rows (exported twice)
subs += [[sub_n + k] + s[1:] for k, s in enumerate(random.sample(subs[:100], 4))]
sub_n += 4
# 6. end date before start date
bad = random.sample(subs[:120], 3)
for s in bad: s[6] = add_months(s[5], -2)

with open("data/crm_accounts.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(crm[0])); w.writeheader(); w.writerows(crm)
with open("data/billing_subscriptions.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["subscription_id", "billing_customer_name", "plan", "currency", "mrr_local", "start_month", "end_month"])
    for s in subs:
        w.writerow([f"sub_{s[0]:04d}", s[1], s[2], s[3], s[4], s[5].isoformat(), s[6].isoformat() if s[6] else ""])
with open("data/fx_rates.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["currency", "usd_rate"]); [w.writerow([c, r]) for c, r in FX.items()]
print(len(crm), "crm rows,", len(subs), "subscription rows")
