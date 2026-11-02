# Automated Market Making for Energy Sharing

This is a repository with source code for the paper ["Automated Market Making for Energy Sharing"](https://arxiv.org/abs/2512.24432) 

## Abstract

We develop an axiomatic theory for Automated Market Makers (AMMs) in local energy sharing markets and analyze the Markov Perfect Equilibrium of the resulting economy with a Mean-Field Game. In this game, heterogeneous prosumers solve a Bellman equation to optimize energy consumption, storage, and exchanges. Our axioms identify a class of mechanisms with linear, Lipschitz continuous payment functions, where prices decrease with the aggregate supply-to-demand ratio of energy. We prove that implementing batch execution and concentrated liquidity allows standard design conditions from decentralized finance-quasi-concavity, monotonicity, and homotheticity-to construct AMMs that satisfy our axioms.

The resulting AMMs are budget-balanced and achieve ex-ante efficiency, contrasting with the strategy-proof, expost optimal VCG mechanism. Since the AMM implements a Potential Game, we solve its equilibrium by first computing the social planner's optimum and then decentralizing the allocation. Numerical experiments using data from the Paris administrative region suggest that the prosumer community can achieve gains from trade up to 40% relative to the grid-only benchmark.

## Functions and code structure

- `supDem.py` - Python functions for Supply and demand creation.
- `rollingHorizon.py` - Prosumer-Level Gains from Decentralization code.
- `pricingFunction.py` - Grid-Level Gains from Decentralization.
- `data` - Folder with datasets used for paper results.

## Dataset

Dataset and depth values can be found in the following .csv files:

- `consumptionParis.csv` - Curves for energy consumption in Paris during 2023,  real consumption information from **[RTE](https://www.rte-france.com/en/data-publications/eco2mix/electricity-consumption-france)**.
- `consumption.csv` - Curves generated for energy consumption in Paris during 2023. Data is based on real consumption information from **RTE**.
- `solar.csv` - Curves generated for solar energy production in Paris during 2023 computed from **[Open-meteo](https://open-meteo.com/en/docs/historical-weather-api)**
- `eolic.csv`  - Curves generated for solar energy production in Paris during 2023.
- `depthConsumption.csv` - Depth values for energy consumption computed using **[data-depth](https://data-depth.github.io/)** for summer period between "2023-06-01" and "2023-08-31".
- `depthSolar.csv` - Depth values for solar energy production computed using **data-depth** for summer period between "2023-06-01" and "2023-08-31".
- `depthEolic.csv` - Depth values for eolic energy production computed using **data-depth** for summer period between "2023-06-01" and "2023-08-31".

## Authors

- **Michele Fabi** - Telecom Paris, CREST, IP Paris.
- **Viraj Nadkarni** - Princeton University.
- **Leonardo Leone** - Telecom Paris, CREST, IP Paris.
- **Matheus X.V. Ferreira** - University of Virginia.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
