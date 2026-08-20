import fs from "node:fs";
import { ethers } from "ethers";
import { hashNetputs, commitBalance, toHex32 } from "../scenario.js";

const env = (k: string, d?: string): string => {
  const v = process.env[k] ?? d;
  if (v === undefined) throw new Error(`missing env ${k}`);
  return v;
};

const RPC_URL = env("RPC_URL", "http://127.0.0.1:8545");
const DEPLOYER_KEY = env("DEPLOYER_KEY");
const N = Number(env("N_PROSUMERS", "50"));
const DEPOSIT_EUR = env("DEPOSIT_EUR", "50");
const GRID_MINT_EUR = env("GRID_MINT_EUR", "100000");
const FUND_ETH = env("FUND_ETH", "1");
const FEED_IN_C = env("FEED_IN_C", "8.86");
const OFF_PEAK_C = env("OFF_PEAK_C", "16.96");
const PEAK_C = env("PEAK_C", "21.46");
const PEAK_WINDOWS = env("PEAK_WINDOWS", "64800-79200");
const TARIFF_MODE = env("TARIFF_MODE", "schedule");   // "schedule" | "feed"
const N_REPORTERS = Number(env("N_REPORTERS", "3"));
const QUORUM = Number(env("QUORUM", "2"));
const ARTIFACTS = env("ARTIFACTS", "out");
const OUT = env("DEPLOY_OUT", "demo/state/deployed_demo.json");
const PROSUMERS_OUT = env("PROSUMERS_OUT", "demo/state/prosumers_demo.json");

type LinkRef = { start: number; length: number };
type Artifact = {
  abi: ethers.InterfaceAbi;
  bytecode: { object: string; linkReferences?: Record<string, Record<string, LinkRef[]>> };
};

function artifact(file: string, contract = file): Artifact {
  return JSON.parse(fs.readFileSync(`${ARTIFACTS}/${file}.sol/${contract}.json`, "utf-8")) as Artifact;
}

async function deploy(file: string, wallet: ethers.Wallet | ethers.NonceManager, args: unknown[], contract = file): Promise<ethers.Contract> {
  const a = artifact(file, contract);
  let code = a.bytecode.object;
  for (const [srcFile, libs] of Object.entries(a.bytecode.linkReferences ?? {})) {
    const libFile = srcFile.split("/").pop()!.replace(/\.sol$/, "");
    for (const [libName, refs] of Object.entries(libs)) {
      const lib = await deploy(libFile, wallet, [], libName);
      const addr = (await lib.getAddress()).slice(2).toLowerCase();
      for (const { start, length } of refs) {
        code = code.slice(0, 2 + start * 2) + addr + code.slice(2 + start * 2 + length * 2);
      }
    }
  }
  const f = new ethers.ContractFactory(a.abi, code, wallet);
  const c = await f.deploy(...args);
  await c.waitForDeployment();
  console.log(`${contract} (${file}) -> ${await c.getAddress()}`);
  return c as ethers.Contract;
}

