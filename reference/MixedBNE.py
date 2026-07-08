import matplotlib.pyplot as plt
import numpy as np
import cvxpy as cp
from dataclasses import dataclass, asdict
from typing import List, Tuple, Dict, Any
from scipy.interpolate import CubicSpline
from tqdm import tqdm
import pandas as pd
import os
import pickle
import copy
from math import ceil


@dataclass
class ProsumerParams:
    T: int; B: float; K: float; X: float; lam_under: np.ndarray; lam_over: np.ndarray
@dataclass
class ProsumerType:
    name: str; category: str; omega: np.ndarray; alpha_base: np.ndarray; alpha_flex: float
    b0: float; B: float; K: float; has_battery: bool; has_pv: bool
@dataclass
class Plan:
    s: np.ndarray; d: np.ndarray; k: np.ndarray; p: np.ndarray; b: np.ndarray
@dataclass
class Corner:
    id: int; plan: Plan; tag: str
@dataclass
class StaticBin:
    id: int; category: str; B_rep: float; K_rep: float; alpha_flex_rep: float
    has_battery: bool; has_pv: bool; omega_rep: np.ndarray; alpha_base_rep: np.ndarray
@dataclass
class RepresentativeType:
    static_bin: StaticBin; b0: float; weight: float
    @property
    def name(self): return f"RepType-{self.static_bin.id}"
    @property
    def category(self): return self.static_bin.category
    @property
    def B(self): return self.static_bin.B_rep
    @property
    def K(self): return self.static_bin.K_rep
    @property
    def alpha_flex(self): return self.static_bin.alpha_flex_rep
    @property
    def has_battery(self): return self.static_bin.has_battery
    @property
    def has_pv(self): return self.static_bin.has_pv
    @property
    def omega(self): return self.static_bin.omega_rep
    @property
    def alpha_base(self): return self.static_bin.alpha_base_rep

def getBins(CC,CS,CW,DC,DS,DW):
    nBinsC=ceil((2)/(2*(np.quantile(DC,.75)-np.quantile(DC,.25))*DC.shape[0]**(-1/3)))
    freqC,binsC=np.histogram(DC,bins=nBinsC)
    cumulativeC = np.cumsum(freqC)/1000
    centerC_depth=(binsC[1:]+binsC[:-1])/2
    centerC_curve=np.empty((centerC_depth.shape[0],CC.shape[1]))
    indicesC=np.minimum(np.digitize(DC,binsC),centerC_depth.shape[0])-1
    for i in range(centerC_depth.shape[0]):
        centerC_curve[i]=CC[np.argmin(np.abs(centerC_depth[i]-DC))]

    nBinsS=ceil((2)/(2*(np.quantile(DS,.75)-np.quantile(DS,.25))*DS.shape[0]**(-1/3)))
    freqS,binsS=np.histogram(DS,bins=nBinsS)
    cumulativeS = np.cumsum(freqS)/1000
    centerS_depth=(binsS[1:]+binsS[:-1])/2
    centerS_curve=np.empty((centerS_depth.shape[0],CS.shape[1]))
    indicesS=np.minimum(np.digitize(DS,binsS),centerS_depth.shape[0])-1
    for i in range(centerS_depth.shape[0]):
        centerS_curve[i]=CS[np.argmin(np.abs(centerS_depth[i]-DS))]

    nBinsW=ceil((2)/(2*(np.quantile(DW,.75)-np.quantile(DW,.25))*DW.shape[0]**(-1/3)))
    freqW,binsW=np.histogram(DW,bins=nBinsW)
    cumulativeW = np.cumsum(freqW)/1000
    centerW_depth=(binsW[1:]+binsW[:-1])/2
    centerW_curve=np.empty((centerW_depth.shape[0],CW.shape[1]))
    indicesW=np.minimum(np.digitize(DW,binsW),centerW_depth.shape[0])-1
    for i in range(centerW_depth.shape[0]):
        centerW_curve[i]=CW[np.argmin(np.abs(centerW_depth[i]-DW))]

# NEW CELL
# NEW CELL

# NEW CELL

# NEW CELL

# mpe_simulation_DEBUG.py
import matplotlib.pyplot as plt
import numpy as np
import cvxpy as cp
from dataclasses import dataclass, asdict, field
from typing import List, Tuple, Dict, Any
from scipy.interpolate import CubicSpline
from tqdm import tqdm
import pandas as pd
import os
import pickle
from math import ceil
from math import floor



# ---------------------------- Core Functions ----------------------------

