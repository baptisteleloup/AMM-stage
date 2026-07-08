import matplotlib.pyplot as plt
from tqdm.notebook import tqdm
from math import floor
import pandas as pd
import numpy as np
import cvxpy as cp
import sys,os

def price_curves(s, d, lam_u, lam_o):
    """
    Pricing function used for AMM.
    s: Supply
    d: Demand
    lam_u: Feed-in Tarif
    lam_o: Retail price

    Returns
    -------
        r: marginal selling price
        c: marginal buying price
    """
    lam_m = 0.5 * (lam_u + lam_o)
    ratio_sd = np.divide(s, d, out=np.zeros_like(s), where=d > 1e-12)
    ratio_ds = np.divide(d, s, out=np.zeros_like(d), where=s > 1e-12)
    c = lam_m + (lam_o - lam_m) * np.maximum(1 - ratio_sd, 0.0)
    r = lam_m - (lam_m - lam_u) * np.maximum(1 - ratio_ds, 0.0)
    return r, c

def solve_horizon(T, L, B, b0,
                  omega_horizon, alpha_base_horizon,
                  alpha_flex_day_horizon, X, K_max,
                  lam_under, lam_over, gamma_timestep,
                  use_amm=False, s_others_horizon=None, d_others_horizon=None,rC=False):
    """
    A single, unified solver for both AMM and NO AMM scenarios.
    - If use_amm is True, it calculates dynamic AMM prices.
    - If use_amm is False, it uses fixed retailer prices.
    - All constraints and optimization logic are IDENTICAL in both cases.
    """
    # --- 1. SETUP ---
    num_days = L + 1
    H = T * num_days
    time_interval = 24 / T

    # --- 2. PRICING LOGIC (The only part that differs) ---
    if use_amm:
        # Dynamic AMM pricing
        r_h, c_h = price_curves(s_others_horizon, d_others_horizon,
                                np.tile(lam_under, num_days),
                                np.tile(lam_over, num_days))
    else:
        # Fixed retailer pricing
        r_h = np.tile(lam_under, num_days)
        c_h = np.tile(lam_over, num_days)

    # --- 3. CORE OPTIMIZATION (Identical for both scenarios) ---
    discounts = np.array([gamma_timestep**t for t in range(H)])
    r_h_discounted = r_h * discounts
    c_h_discounted = c_h * discounts

    k = cp.Variable(H)
    x_pos = cp.Variable(H)
    x_neg = cp.Variable(H)

    constraints = []
    for t in range(1, H + 1):
        constraints += [cp.sum(k[:t]) <= B - b0, cp.sum(k[:t]) >= -b0]
    constraints += [k <= K_max * time_interval, k >= -K_max * time_interval]
    for t in range(H):
        constraints += [k[t] + x_pos[t] - x_neg[t] <= (omega_horizon[t] - alpha_base_horizon[t]) * time_interval]
    constraints += [x_pos >= 0, x_neg >= 0, x_pos <= X * time_interval, x_neg <= X * time_interval]

    #  Flexible Load Constraint
    for d in range(num_days):
        start, end = d * T, (d + 1) * T
        total_potential_flex_day = np.sum((omega_horizon[start:end] - alpha_base_horizon[start:end]) * time_interval)
        target_for_day = total_potential_flex_day - alpha_flex_day_horizon[d]
        constraints += [cp.sum(k[start:end]) + cp.sum(x_pos[start:end] - x_neg[start:end]) == target_for_day]

    objective = cp.Maximize(r_h_discounted @ x_pos - c_h_discounted @ x_neg)
    prob = cp.Problem(objective, constraints)
    prob.solve(solver=cp.SCS, verbose=False)
    if prob.status in ["infeasible", "unbounded"]:
        return None, None, None, None
    if rC:
        return prob.value, k.value, x_pos.value, x_neg.value, constraints, objective
    return prob.value, k.value, x_pos.value, x_neg.value



