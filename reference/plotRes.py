import numpy as np
import pandas as pd
import sys, os
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors
import matplotlib.dates as mdates
from matplotlib.colors import LinearSegmentedColormap
from supDem import *
from rollingHorizon import *
from matplotlib.lines import Line2D



def plotSummerWeek(indDemand,indSupply,
                   start_date_summer = '2023-07-11',
                   end_date_summer = '2023-07-17',city="Paris"):
    myFmt = mdates.DateFormatter('%m-%d')
    fig, (ax1,ax2) = plt.subplots(1, 2, figsize=(16, 5))
    # Plot 1: Sample Summer Week
    ax1.plot(indDemand.loc[start_date_summer:end_date_summer], label="Energy Demand", color='crimson', linewidth=2)
    ax1.plot((indSupply).loc[start_date_summer:end_date_summer], label="Solar Supply", color='blue', linewidth=2)
    ax1.set_title(f"{city} Summer Week: {start_date_summer} to {end_date_summer}", fontsize=18)
    ax1.set_ylabel("Power (kW)", fontsize=16)
    ax1.grid(True, linestyle='--', alpha=0.6)
    ax1.tick_params(axis='both', which='major', labelsize=14)
    ax1.set_ylim(top=3.5,bottom=0)
    ax1.xaxis.set_major_formatter(myFmt)
    start_date_winter = '2023-01-06'
    end_date_winter = '2023-01-12'
    ax2.plot(indDemand.loc[start_date_winter:end_date_winter], label="Energy Demand", color='crimson', linewidth=2)
    ax2.plot((indSupply).loc[start_date_winter:end_date_winter], label="Solar Supply", color='blue', linewidth=2)
    ax2.set_xlabel("Date", fontsize=16)
    ax2.set_title(f"{city} Winter Week: {start_date_winter} to {end_date_winter}", fontsize=18)
    ax2.set_ylabel("Power (kW)", fontsize=16)
    ax2.legend(fontsize=12)
    ax2.grid(True, linestyle='--', alpha=0.6)
    ax2.tick_params(axis='both', which='major', labelsize=14)
    ax2.set_ylim(top=3.5,bottom=0)
    ax2.xaxis.set_major_formatter(myFmt)
    ax1.set_xlabel("Date", fontsize=16)
    plt.tight_layout(rect=[0, 0, 1, 0.93])
    plt.show()





