# ExitGuard

**A personal tripwire for vault deposits. When the contract holding your money is about to change, ExitGuard takes you out first and lets you decide later.**

Built for the [Reactive Omni Buildathon](https://dorahacks.io/hackathon/reactive-omni-buildathon), track *Set It and Forget It*.

## The problem it solves for me

Price alerts are easy to get. The risk I cannot watch around the clock is governance: an upgrade being queued, an owner changing, a proxy pointing at new code. Those are the moments a vault's risk changes, and they happen while I am asleep.

The rule I wanted automated is simple:

> If the contract holding my deposit is about to change, get me out first. I will read the change in the morning and go back in if I like it.

ExitGuard is that rule, running on Reactive Network with no bot, no server and no keys online.

## What happens

1. I deposit into an ERC-4626 vault as usual. The shares stay in my wallet.
2. I give my `ExitGuard` contract an allowance on those shares and arm it.
3. On Reactive Network, my `ExitGuardReactive` contract holds **tripwires**: governance events on any supported chain that should make me leave.
4. A tripwire fires, for example the vault's timelock emits `CallScheduled` with the vault as target.
5. Reactive Network calls `react()`; the reactive contract requests a callback; the callback proxy calls `ExitGuard.exit()`.
6. The guard redeems my shares straight to my wallet (or a cold wallet I chose), while the vault still runs the old code.

```mermaid
sequenceDiagram
    autonumber
    participant Admin as Protocol admin
    participant TL as Timelock (vault chain)
    participant RN as ExitGuardReactive (Reactive Lasna)
    participant CP as Callback proxy (vault chain)
    participant G as ExitGuard (vault chain)
    participant V as Vault (vault chain)
    participant Me as My wallet

    Admin->>TL: schedule(upgrade vault)
    TL-->>RN: CallScheduled(target = vault)
    Note over RN: react(): the tripwire matches,<br/>target is read from the event data
    RN->>CP: requestCallbackV_1_0(exit)
    CP->>G: exit(reactive, vault, reason, ...)
    G->>V: redeem(my shares, receiver = me, owner = me)
    V->>Me: assets
    Note over V: two minutes later the upgrade lands.<br/>I am already out.
```

## Why this needs Reactive Network

The trigger is an event on one contract (a timelock, a proxy, a sister deployment on another chain). The action is a transaction on a different contract, possibly on a different chain. Nothing on-chain connects the two by itself; the usual answer is an off-chain bot with a hot key. Here the reactive contract is the bot: it subscribes to the events, decides in Solidity, and asks for the callback.

The reactive contract does real work beyond forwarding. A subscription can only filter on indexed topics, but a timelock puts the *target* of a queued call in the event's data. `ExitGuardReactive` therefore matches each log against three optional topic filters and one optional 32-byte data word, so "the timelock queued something against **my** vault" is distinguished from "the timelock queued something".

## What is in the box

| Contract | Chain | Role |
|---|---|---|
| [`ExitGuardReactive`](src/ExitGuardReactive.sol) | Reactive Network | Holds the tripwires, reacts to matching events, requests the exit. |
| [`ExitGuard`](src/ExitGuard.sol) | Where the vault is | Receives the callback and redeems the owner's shares to the owner's receiver. |
| [`BoundedCall`](src/libraries/BoundedCall.sol) | (library) | Calls into the vault with a gas budget and capped return data. |
| [`src/demo/*`](src/demo) | Testnet only | Test dollars, an upgradeable vault behind a timelock, and a V2 that freezes withdrawals. |

### Tripwires that come ready-made

| Call | Fires on | Reason code |
|---|---|---|
| `watchTimelock(chain, timelock, target, vault)` | OpenZeppelin `TimelockController.CallScheduled` whose target is `target` | 1 |
| `watchProxy(chain, proxy, vault)` | ERC-1967 `Upgraded` and `AdminChanged` | 2, 3 |
| `watchOwnership(chain, ownable, vault)` | `OwnershipTransferStarted` and `OwnershipTransferred` | 4, 5 |
| `watchPause(chain, pausable, vault)` | `Paused`, typically on a related contract or another chain | 6 |
| `addTripwire(tripwire)` | Any event, with topic and data-word filters of your choice | yours |

### The drill

A safety tool that fails silently is worse than none. `ExitGuard.requestDrill(vault)` emits an event; the reactive contract answers through the same path a real exit would take; the guard emits `DrillPassed` with the round-trip time in seconds and blocks, and the number of tripwires guarding that vault. Nothing is redeemed. If a drill is not answered, something is unfunded or unlinked, and I know before it matters.

## Built for a vault that may have turned hostile

`exit()` runs at the exact moment the vault's code or owner is changing, so the guard treats the vault as untrusted:

- **Only my funds, only to my receiver.** A callback can only redeem the owner's shares to the receiver the owner configured. A forged or mistaken trigger costs yield and gas, never principal.
- **Two-factor callback authentication.** `onlyServiceProvider` (the caller is the callback proxy) and `onlyCallbackSender` (the request came from my reactive contract).
- **Bounded calls.** Every call into the vault copies at most one word of return data and at most 256 bytes of revert data. A vault cannot exhaust the callback's gas with a large blob.
- **Gas reserve.** 60,000 gas is kept back from the redemption, so a vault that burns everything still leaves room to record `ExitFailed`.
- **Never reverts because of the vault.** Failed callbacks are billed anyway; the guard records `ExitFailed` or `ExitSkipped` with a cause and stays armed, so the next tripwire or `exitNow()` can retry.
- **Cooldown.** One governance action often emits several watched events. The reactive contract requests at most one exit per vault per cooldown (five minutes by default).

## Try it

### 1. Tests

```bash
git clone <this repository> && cd exitguard
forge install --no-git foundry-rs/forge-std@v1.17.0 OpenZeppelin/openzeppelin-contracts@v5.7.0 \
  OpenZeppelin/openzeppelin-contracts-upgradeable@v5.7.0 Reactive-Network/reactive-lib-omni
forge test
```

100 tests cover both contracts and the library at 100% of lines and branches, including fuzzing of the matcher and an end-to-end run against a real OpenZeppelin `TimelockController` and UUPS proxy.

One of them, `test_WatchingOnlyTheProxyIsTooLate`, shows why the *early* tripwire matters: if you only watch `Upgraded`, the hostile code is already live when your exit arrives.

### 2. The whole story on your laptop, in one command

No testnet tokens needed. A small script plays the part of Reactive Network on a local anvil chain and runs the same deployment scripts used on the testnets.

```bash
cd tools && npm install && node local-demo.mjs
```

```text
6. The protocol's admin queues an upgrade of the vault in the timelock.
   [reactive] tripwire #0 fired for the vault (reason 1)
   [guard] position disarmed
   [guard] EXITED: 1000.0 shares redeemed for 1000.0 mUSD
   The vault still runs version 1.
   You: 1000.0 mUSD in your wallet, 0.0 vault shares
   Bob: 0.0 mUSD in his wallet, 1000.0 vault shares

7. Two minutes later the upgrade lands. The new code freezes withdrawals.
   Vault now runs version 2
   [reactive] tripwire #1 fired again, inside the cooldown: no second callback
   Bob can redeem: 0.0 shares.

Result: you left with all 1,000 mUSD before the new code went live. Bob is locked in.
```

### 3. On the testnets (Ethereum Sepolia or Base Sepolia, plus Reactive Lasna)

You need a throwaway wallet with a little test ETH on the vault's chain. Part of it becomes test REACT through Reactive's faucet contract (1 ETH gives 100 lREACT).

**In the browser.** The [ExitGuard console](docs/index.html) is a static page (served from `docs/` with GitHub Pages) that runs every step through your wallet: get test REACT, deploy, arm, lay tripwires, drill, queue the upgrade, execute it. It waits for Reactive Network at each step, measures the latency, and collects the addresses and transaction hashes of the run. It defaults to Ethereum Sepolia; add `?chain=base-sepolia` for Base Sepolia.

**From the terminal.** The same steps as Foundry scripts. `VAULT_RPC` is the RPC of the vault's chain.

```bash
cp .env.example .env && source .env
cast wallet import exitguard --interactive        # paste the throwaway key; it is stored encrypted

# Test REACT for the reactive contract (faucet address for Ethereum Sepolia; see .env.example for Base Sepolia)
cast send $REACT_FAUCET "request(address)" $YOU --value 0.03ether --rpc-url $VAULT_RPC --account exitguard

forge script script/01_DeployDemo.s.sol     --rpc-url $VAULT_RPC --account exitguard --broadcast
forge script script/02_DeployReactive.s.sol --rpc-url $LASNA_RPC --account exitguard --broadcast
forge script script/03_DeployGuard.s.sol    --rpc-url $VAULT_RPC --account exitguard --broadcast
forge script script/04_LayTripwires.s.sol   --rpc-url $LASNA_RPC --account exitguard --broadcast

forge script script/05_Drill.s.sol          --rpc-url $VAULT_RPC --account exitguard --broadcast
forge script script/Status.s.sol            --rpc-url $VAULT_RPC   # drill answered?

forge script script/06_QueueUpgrade.s.sol   --rpc-url $VAULT_RPC --account exitguard --broadcast
forge script script/Status.s.sol            --rpc-url $VAULT_RPC   # your test dollars are back

# after the timelock delay (two minutes)
forge script script/07_ExecuteUpgrade.s.sol --rpc-url $VAULT_RPC --account exitguard --broadcast
```

Addresses are passed between steps through small JSON files in `deployments/`, so nothing is copied by hand.

## Live deployment

_To be filled in after the testnet run: contract addresses on the vault chain and on Reactive Lasna, the transaction hashes of one full loop (origin event, reactive transaction, callback), and the measured latency._

## Using it for a real position

1. Deploy `ExitGuardReactive(owner, destinationChainId)` on Reactive Network and fund it with REACT.
2. Deploy `ExitGuard(callbackProxy, reactive, owner)` on the vault's chain and fund it with that chain's native token. Callback proxy addresses are listed in the [Reactive docs](https://dev.reactive.network/origins-and-destinations).
3. `reactive.setGuard(guard)`.
4. Lay tripwires. Start with the earliest signal the protocol offers: its timelock, then ownership, then the proxy.
5. On the vault's chain: `vault.approve(guard, amount)` and `guard.arm(vault, receiver)`.
6. `guard.requestDrill(vault)` now, and again whenever you want to know it still works.

After an exit the position is disarmed. To come back: deposit, `arm` again. The tripwires stay in place.

## Limits, stated plainly

- **It cannot outrun an atomic attack.** If a contract is upgraded and drained in one transaction, no reaction is fast enough. ExitGuard is for the common case where governance leaves a trace first: a queued call, a started ownership transfer, a pause elsewhere.
- **Watching only `Upgraded` is usually too late**, as the test above shows. Use it as a backstop, not as the plan.
- **ERC-4626 only.** Vaults with withdrawal queues or cooldowns can refuse the redemption. The guard reports it and stays armed; it cannot force a vault to pay.
- **It depends on Reactive Network and on both contracts staying funded.** A contract in debt receives no events. The drill is how you find out.
- **Anyone who can make a watched contract emit a watched event can make you exit.** That is griefing, not theft: the assets still go to your receiver.
- **One guard, one owner.** This is a personal tool, not a shared service.
- **Not audited.** It has only run on testnets. Do not put real funds behind it without a review.

## Repository layout

```text
src/                 ExitGuard, ExitGuardReactive, BoundedCall, IExitGuard
src/demo/            MockUSD, DemoVault (UUPS + ERC-4626), DemoVaultV2 (frozen), DemoDeployer
test/                100 tests; mocks of the system contract and the callback proxy
script/              numbered deployment and demo steps, plus a read-only Status report
docs/                the web console (static; no build step)
tools/               local-demo.mjs (one-command local demo), export-artifacts.mjs (feeds the console)
```

## Notes

- Uses [`reactive-lib-omni`](https://github.com/Reactive-Network/reactive-lib-omni): `SYSTEM.subscribe`, `react()` guarded by `onlySystem`, and `SYSTEM.requestCallbackV_1_0`.
- Solidity 0.8.30, Foundry, OpenZeppelin Contracts 5.7.
- MIT licensed.