def generate_night_owl_profile(base_index, base_load=0.2, peak_load=2.0, seed=123):
    """Generates a demand profile for a night shift worker."""
    np.random.seed(seed)
    # Create a base series
    profile = pd.Series(0.0, index=base_index)
    hours = base_index.hour

    # Define time periods
    is_peak_time = (hours >= 22) | (hours < 6) # 10 PM - 6 AM
    is_shoulder_time = (hours >= 18) & (hours < 22) # 6 PM - 10 PM (ramping up)
    is_day_sleep = (hours >= 9) & (hours < 17) # 9 AM - 5 PM (minimal)

    # Assign load based on time
    profile[is_peak_time] = peak_load
    profile[is_shoulder_time] = peak_load / 2
    profile[is_day_sleep] = 0.05 # Just the fridge

    # Add seasonality (more heating/lighting in winter)
    day_of_year = base_index.dayofyear
    seasonal_factor = 1 + 0.4 * np.cos(2 * np.pi * (day_of_year - 15) / 365.25)

    # Combine with base load, noise, and seasonality
    noise = np.random.rand(len(base_index)) * 0.2
    final_profile = (base_load + profile + noise) * seasonal_factor

    return pd.DataFrame({'demand_kw': final_profile})

def generate_remote_worker_profile(base_index, base_load=0.3, work_load=1.2, seed=456):
    """Generates a demand profile for a remote worker."""
    np.random.seed(seed)
    profile = pd.Series(0.0, index=base_index)
    hours = base_index.hour

    # Define time periods
    is_work_time = (hours >= 9) & (hours < 17)
    is_evening = (hours >= 17) & (hours < 23)

    # Assign load
    profile[is_work_time] = work_load
    profile[is_evening] = work_load / 2

    # Add a small morning ramp-up
    morning_ramp = (hours >= 7) & (hours < 9)
    profile[morning_ramp] = 0.5

    # Seasonality
    day_of_year = base_index.dayofyear
    seasonal_factor = 1 + 0.3 * np.cos(2 * np.pi * (day_of_year - 25) / 365.25)

    noise = np.random.rand(len(base_index)) * 0.15
    final_profile = (base_load + profile + noise) * seasonal_factor

    return pd.DataFrame({'demand_kw': final_profile})

def generate_commuter_profile(base_index, base_load=0.2, morning_peak=1.5, evening_peak=2.5, seed=789):
    """Generates a classic double-hump commuter demand profile."""
    np.random.seed(seed)
    profile = pd.Series(0.0, index=base_index)
    hours = base_index.hour

    # Define peaks
    is_morning_peak = (hours >= 6) & (hours < 9)
    is_evening_peak = (hours >= 17) & (hours < 22)

    # Assign load
    profile[is_morning_peak] = morning_peak
    profile[is_evening_peak] = evening_peak

    # Seasonality
    day_of_year = base_index.dayofyear
    seasonal_factor = 1 + 0.5 * np.cos(2 * np.pi * (day_of_year - 20) / 365.25)

    noise = np.random.rand(len(base_index)) * 0.25
    final_profile = (base_load + profile + noise) * seasonal_factor

    return pd.DataFrame({'demand_kw': final_profile})


