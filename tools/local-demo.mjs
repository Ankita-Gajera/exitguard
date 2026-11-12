#!/usr/bin/env node
// Runs the whole ExitGuard story on a local anvil chain, in about a minute, with no testnet tokens.
//
// Reactive Network is replaced by a small stand-in: the test doubles from `test/mocks` play the system contract
// and the callback proxy, and this script plays the network itself. It hands every new log to the reactive
// contract and delivers every callback the reactive contract asks for.
//
// The contracts and the numbered scripts are exactly the ones used on the real testnets.
//
//   cd tools && npm install && node local-demo.mjs

import { spawn, execFileSync } from "node:child_process";
import { readFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ethers } from "ethers";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const PORT = process.env.PORT ?? "8545";
const RPC = `http://127.0.0.1:${PORT}`;
const SYSTEM = "0x8888888888888888888888888888888888888888";

// anvil's public development mnemonic. These accounts exist on every anvil chain; never use them elsewhere.
const MNEMONIC = "test test test test test test test test test test test junk";
const account = (index) => ethers.HDNodeWallet.fromPhrase(MNEMONIC, undefined, `m/44'/60'/0'/0/${index}`);

const artifact = (file, name = file) =>
    JSON.parse(readFileSync(join(ROOT, "out", `${file}.sol`, `${name}.json`), "utf8"));

const deployment = (file) => JSON.parse(readFileSync(join(ROOT, "deployments", `${file}.json`), "utf8"));

const say = (text = "") => console.log(text);
const step = (number, text) => say(`\n\x1b[1m${number}. ${text}\x1b[0m`);
const dollars = (wei) => `${ethers.formatEther(wei)} mUSD`;
const same = (a, b) => a.toLowerCase() === b.toLowerCase();

