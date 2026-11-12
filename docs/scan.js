// ExitGuard vault scan: who can change this vault, how much warning would a depositor get, and which tripwires
// would ExitGuard lay? Read-only. It sends a handful of eth_call, eth_getCode and eth_getStorageAt requests to a
// public RPC and needs no wallet.
//
// It reads standard interfaces only: ERC-1967 proxy slots, owner(), OpenZeppelin and Compound timelocks, Safe,
// and MetaMorpho. Powers granted through AccessControl roles or custom logic are invisible to it, and it says so.

(() => {
    "use strict";

    const { ethers } = window;

    /// Chains the scan can read. Every one of them is an origin Reactive Network supports
    /// (https://dev.reactive.network/origins-and-destinations), so the tripwires it suggests can be laid.
    const CHAINS = {
        ethereum: { chainId: 1, name: "Ethereum", rpc: "https://ethereum-rpc.publicnode.com", explorer: "https://etherscan.io" },
        base: { chainId: 8453, name: "Base", rpc: "https://base-rpc.publicnode.com", explorer: "https://basescan.org" },
        arbitrum: { chainId: 42161, name: "Arbitrum", rpc: "https://arbitrum-one-rpc.publicnode.com", explorer: "https://arbiscan.io" },
        bsc: { chainId: 56, name: "BNB Chain", rpc: "https://bsc-rpc.publicnode.com", explorer: "https://bscscan.com" },
        sepolia: { chainId: 11155111, name: "Ethereum Sepolia", rpc: "https://ethereum-sepolia-rpc.publicnode.com", explorer: "https://sepolia.etherscan.io" },
        "base-sepolia": { chainId: 84532, name: "Base Sepolia", rpc: "https://sepolia.base.org", explorer: "https://sepolia.basescan.org" },
    };

    /// ERC-1967 storage slots, computed from their definition: keccak256(label) - 1.
    const slotOf = (label) => ethers.toBeHex(BigInt(ethers.id(label)) - 1n, 32);
    const SLOTS = {
        implementation: slotOf("eip1967.proxy.implementation"),
        admin: slotOf("eip1967.proxy.admin"),
        beacon: slotOf("eip1967.proxy.beacon"),
    };

    const PROBE = new ethers.Interface([
        "function name() view returns (string)",
        "function symbol() view returns (string)",
        "function asset() view returns (address)",
        "function totalAssets() view returns (uint256)",
        "function owner() view returns (address)",
        "function curator() view returns (address)",
        "function timelock() view returns (uint256)",
        "function MORPHO() view returns (address)",
        "function getMinDelay() view returns (uint256)",
        "function delay() view returns (uint256)",
        "function GRACE_PERIOD() view returns (uint256)",
        "function getOwners() view returns (address[])",
        "function getThreshold() view returns (uint256)",
    ]);

    /// Calls a view function that may well not exist. Returns the decoded value, or null.
    async function read(provider, address, name) {
        try {
            const data = await provider.call({ to: address, data: PROBE.encodeFunctionData(name) });
            return data === "0x" ? null : PROBE.decodeFunctionResult(name, data)[0];
        } catch {
            return null;
        }
    }

    /// The address stored in an ERC-1967 slot, or null when the slot is empty.
    async function slot(provider, address, position) {
        const word = await provider.getStorage(address, position);
        const value = ethers.getAddress(ethers.dataSlice(word, 12));
        return value === ethers.ZeroAddress ? null : value;
    }

    /// What kind of thing is in control: a plain key, a timelock, a multisig, or a contract owned by something
    /// else (a ProxyAdmin, typically), in which case the question moves one level up.
    async function classify(provider, address, depth = 0) {
        if (address === ethers.ZeroAddress) return { address, kind: "nobody" };

        const code = await provider.getCode(address);

        // No code, or an EIP-7702 delegation: an ordinary account, controlled by one private key.
        if (code === "0x" || code.startsWith("0xef0100")) return { address, kind: "key" };

        const [minDelay, grace, delay, signers, threshold, owner] = await Promise.all(
            ["getMinDelay", "GRACE_PERIOD", "delay", "getOwners", "getThreshold", "owner"].map((name) =>
                read(provider, address, name),
            ),
        );

        if (minDelay !== null) return { address, kind: "timelock", delay: Number(minDelay) };
        if (grace !== null && delay !== null) return { address, kind: "compound-timelock", delay: Number(delay) };
        if (signers !== null && threshold !== null) {
            return { address, kind: "safe", signers: signers.length, threshold: Number(threshold) };
        }
        if (owner !== null && depth < 3) {
            return { address, kind: "owned", owner: await classify(provider, owner, depth + 1) };
        }

        return { address, kind: "contract" };
    }

    /// Seconds of warning a depositor gets before `controller` can act: the delay of the first timelock on the
    /// way up, zero when a key or a multisig can act directly, Infinity when nobody can, and null when the scan
    /// does not recognise what is in control.
    function warningOf(controller) {
        switch (controller.kind) {
            case "timelock":
            case "compound-timelock":
                return controller.delay;
            case "owned":
                return warningOf(controller.owner);
            case "nobody":
                return Infinity;
            case "key":
            case "safe":
                return 0;
            default:
                return null;
        }
    }

    async function scan(chain, address) {
        if (!ethers.isAddress(address)) throw new Error("That is not an address.");

        const provider = new ethers.JsonRpcProvider(chain.rpc, chain.chainId, { staticNetwork: true });
        const vault = ethers.getAddress(address);

        if ((await provider.getCode(vault)) === "0x") {
            throw new Error(`There is no contract at this address on ${chain.name}.`);
        }

        const names = ["name", "symbol", "asset", "totalAssets", "owner", "curator", "MORPHO", "timelock"];
        const [values, implementation, admin, beacon] = await Promise.all([
            Promise.all(names.map((name) => read(provider, vault, name))),
            slot(provider, vault, SLOTS.implementation),
            slot(provider, vault, SLOTS.admin),
            slot(provider, vault, SLOTS.beacon),
        ]);
        const found = Object.fromEntries(names.map((name, index) => [name, values[index]]));

        const report = {
            chain,
            vault,
            name: found.name,
            symbol: found.symbol,
            erc4626: found.asset !== null && found.totalAssets !== null,
            asset: found.asset,
            assetSymbol: found.asset ? await read(provider, found.asset, "symbol") : null,
            implementation,
            ways: [], // each way the vault can be changed: { what, controller, warning }
            tripwires: [], // { call, why }
        };

        const wire = (call, why) => {
            if (!report.tripwires.some((existing) => existing.call === call)) report.tripwires.push({ call, why });
        };

        /// Follows a chain of control upwards, suggesting a tripwire at every level that announces itself.
        /// `target` is the contract the controller acts on.
        const follow = (controller, target) => {
            if (controller.kind === "timelock") {
                wire(
                    `watchTimelock(${chain.chainId}, ${controller.address}, ${target}, ${vault})`,
                    "early warning: the timelock queues a call",
                );
            } else if (controller.kind === "compound-timelock") {
                wire(
                    `watchCompoundTimelock(${chain.chainId}, ${controller.address}, ${target}, ${vault})`,
                    "early warning: the timelock queues a transaction",
                );
            } else if (controller.kind === "safe") {
                wire(
                    `watchSafe(${chain.chainId}, ${controller.address}, ${vault})`,
                    "the multisig's signers or threshold change",
                );
            } else if (controller.kind === "owned") {
                wire(
                    `watchOwnership(${chain.chainId}, ${controller.address}, ${vault})`,
                    "the contract in between changes hands",
                );
                follow(controller.owner, controller.address);
            }
        };

        const way = (what, controller, target) => {
            report.ways.push({ what, controller, warning: warningOf(controller) });
            follow(controller, target);
        };

        const owner = found.owner !== null ? await classify(provider, found.owner) : null;
        const isMetaMorpho = found.MORPHO !== null && found.curator !== null && found.timelock !== null;

        if (owner) {
            way(isMetaMorpho ? "Owner functions without a delay (fee, curator, allocators)" : "Owner-only functions", owner, vault);
            wire(`watchOwnership(${chain.chainId}, ${vault}, ${vault})`, "ownership of the vault moves");
        }

        if (admin) {
            way("Replace the code (transparent proxy)", await classify(provider, admin), vault);
        } else if (beacon) {
            way("Replace the code (beacon proxy)", await classify(provider, beacon), beacon);
            wire(`watchProxy(${chain.chainId}, ${beacon}, ${vault})`, "backstop: the beacon points at new code");
        } else if (implementation) {
            // No admin slot: the implementation itself decides who may upgrade, which is the owner as a rule.
            report.ways.push({
                what: "Replace the code (upgradeable proxy)",
                controller: owner ?? { address: implementation, kind: "implementation" },
                warning: owner ? warningOf(owner) : null,
            });
        }

        if (implementation) {
            wire(`watchProxy(${chain.chainId}, ${vault}, ${vault})`, "backstop: the code or the proxy admin changes");
        }

        // MetaMorpho: the vault carries its own timelock for the changes that loosen its risk rules.
        if (isMetaMorpho) {
            report.metaMorpho = { delay: Number(found.timelock), curator: found.curator };
            report.ways.push({
                what: "Loosen the risk rules (new markets, higher caps, new guardian, shorter timelock)",
                controller: { address: vault, kind: "timelock", delay: Number(found.timelock), own: true },
                warning: Number(found.timelock),
            });
            wire(
                `watchMetaMorpho(${chain.chainId}, ${vault}, false)`,
                "early warning: a rule change enters the vault's own timelock",
            );
        }

        // The verdict: "none" (nothing can change), "closed" (every way is shut), "instant" (someone can act
        // without delay), "unknown" (the scan cannot tell for at least one way), or "timelocked".
        const warnings = report.ways.map((entry) => entry.warning);
        const open = warnings.filter((warning) => warning !== Infinity);

        if (warnings.length === 0) report.verdict = "none";
        else if (open.length === 0) report.verdict = "closed";
        else if (open.includes(0)) report.verdict = "instant";
        else if (open.includes(null)) report.verdict = "unknown";
        else report.verdict = "timelocked";

        report.warning = report.verdict === "timelocked" ? Math.min(...open) : null;

        return report;
    }

    // ---------------------------------------------------------------------------------------------------------
    // Rendering
    // ---------------------------------------------------------------------------------------------------------

    const escape = (text) =>
        String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

    const duration = (seconds) => {
        const unit = (count, name) => `${count} ${name}${count === 1 ? "" : "s"}`;
        if (seconds >= 172800) return unit(Math.round(seconds / 86400), "day");
        if (seconds >= 7200) return unit(Math.round(seconds / 3600), "hour");
        if (seconds >= 120) return unit(Math.round(seconds / 60), "minute");
        return unit(seconds, "second");
    };

    const link = (chain, address) =>
        chain.explorer
            ? `<a href="${chain.explorer}/address/${escape(address)}" target="_blank" rel="noopener"><code>${escape(address)}</code></a>`
            : `<code>${escape(address)}</code>`;

    function describe(chain, controller) {
        switch (controller.kind) {
            case "key":
                return `${link(chain, controller.address)}, an ordinary account: one private key`;
            case "timelock":
                return controller.own
                    ? `the vault's own timelock of ${duration(controller.delay)}`
                    : `${link(chain, controller.address)}, a timelock with a delay of ${duration(controller.delay)}`;
            case "compound-timelock":
                return `${link(chain, controller.address)}, a Compound-style timelock with a delay of ${duration(controller.delay)}`;
            case "safe":
                return `${link(chain, controller.address)}, a Safe multisig (${controller.threshold} of ${controller.signers} signers)`;
            case "owned":
                return `${link(chain, controller.address)}, a contract owned by ${describe(chain, controller.owner)}`;
            case "nobody":
                return "nobody: ownership has been renounced";
            case "implementation":
                return "whoever the vault's own code allows; this scan cannot tell";
            default:
                return `${link(chain, controller.address)}, a contract this scan does not recognise`;
        }
    }

    const warningText = (warning) => {
        if (warning === null) return "unknown to this scan";
        if (warning === Infinity) return "cannot happen";
        return warning > 0 ? `${duration(warning)} of warning` : "no warning";
    };

    function render(report) {
        const { chain } = report;
        const title = report.name ? `${escape(report.name)} (${escape(report.symbol ?? "?")})` : "Unnamed contract";
        const kind = report.erc4626
            ? `ERC-4626 vault${report.assetSymbol ? ` holding ${escape(report.assetSymbol)}` : ""}`
            : "not an ERC-4626 vault, so ExitGuard could not redeem from it";

        const verdicts = {
            none: "The scan found no way to change this contract: no upgradeable proxy and no owner. There is nothing here for ExitGuard to watch.",
            closed: "Every way to change this vault that the scan found has been closed.",
            timelocked: `Every way to change this vault that the scan found goes through a timelock. The shortest warning is ${report.warning === null ? "" : duration(report.warning)}: that is the window ExitGuard uses.`,
            instant: "At least one way to change this vault has no delay. There, ExitGuard can only react after the fact.",
            unknown: "The scan cannot tell who is behind at least one way to change this vault, so it cannot promise any warning.",
        };
        const verdict = verdicts[report.verdict];
        const tone = ["instant", "unknown"].includes(report.verdict) ? "warn" : "good";

        const ways = report.ways
            .map(
                (entry) =>
                    `<dt>${escape(entry.what)}</dt><dd>${describe(chain, entry.controller)}<br><strong>${escape(warningText(entry.warning))}</strong></dd>`,
            )
            .join("");

        const tripwires = report.tripwires
            .map((entry) => `<li><code>${escape(entry.call)}</code><br><span class="why">${escape(entry.why)}</span></li>`)
            .join("");

        return `
            <div class="head"><span class="title">${title}</span><span class="chain">${escape(chain.name)}</span></div>
            <p class="about">${link(chain, report.vault)}: ${kind}.</p>
            <p class="note ${tone}">${escape(verdict)}</p>
            ${ways ? `<h3>Who can change it</h3><dl class="ways">${ways}</dl>` : ""}
            ${tripwires ? `<h3>Tripwires ExitGuard would lay</h3><ul class="wires">${tripwires}</ul>` : ""}
            <p class="fine">Read from ${escape(chain.name)} just now. The scan knows ERC-1967 proxies, <code>owner()</code>,
            OpenZeppelin and Compound timelocks, Safe and MetaMorpho. Powers granted through roles or custom logic
            are invisible to it, so treat an empty result as "nothing found", not as "nothing there".</p>`;
    }

    window.ExitGuardScan = { CHAINS, scan, render, duration };
})();