def runRH(T,TotalDays,alpha_base_yearly,b0_initial,L_input,
          omega_yearly,s_others_yearly,d_others_yearly,
          new_demand_profile,pct_flex,alpha_base_yearly_T,
          B, X, K_max,
          lam_under, lam_over, gamma_hourly,
          individual_demand_profile,
          save=False, savePath="simulation_results_original_360.csv"
          ):
    time_interval = 24 / T


    # Initialize result storage
    k_dayT, xnet_dayT, soc_dayT = np.zeros((TotalDays, T)), np.zeros((TotalDays, T)), np.zeros((TotalDays, T))
    b_historyT = []

    unique_days = alpha_base_yearly.index.normalize().unique()
    b0 = b0_initial

    # Define the number of days for the optimization horizon
    # --- CHANGE 1: Define num_days_in_horizon ---
    num_days_in_horizon = L_input + 1
    objTotal = []

    # Wrap the range with tqdm() to create the progress bar
    print("Running rolling-horizon simulation...")
    for i in range(TotalDays):
        current_day = unique_days[i]

        # Define the lookahead horizon
        start_horizon = current_day
        # --- CHANGE 2: Extend the end of the horizon by one day ---
        end_horizon = current_day + pd.Timedelta(days=num_days_in_horizon)

        # Slice all yearly data for the FULL lookahead window
        # The slicing now correctly fetches L+1 days of data
        omega_horizon = omega_yearly.loc[start_horizon:end_horizon - pd.Timedelta(minutes=15)]['supply_kw'].values
        alpha_base_horizon = alpha_base_yearly.loc[start_horizon:end_horizon - pd.Timedelta(minutes=15)].values
        s_others_horizon = s_others_yearly.loc[start_horizon:end_horizon - pd.Timedelta(minutes=15)]['supply_kw'].values
        d_others_horizon = d_others_yearly.loc[start_horizon:end_horizon - pd.Timedelta(minutes=15)]['demand_kw'].values

        # Calculate alpha_flex for each day in the horizon
        alpha_flex_day_horizon = []
        # --- CHANGE 3: Loop over the correct number of days ---
        for d in range(num_days_in_horizon):
            day_in_horizon = current_day + pd.Timedelta(days=d)
            # Sum the total demand for the day
            total_daily_demand_power_sum = new_demand_profile['demand_kw'].loc[day_in_horizon:day_in_horizon + pd.Timedelta(days=1) - pd.Timedelta(minutes=15)].sum()
            total_daily_demand_energy = total_daily_demand_power_sum * time_interval


            # Calculate the flexible portion
            alpha_flex_for_day = pct_flex * total_daily_demand_energy
            alpha_flex_day_horizon.append(alpha_flex_for_day)

        # Call the solver - THIS CALL REMAINS THE SAME
        # The data passed to it is now correctly shaped
        obj, k_h, x_pos_h, x_neg_h, = solve_horizon(
            T, L_input, B, b0,
            omega_horizon, alpha_base_horizon,
            alpha_flex_day_horizon, X, K_max,
            lam_under, lam_over, gamma_hourly,
            use_amm=True,
            s_others_horizon=s_others_horizon,
            d_others_horizon=d_others_horizon,
        )
        alpha_base_yearly_T[i]=alpha_flex_day_horizon

        # --- ERROR HANDLING: Add a check for solver failure ---
        if obj is None:
            print(f"Solver failed for day {i}. Stopping simulation.")
            break
        objTotal.append(obj)
        # Extract results for the first day of the horizon
        k_day = k_h[:T]
        xnet_day = x_pos_h[:T] - x_neg_h[:T]
        soc_day = b0 + np.cumsum(k_day)

        # Store results
        k_dayT[i] = k_day
        xnet_dayT[i] = xnet_day
        soc_dayT[i] = soc_day
        b_historyT.append(b0)

        # Advance the starting battery state for the next day's simulation
        b0 = soc_day[-1]

    b_historyT.append(b0) # Append the final state
    print("Simulation complete.")
    
    # --- 1. Reshape the daily results into continuous arrays ---
    k_series = k_dayT.flatten()
    xnet_series = xnet_dayT.flatten()
    soc_series = soc_dayT.flatten()

    # --- 2. Create a datetime index for the simulation period ---
    sim_start_day = unique_days[0]
    # Calculate the end timestamp for the simulation period
    sim_end_day = unique_days[TotalDays - 1] + pd.Timedelta(days=1) - pd.Timedelta(minutes=15)
    results_index = pd.date_range(start=sim_start_day, end=sim_end_day, freq='15min')

    # --- 3. Gather all relevant input and output data into a DataFrame ---
    # Slice the input data to match the simulation period
    sim_slice = slice(sim_start_day, sim_end_day)

    results_df = pd.DataFrame({
        # --- INPUTS ---
        'prosumer_generation_kw': omega_yearly.loc[sim_slice]['supply_kw'].values,
        'prosumer_total_demand_kw': individual_demand_profile.loc[sim_slice]['demand_kw'].values,
        'prosumer_base_demand_kw': alpha_base_yearly.loc[sim_slice].values,
        'community_supply_kw': s_others_yearly.loc[sim_slice]['supply_kw'].values,
        'community_demand_kw': d_others_yearly.loc[sim_slice]['demand_kw'].values,
        # --- OUTPUTS ---
        'battery_charge_discharge_kw': k_series,
        'net_grid_trade_kw': xnet_series, # xnt - We decompose xnt into non-negative power sold, snt = max{xnt, 0}, and power bought, dnt = max{−xnt, 0}.
        'battery_soc_kwh': soc_series
    }, index=results_index)


    # --- 4. Save the DataFrame to a CSV file ---
    if save:
        results_df.to_csv(savePath)
        print("Successfully saved all results to 'simulation_results.csv'.")

    return results_df