def plotBaseFlexLoad(T,alpha_base_daily,
                     unique_days,alpha_flex_day):
    fig, (ax0,ax1) = plt.subplots(1,2,figsize=(16, 6))
    t_daily = np.arange(0, 360,1)
    # Calculate statistics for each timestep across all days

    def subplot_confidence_bands(data, title, ylabel, color,data2=None, color2=None,ax=None):
        """Calculates quantiles and creates a piecewise confidence band plot."""
        t_daily = np.arange(0, 24, 24 / T)
        # Calculate statistics for each timestep across all days
        median = np.median(data, axis=0)
        q25 = np.quantile(data, 0.25, axis=0)
        q75 = np.quantile(data, 0.75, axis=0)
        q5 = np.quantile(data, 0.05, axis=0)
        q95 = np.quantile(data, 0.95, axis=0)
        # Plot the confidence bands with step='mid' for a piecewise look
        ax.fill_between(t_daily, q5, q95, color=color, alpha=0.2, label='Demand 5%-95% Quantile', step='mid')
        ax.fill_between(t_daily, q25, q75, color=color, alpha=0.5, label='Demand 25%-75% Quantile (IQR)', step='mid')
        # Plot the median line as a step plot
        ax.step(t_daily, median, where='mid', color='black', linewidth=2.5, label='Median Demand')
        if type(data2)!=type(None):
            median_2 = np.median(data2, axis=0)
            q25_2 = np.quantile(data2, 0.25, axis=0)
            q75_2 = np.quantile(data2, 0.75, axis=0)
            q5_2 = np.quantile(data2, 0.05, axis=0)
            q95_2 = np.quantile(data2, 0.95, axis=0)
            # Plot the confidence bands with step='mid' for a piecewise look
            ax.fill_between(t_daily, q5_2, q95_2, color=color2, alpha=0.2, label='Nice 5%-95% Quantile', step='mid')
            ax.fill_between(t_daily, q25_2, q75_2, color=color2, alpha=0.5, label='Nice 25%-75% Quantile (IQR)', step='mid')
            # Plot the median line as a step plot
            ax.step(t_daily, median_2, where='mid', color='red', linewidth=2.5, label='Nice median')
        ax.axhline(0, color="black", lw=0.7, linestyle='--')
        ax.set_ylabel(ylabel,fontsize=18)
        ax.set_xlabel("Hour of Day",fontsize=18)
        ax.set_title(title, fontsize=18)
        ax.grid(True, linestyle='--', alpha=0.6)
        ax.set_xticks(np.arange(0, 25, 3))
        ax.set_xlim([0, 24])
        ax.legend(fontsize=14)
    subplot_confidence_bands(alpha_base_daily, "Daily Base Load Profile Distribution", "Power (kW)", "blue",
                            ax=ax0)
    # Plot the median line as a step plot
    ax1.step(unique_days[:360], alpha_flex_day, where='mid', color='red', linewidth=2.5, label='Daily flexible load')
    locator = mdates.MonthLocator(bymonthday=1, interval=2)  # ticks on the 1st of each month
    ax1.xaxis.set_major_locator(locator)
    # Format ticks as YYYY-MM
    ax1.xaxis.set_major_formatter(mdates.DateFormatter('%Y-%m'))
    ax1.axhline(0, color="black", lw=0.7, linestyle='--')
    ax1.set_ylabel("Power (kW)",fontsize=18)
    ax1.set_xlabel("Date",fontsize=18)
    ax1.set_title("Yearly Flexible Load", fontsize=18)
    ax1.grid(True, linestyle='--', alpha=0.6)
    ax1.tick_params(axis='both', which='major', labelsize=16)
    ax0.tick_params(axis='both', which='major', labelsize=16)
    ax1.legend(fontsize=16)
    ax0.legend(fontsize=16)
    plt.tight_layout()
    plt.show()

def plotSD(dfDemand,s_others_yearly, e_others_yearly):
    daily_demand = dfDemand["consumption"].to_frame(name='val').pivot_table(index=dfDemand.index.date, columns=dfDemand.index.time, values='val')
    daily_supply = s_others_yearly.to_frame(name='val').pivot_table(index=s_others_yearly.index.date, columns=s_others_yearly.index.time, values='val')
    Edaily_supply = e_others_yearly.to_frame(name='val').pivot_table(index=e_others_yearly.index.date, columns=e_others_yearly.index.time, values='val')
    colors = ["#00008B", "#32CD32", "#FFFF00", "#FF8C00", "#00008B","#8900FA"]
    nodes = [0.0, 0.25, 0.5, 0.75, 1.0]
    cmap = LinearSegmentedColormap.from_list("seasonal_cmap_bright_spring", list(zip(nodes, colors)))
    norm = mcolors.Normalize(vmin=0, vmax=365)
    if s_others_yearly is not None and dfDemand is not None:
        fig,ax1 = plt.subplots(1,1,figsize=(12, 5))
        for i in range(7,len(daily_demand),):
            ax1.plot(range(daily_demand.shape[1]), ((daily_supply.iloc[i-7:i+7]+Edaily_supply.iloc[i-7:i+7]
                                                    )/daily_demand.iloc[i-7:i+7]).mean(0), color=cmap(norm(i)), alpha=0.5)
        ax1.set_ylabel("Supply Over Demand", fontsize=16)
        ax1.set_xlabel("15-minute Timestep of the Day", fontsize=16)
        ax1.set_xticks(np.linspace(0, daily_demand.shape[1] - 1, 5))
        ax1.set_yticks(np.linspace(0, 1.2, 5))
        ax1.set_xticklabels(['00:00', '06:00', '12:00', '18:00', '23:45'], fontsize=14)
        ax1.tick_params(axis='y', which='major', labelsize=14)
        ax1.grid(True, linestyle='--', alpha=0.001)
        sm = plt.cm.ScalarMappable(cmap=cmap, norm=norm)
        sm.set_array([])
        cbar_supply = fig.colorbar(sm, ax=ax1, orientation='vertical', )
        cbar_supply.set_label('Day of Year', fontsize=12)
        cbar_supply.set_ticks([1, 91, 182, 274, 365])
        cbar_supply.set_ticklabels(['Winter (Jan 1)', 'Spring (Apr 1)', 'Summer (Jul 1)', 'Autumn (Oct 1)', 'Winter (Dec 31)'])
        cbar_supply.ax.tick_params(labelsize=12)
        ax1.plot(range(daily_demand.shape[1]),np.ones(daily_demand.shape[1]), linewidth=2,linestyle="--",color="black")
    plt.show()

