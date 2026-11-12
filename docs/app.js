// ExitGuard console: a static page that deploys and exercises a personal ExitGuard through the visitor's wallet.
// No build step and no backend. Contract ABIs and bytecode come from `artifacts.js` (generated from the Foundry
// build by tools/export-artifacts.mjs).

(() => {
    "use strict";

    const { ethers } = window;
    const ARTIFACTS = window.EXITGUARD_ARTIFACTS;

    // ---------------------------------------------------------------------------------------------------------
    // Configuration. `window.EXITGUARD_CONFIG` can override any of it (used by the local test harness).
    // ---------------------------------------------------------------------------------------------------------

    // Destination chains this console knows. Pick one with `?chain=sepolia` (default) or `?chain=base-sepolia`.
    // Callback proxies: https://dev.reactive.network/origins-and-destinations
    // Faucets (send ETH, receive test REACT on Lasna at 1 : 100): https://dev.reactive.network/reactive-mainnet
    const DESTINATIONS = {
        sepolia: {
            chainId: 11155111,
            name: "Ethereum Sepolia",
            rpc: "https://ethereum-sepolia-rpc.publicnode.com",
            explorer: "https://sepolia.etherscan.io",
            currency: "ETH",
            callbackProxy: "0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4",
            reactFaucet: "0x9b9BB25f1A81078C544C829c5EB7822d747Cf434",
            guardFunding: "0.001", // ETH kept by the guard for callbacks
            // gwei. Wallets reserve gas limit x max fee up front, and the demo deployment needs about 42 million
            // gas on Sepolia, so the ceiling is kept low. The base fee there is a few wei.
            fees: { maxPriorityFeePerGas: "0.05", maxFeePerGas: "0.1" },
        },
        "base-sepolia": {
            chainId: 84532,
            name: "Base Sepolia",
            rpc: "https://sepolia.base.org",
            explorer: "https://sepolia.basescan.org",
            currency: "ETH",
            callbackProxy: "0x476F44b11F5C942c58f4c8E3d0300E5710743585",
            reactFaucet: "0x2afaFD298b23b62760711756088F75B7409f5967",
            guardFunding: "0.001",
        },
    };

    // The "other chain" of the cross-chain trigger, for each vault chain. `bridge` is the chain's own bridge
    // contract on the vault chain, which moves test ETH there.
    const SISTERS = {
        sepolia: {
            chainId: 84532,
            name: "Base Sepolia",
            rpc: "https://sepolia.base.org",
            explorer: "https://sepolia.basescan.org",
            currency: "ETH",
            // Base's L1StandardBridge on Ethereum Sepolia. Checked on-chain: its messenger's portal points at a
            // SystemConfig whose l2ChainId() is 84532.
            bridge: { address: "0xfd0Bf71F60660E2f608ed56e1659C450eB113120", amount: "0.0015" },
        },
        "base-sepolia": {
            chainId: 11155111,
            name: "Ethereum Sepolia",
            rpc: "https://ethereum-sepolia-rpc.publicnode.com",
            explorer: "https://sepolia.etherscan.io",
            currency: "ETH",
        },
    };

    const requested = new URLSearchParams(window.location.search).get("chain");
    const destinationKey = DESTINATIONS[requested] ? requested : "sepolia";

    const config = {
        destination: DESTINATIONS[destinationKey],
        sister: SISTERS[destinationKey],
        reactive: {
            chainId: 5318007,
            name: "Reactive Lasna",
            rpc: "https://lasna-rpc.rnk.dev/",
            explorer: "https://lasna.reactscan.net",
            currency: "lREACT",
            systemContract: "0x8888888888888888888888888888888888888888",
        },
        bob: "0x0000000000000000000000000000000000000B0b", // the depositor without ExitGuard
        timelockDelay: 120, // seconds
        faucetAmount: "0.03", // ETH sent to the faucet: 3 test REACT
        reactiveFunding: "0.3", // test REACT kept by the reactive contract
        waitSeconds: 240, // how long to wait for Reactive Network before giving up
        ...(window.EXITGUARD_CONFIG ?? {}),
    };

    const DEST = config.destination;
    const REACT = config.reactive;
    const SISTER = config.sister ?? null;

    // ---------------------------------------------------------------------------------------------------------
    // Wallet. With several wallet extensions installed, `window.ethereum` can be a router owned by one of them
    // that refuses to sign on networks it does not know (Reactive Lasna, for one). EIP-6963 lets the page talk
    // to MetaMask directly, so that is preferred when it announces itself.
    // ---------------------------------------------------------------------------------------------------------

    const announced = [];
    let wallet = window.ethereum ?? null;
    let walletName = wallet ? "browser wallet" : null;

    window.addEventListener("eip6963:announceProvider", (event) => {
        announced.push(event.detail);

        const metamask = announced.find((detail) => detail.info?.rdns === "io.metamask");
        const chosen = metamask ?? (window.ethereum ? null : announced[0]);

        if (chosen) {
            wallet = chosen.provider;
            walletName = chosen.info?.name ?? "wallet";
        }
    });
    window.dispatchEvent(new Event("eip6963:requestProvider"));

    /// Gas price overrides for the vault chain, when the preset has them. Wallets otherwise apply their own
    /// defaults, which on a testnet can be thousands of times the going rate.
    const destinationFees = () =>
        DEST.fees
            ? {
                  maxPriorityFeePerGas: ethers.parseUnits(DEST.fees.maxPriorityFeePerGas, "gwei"),
                  maxFeePerGas: ethers.parseUnits(DEST.fees.maxFeePerGas, "gwei"),
              }
            : {};
    const UPGRADE_SALT = ethers.id("exitguard-demo-upgrade");
    const SKIP_CAUSES = [
        "the position is not armed",
        "you hold no shares",
        "the guard has no allowance on your shares",
        "the vault reports nothing can be redeemed",
    ];

    // ---------------------------------------------------------------------------------------------------------
    // State: everything this run has produced, kept in localStorage per account so a reload loses nothing.
    // ---------------------------------------------------------------------------------------------------------

    let account = null;
    let sisterBalance = null; // the wallet's balance on the other chain, once the status panel has read it
    let state = {};
    let busy = null; // id of the step currently running
    const notes = {}; // transient progress or error text per step

    const storageKey = () => `exitguard.console.v1.${DEST.chainId}.${REACT.chainId}.${account}`;

    const load = () => {
        try {
            state = JSON.parse(localStorage.getItem(storageKey())) ?? {};
        } catch {
            state = {};
        }
    };

    const save = () => {
        try {
            localStorage.setItem(storageKey(), JSON.stringify(state));
        } catch {
            // Private windows may refuse storage; the run still works until the page is closed.
        }
    };

    // ---------------------------------------------------------------------------------------------------------
    // Chain access
    // ---------------------------------------------------------------------------------------------------------

    const readers = {};

    /// Read-only provider on the chain's public RPC, independent of which network the wallet is on.
    const reader = (chain) =>
        (readers[chain.rpc] ??= new ethers.JsonRpcProvider(chain.rpc, chain.chainId, { staticNetwork: true }));

    /// The wallet's own connection when it is on `chain` (most reliable), otherwise the public RPC.
    async function bestReader(chain) {
        try {
            const current = await wallet.request({ method: "eth_chainId" });
            if (BigInt(current) === BigInt(chain.chainId)) {
                return new ethers.BrowserProvider(wallet, chain.chainId);
            }
        } catch {
            // fall through to the public RPC
        }

        return reader(chain);
    }

    const hexChainId = (chain) => `0x${chain.chainId.toString(16)}`;

    /// Makes sure the wallet is on `chain` (asking it to add the network if needed) and returns a signer.
    async function signerOn(chain) {
        const current = await wallet.request({ method: "eth_chainId" });

        if (BigInt(current) !== BigInt(chain.chainId)) {
            try {
                await wallet.request({
                    method: "wallet_switchEthereumChain",
                    params: [{ chainId: hexChainId(chain) }],
                });
            } catch (error) {
                const unknown = error?.code === 4902 || error?.data?.originalError?.code === 4902;
                if (!unknown) throw error;

                await wallet.request({
                    method: "wallet_addEthereumChain",
                    params: [
                        {
                            chainId: hexChainId(chain),
                            chainName: chain.name,
                            rpcUrls: [chain.rpc],
                            nativeCurrency: { name: chain.currency, symbol: chain.currency, decimals: 18 },
                            blockExplorerUrls: chain.explorer ? [chain.explorer] : [],
                        },
                    ],
                });
            }

            const now = await wallet.request({ method: "eth_chainId" });
            if (BigInt(now) !== BigInt(chain.chainId)) {
                throw new Error(`Please switch your wallet to ${chain.name} and try again.`);
            }
        }

        return new ethers.BrowserProvider(wallet, chain.chainId).getSigner(account);
    }

    const contract = (name, address, runner) => new ethers.Contract(address, ARTIFACTS[name].abi, runner);

    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

    /// Polls `check` until it returns something truthy or the wait runs out. Returns null on timeout.
    async function waitFor(stepId, what, check) {
        const started = Date.now();

        for (;;) {
            let result = null;

            try {
                result = await check();
            } catch {
                // A public RPC hiccup; try again.
            }

            if (result) return result;

            const elapsed = Math.round((Date.now() - started) / 1000);
            if (elapsed > config.waitSeconds) return null;

            notes[stepId] = { kind: "warn", text: `${what} (${elapsed}s)` };
            render();
            await sleep(2000);
        }
    }

    /// Sends a transaction, waits for it, and returns its receipt.
    async function send(stepId, label, transactionPromise) {
        notes[stepId] = { kind: "warn", text: `${label}: confirm in your wallet...` };
        render();

        const transaction = await transactionPromise;

        notes[stepId] = { kind: "warn", text: `${label}: waiting for the transaction...` };
        render();

        const receipt = await transaction.wait();
        if (!receipt || receipt.status !== 1) throw new Error(`${label}: the transaction failed.`);

        return receipt;
    }

    const upgradeCall = () =>
        new ethers.Interface(["function upgradeToAndCall(address newImplementation, bytes data)"]).encodeFunctionData(
            "upgradeToAndCall",
            [state.demo.vaultV2, "0x"],
        );

    // ---------------------------------------------------------------------------------------------------------
    // Exit rehearsal
    // ---------------------------------------------------------------------------------------------------------

    const REQUEST_TYPE = "tuple(uint256 chainId, address recipient, uint256 gasLimit, bytes payload)";

    /// Replays the transaction that delivered the drill, with the exit payload in place of the drill's and the
    /// gas limit the reactive contract would ask for, as a simulation against the vault chain's current state.
    /// Nothing is sent. The answer is what a real exit would do right now, including whether the gas is enough:
    /// the first live run failed because that was guessed rather than measured.
    async function rehearse() {
        const provider = reader(DEST);
        const coder = ethers.AbiCoder.defaultAbiCoder();
        const guard = contract("ExitGuard", state.guard.address, provider);

        const delivery = await provider.getTransaction(state.drill.passedTx);
        const [head, body] = coder.decode(["uint256", "bytes"], ethers.dataSlice(delivery.data, 4));
        const [request] = coder.decode([REQUEST_TYPE], body);

        const limit = await contract("ExitGuardReactive", state.reactive.address, reader(REACT)).callbackGasLimit();
        const payload = guard.interface.encodeFunctionData("exit", [
            state.reactive.address,
            state.demo.vault,
            1, // an upgrade was scheduled
            DEST.chainId,
            0,
        ]);
        const input = ethers.concat([
            ethers.dataSlice(delivery.data, 0, 4),
            coder.encode(
                ["uint256", "bytes"],
                [head, coder.encode([REQUEST_TYPE], [[request.chainId, state.guard.address, limit, payload]])],
            ),
        ]);

        // The relayer scales the transaction's gas with the requested limit; keep its ratio.
        const gas = (delivery.gasLimit * limit) / request.gasLimit;

        const [block] = await provider.send("eth_simulateV1", [
            { blockStateCalls: [{ calls: [{ from: delivery.from, to: delivery.to, input, gas: ethers.toQuantity(gas) }] }] },
            "latest",
        ]);
        const call = block.calls[0];
        const event = call.logs
            .map((log) => parse(guard.interface, log))
            .find((parsed) => ["Exited", "ExitSkipped", "ExitFailed"].includes(parsed?.name));

        return {
            outcome: event?.name ?? "NotDelivered",
            gasUsed: Number(call.gasUsed),
            gasLimit: Number(limit),
        };
    }

    const number = (value) => Number(value).toLocaleString("en-US");
    const blocks = (count) => `${count} ${count === 1 ? "block" : "blocks"}`;

    function rehearsalText(result) {
        if (!result) return "not available from this page";

        switch (result.outcome) {
            case "Exited":
                return `an exit would succeed right now, using ${number(result.gasUsed)} of ${number(result.gasLimit)} gas`;
            case "ExitSkipped":
                return "there is nothing to redeem right now";
            case "ExitFailed":
                return (
                    `AN EXIT WOULD FAIL: the vault does not complete the redemption within the callback's ` +
                    `${number(result.gasLimit)} gas. Raise it with setCallbackGasLimit on the reactive contract.`
                );
            default:
                return "the callback would not reach the guard";
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // The steps
    // ---------------------------------------------------------------------------------------------------------

    const steps = [
        {
            id: "faucet",
            title: "Get test REACT",
            chain: DEST,
            hidden: () => !DEST.reactFaucet,
            optional: true,
            about: () =>
                `Sends ${config.faucetAmount} ${DEST.currency} to Reactive's faucet contract; the same wallet receives ` +
                `test REACT on ${REACT.name} at 1 : 100. Skip this if the wallet already holds test REACT.`,
            ready: () => true,
            done: () => !!state.faucet,
            async run() {
                const signer = await signerOn(DEST);
                const faucet = new ethers.Contract(DEST.reactFaucet, ["function request(address) payable"], signer);
                const receipt = await send(
                    "faucet",
                    "Faucet",
                    faucet.request(account, { value: ethers.parseEther(config.faucetAmount), ...destinationFees() }),
                );
                state.faucet = { tx: receipt.hash };
            },
            facts: () => [["Faucet transaction", tx(DEST, state.faucet.tx)]],
        },
        {
            id: "demo",
            title: "Set the stage: a vault behind a timelock",
            chain: DEST,
            about: () =>
                "One transaction deploys test dollars, a timelock, an upgradeable ERC-4626 vault owned by that timelock, " +
                "and the V2 code that will freeze withdrawals. You and Bob each get 1,000 test dollars deposited. " +
                "Bob does not run ExitGuard.",
            ready: () => true,
            done: () => !!state.demo,
            async run() {
                const signer = await signerOn(DEST);
                const factory = new ethers.ContractFactory(
                    ARTIFACTS.DemoDeployer.abi,
                    ARTIFACTS.DemoDeployer.bytecode,
                    signer,
                );
                const receipt = await send(
                    "demo",
                    "Demo protocol",
                    factory
                        .deploy(config.timelockDelay, account, config.bob, destinationFees())
                        .then((deployed) => deployed.deploymentTransaction()),
                );
                const deployed = contract("DemoDeployer", receipt.contractAddress, signer);

                state.demo = {
                    tx: receipt.hash,
                    usd: await deployed.usd(),
                    timelock: await deployed.timelock(),
                    vault: await deployed.vault(),
                    vaultV2: await deployed.vaultV2(),
                };
            },
            facts: () => [
                ["Vault (proxy)", address(DEST, state.demo.vault)],
                ["Timelock", address(DEST, state.demo.timelock)],
                ["Test dollars", address(DEST, state.demo.usd)],
                ["V2 code", address(DEST, state.demo.vaultV2)],
                ["Transaction", tx(DEST, state.demo.tx)],
            ],
        },
        {
            id: "reactive",
            title: "Deploy your reactive contract",
            chain: REACT,
            about: () =>
                `ExitGuardReactive goes first because the guard needs its address. It is funded with ` +
                `${config.reactiveFunding} ${REACT.currency} to pay for reactive transactions.`,
            ready: () => !!state.demo,
            done: () => !!state.reactive,
            async run() {
                const signer = await signerOn(REACT);
                const factory = new ethers.ContractFactory(
                    ARTIFACTS.ExitGuardReactive.abi,
                    ARTIFACTS.ExitGuardReactive.bytecode,
                    signer,
                );
                const receipt = await send(
                    "reactive",
                    "Reactive contract",
                    factory
                        .deploy(account, DEST.chainId, { value: ethers.parseEther(config.reactiveFunding) })
                        .then((deployed) => deployed.deploymentTransaction()),
                );

                state.reactive = { address: receipt.contractAddress, tx: receipt.hash };
            },
            facts: () => [
                ["ExitGuardReactive", address(REACT, state.reactive.address)],
                ["Transaction", tx(REACT, state.reactive.tx)],
            ],
        },
        {
            id: "guard",
            title: "Deploy your guard, approve it, arm it",
            chain: DEST,
            about: () =>
                `Three transactions next to the vault: deploy ExitGuard with ${DEST.guardFunding} ${DEST.currency} ` +
                "for callbacks, let it move your vault shares, and arm the position.",
            ready: () => !!state.reactive,
            done: () => !!state.guard?.armTx,
            async run() {
                const signer = await signerOn(DEST);
                state.guard ??= {};

                if (!state.guard.address) {
                    const factory = new ethers.ContractFactory(
                        ARTIFACTS.ExitGuard.abi,
                        ARTIFACTS.ExitGuard.bytecode,
                        signer,
                    );
                    const receipt = await send(
                        "guard",
                        "Guard",
                        factory
                            .deploy(DEST.callbackProxy, state.reactive.address, account, {
                                value: ethers.parseEther(DEST.guardFunding),
                                ...destinationFees(),
                            })
                            .then((deployed) => deployed.deploymentTransaction()),
                    );

                    state.guard.address = receipt.contractAddress;
                    state.guard.tx = receipt.hash;
                    save();
                }

                if (!state.guard.approveTx) {
                    const vault = contract("DemoVault", state.demo.vault, signer);
                    const receipt = await send(
                        "guard",
                        "Allowance",
                        vault.approve(state.guard.address, ethers.MaxUint256, destinationFees()),
                    );

                    state.guard.approveTx = receipt.hash;
                    save();
                }

                const guard = contract("ExitGuard", state.guard.address, signer);
                const receipt = await send(
                    "guard",
                    "Arm",
                    guard.arm(state.demo.vault, ethers.ZeroAddress, destinationFees()),
                );

                state.guard.armTx = receipt.hash;
            },
            facts: () => [
                ["ExitGuard", address(DEST, state.guard.address)],
                ["Deploy", tx(DEST, state.guard.tx)],
                ["Allowance", tx(DEST, state.guard.approveTx)],
                ["Arm", tx(DEST, state.guard.armTx)],
            ],
        },
        {
            id: "tripwires",
            title: "Link the two and lay the tripwires",
            chain: REACT,
            about: () =>
                "Three transactions on Reactive Network: tell the reactive contract where the guard is, then watch " +
                "the timelock for any call queued against the vault, and the vault's proxy for a new implementation " +
                "or a new admin.",
            ready: () => !!state.guard?.armTx,
            done: () => !!state.tripwires?.proxyTx,
            async run() {
                const signer = await signerOn(REACT);
                const reactive = contract("ExitGuardReactive", state.reactive.address, signer);
                state.tripwires ??= {};

                if (!state.tripwires.setGuardTx) {
                    const receipt = await send("tripwires", "Link", reactive.setGuard(state.guard.address));
                    state.tripwires.setGuardTx = receipt.hash;
                    save();
                }

                if (!state.tripwires.timelockTx) {
                    const receipt = await send(
                        "tripwires",
                        "Timelock tripwire",
                        reactive.watchTimelock(DEST.chainId, state.demo.timelock, state.demo.vault, state.demo.vault),
                    );
                    state.tripwires.timelockTx = receipt.hash;
                    save();
                }

                const receipt = await send(
                    "tripwires",
                    "Proxy tripwires",
                    reactive.watchProxy(DEST.chainId, state.demo.vault, state.demo.vault),
                );
                state.tripwires.proxyTx = receipt.hash;
            },
            facts: () => [
                ["Link guard", tx(REACT, state.tripwires.setGuardTx)],
                ["Timelock tripwire", tx(REACT, state.tripwires.timelockTx)],
                ["Proxy tripwires", tx(REACT, state.tripwires.proxyTx)],
            ],
        },
        {
            id: "drill",
            title: "Run a drill",
            chain: DEST,
            repeatable: true,
            about: () =>
                "A health check through the same path a real exit takes: the guard emits an event, Reactive Network " +
                "delivers it, the reactive contract answers with a callback. Nothing is redeemed. The console then " +
                "replays that delivery as a simulation with the exit in its place, to check the gas is enough.",
            ready: () => !!state.tripwires?.proxyTx,
            done: () => !!state.drill?.passedTx,
            async run() {
                const signer = await signerOn(DEST);
                const guard = contract("ExitGuard", state.guard.address, signer);
                const receipt = await send("drill", "Drill", guard.requestDrill(state.demo.vault, destinationFees()));
                const requested = receipt.logs
                    .map((log) => parse(guard.interface, log))
                    .find((event) => event?.name === "DrillRequested");

                state.drill = {
                    nonce: Number(requested.args.nonce),
                    requestTx: receipt.hash,
                    requestBlock: receipt.blockNumber,
                };
                save();

                const reading = contract("ExitGuard", state.guard.address, signer.provider);
                const record = await waitFor("drill", "Waiting for Reactive Network to answer", async () => {
                    const drill = await reading.drills(state.drill.nonce);
                    return drill.passed ? drill : null;
                });

                if (!record) throw new Error(unanswered());

                state.drill.seconds = Number(record.secondsElapsed);
                state.drill.blocks = Number(record.blocksElapsed);
                state.drill.tripwires = Number(record.tripwires);

                const passed = await reading.queryFilter(
                    reading.filters.DrillPassed(state.drill.nonce),
                    state.drill.requestBlock,
                );
                state.drill.passedTx = passed[0]?.transactionHash ?? "(not found)";
                state.drill.rehearsal = await rehearse().catch(() => null);
            },
            facts: () => [
                ["Round trip", escape(`${state.drill.seconds} s, ${blocks(state.drill.blocks)} on ${DEST.name}`)],
                ["Tripwires on this vault", escape(state.drill.tripwires)],
                ["Request", tx(DEST, state.drill.requestTx)],
                ["Answer (callback)", tx(DEST, state.drill.passedTx)],
                ["Exit rehearsal", escape(rehearsalText(state.drill.rehearsal))],
            ],
        },
        {
            id: "queue",
            title: "The protocol queues an upgrade",
            chain: DEST,
            section: {
                title: "Trigger A: an upgrade is queued",
                about: "The vault's own timelock announces a change. Everything happens on the vault's chain.",
            },
            about: () =>
                "You now play the protocol's admin and queue an upgrade of the vault in the timelock. That emits " +
                "CallScheduled with the vault as target, which is the tripwire. Your shares should be redeemed within " +
                "seconds, while the vault still runs the old code.",
            ready: () => !!state.drill?.passedTx && !state.incident?.outcome,
            blocked: () =>
                state.incident?.outcome && !state.exit?.outcome
                    ? "Your position already left in this run (trigger B). Start over to try this one."
                    : null,
            done: () => !!state.exit?.outcome,
            async run() {
                const signer = await signerOn(DEST);
                const timelock = contract("TimelockController", state.demo.timelock, signer);

                if (!state.exit?.scheduleTx) {
                    const delay = await timelock.getMinDelay();
                    const receipt = await send(
                        "queue",
                        "Queue upgrade",
                        timelock.schedule(
                            state.demo.vault,
                            0,
                            upgradeCall(),
                            ethers.ZeroHash,
                            UPGRADE_SALT,
                            delay,
                            destinationFees(),
                        ),
                    );
                    const block = await signer.provider.getBlock(receipt.blockNumber);

                    state.exit = {
                        scheduleTx: receipt.hash,
                        scheduleBlock: receipt.blockNumber,
                        scheduleTime: block.timestamp,
                        executableAt: block.timestamp + Number(delay),
                    };
                    save();
                }

                const guard = contract("ExitGuard", state.guard.address, signer.provider);
                const vault = state.demo.vault;

                const outcome = await waitFor("queue", "Waiting for the exit callback", async () => {
                    for (const name of ["Exited", "ExitSkipped", "ExitFailed"]) {
                        const found = await guard.queryFilter(guard.filters[name](vault), state.exit.scheduleBlock);
                        if (found.length > 0) return { name, event: found[0] };
                    }
                    return null;
                });

                if (!outcome) throw new Error(unanswered());

                const block = await signer.provider.getBlock(outcome.event.blockNumber);

                state.exit.outcome = outcome.name;
                state.exit.exitTx = outcome.event.transactionHash;
                state.exit.exitBlock = outcome.event.blockNumber;
                state.exit.exitTime = block.timestamp;
                state.exit.latencySeconds = block.timestamp - state.exit.scheduleTime;
                state.exit.latencyBlocks = outcome.event.blockNumber - state.exit.scheduleBlock;

                if (outcome.name === "Exited") {
                    state.exit.shares = ethers.formatEther(outcome.event.args.shares);
                    state.exit.assets = ethers.formatEther(outcome.event.args.assets);
                } else if (outcome.name === "ExitSkipped") {
                    state.exit.cause = SKIP_CAUSES[Number(outcome.event.args.cause)];
                }

                // Best effort: the reactive transaction that connected the two.
                try {
                    const reactive = contract("ExitGuardReactive", state.reactive.address, reader(REACT));
                    const from = REACT.rpc === DEST.rpc ? state.exit.scheduleBlock : -5000;
                    const tripped = await reactive.queryFilter(reactive.filters.Tripped(), from);
                    const match = tripped.find((event) => event.args.originTxHash === BigInt(state.exit.scheduleTx));
                    if (match) state.exit.reactiveTx = match.transactionHash;
                } catch {
                    // The explorer shows it too.
                }
            },
            facts: () => {
                const rows = [];

                if (state.exit.outcome === "Exited") {
                    rows.push([
                        "Result",
                        escape(`${state.exit.shares} shares redeemed for ${state.exit.assets} test dollars`),
                    ]);
                } else if (state.exit.outcome === "ExitSkipped") {
                    rows.push(["Result", escape(`exit skipped: ${state.exit.cause}`)]);
                } else {
                    rows.push(["Result", "the vault refused the redemption"]);
                }

                rows.push(
                    [
                        "Event to exit",
                        escape(`${state.exit.latencySeconds} s, ${blocks(state.exit.latencyBlocks)} on ${DEST.name}`),
                    ],
                    ["1. Origin event", tx(DEST, state.exit.scheduleTx)],
                    ["2. Reactive transaction", state.exit.reactiveTx ? tx(REACT, state.exit.reactiveTx) : "see the explorer"],
                    ["3. Callback (exit)", tx(DEST, state.exit.exitTx)],
                );

                return rows;
            },
        },
        {
            id: "execute",
            title: "The upgrade lands",
            chain: DEST,
            about: () =>
                "After the timelock's delay you execute the upgrade. The vault now runs the V2 code, which freezes " +
                "withdrawals. You are already out. Bob is not.",
            ready: () => !!state.exit?.outcome && Date.now() / 1000 >= state.exit.executableAt + 2,
            blocked: () => {
                if (!state.exit?.outcome) return null;
                const left = Math.ceil(state.exit.executableAt + 2 - Date.now() / 1000);
                return left > 0 ? `The timelock opens in ${left} s.` : null;
            },
            done: () => !!state.upgrade,
            async run() {
                const signer = await signerOn(DEST);
                const timelock = contract("TimelockController", state.demo.timelock, signer);
                const receipt = await send(
                    "execute",
                    "Execute upgrade",
                    timelock.execute(state.demo.vault, 0, upgradeCall(), ethers.ZeroHash, UPGRADE_SALT, destinationFees()),
                );
                const vault = contract("DemoVault", state.demo.vault, signer);

                state.upgrade = {
                    tx: receipt.hash,
                    version: await vault.version(),
                    bobCanRedeem: ethers.formatEther(await vault.maxRedeem(config.bob)),
                };
            },
            facts: () => [
                ["Vault code version", escape(state.upgrade.version)],
                ["Bob can redeem", escape(`${state.upgrade.bobCanRedeem} shares`)],
                ["Transaction", tx(DEST, state.upgrade.tx)],
            ],
        },
        {
            id: "bridge",
            title: `Get test ETH on ${SISTER?.name}`,
            chain: DEST,
            optional: true,
            hidden: () => !SISTER?.bridge,
            section: {
                title: "Trigger B: trouble on another chain",
                about:
                    "The same protocol runs on a second chain. When that deployment is paused, you leave this one, " +
                    "before the trouble can spread.",
            },
            about: () =>
                `Sends ${SISTER.bridge.amount} ${DEST.currency} through ${SISTER.name}'s own bridge; it arrives at the ` +
                `same address there a few minutes later, and you can carry on with the other steps meanwhile. Skip ` +
                `this if the wallet already holds ${SISTER.currency} on ${SISTER.name}.`,
            ready: () => true,
            done: () => !!state.bridge?.tx,
            async run() {
                const signer = await signerOn(DEST);
                const bridge = new ethers.Contract(
                    SISTER.bridge.address,
                    ["function bridgeETH(uint32 minGasLimit, bytes extraData) payable"],
                    signer,
                );
                const receipt = await send(
                    "bridge",
                    "Bridge",
                    bridge.bridgeETH(200000, "0x", {
                        value: ethers.parseEther(SISTER.bridge.amount),
                        ...destinationFees(),
                    }),
                );

                state.bridge = { tx: receipt.hash };
            },
            facts: () => [
                ["Bridge transaction", tx(DEST, state.bridge.tx)],
                [
                    `Arrived on ${SISTER.name}`,
                    sisterBalance === null ? "unknown" : sisterBalance > 0n ? "yes" : "not yet; it takes a few minutes",
                ],
            ],
        },
        {
            id: "sister",
            title: "The protocol also runs on another chain",
            chain: SISTER ?? DEST,
            hidden: () => !SISTER,
            section: SISTER?.bridge
                ? undefined
                : {
                      title: "Trigger B: trouble on another chain",
                      about:
                          "The same protocol runs on a second chain. When that deployment is paused, you leave this " +
                          "one, before the trouble can spread.",
                  },
            about: () =>
                `Deploys the demo protocol's sister deployment on ${SISTER.name}. You are its guardian, so you can play ` +
                `the incident response below.`,
            ready: () => !!state.demo && sisterBalance !== 0n,
            blocked: () => {
                if (state.sister || sisterBalance !== 0n) return null;
                return state.bridge?.tx
                    ? `The bridged test ETH has not arrived on ${SISTER.name} yet. This page checks again every few seconds.`
                    : `The wallet holds no ${SISTER.currency} on ${SISTER.name} yet.`;
            },
            done: () => !!state.sister,
            async run() {
                const signer = await signerOn(SISTER);
                const factory = new ethers.ContractFactory(
                    ARTIFACTS.DemoSister.abi,
                    ARTIFACTS.DemoSister.bytecode,
                    signer,
                );
                const receipt = await send(
                    "sister",
                    "Sister deployment",
                    factory.deploy(account).then((deployed) => deployed.deploymentTransaction()),
                );

                state.sister = { address: receipt.contractAddress, tx: receipt.hash };
            },
            facts: () => [
                ["Sister deployment", address(SISTER, state.sister.address)],
                ["Transaction", tx(SISTER, state.sister.tx)],
            ],
        },
        {
            id: "crosswire",
            title: "Lay a tripwire across chains",
            chain: REACT,
            hidden: () => !SISTER,
            about: () =>
                `One transaction on Reactive Network: if the deployment on ${SISTER.name} is paused, leave the vault ` +
                `on ${DEST.name}.`,
            ready: () => !!state.sister && !!state.tripwires?.proxyTx,
            done: () => !!state.crosswire,
            async run() {
                const signer = await signerOn(REACT);
                const reactive = contract("ExitGuardReactive", state.reactive.address, signer);
                const receipt = await send(
                    "crosswire",
                    "Cross-chain tripwire",
                    reactive.watchPause(SISTER.chainId, state.sister.address, state.demo.vault),
                );

                state.crosswire = { tx: receipt.hash };
            },
            facts: () => [["Tripwire", tx(REACT, state.crosswire.tx)]],
        },
        {
            id: "incident",
            title: `An incident on ${SISTER?.name}`,
            chain: SISTER ?? DEST,
            hidden: () => !SISTER,
            about: () =>
                `You play the protocol's guardian and pause the deployment on ${SISTER.name}. Nothing happens to the ` +
                `vault on ${DEST.name}, but the Paused event is the tripwire: your shares there should be redeemed ` +
                `within seconds.`,
            ready: () => !!state.crosswire && !!state.drill?.passedTx && !state.exit?.outcome,
            blocked: () => {
                if (state.incident?.outcome) return null;
                if (state.exit?.outcome) return "Your position already left in this run (trigger A). Start over to try this one.";
                if (state.crosswire && !state.drill?.passedTx) return "Run a drill first.";
                return null;
            },
            done: () => !!state.incident?.outcome,
            async run() {
                const guard = contract("ExitGuard", state.guard.address, reader(DEST));

                if (!state.incident?.pauseTx) {
                    // Where to start looking for the exit on the vault's chain.
                    const fromBlock = await reader(DEST).getBlockNumber();
                    const signer = await signerOn(SISTER);
                    const sister = contract("DemoSister", state.sister.address, signer);
                    const receipt = await send("incident", "Pause", sister.pause());
                    const block = await signer.provider.getBlock(receipt.blockNumber);

                    state.incident = {
                        pauseTx: receipt.hash,
                        pauseBlock: receipt.blockNumber,
                        pauseTime: block.timestamp,
                        fromBlock,
                    };
                    save();
                }

                const vault = state.demo.vault;

                const outcome = await waitFor("incident", `Waiting for the exit on ${DEST.name}`, async () => {
                    for (const name of ["Exited", "ExitSkipped", "ExitFailed"]) {
                        const found = await guard.queryFilter(guard.filters[name](vault), state.incident.fromBlock);
                        if (found.length > 0) return { name, event: found[0] };
                    }
                    return null;
                });

                if (!outcome) throw new Error(unanswered());

                const block = await reader(DEST).getBlock(outcome.event.blockNumber);

                state.incident.outcome = outcome.name;
                state.incident.exitTx = outcome.event.transactionHash;
                state.incident.exitBlock = outcome.event.blockNumber;
                state.incident.exitTime = block.timestamp;
                state.incident.latencySeconds = block.timestamp - state.incident.pauseTime;

                if (outcome.name === "Exited") {
                    state.incident.shares = ethers.formatEther(outcome.event.args.shares);
                    state.incident.assets = ethers.formatEther(outcome.event.args.assets);
                } else if (outcome.name === "ExitSkipped") {
                    state.incident.cause = SKIP_CAUSES[Number(outcome.event.args.cause)];
                }

                // Best effort: the reactive transaction that connected the two chains.
                try {
                    const reactive = contract("ExitGuardReactive", state.reactive.address, reader(REACT));
                    const head = await reader(REACT).getBlockNumber();
                    const tripped = await reactive.queryFilter(reactive.filters.Tripped(), Math.max(0, head - 5000));
                    const match = tripped.find((event) => event.args.originTxHash === BigInt(state.incident.pauseTx));
                    if (match) state.incident.reactiveTx = match.transactionHash;
                } catch {
                    // The explorer shows it too.
                }
            },
            facts: () => {
                const rows = [];

                if (state.incident.outcome === "Exited") {
                    rows.push([
                        "Result",
                        escape(`${state.incident.shares} shares redeemed for ${state.incident.assets} test dollars`),
                    ]);
                } else if (state.incident.outcome === "ExitSkipped") {
                    rows.push(["Result", escape(`exit skipped: ${state.incident.cause}`)]);
                } else {
                    rows.push(["Result", "the vault refused the redemption"]);
                }

                rows.push(
                    [
                        "Incident to exit",
                        escape(`${state.incident.latencySeconds} s, from ${SISTER.name} to ${DEST.name}`),
                    ],
                    [`1. Origin event (${SISTER.name})`, tx(SISTER, state.incident.pauseTx)],
                    [
                        "2. Reactive transaction",
                        state.incident.reactiveTx ? tx(REACT, state.incident.reactiveTx) : "see the explorer",
                    ],
                    [`3. Callback (${DEST.name})`, tx(DEST, state.incident.exitTx)],
                );

                return rows;
            },
        },
    ];

    const unanswered = () =>
        `No answer after ${config.waitSeconds} s. Check on ${REACT.name} that the reactive contract is active and ` +
        `funded, and that the guard holds ${DEST.currency} for callbacks. Press the button again to keep waiting.`;

    function parse(iface, log) {
        try {
            return iface.parseLog(log);
        } catch {
            return null;
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // Rendering
    // ---------------------------------------------------------------------------------------------------------

    const escape = (text) =>
        String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

    const link = (chain, kind, value) =>
        chain.explorer
            ? `<a href="${chain.explorer}/${kind}/${escape(value)}" target="_blank" rel="noopener"><code>${escape(value)}</code></a>`
            : `<code>${escape(value)}</code>`;

    const tx = (chain, hash) => (hash ? link(chain, "tx", hash) : "");
    const address = (chain, value) => (value ? link(chain, "address", value) : "");

    function render() {
        const visible = steps.filter((step) => !step.hidden?.());

        document.getElementById("steps").innerHTML = visible
            .map((step, index) => {
                const done = step.done();
                const running = busy === step.id;
                const note = notes[step.id];
                const blocked = !done && step.blocked?.();
                const canRun = !!account && !busy && step.ready() && (!done || step.repeatable);
                const label = done ? (step.repeatable ? "Run again" : "Done") : running ? "Working..." : "Run";
                const state_ = running ? "running" : note?.kind === "bad" ? "error" : done ? "done" : "";

                // Fact values are HTML built from explorer links and escaped text.
                const facts = done
                    ? `<dl>${step
                          .facts()
                          .map(([name, value]) => `<dt>${escape(name)}</dt><dd>${value}</dd>`)
                          .join("")}</dl>`
                    : "";

                const section = step.section
                    ? `<h3 class="section">${escape(step.section.title)}<small>${escape(step.section.about)}</small></h3>`
                    : "";

                return `${section}
                    <div class="card ${state_}" id="step-${step.id}">
                        <div class="head">
                            <span class="title">${index + 1}. ${escape(step.title)}${step.optional ? " (optional)" : ""}</span>
                            <span class="chain">${escape(step.chain.name)}</span>
                        </div>
                        <p class="about">${escape(step.about())}</p>
                        <button data-step="${step.id}" ${canRun ? "" : "disabled"}>${label}</button>
                        ${blocked ? `<p class="note warn">${escape(blocked)}</p>` : ""}
                        ${note ? `<p class="note ${note.kind}">${escape(note.text)}</p>` : ""}
                        ${facts}
                    </div>`;
            })
            .join("");

        document.getElementById("record").textContent = JSON.stringify(record(), null, 2);
        document.getElementById("refresh").disabled = !account;
        renderExamples();

        if (!window.EXITGUARD_CONFIG?.destination) {
            const others = Object.entries(DESTINATIONS)
                .filter(([key]) => key !== destinationKey)
                .map(([key, chain]) => `<a href="?chain=${key}">${escape(chain.name)}</a>`)
                .join(", ");

            document.getElementById("chains").innerHTML =
                `Vault chain: <strong>${escape(DEST.name)}</strong>. Reactive contract: <strong>${escape(REACT.name)}</strong>. ` +
                (SISTER ? `Other chain: <strong>${escape(SISTER.name)}</strong>. ` : "") +
                `Also available: ${others}.`;
        }
    }

    /// The run as plain data, for the README and the submission form.
    function record() {
        return {
            account,
            destination: { chain: DEST.name, chainId: DEST.chainId, callbackProxy: DEST.callbackProxy },
            reactiveNetwork: { chain: REACT.name, chainId: REACT.chainId },
            ...(SISTER ? { otherChain: { chain: SISTER.name, chainId: SISTER.chainId } } : {}),
            ...state,
        };
    }

    async function run(stepId) {
        const step = steps.find((candidate) => candidate.id === stepId);
        if (!step || busy) return;

        busy = stepId;
        delete notes[stepId];
        render();

        try {
            await step.run();
            delete notes[stepId];
        } catch (error) {
            const rejected = error?.code === "ACTION_REJECTED" || error?.code === 4001;
            const inner = error?.info?.error ?? error?.error ?? error;
            let text = rejected
                ? "You rejected the request in your wallet."
                : (inner?.message ?? error?.shortMessage ?? error?.message ?? String(error));

            // MetaMask can refuse to sign on a network it has only just been asked to add (error 4100), even
            // though the account is connected. Asking for the account permission again fixes it.
            if (inner?.code === 4100) {
                try {
                    await wallet.request({ method: "wallet_requestPermissions", params: [{ eth_accounts: {} }] });
                    text = "Your wallet had not authorized this network yet. That is fixed now: press Run again.";
                } catch {
                    text = "Your wallet has not authorized this page on this network. Reconnect the wallet and try again.";
                }
            }

            notes[stepId] = { kind: "bad", text };
        } finally {
            busy = null;
            save();
            render();
            refresh();
        }
    }

    // ---------------------------------------------------------------------------------------------------------
    // Status panel
    // ---------------------------------------------------------------------------------------------------------

    async function refresh() {
        if (!account) return;

        const rows = [];
        const add = (name, value) => rows.push(`<dt>${escape(name)}</dt><dd>${value}</dd>`);
        const attempt = async (name, read) => {
            try {
                add(name, escape(await read()));
            } catch {
                add(name, "could not be read from this page");
            }
        };

        const sisterBalanceBefore = sisterBalance;
        const destination = await bestReader(DEST);
        const reactiveChain = await bestReader(REACT);
        const ether = (wei, unit) => `${ethers.formatEther(wei)} ${unit}`;

        await attempt(`Wallet on ${DEST.name}`, async () => ether(await destination.getBalance(account), DEST.currency));
        await attempt(`Wallet on ${REACT.name}`, async () => ether(await reactiveChain.getBalance(account), REACT.currency));

        if (SISTER) {
            const sisterChain = await bestReader(SISTER);

            await attempt(`Wallet on ${SISTER.name}`, async () => {
                sisterBalance = await sisterChain.getBalance(account);
                return ether(sisterBalance, SISTER.currency);
            });

            if (state.sister) {
                await attempt(`Deployment on ${SISTER.name}`, async () =>
                    (await contract("DemoSister", state.sister.address, sisterChain).paused()) ? "paused" : "running",
                );
            }
        }

        if (state.demo) {
            const usd = contract("MockUSD", state.demo.usd, destination);
            const vault = contract("DemoVault", state.demo.vault, destination);

            await attempt("Vault code version", () => vault.version());
            await attempt("Your test dollars", async () => ethers.formatEther(await usd.balanceOf(account)));
            await attempt("Your vault shares", async () => ethers.formatEther(await vault.balanceOf(account)));
            await attempt("Bob's vault shares", async () => ethers.formatEther(await vault.balanceOf(config.bob)));
            await attempt("Bob can redeem", async () => `${ethers.formatEther(await vault.maxRedeem(config.bob))} shares`);
        }

        if (state.guard?.address) {
            const guard = contract("ExitGuard", state.guard.address, destination);
            const proxy = new ethers.Contract(DEST.callbackProxy, ["function debt(address) view returns (uint256)"], destination);

            await attempt("Guard", async () => {
                const ready = await guard.readiness(state.demo.vault);
                if (ready.shares_ > 0n && ready.armed_) {
                    return `armed; would redeem ${ethers.formatEther(ready.shares_)} shares to ${ready.receiver_}`;
                }
                return `nothing to redeem: ${SKIP_CAUSES[Number(ready.blocker_)]}`;
            });
            await attempt("Guard gas money", async () => ether(await destination.getBalance(state.guard.address), DEST.currency));
            await attempt("Guard debt to the callback proxy", async () => ether(await proxy.debt(state.guard.address), DEST.currency));
        }

        if (state.drill?.passedTx && !state.exit?.outcome && !state.incident?.outcome) {
            await attempt("Exit rehearsal", async () => rehearsalText(await rehearse()));
        }

        if (state.reactive?.address) {
            const reactive = contract("ExitGuardReactive", state.reactive.address, reactiveChain);
            const system = new ethers.Contract(REACT.systemContract, ["function debt(address) view returns (uint256)"], reactiveChain);

            await attempt("Reactive contract balance", async () => ether(await reactiveChain.getBalance(state.reactive.address), REACT.currency));
            await attempt("Reactive contract debt", async () => ether(await system.debt(state.reactive.address), REACT.currency));

            if (state.demo) {
                await attempt("Tripwires on the vault", async () => String(await reactive.tripwiresOf(state.demo.vault)));
            }
        }

        document.getElementById("status").innerHTML = `<dl>${rows.join("")}</dl>`;

        // A step may have been waiting for the balance this just read. Only then: redrawing the steps under
        // someone's pointer can swallow a click.
        if (!busy && sisterBalance !== sisterBalanceBefore) render();
    }

    // ---------------------------------------------------------------------------------------------------------
    // Vault scan (read-only, no wallet needed; the reading is done in scan.js)
    // ---------------------------------------------------------------------------------------------------------

    const SCAN = window.ExitGuardScan;
    const scanChains = { ...(config.scanChains ?? {}), ...SCAN.CHAINS };

    /// Vaults to try the scan on, chosen because they are built differently. Each address was read back from
    /// the chain (name and symbol) when this list was written.
    const EXAMPLES = config.scanExamples ?? [
        { label: "sDAI", chain: "ethereum", address: "0x83F20F44975D03b1b09e64809B757c47f942BEeA" },
        { label: "sUSDe", chain: "ethereum", address: "0x9D39A5DE30e57443BfF2A8307A4256c8797A3497" },
        { label: "steakUSDC", chain: "ethereum", address: "0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB" },
    ];

    const scanKeyOf = (chain) => Object.keys(scanChains).find((key) => scanChains[key].chainId === chain.chainId);

    function renderExamples() {
        const examples = [...EXAMPLES];
        const demoKey = scanKeyOf(DEST);

        if (state.demo && demoKey) {
            examples.unshift({ label: "this run's demo vault", chain: demoKey, address: state.demo.vault });
        }

        document.getElementById("scan-examples").innerHTML =
            examples.length === 0
                ? ""
                : "Try: " +
                  examples
                      .map(
                          (example) =>
                              `<button class="link" data-scan-chain="${escape(example.chain)}" ` +
                              `data-scan-address="${escape(example.address)}">${escape(example.label)}</button>`,
                      )
                      .join(" · ");
    }

    async function runScan() {
        const chain = scanChains[document.getElementById("scan-chain").value];
        const result = document.getElementById("scan-result");

        result.hidden = false;
        result.className = "card running";
        result.innerHTML = `<p class="about">Reading ${escape(chain.name)}...</p>`;

        try {
            const report = await SCAN.scan(chain, document.getElementById("scan-address").value.trim());
            window.EXITGUARD_LAST_SCAN = report;
            result.className = "card done";
            result.innerHTML = SCAN.render(report);
        } catch (error) {
            window.EXITGUARD_LAST_SCAN = null;
            result.className = "card error";
            result.innerHTML = `<p class="note bad">${escape(error?.shortMessage ?? error?.message ?? String(error))}</p>`;
        }
    }

    document.getElementById("scan-chain").innerHTML = Object.entries(scanChains)
        .map(([key, chain]) => `<option value="${escape(key)}">${escape(chain.name)}</option>`)
        .join("");

    document.getElementById("scan-run").addEventListener("click", runScan);

    document.getElementById("scan-address").addEventListener("keydown", (event) => {
        if (event.key === "Enter") runScan();
    });

    document.getElementById("scan-examples").addEventListener("click", (event) => {
        const { scanChain, scanAddress } = event.target?.dataset ?? {};
        if (!scanAddress) return;

        document.getElementById("scan-chain").value = scanChain;
        document.getElementById("scan-address").value = scanAddress;
        runScan();
    });

    // ---------------------------------------------------------------------------------------------------------
    // Wiring
    // ---------------------------------------------------------------------------------------------------------

    async function connect() {
        if (!wallet) {
            document.getElementById("who").textContent = "No wallet found. Install MetaMask, then reload this page.";
            return;
        }

        const accounts = await wallet.request({ method: "eth_requestAccounts" });
        setAccount(accounts[0]);
    }

    function setAccount(value) {
        account = value ? ethers.getAddress(value) : null;

        if (account) {
            load();
            document.getElementById("who").innerHTML =
                `Connected as <code>${escape(account)}</code> through ${escape(walletName)}`;
            document.getElementById("connect").textContent = "Connected";
        }

        render();
        refresh();
    }

    document.getElementById("connect").addEventListener("click", () => connect().catch((error) => {
        document.getElementById("who").textContent = error?.message ?? String(error);
    }));

    document.getElementById("steps").addEventListener("click", (event) => {
        const stepId = event.target?.dataset?.step;
        if (stepId) run(stepId);
    });

    document.getElementById("refresh").addEventListener("click", refresh);

    document.getElementById("copy").addEventListener("click", async () => {
        try {
            await navigator.clipboard.writeText(JSON.stringify(record(), null, 2));
            document.getElementById("copy").textContent = "Copied";
        } catch {
            document.getElementById("copy").textContent = "Select the text above and copy it";
        }
    });

    document.getElementById("reset").addEventListener("click", () => {
        if (!account || busy) return;
        if (!window.confirm("Forget this run's addresses and start over? Deployed contracts stay on chain.")) return;

        state = {};
        Object.keys(notes).forEach((key) => delete notes[key]);
        save();
        render();
        refresh();
    });

    wallet?.on?.("accountsChanged", (accounts) => {
        if (!busy) setAccount(accounts[0]);
    });

    // Keeps the timelock countdown moving.
    setInterval(() => {
        if (!busy && state.exit?.outcome && !state.upgrade) render();
    }, 1000);

    // Watches for the bridged test ETH to arrive on the other chain.
    setInterval(() => {
        if (!busy && account && SISTER && sisterBalance === 0n && !state.sister) refresh();
    }, 8000);

    render();

    // Reconnect silently if the wallet already trusts this page (after wallets had a moment to announce themselves).
    setTimeout(() => {
        wallet
            ?.request({ method: "eth_accounts" })
            .then((accounts) => accounts[0] && setAccount(accounts[0]))
            .catch(() => {});
    }, 400);
})();
