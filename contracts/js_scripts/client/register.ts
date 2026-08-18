import { Chain } from "./chain.js";
import { Identity } from "./identity.js";
import { Store } from "./store.js";

export type RegistrationStatus = {
  registered: boolean;
  slot: number;
  address: string;
  keyMatches: boolean | null;
  floorSet: boolean;
  floorPending: boolean;
  tradable: boolean;
  note: string;
};

const ZERO32 = "0x" + "0".repeat(64);

export async function status(chain: Chain, id: Identity, store: Store): Promise<RegistrationStatus> {
  const slot = await chain.slotOf(id.address);
  if (slot === 0) {
    return {
      registered: false, slot: 0, address: id.address, keyMatches: null,
      floorSet: false, floorPending: false, tradable: false,
      note: "not registered",
    };
  }

  const onchainKey = (await chain.market.encryptionKeyOf(slot)) as string;
  const keyMatches = id.ownsKey(onchainKey);

  const zeroCommit = (await chain.market.ZERO_BAL_COMMIT()) as string;
  const floorCommit = await chain.floorCommit(slot);
  const pendingFloor = (await chain.market.pendingFloorCommit(slot)) as string;

  const floorSet = floorCommit !== zeroCommit && floorCommit !== ZERO32;
  const floorPending = pendingFloor !== ZERO32;
  const hasOpening = store.floor() !== null;

  let note: string;
  if (!floorSet && floorPending) note = "awaiting metering hookup: a minimum balance requirement has been proposed and is awaiting confirmation";
  else if (!floorSet) note = "awaiting metering hookup: no minimum balance requirement set yet";
  else if (!hasOpening) note = "requirement set on chain, but its opening has not been received - margin alerts unavailable";
  else note = "active";

  return {
    registered: true, slot, address: id.address, keyMatches,
    floorSet, floorPending, tradable: floorSet,
    note,
  };
}

export async function register(chain: Chain, id: Identity, store: Store): Promise<RegistrationStatus> {
  const existing = await chain.slotOf(id.address);
  if (existing !== 0) {
    const st = await status(chain, id, store);
    store.setIdentity(st.slot, id.address, await chain.now());
    return st;
  }

  const key = id.encryptionPubKey;
  const bytes = (key.length - 2) / 2;
  const ok = (bytes === 33 && (key.startsWith("0x02") || key.startsWith("0x03")))
    || (bytes === 65 && key.startsWith("0x04"));
  if (!ok) throw new Error(`bad encryption key format: ${bytes} bytes, ${key.slice(0, 4)}`);

  await chain.register(key);

  const slot = await chain.slotOf(id.address);
  if (slot === 0) throw new Error("registration did not assign a slot");
  store.setIdentity(slot, id.address, await chain.now());
  return await status(chain, id, store);
}
