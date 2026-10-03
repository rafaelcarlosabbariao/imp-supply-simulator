#!/usr/bin/env python3
"""
Generate the sample datasets/ CSVs for the IMP demand & supply simulation.

Fills six tables (studies, dosing, subject visits, site and depot inventory,
resupply orders) with internally-consistent synthetic data built from the
enrollment and dosing plans in Program_Inputs.xlsx for the two demo studies,
TRIAL-201 and TRIAL-118.

Everything is seeded, so output is deterministic and reproducible.

Outputs (datasets/):
  study_info.csv       - one row per study (key col: protocol)
  dosing_matrix.csv    - visit-container-type dosing rows (key col: protocol)
  visit_details.csv    - historical/actual subject visits (key col: protocol)
  site_inventory.csv   - on-hand inventory at each site (key col: protocol_id)
  depot_inventory.csv  - on-hand inventory at each depot (key col: protocol)
  order_details.csv    - historical resupply orders (key col: protocol)
"""
import csv
import os
import random
from datetime import date, datetime, timedelta

import openpyxl

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "datasets")
os.makedirs(OUT, exist_ok=True)

SEED = 20240701
random.seed(SEED)

# --------------------------------------------------------------------------- #
# Read the committed input workbook (the enrollment + dosing plans)
# --------------------------------------------------------------------------- #
def _clean(v):
    if v is None:
        return ""
    if isinstance(v, (datetime, date)):
        return v.strftime("%Y-%m-%d")
    return str(v).strip()


def read_sheet(path, sheet):
    wb = openpyxl.load_workbook(path, data_only=True)
    ws = wb[sheet]
    rows = list(ws.iter_rows(values_only=True))
    header = [_clean(h) for h in rows[0]]
    out = []
    for r in rows[1:]:
        if all(c is None for c in r):
            continue
        out.append({header[i]: _clean(r[i]) for i in range(len(header))})
    wb.close()
    return out


inputs_path = os.path.join(ROOT, "Program_Inputs.xlsx")
enrollment = read_sheet(inputs_path, "Enrollment_Input")
dosing = read_sheet(inputs_path, "Dosing_Input")

# Normalise protocol codes (source data may have trailing spaces)
for row in enrollment:
    row["Protocol"] = row["Protocol"].strip()
    row["Country"] = row["Country"].strip()
for row in dosing:
    row["Protocol"] = row["Protocol"].strip()

PROTOCOLS = sorted({r["Protocol"] for r in enrollment})

# Study-level metadata (compound / program) inferred from the DU descriptions.
STUDY_META = {
    "TRIAL-201": dict(
        irt_system="IRT-Alpha", program_code="PGM-A", compound="Compound-A",
        drug_name="Compound-A", phase="PHASE I",
        therapeutic_area="CARDIOVASCULAR", study_type="INTERVENTIONAL",
    ),
    "TRIAL-118": dict(
        irt_system="IRT-Beta", program_code="PGM-B", compound="Compound-C",
        drug_name="Compound-C / Compound-B", phase="PHASE I",
        therapeutic_area="ONCOLOGY", study_type="INTERVENTIONAL",
    ),
}