async function main() {
    say("Building contracts...");
    execFileSync("forge", ["build"], { cwd: ROOT, stdio: "ignore" });

    const anvil = spawn("anvil", ["--port", PORT, "--silent"], { stdio: "ignore" });

    try {
        await waitForChain();

        const provider = new ethers.JsonRpcProvider(RPC, undefined, { cacheTimeout: -1 });

        const you = account(0);
        const network = account(9).connect(provider); // pays for the stand-in network's transactions

        // --- A stand-in Reactive Network -------------------------------------------------------------------------
        await provider.send("anvil_setCode", [SYSTEM, artifact("MockSystemContract").deployedBytecode.object]);
        const system = new ethers.Contract(SYSTEM, artifact("MockSystemContract").abi, network);

        const proxyArtifact = artifact("MockCallbackProxy");
        const proxy = await new ethers.ContractFactory(proxyArtifact.abi, proxyArtifact.bytecode.object, network)
            .deploy()
            .then((contract) => contract.waitForDeployment());
        const proxyAddress = await proxy.getAddress();

        const forge = (script) => {
            const output = execFileSync(
                "forge",
                ["script", script, "--rpc-url", RPC, "--private-key", you.privateKey, "--broadcast"],
                { cwd: ROOT, encoding: "utf8", env: { ...process.env, CALLBACK_PROXY: proxyAddress }, stdio: "pipe" },
            );
            const logs = output.split("== Logs ==")[1]?.split(/\n\s*\n/)[0] ?? "";
            for (const line of logs.split("\n").filter((line) => line.trim())) say(`   ${line.trim()}`);
        };

        rmSync(join(ROOT, "deployments", "destination.json"), { force: true });
        rmSync(join(ROOT, "deployments", "reactive.json"), { force: true });
        rmSync(join(ROOT, "deployments", "guard.json"), { force: true });

        // --- Setup: scripts 01 to 04 -----------------------------------------------------------------------------
        step(1, "A protocol deploys an upgradeable vault behind a timelock. You and Bob deposit 1,000 mUSD each.");
        forge("script/01_DeployDemo.s.sol");

        step(2, "You deploy your reactive contract (on Reactive Network).");
        forge("script/02_DeployReactive.s.sol");

        step(3, "You deploy your guard next to the vault, let it move your shares, and arm it.");
        forge("script/03_DeployGuard.s.sol");

        step(4, "You link the two and lay three tripwires across the vault's governance.");
        forge("script/04_LayTripwires.s.sol");

        const { usd, vault, owner, bob } = deployment("destination");
        const reactiveAddress = deployment("reactive").reactive;
        const guardAddress = deployment("guard").guard;

        const guardInterface = new ethers.Interface(artifact("ExitGuard").abi);
        const reactiveInterface = new ethers.Interface(artifact("ExitGuardReactive").abi);
        const erc20 = ["function balanceOf(address) view returns (uint256)"];
        const usdToken = new ethers.Contract(usd, erc20, provider);
        const vaultToken = new ethers.Contract(
            vault,
            [...erc20, "function maxRedeem(address) view returns (uint256)", "function version() view returns (string)"],
            provider,
        );

        const { chainId } = await provider.getNetwork();
        let cursor = (await provider.getBlockNumber()) + 1;
        let delivered = 0;

        // Plays Reactive Network: every new log goes to `react`, every requested callback is delivered.
        const relay = async () => {
            for (;;) {
                const head = await provider.getBlockNumber();
                if (cursor > head) return;

                const logs = await provider.getLogs({ fromBlock: cursor, toBlock: head });
                cursor = head + 1;

                for (const log of logs) {
                    if (same(log.address, reactiveAddress)) {
                        // In reality these are emitted on Reactive Network, not on the watched chain.
                        report("reactive", reactiveInterface.parseLog(log));
                        continue;
                    }

                    if (same(log.address, guardAddress)) report("guard", guardInterface.parseLog(log));

                    const topic = (index) => (log.topics[index] ? BigInt(log.topics[index]) : 0n);

                    const record = {
                        chainId,
                        contractAddress: log.address,
                        topic0: topic(0),
                        topic1: topic(1),
                        topic2: topic(2),
                        topic3: topic(3),
                        data: log.data,
                        blockNumber: log.blockNumber,
                        opCode: log.topics.length,
                        blockHash: BigInt(log.blockHash),
                        txHash: BigInt(log.transactionHash),
                        logIndex: log.index,
                    };

                    await (await system.deliver(reactiveAddress, record)).wait();
                }

                for (const total = Number(await system.callbackCount()); delivered < total; ++delivered) {
                    const request = await system.callbackAt(delivered);
                    const transaction = await proxy.deliver(
                        request.sender,
                        request.recipient,
                        request.gasLimit,
                        request.payload,
                        { gasLimit: request.gasLimit + 300_000n },
                    );
                    await transaction.wait();
                }
            }
        };

        const report = (side, event) => {
            if (!event) return;

            const describe = {
                Tripped: (a) => `tripwire #${a.id} fired for the vault (reason ${a.reason})`,
                Suppressed: (a) => `tripwire #${a.id} fired again, inside the cooldown: no second callback`,
                DrillAnswered: (a) => `answered drill #${a.nonce}: ${a.tripwires} tripwires guard this vault`,
                DrillRequested: (a) => `drill #${a.nonce} requested`,
                DrillPassed: (a) =>
                    `drill #${a.nonce} passed: ${a.tripwires} tripwires, round trip ${a.blocksElapsed} blocks`,
                Exited: (a) => `EXITED: ${ethers.formatEther(a.shares)} shares redeemed for ${dollars(a.assets)}`,
                ExitSkipped: (a) => `exit skipped (cause ${a.cause})`,
                ExitFailed: () => "exit FAILED: the vault refused the redemption",
                Disarmed: () => "position disarmed",
            }[event.name];

            if (describe) say(`   \x1b[36m[${side}]\x1b[0m ${describe(event.args)}`);
        };

        const balances = async () => {
            say(`   You: ${dollars(await usdToken.balanceOf(owner))} in your wallet, ` +
                `${ethers.formatEther(await vaultToken.balanceOf(owner))} vault shares`);
            say(`   Bob: ${dollars(await usdToken.balanceOf(bob))} in his wallet, ` +
                `${ethers.formatEther(await vaultToken.balanceOf(bob))} vault shares`);
        };

        // --- The story -------------------------------------------------------------------------------------------
        step(5, "Health check: you ask for a drill. Nothing happens to your position.");
        forge("script/05_Drill.s.sol");
        await relay();
        await balances();

        step(6, "The protocol's admin queues an upgrade of the vault in the timelock.");
        forge("script/06_QueueUpgrade.s.sol");
        await relay();
        say(`   The vault still runs version ${await vaultToken.version()}.`);
        await balances();

        step(7, "Two minutes later the upgrade lands. The new code freezes withdrawals.");
        await provider.send("evm_increaseTime", [121]);
        await provider.send("evm_mine", []);
        forge("script/07_ExecuteUpgrade.s.sol");
        await relay();
        await balances();
        say(`   Bob can redeem: ${ethers.formatEther(await vaultToken.maxRedeem(bob))} shares.`);

        step(8, "The status report anyone can run against the destination chain.");
        const status = execFileSync("forge", ["script", "script/Status.s.sol", "--rpc-url", RPC], {
            cwd: ROOT,
            encoding: "utf8",
            stdio: "pipe",
        });
        const report8 = status.split("== Logs ==")[1] ?? "";
        for (const line of report8.split("\n").filter((line) => line.trim())) say(`   ${line.trim()}`);

        const safe = (await usdToken.balanceOf(owner)) === ethers.parseEther("1000");
        const stuck = (await vaultToken.maxRedeem(bob)) === 0n;

        say();
        say(safe && stuck
            ? "\x1b[32mResult: you left with all 1,000 mUSD before the new code went live. Bob is locked in.\x1b[0m"
            : "\x1b[31mResult: unexpected state, see above.\x1b[0m");

        if (!(safe && stuck)) process.exitCode = 1;
    } finally {
        anvil.kill();
    }
}

async function waitForChain() {
    const request = {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }),
    };

    for (let attempt = 0; attempt < 50; ++attempt) {
        try {
            if ((await fetch(RPC, request)).ok) return;
        } catch {
            // not listening yet
        }

        await new Promise((resolve) => setTimeout(resolve, 200));
    }

    throw new Error("anvil did not start; is Foundry installed and is the port free?");
}

main().catch((error) => {
    console.error(error);
    process.exit(1);
});