def AMMproft(k_dayT,T,s_others_daily,
             d_others_daily,lam_under,lam_over,
             xnet_dayT,b0_initial,alpha_base_yearly,L_input,B,
             omega_yearly,individual_demand_profile,pct_flex,X,K_max,gamma_hourly,
             save=False,
             pathamm="data/cum_profits_amm_exact.txt",
             pathNoamm="data/cum_profits_no_amm.txt"):
    print("Calculating profits with AMM...")
    xnet_series = xnet_dayT.flatten()
    TotalSteps = len(xnet_series)
    TotalDays = TotalSteps // T
    time_interval = 24 / T
    x_pos_sim = np.maximum(xnet_series, 0)
    x_neg_sim = np.maximum(-xnet_series, 0)
    lam_under_yearly = np.tile(lam_under, TotalDays)[:TotalSteps]
    lam_over_yearly = np.tile(lam_over, TotalDays)[:TotalSteps]
    s_others_series = s_others_daily.flatten() # Assuming s_others_daily exists from main sim
    d_others_series = d_others_daily.flatten() # Assuming d_others_daily exists from main sim
    r_sim, c_sim = price_curves(s_others_series, d_others_series, lam_under_yearly, lam_over_yearly)




    print("\nStarting counterfactual simulation without AMM...")

    # Initialize result storage
    k_no_amm_dayT = np.zeros((TotalDays, T))
    x_pos_no_amm_dayT = np.zeros((TotalDays, T))
    x_neg_no_amm_dayT = np.zeros((TotalDays, T))
    b0_no_amm = b0_initial # Reset initial battery state

    # Get list of unique days for looping
    unique_days = alpha_base_yearly.index.normalize().unique()
    for i in range(TotalDays):
        current_day = unique_days[i]
        num_days_in_horizon = L_input + 1
        start_horizon = current_day
        end_horizon = current_day + pd.Timedelta(days=num_days_in_horizon)

        omega_horizon = omega_yearly.loc[start_horizon:end_horizon - pd.Timedelta(minutes=15)]['supply_kw'].values
        alpha_base_horizon = alpha_base_yearly.loc[start_horizon:end_horizon - pd.Timedelta(minutes=15)].values

        # --- MODIFIED: Correct calculation for flexible ENERGY target ---
        alpha_flex_day_horizon = []
        for d in range(num_days_in_horizon):
            day_in_horizon = current_day + pd.Timedelta(days=d)
            # Sum of power (kW)
            total_daily_demand_power_sum = individual_demand_profile['demand_kw'].loc[day_in_horizon:day_in_horizon + pd.Timedelta(days=1) - pd.Timedelta(minutes=15)].sum()
            # Convert to Energy (kWh)
            total_daily_demand_energy = total_daily_demand_power_sum * time_interval
            # Calculate flexible energy portion
            alpha_flex_for_day = pct_flex * total_daily_demand_energy
            alpha_flex_day_horizon.append(alpha_flex_for_day)

        # Call the corrected solver
        obj, k_h, x_pos_h, x_neg_h = solve_horizon(
            T, L_input, B, b0_no_amm,
            omega_horizon, alpha_base_horizon,
            alpha_flex_day_horizon, X, K_max,
            lam_under, lam_over, gamma_hourly,
            use_amm=False
        )

        if obj is not None:
            k_no_amm_dayT[i, :] = k_h[:T]
            x_pos_no_amm_dayT[i, :] = x_pos_h[:T]
            x_neg_no_amm_dayT[i, :] = x_neg_h[:T]
            b0_no_amm = b0_no_amm + np.sum(k_h[:T]) # Corrected state update for clarity
        else:
            print(f"Counterfactual simulation stopped at day {i} due to solver failure.")
            break
    print("Counterfactual simulation complete.")
    # AMM results (energy in kWh)
    xnet_series_amm = k_dayT.flatten() # Assuming this is meant to be xnet_dayT
    TotalSteps = len(xnet_series_amm)
    TotalDays = TotalSteps // T
    x_pos_amm_energy = np.maximum(xnet_series_amm, 0)
    x_neg_amm_energy = np.maximum(-xnet_series_amm, 0)

    # NO AMM results (energy in kWh)
    x_pos_no_amm_dayT = np.zeros((TotalDays, T))
    x_neg_no_amm_dayT = np.zeros((TotalDays, T))
    xnet_series_no_amm = x_pos_no_amm_dayT.flatten() - x_neg_no_amm_dayT.flatten()
    x_pos_no_amm_energy = np.maximum(xnet_series_no_amm, 0)
    x_neg_no_amm_energy = np.maximum(-xnet_series_no_amm, 0)

    # Common data
    s_others_power = s_others_daily.flatten()
    d_others_power = d_others_daily.flatten()
    lam_under_yearly = np.tile(lam_under, TotalDays)[:TotalSteps]
    lam_over_yearly = np.tile(lam_over, TotalDays)[:TotalSteps]

    # --- 2. Perform Diagnostic Profit Calculations ---

    # --- Test A: AMM Profit Calculation NO IMPACT ---
    # Price is calculated IGNORING the prosumer's own trades.
    r_sim_NI, c_sim_NI = price_curves(s_others_power, d_others_power, lam_under_yearly, lam_over_yearly)
    profits_amm_NI = (x_pos_amm_energy * r_sim_NI) - (x_neg_amm_energy * c_sim_NI)
    cum_profits_amm_NI = np.cumsum(profits_amm_NI)
    print(f"Profit with AMM (NI Calculation): €{cum_profits_amm_NI[-1]:.2f}")

    # --- Test B: AMM Profit Calculation IMPACT ---
    # Price is calculated INCLUDING the prosumer's own trades.
    time_interval = 24 / T
    x_pos_amm_power = x_pos_amm_energy / time_interval
    x_neg_amm_power = x_neg_amm_energy / time_interval
    s_total_power = s_others_power + x_pos_amm_power
    d_total_power = d_others_power + x_neg_amm_power
    r_sim_exact, c_sim_exact = price_curves(s_total_power, d_total_power, lam_under_yearly, lam_over_yearly)
    profits_amm_exact = (x_pos_amm_energy * r_sim_exact) - (x_neg_amm_energy * c_sim_exact)
    cum_profits_amm_exact = np.cumsum(profits_amm_exact)
    print(f"Profit with AMM (Exact Calculation): €{cum_profits_amm_exact[-1]:.2f}")


    # --- Test C: NO AMM Profit (Original) ---
    profits_no_amm = (x_pos_no_amm_energy * lam_over_yearly) - (x_neg_no_amm_energy * lam_under_yearly) # Corrected order
    cum_profits_no_amm = np.cumsum(profits_no_amm)
    print(f"Profit without AMM (Original): €{cum_profits_no_amm[-1]:.2f}")
    if save==True:
        np.savetxt(pathamm,cum_profits_amm_exact,)
        np.savetxt(pathNoamm,cum_profits_no_amm,)
    return cum_profits_amm_exact, cum_profits_no_amm