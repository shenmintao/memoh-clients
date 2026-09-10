import {describe, expect, it, vi} from "vitest";
import {MemohSteering, parseMemohSteerRequest} from "../MemohSteering";
import type {ServerNotification} from "../app-server";

const request = {sessionId: "session", runId: "run", id: "supplement", text: "Focus on tests"};

function fixture() {
    const controller = new AbortController();
    const send = vi.fn().mockResolvedValue({turnId: "turn"});
    const publish = vi.fn().mockResolvedValue(undefined);
    let turnId: string | null = "turn";
    const scope = new MemohSteering("session", "run", controller.signal, () => turnId, send, publish);
    return {scope, controller, send, publish, end: () => {turnId = null;}};
}

function consumed(clientId = "supplement", turnId = "turn"): ServerNotification {
    return {method: "item/started", params: {
        threadId: "session", turnId, startedAtMs: 0,
        item: {type: "userMessage", id: "item", clientId,
            content: [{type: "text", text: request.text, text_elements: []}]},
    }};
}

describe("Memoh running-turn steering receipts", () => {
    it("waits for consumption, correlates IDs, publishes history once, and deduplicates", async () => {
        const f = fixture();
        const pending = f.scope.steer(request);
        expect(f.scope.steer(request)).toBe(pending);
        let applied = false;
        void pending.then(() => {applied = true;});
        await vi.waitFor(() => expect(f.send).toHaveBeenCalledOnce());
        expect(f.send).toHaveBeenCalledWith("turn", request.id, request.text);
        expect(applied).toBe(false);
        await f.scope.handleNotification(consumed("unrelated"));
        await f.scope.handleNotification(consumed(request.id, "old-turn"));
        expect(f.publish).not.toHaveBeenCalled();
        await f.scope.handleNotification(consumed());
        await expect(pending).resolves.toEqual({applied: true});
        await f.scope.handleNotification(consumed());
        expect(f.publish).toHaveBeenCalledExactlyOnceWith(request.id, request.text);
        f.scope.finish();
    });

    it("rejects another run, changed duplicate contents, and a second pending request", async () => {
        const f = fixture();
        expect(() => f.scope.steer({...request, runId: "old-run"})).toThrow();
        const pending = f.scope.steer(request).catch(error => error);
        expect(() => f.scope.steer({...request, text: "different"})).toThrow();
        expect(() => f.scope.steer({...request, id: "second"})).toThrow();
        f.scope.finish();
        expect((await pending).code).toBe(-32603);
    });

    it("does not start or send input when the target turn ends before dispatch", async () => {
        const f = fixture();
        const pending = f.scope.steer(request);
        f.end();
        await expect(pending).rejects.toMatchObject({code: -32602});
        expect(f.send).not.toHaveBeenCalled();
        f.scope.finish();
    });

    it("retains unknown transport outcomes without replaying", async () => {
        const f = fixture();
        f.send.mockRejectedValue(new Error("connection lost"));
        const pending = f.scope.steer(request);
        await expect(pending).rejects.toMatchObject({code: -32603});
        await expect(f.scope.steer(request)).rejects.toMatchObject({code: -32603});
        expect(f.send).toHaveBeenCalledOnce();
        f.scope.finish();
    });

    it("settles outstanding input on cancellation and ignores late receipts", async () => {
        const f = fixture();
        const pending = f.scope.steer(request);
        await vi.waitFor(() => expect(f.send).toHaveBeenCalledOnce());
        const result = pending.catch(error => error);
        f.controller.abort();
        expect((await result).code).toBe(-32603);
        await f.scope.handleNotification(consumed());
        expect(f.publish).not.toHaveBeenCalled();
        expect(() => f.scope.steer({...request, id: "next"})).toThrow();
    });

    it("rejects unconsumed input when its turn completes", async () => {
        const f = fixture();
        const pending = f.scope.steer(request);
        const result = pending.catch(error => error);
        await f.scope.handleNotification({method: "turn/completed", params: {
            threadId: "session", turn: {id: "turn", items: [], itemsView: "notLoaded", status: "completed",
                error: null, startedAt: null, completedAt: null, durationMs: null},
        }});
        expect((await result).code).toBe(-32602);
        f.scope.finish();
    });

    it("does not acknowledge if forwarding the user message fails", async () => {
        const f = fixture();
        f.publish.mockRejectedValue(new Error("ACP closed"));
        const pending = f.scope.steer(request).catch(error => error);
        await f.scope.handleNotification(consumed());
        expect((await pending).code).toBe(-32603);
        f.scope.finish();
    });

    it("validates nonempty bounded text and request identity", () => {
        expect(parseMemohSteerRequest(request)).toEqual(request);
        for (const invalid of [{...request, text: " "}, {...request, text: "x".repeat(32001)},
            {...request, runId: ""}, {...request, id: 4}]) {
            expect(() => parseMemohSteerRequest(invalid)).toThrow();
        }
    });
});
