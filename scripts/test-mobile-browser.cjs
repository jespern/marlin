// Real daemon + HTTP bridge + Chromium mobile viewport. No real provider calls.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const http = require('node:http');
const {spawn} = require('node:child_process');
const {chromium} = require(process.env.MARLIN_PLAYWRIGHT_MODULE || 'playwright-core');
const sleep = ms => new Promise(r=>setTimeout(r,ms));
async function main() {
  const root=fs.mkdtempSync(path.join(os.tmpdir(),'marlin-mobile-browser-'));
  const config=path.join(root,'config','marlin'); fs.mkdirSync(config,{recursive:true});
  const env={...process.env,HOME:root,XDG_CONFIG_HOME:path.join(root,'config'),XDG_STATE_HOME:path.join(root,'state'),MARLIN_SOCKET:path.join(root,'daemon.sock')};
  delete env.MARLIN_REMOTE;
  for(const name of Object.keys(env)) if(/API_KEY|TOKEN|SECRET/.test(name)) delete env[name];
  const reserve=net.createServer(); await new Promise(r=>reserve.listen(0,'127.0.0.1',r));
  const port=reserve.address().port; await new Promise(r=>reserve.close(r));
  fs.writeFileSync(path.join(config,'config.toml'),'[web]\nenabled = true\npush = true\nhosts = ["marlin.test"]\nport = '+port+'\n');
  const binary=path.resolve('zig-out/bin/marlin');
  const daemon=spawn(binary,['daemon'],{env,stdio:['ignore','ignore','pipe']});
  let logs=''; daemon.stderr.on('data',b=>logs+=b);
  let browser;
  const origin='http://127.0.0.1:'+port;
  const post=async obj=>{
    const r=await fetch(origin+'/send',{method:'POST',body:JSON.stringify(obj)});
    return JSON.parse((await r.text()).replace(/"sid":(\d+)/g,'"sid":"$1"'));
  };
  // A phone: same port, but addressed by its public name (fetch cannot set Host).
  const remote=(method,target,{body,cookie,host='marlin.test',headers={}}={})=>new Promise((resolve,reject)=>{
    const req=http.request({host:'127.0.0.1',port,method,path:target,headers:{host,...(cookie?{cookie}:{}),...headers}},res=>{
      let text=''; res.on('data',c=>text+=c);
      res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,text,json:()=>JSON.parse(text)}));
      if(target.startsWith('/events')&&res.statusCode===200) {res.destroy(); resolve({status:200,headers:res.headers,text:''});}
    });
    req.on('error',reject); req.end(body);
  });
  const waitReady=async()=>{
    for(let i=0;i<150;i++) {
      try { if((await fetch(origin+'/connection')).ok) return; } catch {}
      await sleep(100);
    }
    assert.fail('web companion did not come up\n'+logs);
  };
  try {
    await waitReady();
    const settings=await (await fetch(origin+'/connection')).json();
    assert.deepEqual(settings,{host:'marlin.test',push_enabled:true,paired:true});
    let managed;
    for (let i=0;i<100;i++) {
      managed=(await post({web_status:{}})).web_status_result;
      if (managed.state==='running' && managed.logs.some(line=>line.includes('GET /connection'))) break;
      await sleep(50);
    }
    assert.equal(managed.enabled,true);
    assert.equal(managed.state,'running');
    assert.ok(managed.logs.some(line=>line.includes('GET /connection')));
    const info=await (await fetch(origin+'/push/info')).json();
    assert.equal(Buffer.from(info.publicKey,'base64url').length,65);
    const created=await post({session_create:{cwd:root,model:'local/testing',title:'Mobile check'}});
    const sid=created.session_created.sid;
    assert.match(sid,/^\d+$/);
    await post({session_create:{cwd:root,model:'local/testing',title:'Another session'}});
    // Golden replies from the real daemon, including short-lived phone requests.
    assert.deepEqual(await post({presence:{kind:'phone',active:true,sid:1,page_id:456}}),{ok:{request_id:0}});
    assert.deepEqual(await post({presence:{kind:'phone',active:false,sid:1,page_id:456}}),{ok:{request_id:0}});
    assert.equal((await post({presence:{kind:'phone',active:true,sid:1,page_id:0}})).err.code,'presence');
    browser=await chromium.launch({headless:true, executablePath:process.env.MARLIN_CHROMIUM_PATH || undefined});
    const context=await browser.newContext({viewport:{width:390,height:844},deviceScaleFactor:3,isMobile:true,hasTouch:true});
    const page=await context.newPage(); const errors=[];
    page.on('pageerror',e=>errors.push(e.message));
    await page.goto(origin+'/?sid='+sid);
    await page.waitForFunction(()=>document.querySelector('#connection-state').textContent==='Connected');
    assert.equal(await page.evaluate(() => String(sid)),sid);
    await page.locator('#menu-btn').click();
    await page.locator('#push-toggle').waitFor({state:'visible'});
    assert.equal(await page.locator('#canonical-url').getAttribute('href'),'https://marlin.test/');
    await page.locator('#backdrop').click({position:{x:380,y:400}});
    const bounds=()=>page.evaluate(()=>{
      const composer=document.querySelector('#composer').getBoundingClientRect();
      const status=document.querySelector('#status').getBoundingClientRect();
      return {bottom:composer.bottom,top:composer.top,statusBottom:status.bottom,height:visualViewport.height,offset:visualViewport.offsetTop,scroll:window.scrollY};
    });
    // The page re-fits on the next animation frame after a resize: wait for
    // that instead of a fixed sleep, then assert (the assert explains a miss).
    const settle=()=>page.waitForFunction(()=>{
      const c=document.querySelector('#composer').getBoundingClientRect();
      return Math.abs(c.bottom-visualViewport.height-visualViewport.offsetTop)<2;
    },null,{timeout:5000}).catch(()=>{});
    let b=await bounds(); assert.ok(Math.abs(b.bottom-b.height-b.offset)<2,JSON.stringify(b));
    assert.ok(b.statusBottom<=b.top+1);
    await page.locator('#input').focus();
    await page.setViewportSize({width:390,height:420});
    await settle();
    b=await bounds(); assert.ok(Math.abs(b.bottom-b.height-b.offset)<2,JSON.stringify(b));
    assert.equal(b.scroll,0);
    await page.evaluate(()=>{
      const t=document.querySelector('#transcript');
      for(let i=0;i<150;i++) {const p=document.createElement('p');p.textContent='Reading fixture '+i;t.append(p);}
      t.scrollTop=400;
    });
    await page.setViewportSize({width:390,height:600}); await settle();
    assert.equal(await page.locator('#transcript').evaluate(t=>t.scrollTop),400);
    await context.setOffline(true);
    await page.waitForFunction(()=>document.querySelector('#connection-state').textContent==='Offline');
    await context.setOffline(false);
    await page.waitForFunction(()=>document.querySelector('#connection-state').textContent==='Connected');
    await page.setViewportSize({width:844,height:390}); await settle();
    b=await bounds(); assert.ok(Math.abs(b.bottom-390)<2,JSON.stringify(b));

    // The attach button comes first, then the prompt marker.
    assert.deepEqual(await page.locator('#composer > :not(#attachments):not([hidden])').evaluateAll(n=>n.map(e=>e.className||e.id)),['attach-btn','prompt','input']);
    // Composer: spellcheck on; status shows the short model name.
    assert.equal(await page.locator('#input').getAttribute('spellcheck'),'true');
    assert.equal(await page.locator('#input').getAttribute('autocorrect'),'on');
    assert.equal(await page.locator('#status .model').textContent(),'testing');
    // Nothing in the transcript scrolls sideways, however long the line.
    await page.evaluate(()=>{
      const pre=document.createElement('pre'); pre.textContent='x'.repeat(2000);
      const d=document.createElement('div'); d.className='block md'; d.appendChild(pre);
      document.querySelector('#transcript').appendChild(d);
    });
    assert.ok(await page.locator('#transcript').evaluate(t=>t.scrollWidth<=t.clientWidth+1));
    // Tool runs fold like the TUI's "Ran N commands"; colors follow its palette.
    const tools=await page.evaluate(()=>{
      const t=document.querySelector('#transcript'), now=Date.now();
      const call=(id,command)=>addBlock({ts:now,body:{tool_call:{name:'Bash',call_id:id,args_json:JSON.stringify({command})}}});
      const result=(id,status='ok')=>addBlock({ts:now,body:{tool_result:{call_id:id,status,inline_body:'out'}}});
      call('c1','git status | head -3');
      const g=t.lastElementChild;
      const lone={single:g.classList.contains('single'),open:g.open,exe:g.querySelector('.sh-exe').textContent,op:g.querySelector('.sh-op').textContent};
      addBlock({ts:now,body:{system_note:{text:'Show status'}}});
      result('c1'); call('c2','zsh -lc "rg -n x src/"'); result('c2');
      const folded={single:g.classList.contains('single'),open:g.open,summary:g.firstElementChild.textContent,
        rows:g.querySelectorAll(':scope > .tool').length,notes:g.querySelectorAll(':scope > .note').length,
        unwrapped:g.querySelectorAll('.tool')[1].querySelector('.prev').textContent};
      call('c3','false'); result('c3','error');
      const failed={summary:g.firstElementChild.textContent,open:g.open};
      addBlock({ts:now,body:{assistant_msg:{text:'done'}}});
      call('c4','ls');
      const next=t.lastElementChild!==g && t.lastElementChild.classList.contains('single');
      addBlock({ts:now,body:{reasoning:{text:'thinking'}}});
      const cs=sel=>getComputedStyle(t.querySelector(sel)).color;
      return {lone,folded,failed,next,reasoning:cs('.reasoning'),body:getComputedStyle(document.body).color,note:cs('.block.note')};
    });
    assert.deepEqual(tools.lone,{single:true,open:true,exe:'git',op:'|'});
    assert.deepEqual(tools.folded,{single:false,open:false,summary:'⚙ Ran 2 commands',rows:2,notes:1,unwrapped:'rg -n x src/'});
    assert.deepEqual(tools.failed,{summary:'⚙ Ran 3 commands · 1 failed',open:true});
    assert.equal(tools.next,true);
    assert.equal(tools.reasoning,tools.body);
    assert.equal(tools.note,'rgb(138, 166, 191)');
    // File tools show their path (session-relative), never the raw arguments JSON.
    const readRow=await page.evaluate(cwd=>{
      addBlock({ts:Date.now(),body:{assistant_msg:{text:'reading'}}});
      addBlock({ts:Date.now(),body:{tool_call:{name:'Read',call_id:'r1',args_json:JSON.stringify({file_path:cwd+'/src/web.zig',limit:40})}}});
      addBlock({ts:Date.now(),body:{tool_call:{name:'TodoWrite',call_id:'t1',args_json:JSON.stringify({todos:[{content:'x'}]})}}});
      return [...document.querySelectorAll('#transcript .tool summary')].slice(-2).map(s=>s.textContent);
    },root);
    assert.deepEqual(readRow,['⚙ Read src/web.zig','⚙ TodoWrite']);
    // Interactive cards behave like the TUI's: questions, approvals, Plan offers.
    const cards=await page.evaluate(async()=>{
      const sent=[], realSend=window.send;
      window.send=async raw=>{sent.push(JSON.parse(raw)); return {ok:{}};};
      const out={};
      try {
        const qsid=sid;
        // A question: options are buttons; the pick answers it.
        handle({question_request:{sid:qsid,question_id:'q1',question:'Which way?',options:['Left','Right']}});
        out.card=[document.querySelector('#question').classList.contains('show'),document.querySelector('#question .q').textContent,
          [...document.querySelectorAll('#question .opts button')].map(b=>b.textContent)];
        // Its transcript record waits behind the live card.
        addBlock({ts:Date.now(),body:{tool_call:{name:'mcp__marlin__ask_user',call_id:'ask1',args_json:JSON.stringify({question:'Which way?',options:['Left','Right']})}}});
        const record=document.querySelector('[data-call="ask1"]');
        out.hiddenWhileAsking=getComputedStyle(record).display;
        out.recordUnfolded=!record.closest('.tool-group');
        document.querySelectorAll('#question .opts button')[1].click();
        await new Promise(r=>setTimeout(r,0));
        out.answer=sent.pop();
        out.cardAfter=document.querySelector('#question').classList.contains('show');
        addBlock({ts:Date.now(),body:{tool_result:{call_id:'ask1',status:'ok',inline_body:'Right'}}});
        out.record=[getComputedStyle(record).display!=='none',[...record.querySelectorAll('.opt')].map(o=>o.textContent+(o.classList.contains('chosen')?'*':''))];
        // Typed words answer a pending question instead of becoming a message.
        handle({question_request:{sid:qsid,question_id:'q2',question:'Name?',options:[]}});
        const input=document.querySelector('#input'); input.value='Bob';
        input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));
        await new Promise(r=>setTimeout(r,0));
        out.typed=sent.pop();
        // An approval names the tool and its argument, not raw JSON.
        handle({approval_request:{sid:qsid,approval_id:'a1',call_id:'c9',tool:'Bash',args_json:JSON.stringify({command:'git push'})}});
        out.approval=[document.querySelector('#approval .q').textContent,!!document.querySelector('#approval .q .sh-exe')];
        document.querySelector('#approval .yes').click();
        out.approved=sent.pop();
        // Plan mode: a finished proposal offers implement/revise/dismiss.
        cur.plan_mode=true; setState('idle');
        addBlock({ts:Date.now(),body:{assistant_msg:{text:'Plan: do the thing'}}});
        out.offer=document.querySelector('#plan-offer').classList.contains('show');
        document.querySelector('#plan-implement').click();
        await new Promise(r=>setTimeout(r,0));
        out.accepted=sent.pop();
        out.offerAfter=document.querySelector('#plan-offer').classList.contains('show');
        cur.plan_mode=false;
        await slashCommand('/plan');
        out.planCmd=sent.find(m=>m.session_set_plan_mode);
        out.planPrompt=document.querySelector('#composer').classList.contains('plan');
        await slashCommand('/plan off');
        sent.pop();
      } finally { window.send=realSend; }
      return out;
    });
    assert.deepEqual(cards.card,[true,'? Which way?',['1Left','2Right']]);
    assert.equal(cards.hiddenWhileAsking,'none');
    assert.equal(cards.recordUnfolded,true);
    assert.equal(cards.answer.question_answer.question_id,'q1');
    assert.equal(cards.answer.question_answer.answer,'Right');
    assert.equal(cards.cardAfter,false);
    assert.deepEqual(cards.record,[true,['  1. Left','✓ 2. Right*']]);
    assert.deepEqual([cards.typed.question_answer.question_id,cards.typed.question_answer.answer],['q2','Bob']);
    assert.deepEqual(cards.approval,['⚠ approve Bash git push ?',true]);
    assert.deepEqual(cards.approved.approve,{sid:cards.approved.approve.sid,approval_id:'a1',decision:'granted'});
    assert.equal(cards.offer,true);
    assert.ok(cards.accepted.plan_accept);
    assert.equal(cards.offerAfter,false);
    assert.equal(cards.planCmd.session_set_plan_mode.enabled,true);
    assert.equal(cards.planPrompt,true);
    // With a real keyboard and an empty composer, y approves (as in the TUI);
    // on a phone the same keystroke is just text.
    const desk=await browser.newContext({viewport:{width:1200,height:800}});
    const deskPage=await desk.newPage();
    await deskPage.goto(origin+'/?sid='+sid);
    await deskPage.waitForFunction(()=>document.querySelector('#connection-state').textContent==='Connected');
    const hotkey=await deskPage.evaluate(()=>{
      const sent=[]; window.send=async raw=>{sent.push(JSON.parse(raw)); return {ok:{}};};
      handle({approval_request:{sid,approval_id:'a2',call_id:'c',tool:'Read',args_json:'{"file_path":"x"}'}});
      document.querySelector('#input').dispatchEvent(new KeyboardEvent('keydown',{key:'y',bubbles:true}));
      return sent.map(m=>m.approve&&m.approve.decision);
    });
    assert.deepEqual(hotkey,['granted']);
    await desk.close();
    // An image well over the bridge's old 64 KB body cap goes through and persists.
    await page.evaluate(async()=>{
      const c=document.createElement('canvas'); c.width=c.height=1500;
      const g=c.getContext('2d');
      for(let i=0;i<6000;i++){g.fillStyle='hsl('+(i*37%360)+' 80% '+(20+i%60)+'%)';g.fillRect((i*7919)%1500,(i*104729)%1500,23,23);}
      const blob=await new Promise(r=>c.toBlob(r,'image/png'));
      const dt=new DataTransfer(); dt.items.add(new File([blob],'shot.png',{type:'image/png'}));
      const input=document.querySelector('#file'); input.files=dt.files; input.dispatchEvent(new Event('change'));
    });
    await page.locator('#attachments img').waitFor({state:'visible'});
    await page.locator('#input').fill('look at this');
    await page.locator('#input').press('Enter');
    await page.waitForFunction(()=>!document.querySelector('#attachments img'));
    await page.reload();
    await page.waitForFunction(()=>[...document.querySelectorAll('.block.user:not(.optimistic)')].some(n=>n.textContent==='look at this [1 image]'));
    assert.deepEqual(errors,[]);
    // A Home Screen app fills its web view and never extends past it: iOS
    // can report a screen taller than the view, and content laid out to the
    // screen is clipped (the composer vanished). Opaque status bar style.
    assert.equal(await page.locator('meta[name="apple-mobile-web-app-status-bar-style"]').getAttribute('content'),'black');
    const standaloneContext=await browser.newContext({viewport:{width:390,height:785},deviceScaleFactor:3,isMobile:true,hasTouch:true,screen:{width:390,height:844}});
    await standaloneContext.addInitScript(()=>Object.defineProperty(Navigator.prototype,'standalone',{get:()=>true}));
    const homeScreen=await standaloneContext.newPage();
    await homeScreen.goto(origin+'/?sid='+sid);
    await homeScreen.waitForFunction(()=>document.querySelector('#connection-state').textContent==='Connected');
    await sleep(200);
    assert.equal(await homeScreen.locator('#composer').evaluate(c=>Math.round(c.getBoundingClientRect().bottom)),785);
    await standaloneContext.close();
    // ---- pairing: the public name requires a paired device ----
    assert.deepEqual((await remote('GET','/connection')).json(),{host:'marlin.test',push_enabled:true,paired:false});
    assert.equal((await remote('GET','/')).status,200);
    let denied=await remote('POST','/send',{body:'{"session_list":{}}'});
    assert.equal(denied.status,403); assert.equal(denied.json().err.code,'unpaired');
    assert.equal((await remote('GET','/events?sid='+sid)).status,403);
    assert.equal((await remote('GET','/push/info')).status,403);
    // A LAN peer cannot claim to be local, and foreign names are refused outright.
    assert.equal((await remote('GET','/connection',{host:'evil.test'})).status,403);
    let code=(await post({web_pair:{}})).web_status_result.pair_code;
    assert.match(code,/^\d{6}$/);
    const wrong=String((Number(code)+1)%1000000).padStart(6,'0');
    let attempt=await remote('POST','/pair',{body:JSON.stringify({code:wrong})});
    assert.equal(attempt.status,403); assert.equal(attempt.json().err.code,'bad_code');
    attempt=await remote('POST','/pair',{body:JSON.stringify({code:code.slice(0,3)+' '+code.slice(3)}),headers:{'x-forwarded-proto':'https','user-agent':'Mozilla/5.0 (iPhone; CPU iPhone OS 19_1 like Mac OS X)'}});
    assert.equal(attempt.status,200,attempt.text);
    const setCookie=attempt.headers['set-cookie'][0];
    assert.match(setCookie,/^marlin_device=[0-9a-f]{64}; Path=\/; Max-Age=34560000; HttpOnly; SameSite=Lax; Secure$/);
    const cookie=setCookie.split(';')[0];
    // Single use.
    assert.equal((await remote('POST','/pair',{body:JSON.stringify({code})})).status,403);
    const listed=await remote('POST','/send',{body:'{"session_list":{}}',cookie});
    assert.equal(listed.status,200); assert.ok(listed.json().session_list_result);
    assert.equal((await remote('GET','/events?sid='+sid,{cookie})).status,200);
    const renewed=await remote('GET','/connection',{cookie});
    assert.equal(renewed.json().paired,true); assert.match(renewed.headers['set-cookie'][0],/^marlin_device=/);
    let status=(await post({web_status:{}})).web_status_result;
    assert.equal(status.url,'https://marlin.test/');
    assert.equal(status.pair_code,'');
    assert.deepEqual(status.devices.map(d=>[d.id,d.name]),[[1,'iPhone']]);
    assert.ok(status.logs.some(line=>line.includes('paired iPhone #1')),status.logs.join('\n'));

    // The real pairing screen, reached by name, typed like a phone would.
    const phone=await chromium.launch({headless:true,executablePath:process.env.MARLIN_CHROMIUM_PATH || undefined,args:['--host-resolver-rules=MAP marlin.test 127.0.0.1']});
    try {
      const phoneContext=await phone.newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true});
      const phonePage=await phoneContext.newPage(); const phoneErrors=[];
      phonePage.on('pageerror',e=>phoneErrors.push(e.message));
      await phonePage.goto('http://marlin.test:'+port+'/?sid='+sid);
      await phonePage.locator('#pair-code').waitFor({state:'visible'});
      await phonePage.locator('#pair-code').fill('000000');
      await phonePage.waitForFunction(()=>document.querySelector('#pair-error').textContent.includes('wrong or expired'));
      code=(await post({web_pair:{}})).web_status_result.pair_code;
      await phonePage.locator('#pair-code').pressSequentially(code);
      await phonePage.waitForFunction(()=>document.querySelector('#connection-state').textContent==='Connected');
      assert.equal(await phonePage.locator('#pair').isHidden(),true);
      assert.deepEqual(phoneErrors,[]);
    } finally { await phone.close(); }
    status=(await post({web_status:{}})).web_status_result;
    assert.deepEqual(status.devices.map(d=>d.id),[1,2]);

    // Unpairing applies to the next request and ends that device's open stream.
    const {ended}=await new Promise((resolve,reject)=>{
      const req=http.request({host:'127.0.0.1',port,path:'/events?sid='+sid,headers:{host:'marlin.test',cookie}},res=>{
        assert.equal(res.statusCode,200);
        res.once('data',()=>resolve({ended:new Promise(done=>res.on('end',()=>done(true)))}));
        res.resume();
      });
      req.on('error',reject); req.end();
    });
    assert.deepEqual((await post({web_unpair:{id:1}})).web_status_result.devices.map(d=>d.id),[2]);
    assert.equal(await Promise.race([ended,sleep(5000).then(()=>false)]),true);
    denied=await remote('POST','/send',{body:'{"session_list":{}}',cookie});
    assert.equal(denied.status,403);
    assert.equal((await post({web_unpair:{id:1}})).err.code,'web');
    const stateFile=path.join(root,'state','marlin','web','pairing.json');
    assert.equal(fs.statSync(stateFile).mode&0o777,0o600);
    assert.ok(!fs.readFileSync(stateFile,'utf8').includes(cookie.split('=')[1]));

    await browser.close(); browser = null;
    const stopped = new Promise(resolve => daemon.once('exit', resolve));
    daemon.kill('SIGTERM');
    await Promise.race([stopped, sleep(5000).then(() => { throw Error('daemon shutdown timed out'); })]);
    await assert.rejects(fetch(origin+'/connection'));

    console.log('Mobile browser: real daemon presence, push key route, deep link, composer bounds, reading position, offline/reconnect, landscape, pairing, and unpairing passed.');
  } catch (error) {
    console.error('daemon log tail:\n'+logs.split('\n').slice(-40).join('\n'));
    throw error;
  } finally {
    await browser?.close();
    daemon.kill('SIGTERM');
    for(const child of [daemon]) {
      await Promise.race([new Promise(r=>child.exitCode!==null||child.signalCode!==null?r():child.once('exit',r)),sleep(5000).then(()=>child.kill('SIGKILL'))]);
    }
    fs.rmSync(root,{recursive:true,force:true});
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