def plotGridRes(T,k_dayT,xnet_dayT,soc_dayT,unique_days,TotalDays,omega_yearly):
    colors = ["#00008B", "#32CD32", "#FFFF00", "#FF8C00", "#00008B"]
    nodes = [0.0, 0.25, 0.5, 0.75, 1.0]
    cmap = LinearSegmentedColormap.from_list("seasonal_cmap_bright_spring", list(zip(nodes, colors)))
    norm = mcolors.Normalize(vmin=0, vmax=365)
    t_daily = np.arange(0, 24, 24 / T) # Time axis for a single day

    k_daily = k_dayT
    xnet_daily = xnet_dayT
    soc_daily = soc_dayT
    sim_days_slice = slice(unique_days[0], unique_days[TotalDays-1] + pd.Timedelta(days=1) - pd.Timedelta(minutes=15))
    omega_daily = omega_yearly.loc[sim_days_slice]['supply_kw'].values.reshape(TotalDays, T) # Individual Generation
    optimized_consumption_daily = omega_daily - xnet_daily - k_daily

    fig1, ax1 = plt.subplots(figsize=(16, 5))
    for i in range(7,TotalDays):
        # Use plt.step with where='mid' for piecewise horizontal lines
        ax1.step(t_daily, np.mean(optimized_consumption_daily[i-7:i+7],axis=0), where='mid', color=cmap(norm(i)), alpha=0.4)
    ax1.axhline(0, color="black", lw=0.7, linestyle='--')
    ax1.set_ylabel("Power (kW)",fontsize=16)
    ax1.set_xlabel("Hour of Day",fontsize=16)
    # ax1.set_title("Optimized Consumption")
    ax1.grid(True, linestyle='--', alpha=0.6)
    ax1.set_xticks(np.arange(0, 25, 3))
    ax1.set_xlim([0, 24])
    ax1.tick_params(axis='both', which='major', labelsize=14)
    # Add colorbar
    sm = plt.cm.ScalarMappable(cmap=cmap, norm=norm)
    sm.set_array([])
    cbar1 = fig1.colorbar(sm, ax=ax1, orientation='vertical', )
    cbar1.set_label('Day of Year', size=14)
    cbar1.set_ticks([1, 91, 182, 274, 365])
    cbar1.set_ticklabels(['Winter', 'Spring', 'Summer', 'Autumn', 'Winter'],fontsize=14)
    plt.show()
    
    fig1, (ax1,ax3) = plt.subplots(1,2,figsize=(18, 5))
    ax1.tick_params(axis='both', which='major', labelsize=12)
    sm = plt.cm.ScalarMappable(cmap=cmap, norm=norm)
    sm.set_array([])
    for i in range(7,TotalDays):
        ax1.step(t_daily, np.mean(k_dayT[i-7:i+7],axis=0), where='mid', color=cmap(norm(i)), alpha=0.4)
    ax1.axhline(0, color="black", lw=0.7, linestyle='--')
    ax1.set_ylabel("Power (kW)",fontsize=18)
    ax1.set_xlabel("Hour of Day",fontsize=18)
    ax1.set_title("Daily Battery Charge/Discharge Profiles (360 Days Overlaid)",fontsize=16)
    ax1.grid(True, linestyle='--', alpha=0.6)
    ax1.set_xticks(np.arange(0, 25, 3))
    ax1.set_xlim([0, 24])
    ax3.tick_params(axis='both', which='major', labelsize=12)
    for i in range(7,TotalDays):
        ax3.step(t_daily, np.mean(soc_dayT[i-7:i+7],axis=0), where='mid', color=cmap(norm(i)), alpha=0.4)
    ax3.set_ylabel("Energy (kWh)",fontsize=18)
    ax3.set_xlabel("Hour of Day",fontsize=18)
    ax3.set_title("Daily State of Charge Profiles (360 Days Overlaid)",fontsize=16)
    ax3.grid(True, linestyle='--', alpha=0.6)
    ax3.set_xticks(np.arange(0, 25, 3))
    ax3.set_xlim([0, 24])
    sm = plt.cm.ScalarMappable(cmap=cmap, norm=norm)
    sm.set_array([])
    plt.show()

