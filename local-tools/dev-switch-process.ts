import { join, resolve } from "node:path";
import { readRuntimePort } from "../src/config/process-state";
import { proveLiveProxyOwnedByHome } from "../src/server/proxy-liveness";
import { windowsProcessNative } from "../src/service/windows-process-native";

const port = 10100;
const entry = resolve(import.meta.dir, "../src/cli/index.ts").toLowerCase();

async function main(): Promise<void> {
  const [mode, rawPid, rawStartTime] = Bun.argv.slice(2);
  const pid = Number(rawPid);
  if (!Number.isSafeInteger(pid) || pid <= 0) throw new Error("Ungueltige Dev-Prozess-ID.");
  const native = windowsProcessNative();
  const identity = native?.sameUserIdentity(pid, true);
  const command = identity?.commandLine?.toLowerCase();
  if (!native || !identity || !command?.trimEnd().endsWith('"' + entry + '" start --port ' + port)) {
    throw new Error("Der Dev-Prozess des Checkouts konnte nicht eindeutig identifiziert werden.");
  }

  if (mode === "verify-legacy" || mode === "stop-legacy") {
    if (!process.env.LOCALAPPDATA) throw new Error("Der lokale Windows-Datenpfad fehlt.");
    process.env.OPENCODEX_HOME = join(process.env.LOCALAPPDATA, "OpenCodex-dev", String(port));
    const record = readRuntimePort(pid);
    if (record?.port !== port || record.hostname !== "127.0.0.1" || record.restartOwner) {
      throw new Error("Die bisherige Dev-Instanz ist kein eigenstaendiger lokaler Proxy.");
    }
    const proof = await proveLiveProxyOwnedByHome(
      { pid, port, hostname: record.hostname, source: "runtime" },
      { timeoutMs: 2500 },
    );
    if (proof !== "proven") throw new Error("Die bisherige Dev-Instanz konnte ihr Datenverzeichnis nicht nachweisen.");
    if (mode === "verify-legacy") return;
  } else if (mode === "stop-attempt") {
    // The Windows primitive compares creation timestamps at CIM precision.
    const startTime = BigInt(rawStartTime ?? "0");
    if (identity.ticks !== (startTime / 10n) * 10n) {
      throw new Error("Der gestartete Dev-Prozess hat seine Identitaet gewechselt.");
    }
  } else {
    throw new Error("Unbekannte Dev-Prozessaktion.");
  }

  const result = native.terminate(pid, identity.ticks);
  if (result.status !== "terminated" && result.status !== "gone") {
    throw new Error("Windows konnte den zugeordneten Dev-Prozess nicht anhalten (" + result.status + ").");
  }
}

try {
  await main();
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
