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
            guardFunding: "0.003", // ETH kept by the guard for callbacks
            fees: { maxPriorityFeePerGas: "0.05", maxFeePerGas: "1" }, // gwei
        },
        "base-sepolia": {
            chainId: 84532,
            name: "Base Sepolia",
            rpc: "https://sepolia.base.org",
            explorer: "https://sepolia.basescan.org",
            currency: "ETH",
            callbackProxy: "0x476F44b11F5C942c58f4c8E3d0300E5710743585",
            reactFaucet: "0x2afaFD298b23b62760711756088F75B7409f5967",
            guardFunding: "0.005",
        },
    };

    const requested = new URLSearchParams(window.location.search).get("chain");
    const destinationKey = DESTINATIONS[requested] ? requested : "sepolia";

    const config = {
        destination: DESTINATIONS[destinationKey],
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
        reactiveFunding: "0.5", // test REACT kept by the reactive contract
        waitSeconds: 240, // how long to wait for Reactive Network before giving up
        ...(window.EXITGUARD_CONFIG ?? {}),
    };

    const DEST = config.destination;
    const REACT = config.reactive;

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
                "delivers it, the reactive contract answers with a callback. Nothing is redeemed.",
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
            },
            facts: () => [
                ["Round trip", escape(`${state.drill.seconds} s, ${state.drill.blocks} blocks on ${DEST.name}`)],
                ["Tripwires on this vault", escape(state.drill.tripwires)],
                ["Request", tx(DEST, state.drill.requestTx)],
                ["Answer (callback)", tx(DEST, state.drill.passedTx)],
            ],
        },
        {
            id: "queue",
            title: "The protocol queues an upgrade",
            chain: DEST,
            about: () =>
                "You now play the protocol's admin and queue an upgrade of the vault in the timelock. That emits " +
                "CallScheduled with the vault as target, which is the tripwire. Your shares should be redeemed within " +
                "seconds, while the vault still runs the old code.",
            ready: () => !!state.drill?.passedTx,
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
                        escape(`${state.exit.latencySeconds} s, ${state.exit.latencyBlocks} blocks on ${DEST.name}`),
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

                return `
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

        if (!window.EXITGUARD_CONFIG?.destination) {
            const others = Object.entries(DESTINATIONS)
                .filter(([key]) => key !== destinationKey)
                .map(([key, chain]) => `<a href="?chain=${key}">${escape(chain.name)}</a>`)
                .join(", ");

            document.getElementById("chains").innerHTML =
                `Vault chain: <strong>${escape(DEST.name)}</strong>. Reactive contract: <strong>${escape(REACT.name)}</strong>. ` +
                `Also available: ${others}.`;
        }
    }

    /// The run as plain data, for the README and the submission form.
    function record() {
        return {
            account,
            destination: { chain: DEST.name, chainId: DEST.chainId, callbackProxy: DEST.callbackProxy },
            reactiveNetwork: { chain: REACT.name, chainId: REACT.chainId },
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

        const destination = await bestReader(DEST);
        const reactiveChain = await bestReader(REACT);
        const ether = (wei, unit) => `${ethers.formatEther(wei)} ${unit}`;

        await attempt(`Wallet on ${DEST.name}`, async () => ether(await destination.getBalance(account), DEST.currency));
        await attempt(`Wallet on ${REACT.name}`, async () => ether(await reactiveChain.getBalance(account), REACT.currency));

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
    }

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

    render();

    // Reconnect silently if the wallet already trusts this page (after wallets had a moment to announce themselves).
    setTimeout(() => {
        wallet
            ?.request({ method: "eth_accounts" })
            .then((accounts) => accounts[0] && setAccount(accounts[0]))
            .catch(() => {});
    }, 400);
})();