def plotLag(results,xnet_daily,t_daily):
    df = results
    lag_mult_flat = np.genfromtxt('data/LagMult.txt')

    # Simulation Constants
    T = 96  # 96 intervals of 15 minutes per day
    limit = min(len(df), len(lag_mult_flat))
    TotalDays = limit // T
    hours_axis = np.arange(0, 24, 24 / T)

    # Trim data to ensure alignment
    df = df.iloc[:limit]
    lag_mult_flat = lag_mult_flat[:limit]
    s_vals = df['community_supply_kw'].values
    d_vals = df['community_demand_kw'].values

    # Tariff Parameters
    lam_under = 0.0886
    HP = 0.2146
    HC = 0.1696
    hourCreusePleine =['c','c','c','c','c','c',
                    'p','p','p','p','p','p',
                    'c',
                    'p','p','p','p','p','p','p','p','p','p',
                    'c',]
    # Build daily tariff profile
    lam_over_daily = np.zeros(T)
    for j in range(T):
        hour_idx = floor(hours_axis[j]) 
        if hourCreusePleine[hour_idx] == 'p':
            lam_over_daily[j] = HP
        else:
            lam_over_daily[j] = HC

    lam_over_full = np.tile(lam_over_daily, TotalDays)
    lam_under_full = np.full(limit, lam_under)

    def calculate_prices(s, d, lu, lo):
        lam_m = 0.5 * (lu + lo)
        ratio_sd = np.divide(s, d, out=np.zeros_like(s), where=d > 1e-12)
        ratio_ds = np.divide(d, s, out=np.zeros_like(d), where=s > 1e-12)
        c = lam_m + (lo - lam_m) * np.maximum(1 - ratio_sd, 0.0)
        r = lam_m - (lam_m - lu) * np.maximum(1 - ratio_ds, 0.0)
        return r, c

    r_full, c_full = calculate_prices(s_vals, d_vals, lam_under_full, lam_over_full)
    
    # ==========================================
    # 3. DATA PROCESSING & STRUCTURED SAMPLING
    # ==========================================
    # Reshape for daily analysis
    theta_daily = lag_mult_flat.reshape(TotalDays, T)
    c_daily = c_full.reshape(TotalDays, T)
    r_daily = r_full.reshape(TotalDays, T)
    x_daily = df['net_grid_trade_kw'].values.reshape(TotalDays, T)

    # --- STRATEGIC SAMPLING ---
    # To map the trading decisions accurately, we need days that represent:
    # 1. The Ceiling (Pure Buying days)
    # 2. The Floor (Pure Selling days)
    # 3. The Transitions (High Variance days)

    # Calculate Daily Metrics
    buy_intensity = np.sum(np.abs(np.minimum(x_daily, 0)), axis=1) # Total kWh Bought
    sell_intensity = np.sum(np.maximum(x_daily, 0), axis=1)        # Total kWh Sold
    theta_variance = np.var(theta_daily, axis=1)                   # Switching Activity

    sampled_days = set()
    seasons = [range(0, 90), range(90, 180), range(180, 270), range(270, 360)]

    for season in seasons:
        # Filter indices for this season
        idxs = [i for i in season if i < TotalDays]
        if not idxs: continue
        
        # Select Top 2 days for Buying (Defines the squares at the top)
        top_buy = [idxs[i] for i in np.argsort(buy_intensity[idxs])[-2:]]
        
        # Select Top 2 days for Selling (Defines the circles at the bottom)
        top_sell = [idxs[i] for i in np.argsort(sell_intensity[idxs])[-2:]]
        
        # Select Top 3 days for Variance (Defines the diamonds in the middle)
        top_var = [idxs[i] for i in np.argsort(theta_variance[idxs])[-3:]]
        
        sampled_days.update(top_buy)
        sampled_days.update(top_sell)
        sampled_days.update(top_var)

    sampled_days = np.sort(list(sampled_days))

    # --- Prepare Data for Scatter Plot ---
    sampled_hours = []
    sampled_theta = []
    sampled_days_color = []
    sampled_regime = [] # 0=Sell, 1=Buy, 2=Mid

    tol = 1e-4

    for d in sampled_days:
        theta_d = theta_daily[d]
        c_d = c_daily[d]
        r_d = r_daily[d]
        h_d = hours_axis
        
        # Classify Regimes
        mask_buy = theta_d >= (c_d - tol)
        mask_sell = theta_d <= (r_d + tol)
        mask_mid = ~(mask_buy | mask_sell)
        
        # Sell points (Regime 0)
        if np.any(mask_sell):
            sampled_hours.extend(h_d[mask_sell])
            sampled_theta.extend(theta_d[mask_sell])
            sampled_days_color.extend([d] * np.sum(mask_sell))
            sampled_regime.extend([0] * np.sum(mask_sell))
            
        # Buy points (Regime 1)
        if np.any(mask_buy):
            sampled_hours.extend(h_d[mask_buy])
            sampled_theta.extend(theta_d[mask_buy])
            sampled_days_color.extend([d] * np.sum(mask_buy))
            sampled_regime.extend([1] * np.sum(mask_buy))

        # Mid points (Regime 2)
        if np.any(mask_mid):
            sampled_hours.extend(h_d[mask_mid])
            sampled_theta.extend(theta_d[mask_mid])
            sampled_days_color.extend([d] * np.sum(mask_mid))
            sampled_regime.extend([2] * np.sum(mask_mid))

    # Convert to numpy
    sampled_hours = np.array(sampled_hours)
    sampled_theta = np.array(sampled_theta)
    sampled_days_color = np.array(sampled_days_color)
    sampled_regime = np.array(sampled_regime)
    colors = ["#00008B", "#32CD32", "#FFFF00", "#FF8C00", "#00008B"]
    nodes = [0.0, 0.25, 0.5, 0.75, 1.0]
    cmap = LinearSegmentedColormap.from_list("seasonal_cmap", list(zip(nodes, colors)))
    norm = mcolors.Normalize(vmin=0, vmax=360)

    fig, (ax0,ax) = plt.subplots(1,2,figsize=(20, 6))

    # Common parameters
    marker_s = 45
    alpha_v = 0.4
    lw_v = 0.6

    # 1. Selling Regime (Circles)
    mask0 = sampled_regime == 0
    ax.scatter(sampled_hours[mask0], sampled_theta[mask0], c="crimson", 
            marker='X', s=marker_s, alpha=alpha_v, edgecolors='black', linewidths=lw_v, label='Selling Regime')

    # 2. Buying Regime (Squares)
    mask1 = sampled_regime == 1
    ax.scatter(sampled_hours[mask1], sampled_theta[mask1], c="green",
            marker='s', s=marker_s, alpha=alpha_v, edgecolors='black', linewidths=lw_v, label='Buying Regime')

    # 3. No Trade Regime (Diamonds)
    mask2 = sampled_regime == 2
    ax.scatter(sampled_hours[mask2], sampled_theta[mask2], c="black",
            marker='d', s=marker_s, alpha=1, edgecolors='black', linewidths=lw_v, label='No Trade')

    # Formatting
    ax.set_title("Lagrange Multiplier Regimes (Structurally Sampled)", fontsize=18)
    ax.set_xlabel("Hour of Day", fontsize=18)
    ax.set_ylabel(r"Lagrange Multiplier ($\theta_{nt}^*$) [€/kWh]", fontsize=18)

    ax0.set_title("Daily Net Grid Trade Profiles", fontsize=18)
    ax0.set_xlabel("Hour of Day", fontsize=18)
    ax0.set_ylabel(r"Power[kW]", fontsize=18)

    # Set Y-axis Limits (Important: 0.08 to capture the selling floor)
    ax.set_ylim(0.1, 0.22) 

    ax.grid(True, linestyle=':', alpha=0.6)
    ax.set_xticks(np.arange(0, 25, 3))
    ax.set_xlim(0, 24)

    # Legend (Bottom Right)
    legend_elements = [
        Line2D([0], [0], marker='s', color='w', label=r'Buying ($\theta \geq \bar{c}$)', 
            markerfacecolor='green', markeredgecolor='black', markersize=10),
        Line2D([0], [0], marker='d', color='w', label=r'No Trade ($\bar{r} < \theta < \bar{c}$)', 
            markerfacecolor='black', markeredgecolor='black', markersize=10),
        Line2D([0], [0], marker='X', color='w', label=r'Selling ($\theta \leq \bar{r}$)', 
            markerfacecolor='crimson', markeredgecolor='black', markersize=10)
    ]
    ax.legend(handles=legend_elements, loc='lower right', fontsize=14, framealpha=0.9, edgecolor='gray')
    # Colorbar
    sm = plt.cm.ScalarMappable(cmap=cmap, norm=norm)
    sm.set_array([])
    cbar = fig.colorbar(sm, ax=ax0, orientation='vertical', pad=0.02)
    cbar.set_label('Season (Day of Year)', fontsize=14)
    cbar.set_ticks([1, 91, 182, 274, 360])
    cbar.set_ticklabels(['Winter', 'Spring', 'Summer', 'Autumn', 'Winter'],fontsize=16)


    for i in range(7,xnet_daily.shape[0],):
        ax0.plot(t_daily,(xnet_daily[i-7:i+7]).mean(0), color=cmap(norm(i)), alpha=0.5)
    ax0.grid(True, linestyle=':', alpha=0.6)
    ax0.set_xticks(np.arange(0, 25, 3),)
    ax0.tick_params(axis='both',labelsize=15)
    ax.tick_params(axis='both',labelsize=15)
    plt.tight_layout()
    plt.show()