async function main(): Promise<void> {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const chainId = (await provider.getNetwork()).chainId;
  const deployerWallet = new ethers.Wallet(DEPLOYER_KEY, provider);
  const deployer = new ethers.NonceManager(deployerWallet);

  const roles = {
    operator: ethers.Wallet.createRandom().connect(provider),
    grid: ethers.Wallet.createRandom().connect(provider),
    floorAdmin: ethers.Wallet.createRandom().connect(provider),
    reserve: ethers.Wallet.createRandom().connect(provider),
  };
  const feedMode = TARIFF_MODE.toLowerCase() === "feed";
  const reporters = feedMode
    ? Array.from({ length: N_REPORTERS }, () => ethers.Wallet.createRandom().connect(provider))
    : [];
  const prosumers = Array.from({ length: N }, () => ethers.Wallet.createRandom().connect(provider));

  const fund = ethers.parseEther(FUND_ETH);
  const targets = [...Object.values(roles), ...reporters, ...prosumers];
  await Promise.all(targets.map((w) => deployer.sendTransaction({ to: w.address, value: fund })));
  console.log(`funded ${targets.length} accounts with ${FUND_ETH} ETH each`);

  const eeur = await deploy("EnergyEuro", deployer, []);

  const wins = PEAK_WINDOWS.split(",").filter(Boolean).map((w) => w.split("-").map(Number));
  const schedule = {
    feedIn: ethers.parseEther(FEED_IN_C),
    retailOffPeak: ethers.parseEther(OFF_PEAK_C),
    retailPeak: ethers.parseEther(PEAK_C),
    winStart: wins.map((w) => w[0]),
    winEnd: wins.map((w) => w[1]),
  };
  // Schedule mode: one feed-in rate and a peak/off-peak retail split, set once.
  // Feed mode: a 96-slot price vector posted per day by reporters, finalised on
  // quorum. The schedule passed here is only the constructor's initial value and
  // is never read in feed mode.
  const tariff = feedMode
    ? await deploy("GridTariff", deployer, [1, roles.grid.address, schedule, reporters.map((w) => w.address), QUORUM])
    : await deploy("GridTariff", deployer, [0, roles.grid.address, schedule, [], 0]);
  console.log(feedMode
    ? `tariff in feed mode: ${reporters.length} reporter(s), quorum ${QUORUM}`
    : `tariff in schedule mode: feed-in ${FEED_IN_C}c, off-peak ${OFF_PEAK_C}c, peak ${PEAK_C}c`);

  const dayVerifier = await deploy("DayChunkVerifier", deployer, [], "HonkVerifier");
  const revealVerifier = await deploy("RevealVerifier", deployer, [], "HonkVerifier");

  const zeros = Array(96).fill(0n);
  const emptyNetputHash = toHex32(await hashNetputs(0n, 0n, zeros, zeros));
  const zeroBalCommit = toHex32(await commitBalance(0n, 0n));
  console.log(`padding constants (computed from circuits): ${emptyNetputHash} ${zeroBalCommit}`);

  const market = await deploy("MarketV4", deployer, [
    await eeur.getAddress(),
    await dayVerifier.getAddress(),
    await revealVerifier.getAddress(),
    await tariff.getAddress(),
    roles.operator.address,
    roles.grid.address,
    roles.floorAdmin.address,
    roles.reserve.address,
    emptyNetputHash,
    zeroBalCommit,
  ]);
  const marketAddr = await market.getAddress();
  const marketAbi = artifact("MarketV4").abi;
  const eeurAbi = artifact("EnergyEuro").abi;

  await Promise.all(prosumers.map((w) => {
    const m = new ethers.Contract(marketAddr, marketAbi, w);
    return m.register(w.signingKey.publicKey).then((tx: ethers.TransactionResponse) => tx.wait());
  }));
  console.log(`registered ${N} prosumers`);

  const depositWei = ethers.parseEther(DEPOSIT_EUR);
  await Promise.all([
    ...prosumers.map((w) => (eeur.connect(deployer) as ethers.Contract).mint(w.address, depositWei * 2n).then((tx: ethers.TransactionResponse) => tx.wait())),
    (eeur.connect(deployer) as ethers.Contract).mint(roles.grid.address, ethers.parseEther(GRID_MINT_EUR)).then((tx: ethers.TransactionResponse) => tx.wait()),
  ]);

  await Promise.all(prosumers.map(async (w) => {
    const e = new ethers.Contract(await eeur.getAddress(), eeurAbi, w);
    const m = new ethers.Contract(marketAddr, marketAbi, w);
    await (await e.approve(marketAddr, ethers.MaxUint256)).wait();
    await (await m.deposit(depositWei)).wait();
  }));
  console.log(`minted + deposited ${DEPOSIT_EUR} EUR per prosumer`);

  const gridEeur = new ethers.Contract(await eeur.getAddress(), eeurAbi, roles.grid);
  await (await gridEeur.approve(marketAddr, ethers.MaxUint256)).wait();
  console.log("grid approve done");

  const marketRead = new ethers.Contract(marketAddr, marketAbi, provider);
  const prosumerEntries: Record<string, { address: string; privateKey: string; slot: number }> = {};
  const simpleMap: Record<string, string> = {};
  for (let i = 0; i < N; i++) {
    const w = prosumers[i];
    const slot = Number(await marketRead.slotOf(w.address));
    prosumerEntries[`prosumer-${i}`] = { address: w.address, privateKey: w.privateKey, slot };
    simpleMap[`prosumer-${i}`] = w.address;
  }

  const outData = {
    chainId: Number(chainId),
    rpcUrl: RPC_URL,
    contracts: {
      eeur: await eeur.getAddress(),
      tariff: await tariff.getAddress(),
      dayVerifier: await dayVerifier.getAddress(),
      revealVerifier: await revealVerifier.getAddress(),
      market: marketAddr,
    },
    tariffMode: feedMode ? "feed" : "schedule",
    quorum: feedMode ? QUORUM : 0,
    reporters: reporters.map((w) => ({ address: w.address, privateKey: w.privateKey })),
    roles: Object.fromEntries(Object.entries(roles).map(([k, w]) => [k, { address: w.address, privateKey: w.privateKey }])),
    prosumers: prosumerEntries,
  };
  fs.writeFileSync(OUT, JSON.stringify(outData, null, 2));
  fs.writeFileSync(PROSUMERS_OUT, JSON.stringify(simpleMap, null, 2));
  console.log(`\nwrote ${OUT} + ${PROSUMERS_OUT}`);
  console.log(`\nrun the daemon:\nOPERATOR_KEY=${roles.operator.privateKey} MARKET_ADDRESS=${marketAddr} PROSUMERS_JSON=${PROSUMERS_OUT} npx tsx js_scripts/operator/main.ts`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
