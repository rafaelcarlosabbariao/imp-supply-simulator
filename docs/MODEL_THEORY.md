# Model Theory — Monte Carlo simulation over a Markov chain

This tool forecasts investigational-drug (IMP) demand and projects site inventory
by combining two classical ideas: a **Markov chain** that describes how a single
patient moves through a trial, and a **Monte Carlo** loop that runs that chain
many times to turn uncertainty into an expected demand curve.

![Model diagram](assets/model_diagram.svg)

---

## 1. The per-patient Markov chain

A **Markov chain** is a stochastic process that moves between a finite set of
*states*, where the probability of the next state depends **only on the current
state** — not on the full history of how you got there. That "memoryless"
property is the *Markov property*:

$$P(X_{t+1} = s \mid X_t, X_{t-1}, \dots, X_0) = P(X_{t+1} = s \mid X_t)$$

A patient in a clinical trial fits this model naturally. Their state is *where
they are in the dosing schedule*, and what happens next depends only on that:

| State | Meaning | Transitions out |
|---|---|---|
| **Screening** | Enrolled, not yet dosed | → Randomization (`p_rand`), → Screen fail |
| **Randomization / Cycle 1** | First dose dispensed | → Cycle 2 |
| **Cycle k** | On treatment, dispensing each cycle | → Cycle k+1 (continue), → Discontinued |
| **Cycle N** | Final on-treatment cycle | → Completed |
| **Completed** | Finished treatment | *absorbing* |
| **Discontinued / Screen fail** | Left the study | *absorbing* |

Two properties make this a well-formed chain:

- **Absorbing states.** `Completed`, `Discontinued`, and `Screen fail` have no
  outgoing transitions. Every patient's walk eventually terminates in one of
  them, so the simulation is guaranteed to halt.
- **Time-homogeneous transitions.** The per-cycle "continue vs. discontinue"
  probabilities don't change from one cycle to the next, so the transition
  structure is fixed and the chain is easy to reason about.

The **consumption** happens *on the transitions*: every time a patient enters a
dosing visit, the protocol's dispensing units (DUs) for their arm are drawn —
this is what ultimately depletes inventory. The visit *timing* is the cycle
length jittered by a visit window (±3 days by default), so demand lands on
realistic, slightly irregular dates rather than a perfect grid.

> In the code, the state machine lives in
> [`R/simulation.R`](../R/simulation.R): `simulate_enrollment()` seeds the
> `Screening` state with random enrollment dates, and `simulate_visits()` walks
> each patient's chain forward, emitting a dispensing record per DU per cycle.

---

## 2. The Monte Carlo wrapper

One run of the chain is a single *possible* future — this patient enrolled on
this day, discontinued at that cycle. It is not, by itself, a forecast.

**Monte Carlo** simulation makes it one: run the whole system of patients `N`
independent times, each with fresh random draws, then aggregate. By the **Law
of Large Numbers**, the average across trials converges to the *expected* value
of the quantity you care about — here, units dispensed per site, per DU, per
day:

$$\mathbb{E}[D(t)] \approx \frac{1}{N} \sum_{i=1}^{N} D_i(t)$$

where $D_i(t)$ is the units dispensed on day $t$ in trial $i$. The spread across
trials also gives you the *uncertainty* around that expectation, which is what
justifies holding safety stock.

This is the demand signal the supply engine consumes: a smooth expected-demand
curve with an honest sense of its own variance, built from thousands of
individually-plausible patient trajectories.

---

## 2a. Dose titration, and why it is still Markov

Not every protocol doses at target from visit 1. Where the CSP defines a
**titration ladder**, the first `N` visits (usually 6) step the dose up while
the patient tolerates it, hold it where they only partly tolerate it, and step
it back down where they do not. A **missed visit dispenses nothing** and sends
the patient back to their floor, restarting the titration window.

The floor **ratchets**. It starts at rung 1, and the first time a patient
*tolerates once* at the CSP's tolerance rung — attends at that rung and does
not down-titrate — the floor moves up to it permanently. A patient who has
never tolerated the tolerance dose restarts from the ground; one who has
restarts from the tolerance rung.

Read literally, "restart from the ground if they have **never** reached the
tolerance dose" is a statement about a patient's whole history, and so appears
to break the Markov property of §1. It does not. It is Markov on the
**enlarged state**