def plotcumProf(T,s_others_yearly,
                cum_profits_amm_exact,
                cum_profits_no_amm):
    TotalSteps = 34560
    TotalDays = TotalSteps // T
    dates = s_others_yearly.index[:TotalSteps]
    fig, ax1 = plt.subplots(1, 1, figsize=(16, 6), sharex=True)
    skip=2000
    ax2=ax1.twinx()
    lp1=ax1.plot(dates[skip:], (1-cum_profits_amm_exact[skip:]/cum_profits_no_amm[skip:])*100, 
            label='Prosumer Percentage Gain', color='black', linewidth=2)
    ax1.set_ylabel('Percentage of spends saved with AMM(%)', fontsize=16)
    ax1.grid(True, linestyle='--', alpha=0.6)
    ax1.set_xlabel("Date",fontsize=16)
    lp2=ax2.plot(dates,cum_profits_no_amm, "-.",
            label='Prosumer Profit Gain Without AMM', color='red', linewidth=2)
    lp3=ax2.plot(dates,cum_profits_amm_exact, "--",
            label='Prosumer Profit Gain With AMM', color='green', linewidth=2)

    lns = lp1+lp2+lp3
    labs = [l.get_label() for l in lns]
    ax1.legend(lns, labs, loc=0, fontsize=16)
    ax1.tick_params(axis='both', which='major', labelsize=16)
    ax2.tick_params(axis='y', which='major', labelsize=16)
    ax2.set_ylabel('Cumulative Profit (€)', fontsize=16)
    plt.tight_layout(rect=[0, 0, 1, 0.95])
    plt.show()

