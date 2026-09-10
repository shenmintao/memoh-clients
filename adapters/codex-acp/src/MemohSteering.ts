import {RequestError} from "@agentclientprotocol/sdk";
import type {ServerNotification} from "./app-server";

export const MEMOH_STEERING_METHOD = "_memoh/steer";

export type MemohSteerRequest = {sessionId: string; runId: string; id: string; text: string};
type Receipt = {applied: true};
type Pending = {
    text: string;
    turnId: string;
    promise: Promise<Receipt>;
    resolve: (receipt: Receipt) => void;
    reject: (error: RequestError) => void;
    settled: boolean;
    publishing: boolean;
};

export function parseMemohSteerRequest(params: Record<string, unknown>): MemohSteerRequest {
    const {sessionId, runId, id, text} = params;
    if (typeof sessionId !== "string" || !sessionId.trim() || sessionId.length > 256
        || typeof runId !== "string" || !runId.trim() || runId.length > 256
        || typeof id !== "string" || !id.trim() || id.length > 256
        || typeof text !== "string" || !text.trim() || text.length > 32000) {
        throw RequestError.invalidParams("Invalid running-turn supplement");
    }
    return {sessionId, runId, id, text};
}

// One scope per ACP prompt. The ordinary steering extension may start a new
// turn; Memoh must only address the admitted run and never use that fallback.
export class MemohSteering {
    private readonly receipts = new Map<string, Pending>();
    private closed = false;
    private readonly onAbort = () => this.finish();

    constructor(
        readonly sessionId: string,
        readonly runId: string,
        private readonly signal: AbortSignal,
        private readonly currentTurn: () => string | null,
        private readonly send: (turnId: string, id: string, text: string) => Promise<{turnId: string}>,
        private readonly publish: (id: string, text: string) => Promise<void>,
    ) {
        signal.addEventListener("abort", this.onAbort, {once: true});
    }

    steer(request: MemohSteerRequest): Promise<Receipt> {
        if (request.sessionId !== this.sessionId || request.runId !== this.runId) {
            throw RequestError.invalidParams("Supplement belongs to a different run");
        }
        const existing = this.receipts.get(request.id);
        if (existing) {
            if (existing.text !== request.text) throw RequestError.invalidParams("Supplement ID already used");
            return existing.promise;
        }
        const turnId = this.currentTurn();
        if (this.closed || this.signal.aborted || !turnId) {
            throw RequestError.invalidParams("No active turn for this supplement");
        }
        if (this.receipts.size >= 128 || [...this.receipts.values()].some(receipt => !receipt.settled)) {
            throw RequestError.invalidParams("Another supplement is pending or this run's limit was reached");
        }
        let resolve!: Pending["resolve"];
        let reject!: Pending["reject"];
        const promise = new Promise<Receipt>((yes, no) => { resolve = yes; reject = no; });
        const receipt: Pending = {text: request.text, turnId, promise, resolve, reject, settled: false, publishing: false};
        this.receipts.set(request.id, receipt);
        // A successful turn/steer response only acknowledges queued input.
        // Complete the receipt on the correlated userMessage notification.
        void Promise.resolve().then(() => {
            if (this.closed || this.signal.aborted || this.currentTurn() !== turnId) {
                throw RequestError.invalidParams("Target turn ended before delivery");
            }
            return this.send(turnId, request.id, request.text);
        }).then(result => {
            if (result.turnId !== turnId) this.fail(receipt, false);
        }, error => {
            const rejected = error instanceof RequestError && error.code === -32602;
            this.fail(receipt, rejected);
        });
        return promise;
    }

    async handleNotification(event: ServerNotification): Promise<void> {
        if (this.closed) return;
        if (event.method === "turn/completed" && event.params.threadId === this.sessionId) {
            for (const receipt of this.receipts.values()) {
                if (receipt.turnId === event.params.turn.id) {
                    this.fail(receipt, event.params.turn.status === "completed");
                }
            }
            return;
        }
        if (event.method !== "item/started" && event.method !== "item/completed") return;
        const {threadId, turnId, item} = event.params;
        if (threadId !== this.sessionId || item.type !== "userMessage" || !item.clientId) return;
        const receipt = this.receipts.get(item.clientId);
        if (!receipt || receipt.turnId !== turnId || receipt.settled || receipt.publishing) return;
        const text = item.content.map(part => part.type === "text" ? part.text : "").join("");
        if (text !== receipt.text) return;
        receipt.publishing = true;
        try {
            await this.publish(item.clientId, receipt.text);
            if (!receipt.settled) {
                receipt.settled = true;
                receipt.resolve({applied: true});
            }
        } catch {
            receipt.publishing = false;
            this.fail(receipt, false);
        }
    }

    finish(): void {
        this.closed = true;
        this.signal.removeEventListener("abort", this.onAbort);
        for (const receipt of this.receipts.values()) {
            receipt.publishing = false;
            this.fail(receipt, false);
        }
    }

    private fail(receipt: Pending, knownRejected: boolean): void {
        if (receipt.settled || receipt.publishing) return;
        receipt.settled = true;
        receipt.reject(knownRejected
            ? RequestError.invalidParams("Supplement was not consumed by the target turn")
            : RequestError.internalError("Supplement delivery status is unknown; do not replay automatically"));
    }
}