$$s = (\text{dose rung},\; \text{ratcheted},\; \text{window position})$$

because `ratcheted` is exactly the one bit of history the transition rule
needs. Carrying that bit is what makes both the simulator and the exact
recursion below correct; dropping it is the most likely way to get a
plausible-looking but wrong answer.

**Why supply cares.** A rung is usually a *different dispensing unit*, not just
a different quantity of one — a 15 mg vial and a 100 mg bottle are separate DUs
with separate lots and separate expiry. So titration reallocates demand *across
DUs*, and a restart pulls the low-dose DU months after the depot stopped
forecasting for it. The `(s, S)` reorder point in §4 keys off a **trailing
average** demand rate, which is precisely the estimator that lags that kind of
step change.

**The tolerance rung's effect is not monotone.** Placed at rung 1 the ratchet
is a no-op — the floor already starts there — so every restart goes to ground
and low-dose exposure is at its maximum. Placed at the top rung it almost never
fires before a miss knocks the patient back, so exposure climbs again. The
minimum sits in the middle, where the rung is both reachable and protective. A
study lead who sets the tolerance dose at target to "make them prove it" buys
close to the same low-dose supply exposure as having no ratchet at all.

### Solving it exactly

The enlarged state space is small — `L` rungs × 2 ratchet states × `N+1` window
positions, about 84 states for a six-rung ladder — so the distribution over
states can be propagated forward analytically, one matrix multiply per visit,
instead of being sampled:

$$\pi_{t+1} = \pi_t P, \qquad \mathbb{E}[\text{units at } t] = \pi_t \cdot e$$

`expected_demand()` does this. It is **O(1) in patient count** (1,000 patients
and 10,000,000 cost the same, ~0.0006 s) because it carries a distribution
rather than individuals, and it is exact rather than an estimate.

That matters because the inventory engine collapses the Monte-Carlo
replications to a **mean** before it ever sees them (§4) — so the demand rate
driving the reorder point is a sampling estimate of something with a closed
form. Use the recursion for that rate. Keep Monte Carlo for what genuinely
needs paths: a stockout is a *threshold on a trajectory*, and no expectation
tells you how often the threshold is crossed.

---

## 3. Is this "MCMC"?

Not in the strict sense, and the distinction is worth being precise about:

- **Markov Chain Monte Carlo (MCMC)** — e.g. Metropolis–Hastings or Gibbs
  sampling — is a family of algorithms that *construct* a Markov chain whose
  **stationary distribution is a target probability distribution** you want to
  sample from (typically a Bayesian posterior). The chain is a means to an end:
  a way to draw correlated samples from a distribution you can't sample directly.

- **This model** is **Monte Carlo simulation *of* a Markov process.** The Markov
  chain is the *object being modelled* (a patient's real trajectory), and Monte
  Carlo is used to estimate expectations over it. We are not sampling from a
  posterior; we are forward-simulating a generative process.

So the accurate one-liner is: *"Monte Carlo simulation of a Markovian
patient-state model."* Both concepts — the Markov chain and the Monte Carlo
estimator — are doing real work; they're just composed differently than in a
textbook MCMC sampler. (A natural extension *would* bring in Bayesian/MCMC
machinery: fit the transition probabilities `p_rand`, `p_discontinue` from
historical trial data with a posterior, then propagate that parameter
uncertainty through the forward simulation.)

---

## 4. From demand to inventory

The expected demand curve feeds an **(s, S) inventory policy** with lot expiry
and lead times — the supply half of the tool. That engine is documented
separately in [`METHODOLOGY.md`](METHODOLOGY.md); in brief, for each site × DU it
walks day by day:

1. **expire** lots past their retest date (FEFO — first-expiry-first-out),
2. **dispense** the day's expected demand,
3. **reorder** up to an order-up-to level `S` when the inventory position drops
   below the reorder point `s`, pulling from a depot with a shipping lead time,

and flags each site × DU as **OK / AT RISK / STOCKOUT** with the date it will
first run dry.

The result: a Markov chain describes *one patient*, Monte Carlo turns *many
patients* into an expected demand, and the inventory policy turns that demand
into *actionable stockout warnings* across every site and study.
