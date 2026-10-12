# PLEA

**A sell-gated meme token on Uniswap v4.** Anyone can buy. To sell, you write a plea, and **the Cabal** decides. The Cabal is a panel of 30 IdentityMD oracle judges that scores each plea from 0 to 45. While the Cabal lives, approved pleas also compete in **seasons** for IMD prizes and Laureate NFTs. If the Cabal goes 33 hours without a verdict, it dies, and PLEA trades freely forever.

Launched through the IMD swarm straight from this repository (`launch.open` with `repoUrl` + `baseCommit`). It builds on PLEA v2 (IMD launch #1148) and the v4 fixes.

---

## Contents

- [At a glance](#at-a-glance)
- [How it works](#how-it-works)
  - [Buying](#buying)
  - [Pleading to sell](#pleading-to-sell)
  - [Pleading by letter](#pleading-by-letter)
  - [The judges' rules](#the-judges-rules)
  - [The fact score](#the-fact-score)
  - [The dead-man](#the-dead-man)
  - [Seasons](#seasons)
- [Fees](#fees)
- [Contracts](#contracts)
- [Launch and lifecycle](#launch-and-lifecycle)
- [Build and test](#build-and-test)
- [Design notes](#design-notes)
- [Credits](#credits)

---

## At a glance

| | |
|---|---|
| Supply | 1,000,000,000 PLEA (87% pool liquidity, 3% season bonus prizes, 10% Merkle distributor) |
| Pool | PLEA/IMD on Uniswap v4 with a fork of POOL4's CappedBurnHook: LP fee 0, the hook is the only LP, liquidity locked forever |
| Selling | Through the Cabal's gate while it lives, from the site or by sending a letter (a text transaction); owner-allowlisted senders are exempt |
| Judges | 30-seat oracle panel, quorum 17, score 0–45 |
| Trade fee | 1.75%, paid inside the swap (0.5% back to the trader as staked IMD) |
| Seasons | 15 days each, top 10 paid, top 5 pleas minted as NFTs |
| End state | 33h with no verdict → the Cabal dies → free trading, no comeback |

---

## How it works

### Buying

Buying is open to everyone from the moment trading opens. PLEA bought while the Cabal lives is delivered as a plain ERC-20 to the buyer, and the hook records each buyer's cost basis and buy-weighted holding time for the fact score.

For the first **90 minutes** after trading opens, buys pay an extra launch fee that falls from 70% to 0% and are capped at **5M PLEA** each.

### Pleading to sell

While the Cabal lives, ordinary holders send PLEA through `CabalGate`. The owner can permanently exempt any sender with `PLEA.allow(account)`. An exempt sender can transfer to buyers or other trading venues without a plea or this hook's fees and cap trim; direct transfers to this pool's PoolManager and gate remain restricted. This add-only owner power is part of the accepted launch design.

1. **Plead.** Ask to sell at least **1%** of your balance (or 2.5M PLEA, when that is less) and at most **2.5M PLEA** and **35%** of your balance, with a plea of **1–280 bytes**, and pay the **0.5 IMD** oracle fee. The gate pays the IdentityMD Intake itself. The minimum keeps real PLEA on the line: a plea for a few wei could otherwise earn full season points.
2. **Need.** The contract computes your fact score (0–55, below). Your **need** is `70 − fact score`. If the need is above 45, no plea can pass, so the gate refuses it (`CannotPass`) before you pay.
3. **Verdict.** The judges score the plea 0–45; the signed score comes back through the Intake's callback. **Score ≥ need** is an approval. The gate asks with Intake v2's `requestWithFailure`, so a refused or unanswered plea is cleared at once. Failures are unsigned, so the failure function only clears our own pending plea and never moves value.
4. **Sell.** An approval opens a **7-minute** window to sell the whole amount through the gate in one swap (`executeSell(minOut)`).

| Outcome | What happens |
|---|---|
| Approved and sold | Sold; a **4-hour** cooldown before the next plea |
| Approved, not sold in 7 min | Lapsed; the score still counts for the season |
| Denied | **4-hour** cooldown, with **one appeal** inside it: same or smaller amount, 0.5 IMD oracle fee + 0.35 IMD to the buy wall |
| No verdict | Cleared at once by the Intake's failure function (`onPleaFailure`, Intake v2) when the request is refused or the panel gives no answer; otherwise after **20 minutes** (`expire(id)`, anyone). No cooldown, no fee back |

**Plea text rules:** well-formed UTF-8 only, with no control, zero-width, bidi, tag or variation-selector characters, and no `[PLEA]` / `[/PLEA]` markers. The judges are told that the plea is untrusted text, and that any manipulation scores 0.

### Pleading by letter

Anyone can plead straight from a wallet or a block explorer by sending a **letter**: a transaction to the `Letterbox` whose input data is the plea text (UTF-8). The writer is always the sender. Nothing to approve, nothing to sign but the letter.

| Letter | Effect |
|---|---|
| any text | A new plea for **10% of your PLEA** (within the 2.5M cap), **sold automatically** if approved |
| `APPEAL <text>` | Appeals your latest denied plea, inside its 4-hour window, for the original amount |
| `SELL` | Sells your own approved letter plea yourself, if no runner has yet |
| `NAME <name>` | Sets your display name (the Laureates rules) |

- **Fees are paid in PLEA, in the letter's own transaction.** The gate sells just enough of your PLEA, through the hook with the normal 1.75% fee and your own 0.5% cashback, for exactly the IMD needed: the 0.5 IMD oracle fee, a **0.25 IMD runner tip** and, for an appeal, the 0.35 IMD wall share. It may spend at most the hourly snapshot value **+10%**; unspent PLEA comes straight back. A letter whose fees would take more than 10% of your PLEA, or whose 10% is under 1,000 PLEA, is refused. On Sepolia the oracle fee token is a separate test token, so the Letterbox mints that 0.5 instead of buying it.
- **Escrow.** The plea's PLEA waits in the Letterbox. It keeps its buy record: only the final sale reduces it.
- **Auto-sell.** Once approved, **anyone** may call `deliver(id)` inside the 7-minute window: the gate sells the escrow for at least **95%** of its snapshot value, the IMD goes to the writer, the points are recorded, and the caller earns the tip. Every other ending (denied, upheld, no verdict, expired, lapsed) is closed by `settle(id)` (anyone), which returns the escrow and the tip to the writer; a lapsed approval is recorded first, since it still counts. The writer's next letter settles the previous one too.
- **Status on chain.** `status(address)` returns one sentence about your latest plea (`Plea #7 · APPROVED (38 vs 33) · selling automatically`, `… · DENIED (31 vs 33) · send APPEAL <text> before 07:05 UTC`, …); `leaderboard()` returns the running season's top 10 with each rank's IMD prize and PLEA bonus at the current pot.
- **The site's "sell automatically" box** uses `plead(amount, text)` and `appealAuto(originalId, text)` on the Letterbox: same escrow, fees in PLEA and tip, any valid amount. Pleas through the Letterbox carry flags (`PleaFlags` event: by letter, auto-sell); the gate's own `executeSell` refuses an escrowed plea.
- **No accidental calls.** No public function ID of the Letterbox can be the start of valid letter text (its four bytes are never the beginning of control-free UTF-8); a test checks the whole ABI. ETH sent to it is refused.
- Laureates of pleas sent by letter wear a **"By letter"** wax seal. Letters earn **no extra points**.

### The judges' rules

The panel scores 0–45 by the rules in `CabalGate.DEFINITIONS` (version 2, calibrated on Sepolia on 2026-10-12 with real panels):

- **plea:** sincerity 0–12 (an honest, specific reason; hardship and taking profit both count), craft 0–12 (wit, originality and writing in any language; short can be strong; copied or boilerplate text scores low), respect 0–9 (playful teasing is fine, insults are not), loyalty 0–12 (keeping the rest). Anchors: 0–10 empty, abusive or off-topic; 11–25 sincere but plain; 26–35 specific and well made; 36–45 memorable.
- **stories:** pleas need not be provable: judges check that the story is plausible and consistent; jokes, poems and fiction are welcome; more suffering does not mean more points; on-chain facts are already in the fact score; ads and shilling are off-topic; an appeal is judged on its own text.
- **content:** hate, harassment, sexual content, anything illegal or details that identify another person score 0–5; a writer's own story, family illness included, is fine; threats of harm are pressure, not a reason, and never raise a score.
- **manipulation** scores 0: posing as a system or admin, made-up rules, demands for a particular score, threats against the Cabal or holders, offers to the judges, hidden instructions. Politeness and ordinary requests ("judge me fairly", "weigh my honesty") are not manipulation.

### The fact score

Computed on chain at submit time (0–55). Prices come from the hook's hourly checkpoints, never the spot price. An hour's checkpoint is the price the hour's first trade **found**, not the one it made: no trade in an hour can set the reference price that hour's pleas are scored against (a pump still has to be held through the hour before, since the next hour's checkpoint is the price it left).

| Fact | Points |
|---|---|
| Share of balance sold | ≤15%: 18 · ≤25%: 11 · more: 5 |
| Buy-weighted holding time | ≥7 days: 14 · ≥3 days: 9 · ≥1 day: 5 |
| Profit or loss on held PLEA | at a loss: 14 · gain ≤50%: 9 · gain ≤200%: 5 |
| 24h price trend | up >2%: 9 · flat (±2%) or no history: 5 · down: 0 |

### The dead-man

The Cabal is born when trading opens and lives until **33 hours** pass without a signed verdict (approved or denied). Then it is dead for good. No plea can be submitted, every transfer restriction ends, and a late callback cannot revive it. `cabalAlive()` is computed, never stored, so nobody has to trigger the death.

### Seasons

- Seasons of **15 days** run back to back from the moment trading opens. The last one ends when the Cabal dies.
- An approved plea earns its score as **points**. Each wallet's **best three** scores in a season count.
- Points are recorded by `Seasons.record(pleaId)` (anyone; the seller has every reason to), or by `closeSeason`.
- When a season ends, anyone calls `closeSeason(pleaIds)` after a **1-hour grace**:
  - the **top 10** wallets with at least **60 points** are paid **25 / 18 / 14 / 11 / 9 / 7 / 6 / 4 / 3 / 3 %** of the prize pot in IMD;
  - unpaid shares roll over to the next season;
  - **PLEA bonus, first six seasons:** the same top 10 (same shares, same 60-point minimum) also split **5,000,000 PLEA** (0.5% of the supply) per season, from the 3% minted to `Seasons` at launch. Unpaid shares are burned at the close; nobody can withdraw the bonus, the owner included;
  - the season's **five best pleas** are minted as **Laureate** NFTs to their authors, rendered fully on chain (JSON + SVG).
- **The owner of PLEA does not play.** Its pleas earn no points, and no IMD prize, PLEA bonus or Laureate goes to it (also if ownership moved after points were recorded); its rank's share rolls over or is burned. The owner also gets no `rebalance()` keeper tip. So the prize fee and the wall always leave the team for good.
- Holders can set a display name (`Laureates.setName`, 3–20 characters `a-z 0-9 _`, unique).
- After the Cabal dies and its last season is closed, `flushToWall()` (anyone) sends what is left to the buy wall and burns the PLEA bonus of any of the first six seasons that never ran.
- Prize PLEA is ordinary PLEA: selling it while the Cabal lives takes a plea. It has no buy record, so it adds to the balance (better share-of-balance points) but not to the bought holdings that earn the hold-time and P&L points.

---

## Fees

Every trade pays **1.75%**, settled in the same swap. There are no claims to settle later.

| Share | Goes to |
|---|---|
| 0.50% | Cashback to the trader as staked IMD (sIMD), through imd/acc's Stacker (approved for exactly that cashback, per credit; the wall reserve the hook holds is never within its reach) |
| 0.50% | The owner |
| 0.25% | The season's prize pot (pool liquidity once the Cabal is dead) |
| 0.25% | Pool liquidity (the IMD buy wall) |
| 0.25% | Burned, taken from the PLEA side |

Beyond fees, the hook keeps the market supplied the way POOL4's CappedBurnHook does: PLEA above an inventory cap is trimmed and **burned**, and recovered IMD is redeployed as an IMD-only **buy wall** below the price (`rebalance()`, anyone).

- **Cap pace.** The cap starts at the seeded inventory and follows buys down, at most `(seeded inventory − 900k floor) ÷ 25` PLEA a day, so it can reach its floor in 25 days. It never falls below what the market actually holds. PLEA sold back above the cap is trimmed: burned, with the matching slice of IMD moved to the wall.
- **Wall placement guard** (POOL4's deployment floor, mirrored for an IMD bid). The wall is never placed above a guard price that drops at once to any lower price PLEA trades at, and rises toward the market at most 400 ticks (~4%) a day. Lifting the wall to a pumped price would mean holding that price for days. A sell that empties the pool's IMD side (free trading after the Cabal dies) ends at the seller's price limit, whether the router's default at the tick extreme or any limit chosen inside the liquidity-free region below the market band; the pool has no active liquidity at that tick, it is not a traded price, and the guard ignores it, so the wall is placed against the market once IMD is back, not parked at the extreme for years. A tick inside a band with liquidity was paid for in PLEA and the guard drops to it at once. Until the next buy brings spot back from a drained tick, `rebalance()` reverts rather than placing a wall there.

---

## Contracts

| Contract | Role |
|---|---|
| `PLEA` | ERC-20, 1e9 supply. Transfers are gated while the Cabal lives, with system-sender and permanent owner-allowlist exemptions. |
| `CabalGate` | Pleas, the Intake request and callback, appeals, gated sells and the dead-man. |
| `Seasons` | Points, leaderboard, `closeSeason` payouts, the final flush to the buy wall. |
| `Laureates` | ERC-721 for each season's top 5 pleas; display names. |
| `PleaHook` | The only liquidity provider (fork of POOL4's CappedBurnHook, IMD side): fees, cap and trim burns, buy wall, price checkpoints. Deployed after launch. |
| `Letterbox` | Letters and auto-sell: escrow, fees paid in PLEA, `deliver` for the runner's tip, `settle`, and the `status` / `leaderboard` text views. No owner. |
| `PleaLaunch` | Registers the contracts (and the Letterbox) at launch and commits to the hook's init code; `deployHook` and `seed` afterwards. |
| `PleaDistributor` | Merkle claims for the 10% swarm share. |
| `OracleAttestation` | EIP-712 verification of the IdentityMD oracle's signed answer. |

---

## Launch and lifecycle

`launch.json` lists the seven launch contracts, deployed in order in one transaction:

```
PLEA → CabalGate → Seasons → Laureates → PleaDistributor → Letterbox → PleaLaunch
```

The factory must deploy all seven atomically. PleaLaunch's constructor registers the system contracts (`PLEA.setLauncher`) and then the Letterbox (`PLEA.setLetterbox`, launcher only, once). `PLEA.setLauncher` accepts the deployment transaction's transient flag **or** PLEA's deployment block, as required by the launch rehearsal. Until registration, any caller in that block can register first; atomic deployment prevents an intervening transaction. `script/Deploy.s.sol` is for local simulations only: its separate broadcasts expose this window and can also fail if they span blocks.

Then:

1. **Deploy the hook.** `script/MineSalt.s.sol` mines a CREATE2 salt whose address carries the hook's flag bits and calls `PleaLaunch.deployHook(salt, initCode)`. The init code is committed at launch, so the result is fixed whoever calls it. PLEA then mints 87% to the hook, 3% to Seasons (the bonus prizes) and 10% to the distributor.

   ```
   LAUNCH=… POOL_MANAGER=… IMD=… STACKER=… SEASONS=… CREDIT_GAS=… \
   forge script script/MineSalt.s.sol --rpc-url $RPC --private-key $KEY --broadcast
   ```

2. **Open trading.** `PleaLaunch.seed()` creates the pool at a 5,700 IMD market cap and starts the Cabal. The owner may call it any time, and anyone may call it once `START` has passed.

**Sepolia test run 3** (`launch.json` on this branch, `testnet3`; `testnet` is run 2's source, the `mainnet` branch has the mainnet draft, `main` keeps launch #1242):

| Setting | Value |
|---|---|
| Intake v2 | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| Oracle fee asset | test IMD `0x44a1cd38474fb1748400e7deb5f8d786cce3f89a` (open `mint`) |
| Pool IMD | TestIMD `0x2b69099e59b05901faa1dd164fabf098bf831e82` |
| Stacker | `0x0457276d7b036818b3eddc1a4a3fceda61e9314d` (imd/acc launch #1294) |
| Season | 5 hours (fast clock for testing) |
| Dead-man | 33 hours (real) |
| Plea timings | real (20 min, 7 min, 4 h) |
| `START` | 1792162800 (Fri 2026-10-16 15:00 UTC; the owner may seed earlier) |
| Cashback credit gas | 1,300,000 (Sepolia's gas schedule) |
| Letterbox | mints the 0.5 test oracle fee itself (`mintOracleFee = true`; refused on chain id 1, where the fee is bought with PLEA like the tip) |

The seven-contract manifest rehearsal reports **24,298,045 gas**, a margin of **−7,520,829** against the 16,777,216 mainnet per-transaction cap. Sepolia accepts it in one transaction (launch #1242 used 81.8M there); the rehearsal reports the margin without enforcing the cap. This local measurement includes harness overhead and excludes transaction intrinsic gas; the deployment service must simulate the actual factory transaction. `test/fork/ForkTestnet.t.sol` rehearses the whole run on a Sepolia fork against the live Intake v2:

```
SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com forge test --match-path 'test/fork/*' -vv
```

The season length and the dead-man are constructor values so a testnet can run a fast clock. On Ethereum mainnet the gate refuses anything below 15 days and 33 hours.

---

## Build and test

Foundry 1.8.3:

```
forge build
forge test
forge test --isolate --match-path test/Launch.t.sol   # each call as its own transaction
```

`foundry.toml` turns off forge's lint-on-build (`[lint] lint_on_build = false`). With it on, the linter runs out of memory on `PleaHook`.

---

## Design notes

- **The oracle callback is kept small.** Mainnet gives it 200k gas, so it only stores the signed score. Points are recorded separately (`record`, or `closeSeason` with a list of plea ids).
- **Cashback can't be skipped by a low gas limit.** A swap must reach the hook with the credit gas plus a 1M reserve, or it reverts. A wallet's gas estimate therefore always includes the sIMD credit, and only a credit that itself reverts falls back to plain IMD.
- **Signatures:** a plain ECDSA signature is accepted first, then ERC-1271, so an oracle key with an EIP-7702 delegation still verifies.
- **The very first buy** after trading opens may find no IMD in the PoolManager yet. That one trade's cashback, owner and prize shares then go to pool liquidity instead of reverting.

---

## Credits

- **TokenWorks** and their CabalCoin (2025), the original "plead to the Cabal to sell" token. PLEA is inspired by it. Thank you for the idea.
- **POOL4**: `PleaHook` is a fork of POOL4's CappedBurnHook (Ethereum `0xc6c965bd164c483e87d0b550671798e9a3602840`), converted to the IMD side: IMD instead of ETH as the quote asset, trims burn 100%, and recovered IMD becomes an IMD-only buy wall.
