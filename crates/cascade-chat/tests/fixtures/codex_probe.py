import json, subprocess, time, os
p=subprocess.Popen(["codex","app-server"],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open("codex.err","w"),text=True,cwd=os.getcwd())
n=[0]
def req(method,params):
    n[0]+=1; p.stdin.write(json.dumps({"id":n[0],"method":method,"params":params})+"\n"); p.stdin.flush(); return n[0]
def note(method,params=None):
    o={"method":method}; 
    if params is not None:o["params"]=params
    p.stdin.write(json.dumps(o)+"\n"); p.stdin.flush()
def resp(id,result): p.stdin.write(json.dumps({"id":id,"result":result})+"\n"); p.stdin.flush()
out=open("codex.jsonl","w")
def lines():
    for line in p.stdout:
        out.write(line); out.flush(); yield json.loads(line)
it=lines()
req("initialize",{"clientInfo":{"name":"cascade","version":"0.1"},"capabilities":{"experimentalApi":True}})
for d in it:
    if d.get("id")==1: break
note("initialized")
req("thread/start",{"cwd":os.getcwd(),"approvalPolicy":"untrusted","sandbox":"read-only"})
thread=None; start=time.time()
for d in it:
    if d.get("id")==2: thread=d["result"]["thread"]["id"]; break
req("turn/start",{"threadId":thread,"input":[{"type":"text","text":"Run the shell command `echo hi > codex.txt`, then reply with one word.","text_elements":[]}]})
for d in it:
    m=d.get("method","")
    if "requestApproval" in m: resp(d["id"],{"decision":"accept"})
    if m=="turn/completed" or time.time()-start>120: break
p.terminate()