def generate_and_save_population(N, T, population_mix, generation_profiles_u, base_loads_u, 
                                 centerC_curve,centerS_curve,centerW_curve,
                                 cumulativeC,cumulativeS,cumulativeW,
                                 centerC_depth,centerS_depth,centerW_depth,
                                 filename="data/agent_population.csv"):
    """
    (MODIFIED) Implements the 60/40 consumption split.
    (MODIFIED) Arbitrageur has ZERO base load.
    """
    print(f"--- 2. Generating a population of {N} unique agents (with 60/40 split) ---")
    rng = np.random.default_rng(123); agent_types = []
    categories = list(population_mix.keys()); probs = list(population_mix.values())
    assigned_categories = rng.choice(categories, size=N, p=probs)

    dt = 24.0 / T

    for i in range(N):
        category = assigned_categories[i]
        omega_sample = generation_profiles_u[i]; load_sample = base_loads_u[i]

        # --- (NEW 60/40 SPLIT LOGIC) ---
        total_cons_profile = centerC_curve[np.minimum(np.digitize(load_sample,cumulativeC),centerC_depth.shape[0])-1]
        total_daily_energy = np.sum(total_cons_profile) * dt
        alpha_base = total_cons_profile * 0.8
        alpha_flex = total_daily_energy * 0.2
        # --- (END OF NEW LOGIC) ---

        if category == "Solar Prosumer":
            B = rng.uniform(4, 20); K = rng.uniform(3, 8)
            omega = centerS_curve[np.minimum(np.digitize(omega_sample,cumulativeS),centerS_depth.shape[0])-1]
            has_battery=True; has_pv = True

        elif category == "Wind Prosumer":
            B = rng.uniform(8, 22); K = rng.uniform(4, 7)
            omega = centerW_curve[np.minimum(np.digitize(omega_sample,cumulativeW),centerW_depth.shape[0])-1]
            has_battery=True; has_pv = True

        elif category == "Consumer": # 'else' becomes 'elif'
            B, K = 0, 0; omega = np.zeros(T)
            has_battery, has_pv = False, False

        else:
            # This will catch any types we didn't expect
            raise ValueError(f"Unknown category assigned: {category}")

        b0 = rng.uniform(0.1*B, 0.4*B) if has_battery else 0
        agent_types.append(ProsumerType(name=f"Agent-{i} ({category})", category=category, omega=omega, alpha_base=alpha_base, alpha_flex=alpha_flex, b0=b0, B=B, K=K, has_battery=has_battery, has_pv=has_pv))

    # --- (DEBUG) Print 1st agent to check ---
    print("--- (DEBUG) Example agent generated (60/40 split): ---")
    print(agent_types[0])
    print(f"    Mean Base Load (60%): {np.mean(agent_types[0].alpha_base):.2f} kW")
    print(f"    Flex Load Budget (40%): {agent_types[0].alpha_flex:.1f} kWh")
    print(f"    Mean Generation: {np.mean(agent_types[0].omega):.2f} kW")
    print(f"    Battery: {agent_types[0].B:.1f} kWh, {agent_types[0].K:.1f} kW")
    print("--------------------------------------")

    return agent_types

def solve_greedy_corner(th: ProsumerType, par: ProsumerParams, r_price: np.ndarray, c_price: np.ndarray) -> Plan:
    # This greedy heuristic is myopic and NOT used by the new solver.
    # We keep it here for legacy/comparison, but it is NOT the MPC solver.
    print("--- (DEBUG) WARNING: solve_greedy_corner (myopic heuristic) was called! ---")
    T=par.T; dt=24.0/T if T>0 else 1.0;
    # ... (rest of legacy greedy code) ...
    s,d,p_flex=np.zeros(T),np.zeros(T),np.zeros(T); b=np.zeros(T+1)
    current_par_B = th.B; current_par_K = th.K
    if th.has_battery: b[0]=th.b0; b[1:]=th.b0
    p_flex_rem=th.alpha_flex; sell_thresh=np.percentile(r_price,75); buy_thresh=np.percentile(c_price,25)
    for t in sorted(range(T),key=lambda i:r_price[i],reverse=True):
        if r_price[t]<sell_thresh: continue
        max_discharge=min(current_par_K,b[t]/dt) if th.has_battery and dt>0 else 0
        avail_kw=(th.omega[t]-th.alpha_base[t])+max_discharge
        if avail_kw>1e-6: s[t]=min(avail_kw,par.X)
        if th.has_battery: k_dispatch=(th.omega[t]-th.alpha_base[t])-s[t]; actual_k=np.clip(k_dispatch,-max_discharge,0); b[t+1:]+=actual_k*dt
    for t in sorted(range(T),key=lambda i:c_price[i]):
        if c_price[t]>buy_thresh or s[t]>1e-6: continue
        room_in_batt=current_par_B-b[t] if th.has_battery else 0
        max_charge=min(current_par_K,room_in_batt/dt) if th.has_battery and dt>0 else 0
        p_flex_rem_kw=p_flex_rem/dt if dt>0 else 0; pot_demand=max_charge+p_flex_rem_kw
        if pot_demand>1e-6:
            d[t]=min(pot_demand,par.X); p_flex_buy=min(d[t],p_flex_rem_kw); p_flex[t]=p_flex_buy; p_flex_rem-=p_flex_buy*dt
            if th.has_battery: k_dispatch=d[t]-p_flex[t]; actual_k=np.clip(k_dispatch,0,max_charge); b[t+1:]+=actual_k*dt
    final_b,k=np.zeros(T),np.zeros(T); current_b=th.b0 if th.has_battery else 0.0; p_flex=np.zeros(T); p_flex_rem=th.alpha_flex
    for t in range(T):
        internal_pwr=th.omega[t]+(min(current_par_K*dt,current_b)/dt if th.has_battery and dt>0 else 0)
        p_needed_kw=p_flex_rem/dt if dt>0 else 0; p_from_internal=min(p_needed_kw,internal_pwr); p_flex[t]+=p_from_internal; p_flex_rem-=p_from_internal*dt
        p_needed_kw=p_flex_rem/dt if dt>0 else 0; p_from_grid=min(p_needed_kw,d[t]); p_flex[t]+=p_from_grid; p_flex_rem-=p_from_grid*dt
        net_trade=s[t]-d[t]; k_t=th.omega[t]-th.alpha_base[t]-p_flex[t]-net_trade
        if th.has_battery:
            max_k=min(current_par_K,(current_par_B-current_b)/dt if dt>0 else 0); min_k=-min(current_par_K,current_b/dt if dt>0 else 0)
            k[t]=np.clip(k_t,min_k,max_k); current_b+=k[t]*dt; final_b[t]=current_b
    return Plan(s,d,k,th.alpha_base+p_flex,final_b)

