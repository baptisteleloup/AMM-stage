# --- FINAL PLOTTING & EXPORTING SCRIPT (COMPREHENSIVE & FIXED) ---

import numpy as np
import matplotlib.pyplot as plt
from dataclasses import dataclass
from typing import List, Tuple, Dict, Any
import seaborn as sns
import pickle
import os
import pandas as pd
import matplotlib.ticker as mticker
from tqdm import tqdm
import matplotlib.cm as cm
from math import ceil

# ---------------------------- Data Structures ----------------------------
@dataclass
class ProsumerParams:
    T: int; B: float; K: float; X: float; lam_under: np.ndarray; lam_over: np.ndarray
@dataclass
class Plan:
    s: np.ndarray; d: np.ndarray; k: np.ndarray; p: np.ndarray; b: np.ndarray
@dataclass
class Corner:
    id: int; plan: Plan; tag: str
@dataclass
class ProsumerType:
    name: str; category: str; omega: np.ndarray; alpha_base: np.ndarray; alpha_flex: float
    b0: float; B: float; K: float; has_battery: bool; has_pv: bool
    depth_cons: float = 0.0; depth_gen: float = 0.0; flex_rate_limit: float = 3.0
@dataclass
class StaticBin:
    id: int; category: str; B_rep: float; K_rep: float; alpha_flex_rep: float
    has_battery: bool; has_pv: bool; omega_rep: np.ndarray; alpha_base_rep: np.ndarray
    depth_cons_rep: float = 0.0; depth_gen_rep: float = 0.0; flex_rate_limit_rep: float = 3.0
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
    @property
    def flex_rate_limit(self): return self.static_bin.flex_rate_limit_rep

class PlotProsumer:
    def __init__(self, plan_dict: Dict, T: int, agent_lookup: Dict, dt: float = None, bin_id: int = -1):
        self.type_category = plan_dict['category']
        self.plan = plan_dict['plan']
        self.name = plan_dict['agent_id']
        self.bin_id = bin_id
        if dt is None: self.dt = 24.0 / T
        else: self.dt = dt
        agent_static_info = agent_lookup.get(self.name)
        if agent_static_info:
            base = agent_static_info.alpha_base
            omega = agent_static_info.omega
            if len(base) < T:
                repeats = ceil(T / len(base))
                self.alpha_base_day = np.tile(base, repeats)[:T]
                self.omega_day = np.tile(omega, repeats)[:T]
            else:
                self.alpha_base_day = base[:T]
                self.omega_day = omega[:T]
        else:
            self.alpha_base_day = np.zeros(T)
            self.omega_day = np.zeros(T)
        if self.plan.s is not None:
            self.plan_s = self.plan.s / self.dt
            self.plan_d = self.plan.d / self.dt
            self.plan_k = self.plan.k / self.dt
            self.plan_b = self.plan.b
            self.plan_p_total = self.plan.p / self.dt
        else:
            self.plan_s = np.zeros(T); self.plan_d = np.zeros(T)
            self.plan_k = np.zeros(T); self.plan_b = np.zeros(T)
            self.plan_p_total = self.alpha_base_day

# ---------------------------- Helper Functions ----------------------------
_CATS = ['Consumer', 'Solar Prosumer', 'Wind Prosumer']
_MARKERS = ['o', 'v', '^', '<', '>', 's', 'p', '*', 'h', 'H', 'D', 'd', 'P', 'X']

def assign_agent_to_bin(agent: ProsumerType, static_bins: List[StaticBin]) -> int:
    best_id = -1; min_dist_l1 = float('inf')
    candidate_bins = [b for b in static_bins if b.category == agent.category]
    if not candidate_bins: return -1
    for bin_ in candidate_bins:
        if agent.category == "Consumer": dist = abs(agent.depth_cons - bin_.depth_cons_rep)
        else: dist = abs(agent.depth_cons - bin_.depth_cons_rep) + abs(agent.depth_gen - bin_.depth_gen_rep)
        if dist < min_dist_l1: min_dist_l1 = dist; best_id = bin_.id
    return best_id