def meta_for(protocol):
    return STUDY_META.get(
        protocol,
        dict(irt_system="Unknown", program_code=protocol[:4],
             compound="NA", drug_name="NA",
             phase="NA", therapeutic_area="NA", study_type="INTERVENTIONAL"),
    )


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def write_csv(name, fieldnames, rows):
    path = os.path.join(OUT, name)
    with open(path, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow(r)
    print(f"  wrote {name:24s} {len(rows):5d} rows")


def parse_d(s):
    return datetime.strptime(s, "%Y-%m-%d").date()


def lot_id(protocol, i):
    return f"{protocol[:4]}LOT{1000 + i}"


# Distinct (protocol, center, country) sites, and (protocol, arm, DU, qty).
# A site is a center IN A COUNTRY: TRIAL-118 runs a center 1004 in Mexico and
# another in the USA, and each needs its own inventory and map position.
sites = {}
for r in enrollment:
    key = (r["Protocol"], r["Center"], r["Country"])
    if key not in sites:
        sites[key] = r["Country"]

# dosing: quantity is the first non-empty Option column
dosing_long = []
for r in dosing:
    qty = ""
    for c in ["Option1", "Option2", "Option3", "Option4", "Option5", "Option6"]:
        if r.get(c, "") not in ("", "None"):
            qty = r[c]
            break
    dosing_long.append(dict(
        protocol=r["Protocol"], arm=r["Arm"], du=r["DU_Description"],
        cycles=int(float(r["Cycles"])), cycle_length=int(float(r["Cycle_Length"])),
        qty=float(qty) if qty not in ("", "None") else 1.0,
    ))

# per-protocol DU list
dus_by_protocol = {}
for d in dosing_long:
    dus_by_protocol.setdefault(d["protocol"], [])
    if d["du"] not in dus_by_protocol[d["protocol"]]:
        dus_by_protocol[d["protocol"]].append(d["du"])

# --------------------------------------------------------------------------- #
# 1. study_info.csv
# --------------------------------------------------------------------------- #
study_rows = []
for p in PROTOCOLS:
    m = meta_for(p)
    p_enr = [r for r in enrollment if r["Protocol"] == p]
    countries = sorted({r["Country"] for r in p_enr})
    centers = sorted({(r["Center"], r["Country"]) for r in p_enr})
    starts = [parse_d(r["Enroll_Start"]) for r in p_enr]
    ends = [parse_d(r["Enroll_End"]) for r in p_enr]
    total_planned = sum(int(float(r["Patients"])) for r in p_enr)
    study_rows.append(dict(
        irt_system=m["irt_system"], protocol=p, program_code=m["program_code"],
        compound=m["compound"], drug_name=m["drug_name"],
        phase=m["phase"], therapeutic_area=m["therapeutic_area"], study_type=m["study_type"],
        status="ONGOING",
        first_visit_date=min(starts).isoformat(),
        last_visit_date=max(ends).isoformat(),
        planned_patients=total_planned,
        enrolled_patients=int(total_planned * 0.35),
        active_sites=len(centers),
        countries=len(countries),
        planned_end_date=(max(ends) + timedelta(days=365)).isoformat(),
    ))
write_csv("study_info.csv", list(study_rows[0].keys()), study_rows)

# --------------------------------------------------------------------------- #
# 2. dosing_matrix.csv  (mirror of a visit-container-type dosing table)
# --------------------------------------------------------------------------- #
dose_rows = []
container_id = 5000
for d in dosing_long:
    m = meta_for(d["protocol"])
    container_id += 1
    # one representative row per (protocol, arm, DU); the visit code is generic
    dose_rows.append(dict(
        source=m["irt_system"],
        protocol=d["protocol"],
        arm=d["arm"],
        arm_description=f"{d['arm']} treatment group",
        visit_code="C1D1",
        visit_description="Randomization/Cycle 1 Day 1",
        container_type_id=container_id,
        du_description=d["du"],
        du_type_id=container_id,
        dispensing_set=f"{d['arm']}-SET",
        quantity=d["qty"],
        quantity_dispensed=d["qty"],
        cycle_length=d["cycle_length"],
        remaining_cycles=d["cycles"],
        days_from_anchor=0,
        window_plus_days=3,
        window_minus_days=3,
        sequence=1,
    ))
write_csv("dosing_matrix.csv", list(dose_rows[0].keys()), dose_rows)

# --------------------------------------------------------------------------- #
# 3. visit_details.csv  (historical actuals for already-active subjects)
#    A fraction of planned patients are modelled as already enrolled/active so
#    a "current active subjects" view has data to work with.
# --------------------------------------------------------------------------- #
visit_rows = []
today = date(2024, 1, 1)  # the sample data's frame of reference ("2023+")
for r in enrollment:
    p = r["Protocol"]
    start = parse_d(r["Enroll_Start"])
    if start > today:
        continue  # cohort hasn't started enrolling yet -> no actuals
    n_active = max(0, int(int(float(r["Patients"])) * random.uniform(0.2, 0.6)))
    arm = r["Arm"]
    dus = [d for d in dosing_long if d["protocol"] == p and d["arm"] == arm]
    if not dus:
        continue
    cyc_len = dus[0]["cycle_length"]
    for k in range(n_active):
        subject_id = f"{r['Center']}{1000 + k + 1}"
        screen = start + timedelta(days=random.randint(0, 20))
        rand = screen + timedelta(days=random.randint(1, 28))
        # emit screening + a few completed cycles up to `today`
        seq = [("Screening", screen, 0)]
        vn = 1
        d0 = rand
        while d0 <= today and vn <= dus[0]["cycles"]:
            seq.append((f"Cycle {vn}", d0, vn))
            d0 = d0 + timedelta(days=cyc_len + random.randint(-3, 3))
            vn += 1
        for desc, vd, vn in seq:
            for d in dus:
                visit_rows.append(dict(
                    protocol=p, country=r["Country"], center=r["Center"], site=r["Center"],
                    subject_id=subject_id, subject_status="Active", arm=arm,
                    arm_description=f"{arm} group",
                    cohort=r["Cohort"], cohort_description=r["Cohort"],
                    visit_number=vn,
                    visit_description="Randomization/Cycle 1 Day 1" if desc == "Cycle 1" else desc,
                    visit_date=vd.isoformat(), visit_type="Planned",
                    du_description=(d["du"] if desc != "Screening" else ""),
                    kit_id=(f"KIT{random.randint(100000,999999)}" if desc != "Screening" else ""),
                    screening_date=screen.isoformat(), randomization_date=rand.isoformat(),
                    discontinuation_date="",
                ))
write_csv("visit_details.csv", list(visit_rows[0].keys()), visit_rows)

# --------------------------------------------------------------------------- #
# Demand-aware inventory sizing
# Estimate the near-term daily demand (units/day) for each (protocol, center,
# DU) from the enrollment plan + dosing schedule, so starting inventory can be
# stocked in realistic "days of coverage" rather than arbitrary numbers.
#
# A patient in arm A consumes qty(A, DU) units every cycle_length(A) days, i.e.
# qty/cycle_length units/day. We count patients from cohorts active around the
# planning as-of date (2024-01-01) -> enrollment start within ~18 months.
# --------------------------------------------------------------------------- #
AS_OF = date(2024, 1, 1)
# Size opening stock to demand that is genuinely imminent (within ~a lot's
# shelf-life horizon). Cohorts further out are covered by resupply as they
# approach, not by day-one stock -- otherwise stock just expires on the shelf.
NEARTERM_CUTOFF = AS_OF + timedelta(days=120)

def daily_rate(protocol, center, country, du):
    rate = 0.0
    for d in dosing_long:
        if d["protocol"] != protocol or d["du"] != du:
            continue
        pts = sum(
            int(float(r["Patients"]))
            for r in enrollment
            if r["Protocol"] == protocol and r["Center"] == center
            and r["Country"] == country and r["Arm"] == d["arm"]
            and parse_d(r["Enroll_Start"]) <= NEARTERM_CUTOFF
        )
        if pts and d["cycle_length"] > 0:
            rate += pts * d["qty"] / d["cycle_length"]
    return rate

# --------------------------------------------------------------------------- #
# 4. site_inventory.csv  (on-hand at each site, by DU + lot with expiry)
#    Coverage bands create a realistic mix: most sites healthy, a minority tight
#    or critically low so the projection has genuine stockouts to catch.
# --------------------------------------------------------------------------- #
site_inv_rows = []
lot_counter = 0
for (p, center, _c), country in sorted(sites.items()):
    for du in dus_by_protocol.get(p, []):
        lot_counter += 1
        rate = daily_rate(p, center, country, du)
        qtys = [d["qty"] for d in dosing_long if d["protocol"] == p and d["du"] == du]
        per_cycle = max(qtys) if qtys else 1

        u = random.random()
        if u < 0.15:
            coverage = random.uniform(8, 22)     # critical  -> stockout
        elif u < 0.32:
            coverage = random.uniform(30, 52)    # tight     -> at risk
        else:
            coverage = random.uniform(75, 135)   # healthy   -> OK

        if rate > 0:
            base = max(1, int(round(rate * coverage)))
        else:  # no near-term demand: keep a token amount on the shelf
            base = max(1, int(round(per_cycle * random.uniform(1, 4))))

        retest = AS_OF + timedelta(days=random.choice([120, 180, 270, 365, 540]))
        site_inv_rows.append(dict(
            protocol_id=p, center_number=center, country_name=country,
            du_description=du, inventory_status="Inventory_Available",
            qa_status="Released", quantity=base,
            retest_date=retest.isoformat(), lot_id=lot_id(p, lot_counter),
        ))
write_csv("site_inventory.csv", list(site_inv_rows[0].keys()), site_inv_rows)

# --------------------------------------------------------------------------- #
# 5. depot_inventory.csv  (central/regional depot stock feeding the sites)
#    Depots hold a bulk buffer sized to total downstream demand so resupply can
#    actually keep healthy sites healthy.
# --------------------------------------------------------------------------- #
DEPOTS = {  # country -> depot
    "USA": "US Central Depot", "Canada": "US Central Depot",
    "Mexico": "US Central Depot", "Argentina": "US Central Depot",
    "Korea": "APAC Depot", "Japan": "APAC Depot", "Japan ": "APAC Depot",
    "Israel": "EMEA Depot",
}
def program_units(protocol, du):
    """Total units of a DU the whole program will ever dispense (all cohorts)."""
    total = 0.0
    for d in dosing_long:
        if d["protocol"] != protocol or d["du"] != du:
            continue
        pts = sum(int(float(r["Patients"])) for r in enrollment
                  if r["Protocol"] == protocol and r["Arm"] == d["arm"])
        total += pts * d["qty"] * d["cycles"]
    return total

depot_inv_rows = []
for p in PROTOCOLS:
    p_countries = sorted({c for (pp, _cn, _c), c in sites.items() if pp == p})
    depots = sorted({DEPOTS.get(c.strip(), "Global Depot") for c in p_countries})
    for depot in depots:
        for du in dus_by_protocol.get(p, []):
            lot_counter += 1
            # Long-dated bulk buffer sized to whole-program demand, so the depot
            # is not the constraint -- site-level under-stocking drives stockouts.
            # (Depot replenishment from manufacturing is out of scope here.)
            base = max(50, int(round(program_units(p, du) * random.uniform(0.6, 1.0))))
            # long-dated (beyond the demo horizon): depot restock/manufacturing
            # is out of scope, so the depot itself should not self-expire here.
            retest = AS_OF + timedelta(days=random.choice([1460, 1825, 2190]))
            depot_inv_rows.append(dict(
                protocol=p, depot_name=depot,
                country_name=depot.split()[0], du_description=du,
                inventory_status="Inventory_Available", qa_status="Released",
                quantity=base, retest_date=retest.isoformat(),
                lot_id=lot_id(p, lot_counter),
            ))
write_csv("depot_inventory.csv", list(depot_inv_rows[0].keys()), depot_inv_rows)

# --------------------------------------------------------------------------- #
# 6. order_details.csv  (historical resupply shipments depot -> site)
# --------------------------------------------------------------------------- #
order_rows = []
order_lot = 0
for (p, center, _c), country in sorted(sites.items()):
    for du in dus_by_protocol.get(p, []):
        # 0-3 historical orders per site/DU
        for _ in range(random.randint(0, 3)):
            order_lot += 1
            od = today - timedelta(days=random.randint(10, 300))
            qtys = [d["qty"] for d in dosing_long if d["protocol"] == p and d["du"] == du]
            per_cycle = max(qtys) if qtys else 1
            qty = max(1, int(round(per_cycle * random.uniform(2, 10))))
            order_rows.append(dict(
                protocol=p, center=center, country_name=country,
                du_description=du, order_year=od.year, order_month=od.month,
                order_date=od.isoformat(), quantity=qty,
                lot_id=lot_id(p, order_lot), status="Shipped",
            ))
order_rows.sort(key=lambda r: (r["protocol"], r["center"], r["order_date"]))
write_csv("order_details.csv", list(order_rows[0].keys()), order_rows)

# --------------------------------------------------------------------------- #
# 7. site_locations.csv  (geo coordinates so sites can be mapped)
#    Representative clinical-hub coordinates per country, with a small
#    deterministic per-center offset so co-located sites don't overlap.
# --------------------------------------------------------------------------- #
COUNTRY_COORDS = {
    "USA":       (39.5, -98.35),   # spread across the US (large jitter below)
    "Canada":    (43.65, -79.38),  # Toronto
    "Israel":    (32.08, 34.78),   # Tel Aviv
    "Mexico":    (19.43, -99.13),  # Mexico City
    "Argentina": (-34.60, -58.38), # Buenos Aires
    "Korea":     (37.57, 126.98),  # Seoul
    "Japan":     (35.68, 139.69),  # Tokyo
}
# Bigger spread for the US so its several centers land in different cities.
US_CITIES = [
    (40.71, -74.01), (34.05, -118.24), (41.88, -87.63), (29.76, -95.37),
    (33.75, -84.39), (39.95, -75.17), (42.36, -71.06), (47.61, -122.33),
]

loc_rows = []
for (p, center, _c), country in sorted(sites.items()):
    cc = country.strip()
    if cc == "USA":
        # deterministic city pick by center number
        base = US_CITIES[int(str(center)[-1]) % len(US_CITIES)]
        jit = 0.6
    else:
        base = COUNTRY_COORDS.get(cc, (0.0, 0.0))
        jit = 0.8
    # deterministic offset from a stable hash of protocol+center
    import hashlib
    h = int(hashlib.md5(f"{p}-{center}".encode()).hexdigest(), 16) % 1000 / 1000.0
    lat = round(base[0] + (h - 0.5) * jit, 4)
    lon = round(base[1] + ((h * 7 % 1) - 0.5) * jit, 4)
    loc_rows.append(dict(
        protocol=p, center=center, country_name=cc,
        latitude=lat, longitude=lon,
    ))
write_csv("site_locations.csv", list(loc_rows[0].keys()), loc_rows)

# --------------------------------------------------------------------------- #
# 8. lanes.csv  (lead time, depot to site, by country; synthetic)
# 9. in_transit.csv  (shipments on the road at the as-of date)
# 10. scenarios/  (disruption windows; opt-in, never loaded by default)
#    A separate random stream, so adding these leaves files 1-7 unchanged.
# --------------------------------------------------------------------------- #
LANES = {"USA": 7, "Canada": 10, "Mexico": 21, "Argentina": 35,
         "Israel": 14, "Korea": 12, "Japan": 12}
write_csv("lanes.csv", ["Country", "Lead_Time_Days"],
          [dict(Country=c, Lead_Time_Days=d) for c, d in sorted(LANES.items())])

rng = random.Random(SEED + 101)
transit_rows = []
for (p, center, _c), country in sorted(sites.items()):
    for du in dus_by_protocol.get(p, []):
        if rng.random() > 0.30:            # about a third of site x DUs have stock moving
            continue
        lane = LANES.get(country.strip(), 21)
        shipped = AS_OF - timedelta(days=rng.randint(1, lane + 3))
        eta = shipped + timedelta(days=lane)          # some are already overdue
        qtys = [d["qty"] for d in dosing_long if d["protocol"] == p and d["du"] == du]
        per_cycle = max(qtys) if qtys else 1
        lot_counter += 1
        transit_rows.append(dict(
            protocol_id=p, center_number=center, country_name=country.strip(),
            du_description=du, quantity=max(1, int(round(per_cycle * rng.uniform(4, 12)))),
            ship_date=shipped.isoformat(), eta=eta.isoformat(),
            retest_date=(AS_OF + timedelta(days=rng.choice([365, 540, 730]))).isoformat(),
            lot_id=lot_id(p, lot_counter),
            origin=DEPOTS.get(country.strip(), "Global Depot"),
        ))
write_csv("in_transit.csv", list(transit_rows[0].keys()), transit_rows)

os.makedirs(os.path.join(OUT, "scenarios"), exist_ok=True)
write_csv(os.path.join("scenarios", "argentina_customs_hold.csv"),
          ["Country", "Start", "End", "Delay_Days", "Known"],
          [dict(Country="Argentina", Start="2024-03-01", End="2024-05-31",
                Delay_Days=28, Known="FALSE")])
write_csv(os.path.join("scenarios", "global_port_strike.csv"),
          ["Country", "Start", "End", "Delay_Days", "Known"],
          [dict(Country="*", Start="2024-09-01", End="2024-10-15",
                Delay_Days=14, Known="FALSE")])

print("\nAll datasets written to:", OUT)
