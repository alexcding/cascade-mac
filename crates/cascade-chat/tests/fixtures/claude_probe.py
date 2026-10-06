import json, subprocess, sys, time, os
env=dict(os.environ, CLAUDE_CODE_ENTRYPOINT="sdk-ts")
p=subprocess.Popen(["claude","--output-format","stream-json","--verbose","--input-format","stream-json","--include-partial-messages","--permission-prompt-tool","stdio","--permission-mode","default","--setting-sources=user,project,local","--model","haiku"],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open("claude.err","w"),text=True,env=env)
def send(o): p.stdin.write(json.dumps(o)+"\n"); p.stdin.flush()
send({"type":"control_request","request_id":"r1","request":{"subtype":"initialize"}})
send({"type":"user","session_id":"","parent_tool_use_id":None,"message":{"role":"user","content":[{"type":"text","text":"Run the shell command `echo hi > probe.txt` with Bash, then reply with one word."}]}})
out=open("claude.jsonl","w"); start=time.time()
for line in p.stdout:
    out.write(line); out.flush()
    d=json.loads(line)
    if d.get("type")=="control_request" and d["request"].get("subtype")=="can_use_tool":
        send({"type":"control_response","response":{"subtype":"success","request_id":d["request_id"],"response":{"behavior":"allow","updatedInput":d["request"]["input"]}}})
    if d.get("type")=="result" or time.time()-start>90: break
p.stdin.close(); p.terminate()