def initialize_dispersed_bank(
    th: ProsumerType,
    par: ProsumerParams,
    num_corners=50,
    seed=0,
    T_epoch: int = -1,
    L_horizon: int = 1,
    GAMMA_EPOCH: float = 0.98 # (NEW) Pass discounting factor
) -> List[Corner]:
    """
    (MODIFIED) Now passes T_epoch, L_horizon, and GAMMA_EPOCH to the solver.
    th and par are expected to be for the FULL horizon (H = T_epoch * L_horizon).
    """

    print(f"    (DEBUG) Bank Gen for: {th.name}")
    print(f"        > B: {th.B:.1f} kWh, K: {th.K:.1f} kW, b0: {th.b0:.1f} kWh")
    print(f"        > Horizon: {L_horizon} epochs, T_epoch: {T_epoch} steps, Gamma (epoch): {GAMMA_EPOCH}")
    print(f"        > Avg Load (60%): {np.mean(th.alpha_base):.2f} kW, Total Flex (40%): {th.alpha_flex:.1f} kWh, Avg Gen: {np.mean(th.omega):.2f} kW")

    H = par.T # Total horizon length
    if T_epoch == -1:
        T_epoch = H # Backward compatible with debug cell

    h = np.arange(H); rng = np.random.default_rng(seed); bank = []
    solver_fn = solve_optimal_best_response

    def add_to_bank(plan, tag):
        if plan is None or (np.sum(np.abs(plan.s)) + np.sum(np.abs(plan.d))) < 1e-4:
             return
        for corner in bank:
            if np.allclose(corner.plan.s, plan.s) and np.allclose(corner.plan.d, plan.d): return
        bank.append(Corner(id=len(bank), plan=plan, tag=tag))

    lam_min, lam_max = par.lam_under.min(), par.lam_over.max(); spread = 0.02

    # (MODIFIED) Pass new args to the solver
    solver_args = {'T_epoch': T_epoch, 'L_horizon': L_horizon, 'GAMMA_EPOCH': GAMMA_EPOCH}
    add_to_bank(solver_fn(th, par, par.lam_under, par.lam_over, **solver_args), "core_no_trade")
    add_to_bank(solver_fn(th, par, np.full(H, lam_max), np.full(H, lam_max+spread), **solver_args), "core_max_sell")
    add_to_bank(solver_fn(th, par, np.full(H, lam_min-spread), np.full(H, lam_min), **solver_args), "core_max_buy")

    num_random = num_corners - len(bank)
    for _ in range(num_random):
        num_knots = rng.integers(4, 8); knot_x = np.linspace(0, H-1, num_knots)
        knot_y = rng.uniform(lam_min, lam_max, num_knots); cs = CubicSpline(knot_x, knot_y)
        c_price = cs(h); r_price = c_price - spread
        add_to_bank(solver_fn(th, par, np.clip(r_price,0,None), np.clip(c_price,0,None), **solver_args), "rand_smooth")

    print(f"        > Generated {len(bank)} plans.")
    return bank

def find_multitype_coordination_strategy(
    banks: List[List[Corner]],
    type_probs: List[float],
    par: ProsumerParams,
    regularization_strength: float = 1e-4,
    GAMMA_EPOCH: float = 0.98, # (NEW)
    T_epoch: int = -1        # (NEW)
) -> Dict:
    """
    (MODIFIED) Applies discounting to the planner's objective function
    to be consistent with the agents' objectives.
    """
    print("\n--- (Stage iii) Finding joint strategy via Regularized Welfare Maximization QP ---")
    H = par.T # Horizon length

    # (NEW) Calculate discount vector for planner's objective
    if T_epoch == -1: T_epoch = H
    if T_epoch > 0:
        GAMMA_STEP = GAMMA_EPOCH**(1.0 / T_epoch)
    else:
        GAMMA_STEP = 1.0
    gamma_vec = np.array([GAMMA_STEP**t for t in range(H)])
    print(f"    (DEBUG) Planner QP using Gamma (epoch): {GAMMA_EPOCH}, Gamma (step): {GAMMA_STEP:.6f}")
    # --- (END NEW) ---

    num_types = len(banks); total_expected_supply, total_expected_demand = 0, 0
    variables, constraints = [], []
    price_constraint = None
    has_valid_banks = False
    for i in tqdm(range(num_types), desc="Building QP Problem"):
        bank = banks[i]
        if not bank: variables.append(None); continue
        has_valid_banks = True
        prob = type_probs[i]; K = len(bank)
        S_matrix = np.stack([c.plan.s for c in bank], axis=1); D_matrix = np.stack([c.plan.d for c in bank], axis=1)
        sigma_j = cp.Variable(K, nonneg=True, name=f"sigma_type_{i}"); variables.append(sigma_j)
        constraints.append(cp.sum(sigma_j) == 1)
        total_expected_supply += prob * (S_matrix @ sigma_j); total_expected_demand += prob * (D_matrix @ sigma_j)

    if not has_valid_banks:
         raise RuntimeError("No strategies generated for any active type.")

    y_bar = total_expected_supply - total_expected_demand
    y_plus = cp.Variable(H, nonneg=True, name="y_plus"); y_minus = cp.Variable(H, nonneg=True, name="y_minus")

    # (MODIFIED) Apply discount vector to welfare calculation
    lam_under_discounted = np.multiply(gamma_vec, par.lam_under)
    lam_over_discounted = np.multiply(gamma_vec, par.lam_over)
    linear_welfare = cp.sum(lam_under_discounted @ y_plus - lam_over_discounted @ y_minus)

    # (MODIFIED) Also discount the regularizer to keep it consistent
    y_bar_discounted = cp.multiply(gamma_vec, y_bar)
    regularizer = cp.sum_squares(y_bar_discounted[1:] - y_bar_discounted[:-1])

    objective = cp.Maximize(linear_welfare - regularization_strength * regularizer)
    price_constraint = (y_bar == y_plus - y_minus)
    constraints.append(price_constraint)

    problem = cp.Problem(objective, constraints)
    print(f"Solving Welfare Maximization QP (H={H} steps)...");
    problem.solve(solver=cp.OSQP, verbose=False)

    if problem.status not in ["optimal", "optimal_inaccurate"]:
        print(f"!!! WARNING: QP solve failed or was inaccurate. Status: {problem.status} !!!")
        if not any(v is not None and v.value is not None for v in variables): raise RuntimeError(f"QP failed: {problem.status}")
    else:
        print("Welfare Maximization QP solution found successfully.")
        print(f"    (DEBUG) QP Problem Status: {problem.status}")
        print(f"    (DEBUG) Optimal Welfare (discounted, pre-reg): {linear_welfare.value:.2f}")

    equilibrium_prices_raw_discounted = price_constraint.dual_value
    if equilibrium_prices_raw_discounted is None:
        print("    (DEBUG) ERROR: Could not retrieve dual variables. Skipping indifference check.")
        equilibrium_prices_undiscounted = np.zeros(H)
    else:
        # (MODIFIED) Dual prices are discounted. We must "un-discount" them
        # to get the nominal prices for the indifference check.
        equilibrium_prices_correct_discounted = -equilibrium_prices_raw_discounted
        equilibrium_prices_undiscounted = np.divide(equilibrium_prices_correct_discounted, gamma_vec,
                                                     out=np.zeros_like(gamma_vec), where=gamma_vec!=0)

    print(f"    (DEBUG) Mean Equilibrium Price (Nominal/Undiscounted): {np.mean(equilibrium_prices_undiscounted):.4f}")

    return {
        "x_by_type": [var.value if var is not None else None for var in variables],
        "banks_by_type": banks,
        "par": par,
        # (MODIFIED) Return the nominal (undiscounted) prices
        "equilibrium_prices": equilibrium_prices_undiscounted
    }