def plotSimData(conSin,windSin,solarSin,DC,DE,DS,dfDemand,summerStart,summerEnd):
    
    colors = ["#00008B", "#32CD32", "#FFFF00", "#FF8C00", "#00008B","#8900FA"]
    nodes = [0.0, 0.25, 0.5, 0.75, 1.0]
    fig=plt.figure(figsize=(18,5))
    # GeneratedCurvesWind=np.zeros((1000,96))
    start=summerStart
    end=summerEnd
    # Compute depth
    XVALS=[int(col[:2]) if col[3:5]=="00" else col[:5] for col in dfDemand.index.astype(str).str[11:].values[:96]]

    plt.subplot(1, 3, 1)
    norm = mcolors.Normalize(vmin=min(DC), vmax=max(DC))
    cmap = plt.cm.plasma
    for i in range(conSin.shape[0]):plt.plot(XVALS,conSin[i], color=cmap(norm(DC[i])),alpha=.5)
    plt.xticks(range(0,4*24,16))

    plt.tick_params(axis='both', which='major', labelsize=12)
    plt.xlabel("Hour of the day", fontsize=16)
    plt.ylabel("Power [kW]", fontsize=16)
    plt.title("Sintetic consumption", fontsize=16)
    plt.grid()
    # plt.gca().xaxis.set_major_formatter(md.DateFormatter('%H'))

    plt.subplot(1, 3, 2)
    norm = mcolors.Normalize(vmin=min(DE), vmax=max(DE))
    cmap = plt.cm.plasma
    for i in range(windSin.shape[0]):plt.plot(XVALS,windSin[i], color=cmap(norm(DE[i])),alpha=.5)
    plt.xticks(range(0,4*24,16))
    plt.tick_params(axis='both', which='major', labelsize=12)


    plt.xlabel("Hour of the day", fontsize=16)
    plt.ylabel("Power [kW]", fontsize=16)
    plt.title("Sintetic Eolic Production", fontsize=16)
    plt.grid()

    plt.subplot(1, 3, 3)
    norm = mcolors.Normalize(vmin=min(DS), vmax=max(DS))
    cmap = plt.cm.plasma
    for i in range(solarSin.shape[0]):plt.plot(XVALS,solarSin[i], color=cmap(norm(DS[i])),alpha=.5)
    plt.xticks(range(0,4*24,16))
    plt.tick_params(axis='both', which='major', labelsize=12)
    plt.grid()
    plt.xlabel("Hour of the day", fontsize=16)
    plt.ylabel("Power [kW]", fontsize=16)
    plt.title("Sintetic Solar production", fontsize=16)
    plt.tight_layout()
    plt.show()