def format_time_axis(ax, T, T_epoch_steps=None):
    if T_epoch_steps is None: T_epoch_steps = T
    intervals_per_hour = max(1, T_epoch_steps // 24)
    total_days = T / T_epoch_steps
    step = 6 if total_days <= 2 else (12 if total_days <= 5 else 24)
    major_ticks = np.arange(0, T + 1, intervals_per_hour * step)
    if T_epoch_steps < T: major_labels = [f"D{int(t/T_epoch_steps)+1} H{int((t % T_epoch_steps)/intervals_per_hour)}" for t in major_ticks]
    else: major_labels = [f"D1 H{int(t/intervals_per_hour)}" for t in major_ticks]
    ax.set_xticks(major_ticks)
    ax.set_xticklabels(major_labels, rotation=45, ha='right',fontsize=18)
    ax.set_xlim(0, T-1)

    for t in range(T_epoch_steps, T, T_epoch_steps): ax.axvline(t - 0.5, color='red', linestyle='--', lw=1)

def _series_from_agent(p: PlotProsumer, key: str, T: int):
    if key == 'net_trade': return p.plan_s - p.plan_d
    elif key == 'consumption': return p.plan_p_total
    elif key == 'flex_consumption': return p.plan_p_total - p.alpha_base_day
    elif key == 'k': return p.plan_k
    elif key == 'b': return p.plan_b
    elif key == 'base_consumption': return p.alpha_base_day
    elif key == 'production': return p.omega_day
    return np.zeros(T)

def amm_prices(S: np.ndarray, D: np.ndarray, lam_u: np.ndarray, lam_o: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    lam_m = 0.5 * (lam_u + lam_o)
    ratio_sd = np.divide(S, D, out=np.zeros_like(S), where=D > 1e-12)
    ratio_ds = np.divide(D, S, out=np.zeros_like(D), where=S > 1e-12)
    c = lam_m + (lam_o - lam_m) * np.maximum(1 - ratio_sd, 0.0)
    r = lam_m - (lam_m - lam_u) * np.maximum(1 - ratio_ds, 0.0)
    return np.clip(r,lam_u,lam_o), np.clip(c,lam_u,lam_o)

def generate_ex_ante_aggregate_samples(J_strategies, J_banks, J_rep_types, par_H, N, L, seed, T_epoch, L_horizon):
    rng = np.random.default_rng(seed); H = par_H.T; dt = 24.0 / T_epoch
    S_all = np.zeros((L, H)); D_all = np.zeros((L, H))
    if not J_strategies or not J_banks or not J_rep_types: return {}, None, None, None, None
    processed_strats = []
    for i, bank in enumerate(J_banks):
        x_i = J_strategies[i]; rep_type = J_rep_types[i]
        if not bank or x_i is None: continue
        probs = np.maximum(x_i, 0.0); probs /= probs.sum() if probs.sum() > 1e-6 else len(bank)
        num_agents = int(round(rep_type.weight * N))
        if num_agents > 0: processed_strats.append({"bank": bank, "probs": probs, "num_agents": num_agents})
    if not processed_strats: return {}, None, None, None, None

    for l in range(L):
        s_total_l = np.zeros(H); d_total_l = np.zeros(H)
        for p_strat in processed_strats:
            counts = rng.multinomial(p_strat["num_agents"], p_strat["probs"])
            for k, count in enumerate(counts):
                if count > 0:
                    plan = p_strat["bank"][k].plan
                    s_total_l += count * plan.s; d_total_l += count * plan.d
        S_all[l, :] = s_total_l / dt; D_all[l, :] = d_total_l / dt

    r_all, c_all = amm_prices(S_all, D_all, par_H.lam_under, par_H.lam_over)
    pct = np.percentile
    bands = {"r_med": pct(r_all, 50, axis=0), "r_lo": pct(r_all, 10, axis=0), "r_hi": pct(r_all, 90, axis=0),
             "c_med": pct(c_all, 50, axis=0), "c_lo": pct(c_all, 10, axis=0), "c_hi": pct(c_all, 90, axis=0)}
    return bands, r_all, c_all, S_all, D_all

# ---------------------------- 1. SoC & Aggregate Plots ----------------------------

def plot_soc_evolution(all_epoch_results: List[Dict], static_bins: List[StaticBin]):
    print("--- Plotting SoC evolution over epochs ---")
    num_epochs = len(all_epoch_results); xh_epoch = np.arange(num_epochs)
    battery_bins = [b for b in static_bins if b.category in _CATS and b.has_battery]
    if not battery_bins: return
    plt.figure(figsize=(12, 6))
    ax = plt.gca()
    cat_data = {}
    for bin_ in battery_bins:
        if bin_.category not in cat_data: cat_data[bin_.category] = []
        avg_soc = []
        for e_data in all_epoch_results:
            soc_vals = [rt.b0 for rt in e_data['representative_types'] if rt.static_bin.id == bin_.id]
            if soc_vals: avg_soc.append(np.mean(soc_vals) / bin_.B_rep * 100)
            else: avg_soc.append(0)
        cat_data[bin_.category].append(avg_soc)

    colors = {'Solar Prosumer': 'orange', 'Wind Prosumer': 'green'}
    for cat, socs in cat_data.items():
        mean_curve = np.mean(np.array(socs), axis=0)
        ax.plot(xh_epoch, mean_curve, 'o-', label=f"{cat} (Avg)", color=colors.get(cat, 'blue'))

    ax.set_title("Evolution of Average Start-of-Epoch SoC"); ax.set_xlabel("Epoch"); ax.set_ylabel("SoC (%)")
    ax.set_ylim(0, 100); ax.set_xticks(xh_epoch); ax.set_xticklabels([str(e+1) for e in xh_epoch])
    ax.legend(); ax.grid(True, linestyle='--', alpha=0.7); plt.tight_layout()

def plot_soc_distribution_histograms(all_epoch_results, all_agents_initial_state):
    print("--- Plotting SoC distribution histograms ---")
    num_epochs = len(all_epoch_results)
    if num_epochs == 0: return
    agent_info = {a.name: {'B': a.B, 'category': a.category, 'b0': a.b0} for a in all_agents_initial_state}
    battery_agents = {name: info for name, info in agent_info.items() if info['B'] > 0 and info['category'] in _CATS}
    if not battery_agents: return

    soc_data_by_epoch = []
    epoch_0_soc = []
    for name, info in battery_agents.items():
        epoch_0_soc.append((info['b0'] / info['B']) * 100)
    soc_data_by_epoch.append(epoch_0_soc)

    current_b_states = {name: info['b0'] for name, info in battery_agents.items()}
    for e in range(num_epochs):
        plans_e = all_epoch_results[e]['plans']
        agent_plan_map = {p['agent_id']: p['plan'] for p in plans_e}
        epoch_e_plus_1_soc = []
        for agent_name, info in battery_agents.items():
            plan = agent_plan_map.get(agent_name)
            if plan and hasattr(plan, 'b') and len(plan.b) > 0:
                current_b_states[agent_name] = plan.b[-1]
            soc_percent = (current_b_states[agent_name] / info['B']) * 100
            epoch_e_plus_1_soc.append(soc_percent)
        soc_data_by_epoch.append(epoch_e_plus_1_soc)

    plt.figure(figsize=(14, 6))
    ax = plt.gca()
    plot_data = soc_data_by_epoch[1:]
    colors = plt.cm.viridis(np.linspace(0, 1, len(plot_data)))
    for i, soc_data in enumerate(plot_data):
        e = i + 1
        sns.histplot(soc_data, bins=25, kde=False, stat="density", label=f"Start of Epoch {e}", color=colors[i], alpha=0.5)
    ax.legend(title="Time",fontsize=14,title_fontsize=14); ax.set_title("Distribution of Agent SoC at Start of Each Epoch", fontsize=18)
    ax.set_xlabel("State of Charge (% Full)", fontsize=16); ax.set_ylabel("Density", fontsize=16); ax.set_xlim(-5, 105)
    ax.grid(True, linestyle='--', alpha=0.7); plt.tight_layout()
    ax.tick_params(axis='both',labelsize=14) 


def plot_master_aggregate_figure(prosumers, T, T_epoch, par=None):
    print("--- Plotting Aggregate Master Figure (with Secondary Axis) ---")
    S_agg = np.sum([p.plan_s for p in prosumers], axis=0)
    D_agg = np.sum([p.plan_d for p in prosumers], axis=0)

    # Common function to add price axis
    def add_price_axis(ax):
        if par:
            ax2 = ax.twinx()
            # Plot Benchmark BUY Price (High Band)
            ax2.plot(range(T), par.lam_over[:T], color='black', linestyle=':', lw=1.5, alpha=0.7, label='Benchmark Buy')
            ax2.set_ylabel("Price (€/kWh)", color='black', fontsize=18)
            ax2.grid(False) # Disable grid for secondary axis
            return ax2
        return None
    # fig, axes = plt.subplots(3, 1, figsize=(16, 15), sharex=True)
    fig, axes0 = plt.subplots(1, 1, figsize=(16, 5), sharex=True) # Slightly taller
    fig, axes1 = plt.subplots(1, 1, figsize=(16, 5), sharex=True) # Slightly taller
    fig, axes2 = plt.subplots(1, 1, figsize=(16, 5), sharex=True) # Slightly taller
    # 1. Grid Interaction
    axes0.bar(range(T), S_agg, color='lightgreen', alpha=0.6, label='Aggregated Sell')
    axes0.bar(range(T), -D_agg, color='salmon', alpha=0.6, label='Aggregated Buy')
    axes0.plot(range(T), S_agg - D_agg, 'o-', color='dodgerblue', lw=1.5, markersize=2, label='Net Interaction')
    axes0.axhline(0, color='black', linewidth=0.8)
    # axes[0].set_title("Aggregate Grid Interaction (Implemented)", fontsize=16)
    axes0.set_ylabel("Total Power (kW)", fontsize=18)
    axes0.legend(loc='upper left', fontsize=18)
    axes0.grid(True, alpha=0.5)
    axes0.tick_params(axis='both',labelsize=18)
    add_price_axis(axes0)

    # fig, axes[1] = plt.subplots(1, 1, figsize=(16, 14), sharex=True) # Slightly taller
    # 2. Battery Dispatch
    batt_k = np.sum([p.plan_k for p in prosumers], axis=0)
    axes1.bar(range(T), np.maximum(0, batt_k), color='lightblue', alpha=0.8, label='Aggregated Charging')
    axes1.bar(range(T), np.minimum(0, batt_k), color='peachpuff', alpha=0.8, label='Aggregated Discharging')
    axes1.plot(range(T), batt_k, 'o-', color='purple', lw=1.5, markersize=2, label='Net Battery Dispatch')
    axes1.axhline(0, color='black', linewidth=0.8)
    # axes[1].set_title("Aggregate Battery Dispatch (Implemented)", fontsize=16)
    axes1.set_ylabel("Total Power (kW)", fontsize=18)
    axes1.legend(loc='upper left', fontsize=18)
    axes1.grid(True, alpha=0.5)
    axes1.tick_params(axis='both',labelsize=18)
    add_price_axis(axes1)

    # fig, axes[2] = plt.subplots(1, 1, figsize=(16, 14), sharex=True) # Slightly taller
    # 3. Consumption
    base = np.sum([p.alpha_base_day for p in prosumers], axis=0)
    flex = np.sum([_series_from_agent(p, 'flex_consumption', T) for p in prosumers], axis=0)
    total_cons = base + flex
    axes2.bar(range(T), base, color='#ffcc99', alpha=0.7, label='Base Consumption')
    axes2.bar(range(T), flex, bottom=base, color='#66c2a5', alpha=0.7, label='Flexible Consumption')
    axes2.plot(range(T), total_cons, 'o-', color='#2ca25f', lw=1.5, markersize=2, label='Total Consumption')
    # axes[2].set_title("Aggregate Community Consumption (Implemented)", fontsize=16)
    axes2.set_ylabel("Total Power (kW)", fontsize=18)
    axes2.legend(loc='upper left', fontsize=18)
    axes2.grid(True, alpha=0.5)
    axes2.tick_params(axis='both',labelsize=18)
    add_price_axis(axes2)

    format_time_axis(axes0, T, T_epoch)
    format_time_axis(axes1, T, T_epoch)
    format_time_axis(axes2, T, T_epoch)
    plt.tight_layout()

# ---------------------------- 2. Financial Plots ----------------------------

def plot_profit_histograms(dynamic_profits, benchmark_profits,ax):
    print("--- Plotting Profit Histograms ---")
    # plt.figure(figsize=(12, 7))
    ax.hist(benchmark_profits, bins=30, alpha=0.5, color='salmon', label='Benchmark Profits (Fixed Price)')
    ax.hist(dynamic_profits, bins=30, alpha=0.5, color='lightgreen', label='Dynamic Profits (AMM)')
    mean_benchmark = np.mean(benchmark_profits); mean_dynamic = np.mean(dynamic_profits)
    ax.axvline(mean_benchmark, color='red', linestyle='--', linewidth=2, label=f'Benchmark Mean: €{mean_benchmark:.2f}')
    ax.axvline(mean_dynamic, color='green', linestyle='--', linewidth=2, label=f'Dynamic Mean: €{mean_dynamic:.2f}')
    ax.set_title("Distribution of Total Individual Agent Profits", fontsize=20)
    ax.set_xlabel("Total Profit per Agent (€)", fontsize=18)
    ax.set_ylabel("Number of Agents", fontsize=18)
    ax.tick_params(axis='both',labelsize=16) 
    ax.legend(fontsize=14)
    ax.grid(True, linestyle='--', alpha=0.6)
    # ax.tight_layout()

def plot_welfare_gains(dynamic_profits, benchmark_profits,ax):
    print("--- Plotting Welfare Gains ---")
    total_dynamic = np.sum(dynamic_profits); total_benchmark = np.sum(benchmark_profits)
    # ax.figure(figsize=(10, 6))
    bars = ax.bar(['Fixed Price (Benchmark)', 'Dynamic Equilibrium'], [total_benchmark, total_dynamic], color=['salmon', 'lightgreen'])
    ax.set_ylabel("Total Population Profit (€)", fontsize=20) 
    ax.set_title("Gains from Trade", fontsize=18)
    ax.grid(axis='y', linestyle='--', alpha=0.7)
    for bar in bars:
        yval = bar.get_height()
        ax.text(x=bar.get_x() + bar.get_width()/2.0, y=yval, s=f'€{yval:,.2f}', va='bottom', ha='center', fontsize=18)
    ax.tick_params(axis='both',labelsize=16) 
    # ax.tight_layout()

def plot_actual_prices(prices_H: np.ndarray, H: int, T_epoch: int, par_H: ProsumerParams):
    print("--- Plotting Actual Prices ---")
    xh = np.arange(H)
    plt.figure(figsize=(20, 6))
    plt.plot(xh, prices_H, color='darkred', label='Actual Equilibrium Price (Planner Dual)')
    plt.plot(xh, par_H.lam_under, color='gray', linestyle='--', label=f'Benchmark Sell')
    plt.plot(xh, par_H.lam_over, color='gray', linestyle=':', label=f'Benchmark Buy')
    plt.title(f"Actual Equilibrium Prices (Full History)", fontsize=16)
    plt.xlabel("Hour of Day"); plt.ylabel("Price (€/kWh)")
    plt.legend(); plt.grid(True, linestyle='--', alpha=0.6)
    format_time_axis(plt.gca(), H, T_epoch); plt.tight_layout()

def plot_price_bands_combined(bands, H, T_epoch, par):
    print("--- Plotting Price Bands (Cloud) ---")
    plt.figure(figsize=(18, 6))
    xh = np.arange(H)
    # Plot Bands
    plt.fill_between(xh, bands['r_lo'], bands['r_hi'], color='lightgreen', alpha=0.3, label='Sell Price (10-90% band)')
    plt.fill_between(xh, bands['c_lo'], bands['c_hi'], color='salmon', alpha=0.3, label='Buy Price (10-90% band)')
    # Plot Medians
    plt.plot(xh, bands['r_med'], color='darkgreen', lw=2, label='Sell Price (Median)')
    plt.plot(xh, bands['c_med'], color='darkred', lw=2, label='Buy Price (Median)')
    # Plot Benchmarks
    if par:
        limit = min(len(par.lam_under), H)
        plt.plot(xh[:limit], par.lam_under[:limit], color='gray', linestyle='--', alpha=0.8, label='Benchmark Sell')
        plt.plot(xh[:limit], par.lam_over[:limit], color='gray', linestyle=':', alpha=0.8, label='Benchmark Buy')

    # plt.title(f"Simulated AMM Price Bands (Full History - All Epochs)", fontsize=20)
    plt.xlabel("Simulation Horizon",fontsize=18); plt.ylabel("Price (€/kWh)",fontsize=18)
    plt.legend(loc='upper left',fontsize=16)
    plt.grid(True, linestyle='--', alpha=0.6)
    plt.tick_params(axis='both', which='major', labelsize=16)
    for t in range(T_epoch, H, T_epoch):
        plt.axvline(t - 0.5, color='red', linestyle='--', lw=1)
    format_time_axis(plt.gca(), H, T_epoch)
    plt.tight_layout()

# ---------------------------- 3. Detailed Ribbon & Scatter Plots ----------------------------

def _plot_quantile_helper(ax, Y, T, show_legend=False):
    xh = np.arange(T)
    quantiles = [5, 15, 25, 35, 45, 55, 65, 75, 85, 95]
    num_bands = len(quantiles) // 2
    cmap = plt.get_cmap('Blues')
    legend_handles = []
    if Y.shape[0] > 1:
        percentiles = np.percentile(Y, quantiles, axis=0)
        for j in range(num_bands):
            q_low, q_high = percentiles[j], percentiles[-(j + 1)]
            color = cmap((j + 1) / (num_bands + 1))
            h = ax.fill_between(xh, q_low, q_high, color=color, alpha=0.6, linewidth=0, label=f'{quantiles[j]}-{quantiles[-(j+1)]}%')
            if show_legend and j==0: legend_handles.append(h)
    q50 = np.median(Y, axis=0)
    h_med, = ax.plot(xh, q50, lw=2, color='black', label='Median')
    if show_legend: legend_handles.append(h_med)
    return legend_handles

# --- UPDATED PLOTTING FUNCTIONS ---

def plot_single_quantile_with_scatter(ax, prosumers, category_filter, data_key, title, ylabel, T, T_epoch):
    """
    Updated to accept 'All' as a category_filter to plot the entire population.
    """
    # 1. Filter Agents
    if category_filter == "All":
        P_cat = prosumers
    else:
        P_cat = [p for p in prosumers if p.type_category == category_filter]

    if not P_cat: ax.set_title(f"{title} (No Data)"); return

    # 2. Prepare Data
    Y_data = np.stack([_series_from_agent(p, data_key, T) for p in P_cat], axis=0)
    xh = np.arange(T)

    # --- LAYER 1: SCATTER DOTS (BACKGROUND) ---
    unique_bins = sorted(list(set(p.bin_id for p in P_cat)))

    # Create a color map that spans all bins present
    cmap = plt.get_cmap('viridis')
    norm = plt.Normalize(min(unique_bins), max(unique_bins)) if unique_bins else None

    # Downsample for performance if needed (plot max 1000 agents' dots)
    MAX_DOTS = 1000
    P_cat_subset = P_cat if len(P_cat) <= MAX_DOTS else np.random.choice(P_cat, MAX_DOTS, replace=False)

    for p in P_cat_subset:
        y_series = _series_from_agent(p, data_key, T)
        x_jitter = xh + np.random.normal(0, 0.12, size=T)

        color = cmap(norm(p.bin_id)) if norm else 'blue'
        # Markers cycle through the list
        marker = _MARKERS[p.bin_id % len(_MARKERS)]

        # Alpha = 0.35 for visibility behind clouds
        ax.scatter(x_jitter, y_series, s=8, color=color, marker=marker,
                   alpha=0.35, edgecolors='none', zorder=1)

    # --- LAYER 2: QUANTILE RIBBONS (FOREGROUND) ---
    pcts = np.percentile(Y_data, [5, 25, 50, 75, 95], axis=0)

    ax.fill_between(xh, pcts[0], pcts[4], color='skyblue', alpha=0.35, zorder=2, lw=0,label="Interquartile: 5%-95%")
    ax.fill_between(xh, pcts[1], pcts[3], color='steelblue', alpha=0.45, zorder=2, lw=0,label="Interquartile: 15%-75%")
    ax.plot(xh, pcts[2], 'k-', lw=1.5, label='Median', zorder=3)

    ax.set_title(title,fontsize=24)
    ax.set_ylabel(ylabel,fontsize=20)
    ax.set_ylim([-max(abs(Y_data.min()),abs(Y_data.min())),
                 max(abs(Y_data.min()),abs(Y_data.min()))])
    ax.tick_params(axis='both', which='major', labelsize=16)
    ax.grid(True, alpha=0.3, zorder=0)
    format_time_axis(ax, T, T_epoch)

def plot_new_layout_3x2(prosumers, T, T_epoch):
    print("--- Plotting 3x2 Layout (Top-Left: Population Consumption) ---")
    fig, axes = plt.subplots(1, 2, figsize=(20, 6), sharex=True)

    # Row 1: POPULATION Consumption (All Agents) | Consumer Net Trade
    plot_single_quantile_with_scatter(axes[0], prosumers, "All", "consumption", "Total Population Consumption", "Power (kW)", T, T_epoch)
    plot_single_quantile_with_scatter(axes[0], prosumers, "All", "consumption", "Total Population Consumption", "Power (kW)", T, T_epoch)
    plot_single_quantile_with_scatter(axes[0], prosumers, "Solar Prosumer", "k", "Solar Prosumer Battery", "kW", T, T_epoch)
    plot_single_quantile_with_scatter(axes[1], prosumers, "Wind Prosumer", "k", "Wind Prosumer Battery", "kW", T, T_epoch)
    axes[1].legend(fontsize=18)
    plt.tight_layout()
    plt.show()


    fig, axes = plt.subplots(1, 3, figsize=(20, 6), sharex=True)
    # Row 2: Solar (Unchanged)
    plot_single_quantile_with_scatter(axes[0], prosumers, "Consumer", "net_trade", "Consumer Net Trade", "kW", T, T_epoch)
    plot_single_quantile_with_scatter(axes[1], prosumers, "Solar Prosumer", "net_trade", "Solar Prosumer Net Trade", "kW", T, T_epoch)
    plot_single_quantile_with_scatter(axes[2], prosumers, "Wind Prosumer", "net_trade", "Wind Prosumer Net Trade", "kW", T, T_epoch)
    axes[2].legend(fontsize=18)
    plt.tight_layout()
    plt.show()


def plot_new_layout_1x3(prosumers, T, T_epoch):
    print("--- Plotting 1x3 Base/Production Layout ---")
    fig, axes = plt.subplots(1, 3, figsize=(20, 6), sharex=True, sharey=False)
    plot_single_quantile_with_scatter(axes[0], prosumers, "Consumer", "base_consumption", "Base Consumption", "kW", T, T_epoch)
    plot_single_quantile_with_scatter(axes[1], prosumers, "Solar Prosumer", "production", "Solar Production", "kW", T, T_epoch)
    plot_single_quantile_with_scatter(axes[2], prosumers, "Wind Prosumer", "production", "Wind Production", "kW", T, T_epoch)
    axes[0].set_ylim(bottom=0); axes[1].set_ylim(bottom=0); axes[2].set_ylim(bottom=0)
    axes[2].legend(fontsize=18)
    plt.tight_layout(); plt.show()

# ---------------------------- Main Execution ----------------------------

def main_plottingMNE(results):
    sns.set_theme(style="whitegrid", palette="muted")
    all_epoch_results = results['all_epoch_results']
    par_T = results['par']
    T_EPOCH = results['T']; L_HORIZON = results['L_HORIZON']
    NUM_EPOCHS = results['NUM_EPOCHS']; static_bins = results['static_bins']
    all_agents_initial_state = results.get('all_agents_initial_state', [])

    print("--- Mapping Agents to Bins ---")
    agent_bin_map = {}
    for agent in all_agents_initial_state:
        try: agent_bin_map[agent.name] = assign_agent_to_bin(agent, static_bins)
        except: agent_bin_map[agent.name] = 0

    full_history_map = {}
    for agent in all_agents_initial_state:
        full_history_map[agent.name] = {'s':[], 'd':[], 'k':[], 'p':[], 'b':[], 'category': agent.category}

    full_horizon_prices = []
    for epoch_data in all_epoch_results:
        prices_H = epoch_data.get('equilibrium_prices')
        if prices_H is not None: full_horizon_prices.extend(prices_H[:T_EPOCH])
        plans = {p['agent_id']: p['plan'] for p in epoch_data['plans']}
        for name, data in full_history_map.items():
            if name in plans:
                p = plans[name]
                data['s'].append(p.s); data['d'].append(p.d); data['k'].append(p.k); data['p'].append(p.p); data['b'].append(p.b)

    full_prosumers = []
    agent_lookup = {a.name: a for a in all_agents_initial_state}
    total_T = NUM_EPOCHS * T_EPOCH
    dynamic_profits = []; benchmark_profits = []
    full_prices_arr = np.array(full_horizon_prices) if full_horizon_prices else None
    dt = 24.0 / T_EPOCH

    par_Full = None
    if par_T:
        par_Full = ProsumerParams(T=total_T, B=0, K=0, X=par_T.X, lam_under=np.tile(par_T.lam_under, NUM_EPOCHS), lam_over=np.tile(par_T.lam_over, NUM_EPOCHS))

    for name, data in full_history_map.items():
        if not data['s']: continue
        full_plan = Plan(s=np.concatenate(data['s']), d=np.concatenate(data['d']), k=np.concatenate(data['k']), p=np.concatenate(data['p']), b=np.concatenate(data['b']))
        pp = PlotProsumer({'agent_id':name, 'category':data['category'], 'plan':full_plan}, total_T, agent_lookup, dt=dt, bin_id=agent_bin_map.get(name, 0))
        full_prosumers.append(pp)

        if full_prices_arr is not None:
            n_steps = min(len(pp.plan_s), len(full_prices_arr))
            net_pwr = pp.plan_s[:n_steps] - pp.plan_d[:n_steps]
            dynamic_profits.append(np.sum(net_pwr * full_prices_arr[:n_steps] * dt))
            lam_u = par_Full.lam_under[:n_steps]; lam_o = par_Full.lam_over[:n_steps]
            benchmark_profits.append(np.sum((pp.plan_s[:n_steps]*lam_u - pp.plan_d[:n_steps]*lam_o)*dt))

    # --- CALL ALL PLOTS ---
    plot_soc_evolution(all_epoch_results, static_bins)
    # if all_agents_initial_state: plot_soc_distribution_histograms(all_epoch_results, all_agents_initial_state)
    if dynamic_profits:
        fig, (ax1,ax2)=plt.subplots(1,2,figsize=(18,6))
        plot_profit_histograms(dynamic_profits, benchmark_profits,ax1)
        plot_welfare_gains(dynamic_profits, benchmark_profits,ax2)
        plt.tight_layout()
        plt.show()

    plot_master_aggregate_figure(full_prosumers, total_T, T_EPOCH, par=par_Full)
    # if full_prices_arr is not None: plot_actual_prices(full_prices_arr, total_T, T_EPOCH, par_Full)

    # # --- PRICE BANDS GENERATION ---
    print("\n--- Generating Price Band Data ---")
    stitched_bands = {k: [] for k in ['r_med', 'r_lo', 'r_hi', 'c_med', 'c_lo', 'c_hi']}

    # # Create temp Sim Params (Fixing the NameError)
    par_Sim = ProsumerParams(
        T = T_EPOCH * L_HORIZON,
        B=0, K=0, X=results['par'].X,
        lam_under=np.tile(results['par'].lam_under, L_HORIZON),
        lam_over=np.tile(results['par'].lam_over, L_HORIZON)
    )

    for e_data in tqdm(all_epoch_results, desc="Sampling Epochs"):
        J_strat = e_data.get('J_strategies'); J_bank = e_data.get('J_banks'); J_rep = e_data.get('representative_types')
        if J_strat and J_bank and J_rep:
            bands_e, _, _, _, _ = generate_ex_ante_aggregate_samples(
                J_strat, J_bank, J_rep, par_Sim, N=results['N'], L=200, seed=99+e_data['epoch'],
                T_epoch=T_EPOCH, L_horizon=L_HORIZON
            )
            if bands_e:
                for k in stitched_bands: stitched_bands[k].append(bands_e[k][:T_EPOCH])

    if stitched_bands['r_med']:
        final_long_bands = {k: np.concatenate(v) for k, v in stitched_bands.items()}
        plot_price_bands_combined(final_long_bands, total_T, T_EPOCH, par_Full)

    plot_new_layout_3x2(full_prosumers, total_T, T_EPOCH)

    # print("\n✅ All Plots Generated Successfully.")