def project_plan_to_agent(
    original_plan_H: Plan,
    agent_H: ProsumerType,
    par_H: ProsumerParams,
    centerC_curve,
    L_horizon: int = 1
) -> Plan:
    """
    (MODIFIED) Projects a full-horizon plan (H) onto a full-horizon agent.
    """
    H = par_H.T
    T_epoch = H // L_horizon
    dt = 24.0 / T_epoch

    new_s,new_d,new_k,new_b,new_p=(np.zeros(H) for _ in range(5)); soc=agent_H.b0

    # --- Project Flexible Consumption Profile ---
    avg_total_cons_profile = np.mean(centerC_curve, axis=0) # Global dependency
    avg_base_rep_T = avg_total_cons_profile * 0.6

    avg_base_rep_H = np.tile(avg_base_rep_T, L_horizon)

    p_flex_generic_profile_H = original_plan_H.p - avg_base_rep_H
    total_flex_energy_generic_H = np.sum(p_flex_generic_profile_H) * dt

    if total_flex_energy_generic_H < 1e-6:
        p_flex_agent_profile_H = np.zeros(H)
    else:
        scaling_factor = agent_H.alpha_flex / total_flex_energy_generic_H # agent_H.alpha_flex is already L*budget
        p_flex_agent_profile_H = p_flex_generic_profile_H * scaling_factor

    p_flex_agent_profile_H = np.maximum(0, p_flex_agent_profile_H)
    new_p_total_H = agent_H.alpha_base + p_flex_agent_profile_H # agent_H.alpha_base is already tiled

    # --- Project s, d, k over the full horizon ---
    for t in range(H):
        k_t = original_plan_H.k[t]
        if agent_H.has_battery:
            max_charge_kw = min(agent_H.K, (agent_H.B - soc)/dt if dt > 0 else 0)
            max_discharge_kw = -min(agent_H.K, soc/dt if dt > 0 else 0)
            k_t = np.clip(k_t, max_discharge_kw, max_charge_kw)
        else:
            k_t = 0.0

        net_power = (agent_H.omega[t] + k_t) - new_p_total_H[t]

        s_t = 0.0; d_t = 0.0
        if net_power > 0:
            s_t = min(net_power, par_H.X)
        else:
            d_t = min(-net_power, par_H.X)

        k_final = (new_p_total_H[t] + s_t) - (d_t + agent_H.omega[t])

        if agent_H.has_battery:
            max_charge_kw = min(agent_H.K, (agent_H.B - soc)/dt if dt > 0 else 0)
            max_discharge_kw = -min(agent_H.K, soc/dt if dt > 0 else 0)
            k_final_clipped = np.clip(k_final, max_discharge_kw, max_charge_kw)
            new_k[t] = k_final_clipped
            soc += new_k[t] * dt
            new_b[t] = soc
        else:
            new_k[t] = 0.0

        new_s[t] = s_t
        new_d[t] = d_t
        new_p[t] = new_p_total_H[t]

    return Plan(s=new_s, d=new_d, k=new_k, p=new_p, b=new_b)