def plotDepthHist(DCN,DSN,DEN):
    fig, (ax1,ax2) = plt.subplots(1,2,figsize=(16, 8))
    x=DCN.copy()
    values, base = np.histogram(x, bins=40)
    cumulative = np.cumsum(values)/1000
    ax2.plot(base[:-1], cumulative, c='green', label="Energy Consumption")
    x=DSN.copy()
    values, base = np.histogram(x, bins=40)
    cumulative = np.cumsum(values)/1000
    ax2.plot(base[:-1], cumulative, c='red', label="Solar Production")
    x=DEN.copy()
    values, base = np.histogram(x, bins=40)
    cumulative = np.cumsum(values)/1000
    ax2.plot(base[:-1], cumulative, c='blue', label="Eolic Production")


    ax2.grid(True)
    ax2.set_title('Uniform distribution to depth mapping')
    ax2.set_xlabel('Depth value')
    ax2.set_ylabel('Likelihood of occurrence')
    ax2.legend()

    n_bins=50
    # plot the cumulative histogram
    x=DCN.copy()
    n, bins, patches = ax1.hist(x, n_bins, density=True,color='green', label="Energy Consumption",alpha=.75)
    x=DEN.copy()
    n, bins, patches = ax1.hist(x, n_bins, density=True,color='red', label="Solar Production",alpha=.75)
    x=DSN.copy()
    n, bins, patches = ax1.hist(x, n_bins, density=True,color='blue', label="Eolic Production",alpha=.75)

    # Overlay a reversed cumulative histogram.
    # ax.hist(x, bins=bins, density=True, histtype='step', cumulative=-1,
    #         label='Reversed emp.')

    # tidy up the figure
    ax1.grid(True)
    ax1.legend(loc='right')
    ax1.set_title('Depth value distribution histogram')
    ax1.set_xlabel('Depth value')
    # ax1.set_ylabel('Likelihood of occurrence')

    plt.tight_layout()
    plt.show()
