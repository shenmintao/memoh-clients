import * as acp from "@agentclientprotocol/sdk";
import {spawn} from "node:child_process";
import {createServer} from "node:http";
import {mkdtemp, mkdir, writeFile} from "node:fs/promises";
import {Readable, Writable} from "node:stream";
import {tmpdir} from "node:os";
import path from "node:path";
import assert from "node:assert/strict";

// Real pinned Codex process and ACP wire protocol, synthetic loopback provider.
// No user credentials or paid inference; the model output contains no tools.
const root = await mkdtemp(path.join(tmpdir(), "memoh-codex-smoke-"));
const workspace = path.join(root, "workspace");
const codexHome = path.join(root, "codex-home");
await mkdir(workspace); await mkdir(codexHome);
let firstResponse;
let count = 0;
const requests = [];
const updates = [];
let notifyFirst;
const firstRequest = new Promise(resolve => {notifyFirst = resolve;});
function respond(res, number) {
    const text = number === 1 ? "Phase one complete." : "Supplement received.";
    const id = `resp_${number}`;
    const item = {id:`msg_${number}`, type:"message", role:"assistant", status:"completed",
        content:[{type:"output_text", text, annotations:[]}]};
    const response = {id, object:"response", created_at:1, model:"gpt-5.6-sol", status:"completed",
        output:[item], usage:{input_tokens:10, output_tokens:5, total_tokens:15}};
    res.writeHead(200, {"content-type":"text/event-stream"});
    for (const event of [
        {type:"response.created", response:{...response, status:"in_progress", output:[]}},
        {type:"response.output_item.added", output_index:0, item:{...item, status:"in_progress", content:[]}},
        {type:"response.content_part.added", item_id:item.id, output_index:0, content_index:0,
            part:{type:"output_text", text:"", annotations:[]}},
        {type:"response.output_text.delta", item_id:item.id, output_index:0, content_index:0, delta:text},
        {type:"response.output_text.done", item_id:item.id, output_index:0, content_index:0, text},
        {type:"response.content_part.done", item_id:item.id, output_index:0, content_index:0, part:item.content[0]},
        {type:"response.output_item.done", output_index:0, item},
        {type:"response.completed", response},
    ]) res.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
    res.end();
}
const server = createServer(async (req,res) => {
    let body = ""; for await (const chunk of req) body += chunk;
    if (!req.url?.includes("responses")) {res.writeHead(404);res.end();return;}
    requests.push(JSON.parse(body)); count++;
    if(count === 1) { firstResponse = res; notifyFirst(); }
    else respond(res,count);
});
await new Promise(resolve => server.listen(0,"127.0.0.1",resolve));
const baseUrl = `http://127.0.0.1:${server.address().port}/v1`;
const childEnv = {...process.env, CODEX_HOME:codexHome, USERPROFILE:root,
    CODEX_CONFIG:JSON.stringify({model:"gpt-5.6-sol", model_reasoning_effort:"low", check_for_update_on_startup:false})};
for(const key of ["OPENAI_API_KEY","CODEX_API_KEY","CODEX_AUTH_TOKEN","APP_SERVER_LOGS","CODEX_PATH","HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","http_proxy","https_proxy","all_proxy"])
    delete childEnv[key];
const child = spawn(process.execPath, ["dist/index.js"], {env:childEnv, stdio:["pipe","pipe","pipe"]});
let stderr = ""; child.stderr.on("data", data => {stderr += data.toString();});
const timeout = setTimeout(() => {console.error("SMOKE TIMEOUT", stderr.slice(-3000)); child.kill();server.closeAllConnections();server.close();process.exitCode=1;},45000);
const stream = acp.ndJsonStream(Writable.toWeb(child.stdin), Readable.toWeb(child.stdout));
try {
    await acp.client({name:"memoh-steering-smoke"})
      .onNotification(acp.methods.client.session.update, ctx => {updates.push(ctx.params);})
      .connectWith(stream, async agent => {
        const init = await agent.request(acp.methods.agent.initialize,{protocolVersion:acp.PROTOCOL_VERSION,
            clientCapabilities:{auth:{_meta:{gateway:true}}}});
        assert.equal(init._meta?.["memoh/steer"],1);
        await agent.request(acp.methods.agent.authenticate,{methodId:"gateway",_meta:{gateway:{baseUrl,headers:{}}}});
        const session = await agent.request(acp.methods.agent.session.new,{cwd:workspace,mcpServers:[]});
        const runId = "smoke-run";
        const prompt = agent.request(acp.methods.agent.session.prompt,{sessionId:session.sessionId,
            prompt:[{type:"text",text:"Reply with a short sentence."}],_meta:{"memoh/runId":runId}});
        prompt.catch(()=>{});
        await Promise.race([firstRequest,prompt.then(()=>{throw Error("Turn finished before provider request");})]);
        let acknowledged = false;
        const params = {sessionId:session.sessionId,runId,id:"smoke-supplement",text:"Also include the word SMOKE_SUPPLEMENT_147."};
        const steer = agent.request("_memoh/steer",params).then(value=>{acknowledged=true;return value;});
        steer.catch(()=>{});
        await new Promise(resolve=>setTimeout(resolve,300));
        assert.equal(acknowledged,false,"Queue acceptance must not claim consumption");
        if (process.argv.includes("--cancel")) {
            await agent.notify(acp.methods.agent.session.cancel, {sessionId:session.sessionId});
            await assert.rejects(steer);
            assert.equal((await prompt).stopReason,"cancelled");
            firstResponse.destroy();
            const next = await agent.request(acp.methods.agent.session.prompt,{sessionId:session.sessionId,
                prompt:[{type:"text",text:"Start a fresh response."}],_meta:{"memoh/runId":"next-run"}});
            assert.equal(next.stopReason,"end_turn");
            assert.ok(!JSON.stringify(requests[1].input).includes("SMOKE_SUPPLEMENT_147"),
                "Cancelled queued input must not spill into the next run");
            console.log(JSON.stringify({passed:true,codex:"0.147.0",cancelledQueueDidNotLeak:true,providerRequests:count}));
            await agent.request(acp.methods.agent.session.close,{sessionId:session.sessionId});
            return;
        }
        respond(firstResponse,1);
        assert.deepEqual(await steer,{applied:true});
        assert.equal((await prompt).stopReason,"end_turn");
        assert.ok(requests.slice(1).some(r=>JSON.stringify(r.input).includes("SMOKE_SUPPLEMENT_147")),"Next model step must contain supplement");
        assert.equal(updates.filter(e=>e.update.sessionUpdate==="user_message_chunk" &&
            e.update.content.text===params.text).length,1,"Supplement appears once in transcript");
        await assert.rejects(agent.request("_memoh/steer",{...params,id:"late"}));
        assert.equal(count,2,"Late supplement must not open a third turn");
        console.log(JSON.stringify({passed:true,codex:"0.147.0",adapter:"1.2.0",providerRequests:count,
            actualConsumptionConfirmed:true,lateRequestRejected:true,transcriptCopies:1}));
        await agent.request(acp.methods.agent.session.close,{sessionId:session.sessionId});
      });
} catch(error) {console.error(error);console.error(stderr.slice(-3000));process.exitCode=1;}
finally {clearTimeout(timeout); child.stdin.end(); child.kill();server.closeAllConnections();server.close();
    await writeFile(path.join(root,"audit.json"),JSON.stringify({requestCount:count,updates},null,2));}