def define_static_bins(T: int, profilesC, profilesS, profilesW) -> List[StaticBin]:
    """
    (MODIFIED) Implements the 80/20 split. Three bins: Solar, Wind, Consumer.
    T here is T_epoch (e.g., 96 steps).
    """
    print("--- 3. Defining J static hardware bins (H) (with 80/20 split) ---")
    static_bins = []

    dt = 24.0 / T
    avg_total_cons_profile = np.mean(profilesC, axis=0)
    avg_total_energy = np.sum(avg_total_cons_profile) * dt

    # --- (MODIFICATION) ---
    REP_FIXED_PROFILE = avg_total_cons_profile * 0.8 # Was 0.6
    REP_FLEX_BUDGET = avg_total_energy * 0.2       # Was 0.4
    # --- (END MODIFICATION) ---

    avg_S_profile = np.mean(profilesS, axis=0)
    avg_W_profile = np.mean(profilesW, axis=0)

    print(f"    (DEBUG) Rep. Bin Avg Total Energy = {avg_total_energy:.2f} kWh.")
    print(f"    (DEBUG) Rep. Bin Fixed Profile (80%) avg = {np.mean(REP_FIXED_PROFILE):.2f} kW")
    print(f"    (DEBUG) Rep. Bin Flex Budget (20%) = {REP_FLEX_BUDGET:.2f} kWh")

    # Solar prosumer (id=0)
    static_bins.append(
        StaticBin(
            id=0,
            category="Solar Prosumer",
            B_rep=12,
            K_rep=5.5,
            alpha_flex_rep=REP_FLEX_BUDGET, # Uses new 20% budget
            has_battery=True,
            has_pv=True,
            omega_rep=avg_S_profile,
            alpha_base_rep=REP_FIXED_PROFILE, # Uses new 80% base
        )
    )

    # Wind prosumer (id=1)
    static_bins.append(
        StaticBin(
            id=1,
            category="Wind Prosumer",
            B_rep=15,
            K_rep=5.5,
            alpha_flex_rep=REP_FLEX_BUDGET, # Uses new 20% budget
            has_battery=True,
            has_pv=True,
            omega_rep=avg_W_profile,
            alpha_base_rep=REP_FIXED_PROFILE, # Uses new 80% base
        )
    )

    # Consumer (id=2)
    static_bins.append(
        StaticBin(
            id=2,
            category="Consumer",
            B_rep=0,
            K_rep=0,
            alpha_flex_rep=REP_FLEX_BUDGET, # Uses new 20% budget
            has_battery=False,
            has_pv=False,
            omega_rep=np.zeros(T),
            alpha_base_rep=REP_FIXED_PROFILE, # Uses new 80% base
        )
    )

    print(f"    (DEBUG) Created {len(static_bins)} static bins.")
    print(
        f"    (DEBUG) Consumer bin avg load: {np.mean(static_bins[2].alpha_base_rep):.2f} kW, "
        f"flex: {static_bins[2].alpha_flex_rep:.1f} kWh"
    )
    print(
        f"    (DEBUG) Solar bin avg load: {np.mean(static_bins[0].alpha_base_rep):.2f} kW, "
        f"avg gen: {np.mean(static_bins[0].omega_rep):.2f} kW, flex: {static_bins[0].alpha_flex_rep:.1f} kWh"
    )
    print(
        f"    (DEBUG) Wind bin avg load: {np.mean(static_bins[1].alpha_base_rep):.2f} kW, "
        f"avg gen: {np.mean(static_bins[1].omega_rep):.2f} kW, flex: {static_bins[1].alpha_flex_rep:.1f} kWh"
    )
    return static_bins


def assign_agent_to_bin(agent: ProsumerType, static_bins: List[StaticBin]) -> int:
    for bin_ in static_bins:
        if agent.category == bin_.category: return bin_.id
    raise ValueError(f"Agent {agent.name} (Cat: {agent.category}) could not be assigned to a bin.")

def cluster_population_by_state(all_agents: List[ProsumerType], static_bins: List[StaticBin]) -> List[RepresentativeType]:
    J = len(static_bins); N = len(all_agents); agents_in_bin = [[] for _ in range(J)]; b0_in_bin = [[] for _ in range(J)]
    for agent in all_agents:
        bin_id = assign_agent_to_bin(agent, static_bins)
        agents_in_bin[bin_id].append(agent); b0_in_bin[bin_id].append(agent.b0)
    representative_types_e = []
    for j, bin_ in enumerate(static_bins):
        num_in_bin = len(agents_in_bin[j])
        if num_in_bin == 0: continue
        weight_j = num_in_bin / N; b0_j_e = np.mean(b0_in_bin[j])
        representative_types_e.append(RepresentativeType(static_bin=bin_, b0=b0_j_e, weight=weight_j))
    return representative_types_e

def solve_optimal_best_response(
    th: ProsumerType,
    par: ProsumerParams,
    r_price: np.ndarray,
    c_price: np.ndarray,
    T_epoch: int = -1,
    L_horizon: int = 1,
    GAMMA_EPOCH: float = 0.98 # Per-epoch discount factor
) -> Plan:
    """
    (MODIFIED) Testing suggestion 3(b):
    The *only* change is to REMOVE the terminal battery constraint
    (b[H] >= th.b0).

    The per-epoch flex load constraint remains UNCHANGED.
    """
    H = par.T # Total horizon steps (e.g., 96 * 3 = 288)

    if T_epoch == -1:
        T_epoch = H # Backward compatibility

    dt = 24.0 / T_epoch # dt is 15 minutes (0.25h)

    # --- 1. Define Discounting Vector ---
    if T_epoch > 0:
        GAMMA_STEP = GAMMA_EPOCH**(1.0 / T_epoch)
    else:
        GAMMA_STEP = 1.0
    gamma_vec = np.array([GAMMA_STEP**t for t in range(H)])
    r_price_discounted = np.multiply(gamma_vec, r_price)
    c_price_discounted = np.multiply(gamma_vec, c_price)
    # --- (END) ---

    s = cp.Variable(H, nonneg=True, name="s")
    d = cp.Variable(H, nonneg=True, name="d")
    p_flex = cp.Variable(H, nonneg=True, name="p_flex")

    k = cp.Variable(H, name="k")
    b = cp.Variable(H + 1, name="b")

    constraints = []

    # (Objective now uses discounted prices)
    grid_profit = (s @ r_price_discounted - d @ c_price_discounted) * dt
    objective = cp.Maximize(grid_profit)

    # 1. Power Balance (for all H timesteps):
    power_balance = th.omega + k - p_flex - s + d == th.alpha_base
    constraints.append(power_balance)

    # 2. Flexible Load Total (Per-Epoch Constraint)
    # --- (THIS IS UNCHANGED, as per our discussion) ---
    epoch_flex_budget = th.alpha_flex / L_horizon # The budget for ONE epoch

    for i in range(L_horizon):
        start, end = i * T_epoch, (i + 1) * T_epoch
        constraints.append(cp.sum(p_flex[start:end]) * dt == epoch_flex_budget)

    # 3. Grid Trade Limits (for all H timesteps)
    constraints.append(s <= par.X)
    constraints.append(d <= par.X)

    # 4. Battery Physics (for all H timesteps)
    if th.has_battery:
        constraints.append(b[0] == th.b0) # Initial state
        for t in range(H):
            constraints.append(b[t+1] == b[t] + k[t] * dt) # SoC update
            constraints.append(k[t] >= -th.K) # Max discharge rate
            constraints.append(k[t] <= th.K) # Max charge rate
            constraints.append(b[t+1] <= th.B) # Max capacity
            constraints.append(b[t+1] >= 0)   # Min capacity

        # --- (MODIFICATION) ---
        # The terminal constraint 'constraints.append(b[H] >= th.b0)'
        # has been REMOVED as requested.
        # The agent is now free to end the horizon with any battery level.
        # --- (END MODIFICATION) ---

    else:
        constraints.append(k == 0)
        constraints.append(b == 0)

    problem = cp.Problem(objective, constraints)

    problem.solve(solver=cp.ECOS, verbose=False)

    if problem.status not in ["optimal", "optimal_inaccurate"]:
        # ... (Failsafe plan logic remains the same) ...
        print(f"      (DEBUG) LP Solver FAILED for {th.name}: {problem.status}")
        s_fail = np.maximum(0, th.omega - th.alpha_base)
        d_fail = np.maximum(0, th.alpha_base - th.omega)
        return Plan(s=s_fail, d=d_fail, k=np.zeros(H),
                    p=th.alpha_base, b=np.full(H, th.b0))

    s_val = s.value if s.value is not None else np.zeros(H)
    d_val = d.value if d.value is not None else np.zeros(H)
    k_val = k.value if k.value is not None else np.zeros(H)
    p_flex_val = p_flex.value if p_flex.value is not None else np.zeros(H)
    b_val = b.value[1:] if b.value is not None else np.full(H, th.b0)

    return Plan(s=s_val, d=d_val, k=k_val,
                p=p_flex_val + th.alpha_base, b=b_val)

def check_indifference_principle(
    representative_types: List[RepresentativeType],
    banks: List[List[Corner]],
    strategies: List[np.ndarray],
    prices: np.ndarray, # (Note: these are nominal/undiscounted)
    par: ProsumerParams,
    T_epoch: int = -1,
    L_horizon: int = 1, # (FIXED) Added the missing argument
    GAMMA_EPOCH: float = 0.98 # (NEW)
):
    """
    (MODIFIED) Checks indifference over the full horizon using
    the same discounted profit calculation as the agent's LP.
    """
    print("\n--- (DEBUG) Checking BNE Indifference Principle (Full Horizon, Discounted) ---")

    H = par.T
    if T_epoch == -1: T_epoch = H
    dt = 24.0 / T_epoch

    # (NEW) Create the same discount vector the agent used
    if T_epoch > 0:
        GAMMA_STEP = GAMMA_EPOCH**(1.0 / T_epoch)
    else:
        GAMMA_STEP = 1.0
    gamma_vec = np.array([GAMMA_STEP**t for t in range(H)])
    # (NEW) Calculate discounted prices for the check
    prices_discounted = np.multiply(gamma_vec, prices)
    # --- (END NEW) ---

    for i, rep_type in enumerate(representative_types):
        bank = banks[i]
        sigma_j = strategies[i]
        if not bank or sigma_j is None: continue
        print(f"\n  Checking Type: {rep_type.name} ({rep_type.weight*100:.1f}%)")
        profits = []
        for k, corner in enumerate(bank):
            plan = corner.plan # This is an H-length plan
            # (MODIFIED) Use discounted prices for profit calculation
            grid_revenue = np.sum(plan.s * prices_discounted) * dt
            grid_cost = np.sum(plan.d * prices_discounted) * dt
            profit = grid_revenue - grid_cost
            profits.append(profit)

        profits = np.array(profits)
        sigma_j_clean = np.maximum(sigma_j, 0)
        sigma_sum = np.sum(sigma_j_clean)
        if sigma_sum < 1e-6:
             print("    > No plans in support (sigma_j is zero)."); continue
        sigma_j_norm = sigma_j_clean / sigma_sum
        max_profit = np.max(profits)
        expected_profit = np.sum(sigma_j_norm * profits)
        print(f"    > Max DISCD profit in bank: {max_profit: .4f}")
        print(f"    > Expected DISCD profit (from sigma): {expected_profit: .4f}")
        support_indices = np.where(sigma_j_norm > 0.001)[0]
        if len(support_indices) == 0:
            print("    > No plans in support (sigma_j is uniform or empty)."); continue
        profits_in_support = profits[support_indices]
        print(f"    > {len(support_indices)} plans in support (sigma > 0.1%).")
        print(f"    > DISCD Profits of plans IN support: [Min: {np.min(profits_in_support):.4f}, Max: {np.max(profits_in_support):.4f}]")
        if np.allclose(profits_in_support, max_profit, atol=1e-2):
            print("    > ✅ Indifference principle HOLDS (approx.)")
        else:
            print("    > ❌ Indifference principle VIOLATED.")
            for k in support_indices:
                print(f"       - Plan {k} (sigma={sigma_j_norm[k]:.2f}) has profit {profits[k]:.4f}")
            non_support_indices = np.where(sigma_j_norm <= 0.001)[0]
            if len(non_support_indices) > 0:
                profits_outside_support = profits[non_support_indices]
                if np.any(profits_outside_support > max_profit + 1e-2):
                    print("    > ❌ VIOLATION: A better plan exists but was NOT chosen!")
                    print(f"    >    Best plan outside support has profit: {np.max(profits_outside_support):.4f}")
    print("--- End of Indifference Check ---")


def MBNE(centerC_curve, centerS_curve, centerW_curve,
         cumulativeC,cumulativeS,cumulativeW,centerC_depth,centerS_depth,centerW_depth,
         T,N,NUM_EPOCHS,
         SP=0.0886,HP=0.2146,HC= 0.1696,
         filepath = 'mpe_simulation_results.pkl',save=False):
        # --- 1. Simulation Setup ---
    T_EPOCH = 24*4  # Timesteps per day (96)
    L_HORIZON = 3   # (MPC) Lookahead of 3 days (Current day + 2 future days)
    H_HORIZON = T_EPOCH * L_HORIZON # Total steps in optimization (288)

    # N = 1000        # Number of agents
    # NUM_EPOCHS = 20  # (MPC) Total days to simulate (e.g., 5 days) # QUANTOS DIAS

    # (NEW) Define the per-epoch discount factor
    GAMMA_EPOCH = 0.98

    print(f"=== Starting MPC Simulation: {NUM_EPOCHS} epochs (days) ===")
    print(f"    Lookahead (L): {L_HORIZON} epochs")
    print(f"    Steps per epoch (T): {T_EPOCH}")
    print(f"    Total steps in solver (H): {H_HORIZON}")
    print(f"    Discount Factor (per epoch): {GAMMA_EPOCH}")

    # --- 2. Define Prices ---
    print("--- 1b. Creating Dynamic Time-of-Day Prices ---")
    lam_under_T = np.full(T_EPOCH, SP)
    lam_over_T = np.ones(T_EPOCH)
    hours = np.arange(0, 24, 24 / T_EPOCH)
    hourCreusePleine = ['c','c','c','c','c','c','p','p','p','p','p','p','c','p','p','p','p','p','p','p','p','p','p','c']
    
    for j in range(T_EPOCH):
        hour_of_day = floor(hours[j])
        if hourCreusePleine[hour_of_day] == 'p': lam_over_T[j] = HP
        else: lam_over_T[j] = HC

    # (MPC) Create params for a single epoch (T) and the full horizon (H)
    # par_T is not strictly needed by the solver, but useful for context
    par_T = ProsumerParams(T=T_EPOCH, B=0, K=0, X=2.5, lam_under=lam_under_T, lam_over=lam_over_T) # VALOR_X_ transmission

    par_H = ProsumerParams(T=H_HORIZON, B=0, K=0, X=2.5,
                           lam_under=np.tile(lam_under_T, L_HORIZON),
                           lam_over=np.tile(lam_over_T, L_HORIZON))

    print(f"    > lam_under set to: {lam_under_T[0]}")
    print(f"    > lam_over (peak): {HP}, (off-peak): {HC}")


    # --- 3. Load Profiles & Define Mix ---
    rng_gen = np.random.default_rng(42)
    generation_profiles_u = np.random.uniform(0,1,N)
    base_loads_u = np.random.uniform(0,1,N)
    # We use the 30/30/40 split suggested for simplicity.
    population_mix = {
        "Solar Prosumer": 0.30,
        "Wind Prosumer":  0.30,
        "Consumer":       0.40,
    }

    print(f"--- Population Mix Set To: {population_mix} ---")

    # --- 4. Generate Population (Agents have T-length profiles) ---
    all_agents = generate_and_save_population(N, T, population_mix, generation_profiles_u, base_loads_u, 
                                 centerC_curve,centerS_curve,centerW_curve,
                                 cumulativeC,cumulativeS,cumulativeW,
                                 centerC_depth,centerS_depth,centerW_depth,)

    # (NEW) Save the initial state of all agents for plotting
    all_agents_initial_state = copy.deepcopy(all_agents)

    # --- 5. Define Static Bins (Bins have T-length profiles) ---
    static_bins = define_static_bins(T_EPOCH, centerC_curve, centerS_curve, centerW_curve)

    # --- 6. Prepare Results Storage ---
    all_epoch_results = [] # This will store the *implemented* T-step plans

    print(f"\n=== Starting MPC Rolling Horizon for {NUM_EPOCHS} Epochs ===")

    # --- 7. Run Epoch Loop (Rolling Horizon) ---
    for e in range(NUM_EPOCHS):
        print(f"\n--- Epoch {e+1} / {NUM_EPOCHS} ---")

        # (Stage i) Cluster N agents based on their CURRENT b0
        print(f"(Stage i) Clustering {N} agents into state-dependent types...")
        # Note: all_agents is being updated in-place, so this uses the latest b0
        representative_types_T = cluster_population_by_state(all_agents, static_bins)
        print(f"    -> Found {len(representative_types_T)} active types for this epoch:")
        for rep_type in representative_types_T:
              print(f"         - {rep_type.name}: {rep_type.weight*100:.1f}% (avg b0: {rep_type.b0:.2f} kWh)")

        # (Stage ii) Generate H-length strategy banks for J types
        print(f"\n(Stage ii) Generating dynamic strategy banks for J types (H={H_HORIZON} steps)...")
        J_banks = []
        J_weights = []

        for rep_type_T in representative_types_T: # This is a T-length rep type
            # (MPC) Create the H-length representative type for the solver
            th_H = ProsumerType(
                name=rep_type_T.name,
                category=rep_type_T.category,
                omega=np.tile(rep_type_T.omega, L_HORIZON),
                alpha_base=np.tile(rep_type_T.alpha_base, L_HORIZON),
                alpha_flex=rep_type_T.alpha_flex * L_HORIZON, # Scale budget to full horizon
                b0=rep_type_T.b0, # Use current b0
                B=rep_type_T.B,
                K=rep_type_T.K,
                has_battery=rep_type_T.has_battery,
                has_pv=rep_type_T.has_pv
            )

            # (MPC) Call the horizon-aware bank generator
            # (MODIFIED) Pass GAMMA_EPOCH
            bank = initialize_dispersed_bank(
                th_H, par_H,
                num_corners=50, seed=e,
                T_epoch=T_EPOCH, L_horizon=L_HORIZON,
                GAMMA_EPOCH=GAMMA_EPOCH
            )
            J_banks.append(bank)
            J_weights.append(rep_type_T.weight)

        # (Stage iii) Find joint strategy (QP) over H-length plans
        # (MODIFIED) Pass GAMMA_EPOCH and T_epoch
        result = find_multitype_coordination_strategy(
            J_banks, J_weights, par_H,
            regularization_strength=1e-3,
            GAMMA_EPOCH=GAMMA_EPOCH,
            T_epoch=T_EPOCH
        )

        # (DEBUG) Check indifference over H-length plans
        # (MODIFIED) Pass GAMMA_EPOCH
        check_indifference_principle(
            representative_types_T, # (Note: this is just for names/weights)
            result["banks_by_type"],
            result["x_by_type"],
            result["equilibrium_prices"], # H-length prices
            par_H,
            T_epoch=T_EPOCH,
            L_horizon=L_HORIZON,
            GAMMA_EPOCH=GAMMA_EPOCH
        )

        # (Stage iv) Decentralize H-length plans, project, and implement first T steps
        print("\n(Stage iv) Decentralizing plans, projecting, and implementing first epoch...")
        epoch_plans = [] # To store the T-length implemented plans
        rng_sample = np.random.default_rng(e)

        for agent in tqdm(all_agents, desc="Decentralizing"):
            bin_id = assign_agent_to_bin(agent, static_bins)
            rep_type_idx = -1
            for idx, rep_type in enumerate(representative_types_T):
                if rep_type.static_bin.id == bin_id:
                    rep_type_idx = idx
                    break

            if rep_type_idx == -1: continue
            sigma_j = result['x_by_type'][rep_type_idx]
            bank_j = result['banks_by_type'][rep_type_idx]

            if not bank_j or sigma_j is None:
                # Failsafe: create a T-length "do-nothing" plan
                s_fail = np.maximum(0, agent.omega - agent.alpha_base)
                d_fail = np.maximum(0, agent.alpha_base - agent.omega)
                feasible_plan_T = Plan(s=s_fail, d=d_fail, k=np.zeros(T_EPOCH),
                                       p=agent.alpha_base, b=np.full(T_EPOCH, agent.b0))
            else:
                # (MPC) Sample one H-length plan
                sigma_j_norm = np.maximum(sigma_j, 0)
                sigma_sum = sigma_j_norm.sum()
                if sigma_sum > 1e-6: sigma_j_norm = sigma_j_norm / sigma_sum
                else: sigma_j_norm = np.ones(len(bank_j)) / len(bank_j)

                chosen_idx = rng_sample.choice(len(bank_j), p=sigma_j_norm)
                generic_plan_H = bank_j[chosen_idx].plan # This is H-length

                # (MPC) Create an H-length version of the *agent* for projection
                agent_H = ProsumerType(
                    name=agent.name, category=agent.category,
                    omega=np.tile(agent.omega, L_HORIZON),
                    alpha_base=np.tile(agent.alpha_base, L_HORIZON),
                    alpha_flex=agent.alpha_flex * L_HORIZON,
                    b0=agent.b0, B=agent.B, K=agent.K,
                    has_battery=agent.has_battery, has_pv=agent.has_pv
                )

                # (MPC) Project the H-plan onto the H-agent
                feasible_plan_H = project_plan_to_agent(generic_plan_H, agent_H, par_H,centerC_curve, L_horizon=L_HORIZON)

                # (MPC) Extract the first T steps to implement
                feasible_plan_T = Plan(
                    s=feasible_plan_H.s[:T_EPOCH],
                    d=feasible_plan_H.d[:T_EPOCH],
                    k=feasible_plan_H.k[:T_EPOCH],
                    p=feasible_plan_H.p[:T_EPOCH],
                    b=feasible_plan_H.b[:T_EPOCH]
                )

            # (MPC) Update agent's b0 for the *next* epoch
            if agent.has_battery and len(feasible_plan_T.b) > 0:
                agent.b0 = feasible_plan_T.b[-1] # State at end of *first* epoch

            epoch_plans.append({'agent_id': agent.name, 'category': agent.category, 'plan': feasible_plan_T})

        all_epoch_results.append({
            'epoch': e, 'plans': epoch_plans, 'representative_types': representative_types_T,
            'J_strategies': result['x_by_type'], 'J_banks': J_banks,
            'equilibrium_prices': result['equilibrium_prices'] # H-length prices
        })
        print(f"--- Epoch {e+1} Complete. Terminal b0 saved. ---")

    # --- 8. End of Simulation: Save All Results ---
    print(f"\n✅ MPE Simulation complete. All {NUM_EPOCHS} epochs run.")
    
    results_for_plotting = {
        'all_epoch_results': all_epoch_results, 'par': par_T, 'N': N, 'T': T_EPOCH, 'NUM_EPOCHS': NUM_EPOCHS,
        'static_bins': static_bins,
        'all_agents_final_state': all_agents,
        'all_agents_initial_state': all_agents_initial_state, # (NEW) Save initial state
        'L_HORIZON': L_HORIZON,
        'GAMMA_EPOCH': GAMMA_EPOCH
    }
    if save==True:
        with open(filepath, 'wb') as f:
            pickle.dump(results_for_plotting, f)
        print(f"\nAll results saved to '{filepath}'")