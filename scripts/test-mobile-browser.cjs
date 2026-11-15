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
  env.SHELL='/bin/sh'; // shells (`!!`) without the machine's rc files
  for(const name of Object.keys(env)) if(/API_KEY|TOKEN|SECRET/.test(name)) delete env[name];
  const reserve=net.createServer(); await new Promise(r=>reserve.listen(0,'127.0.0.1',r));
  const port=reserve.address().port; await new Promise(r=>reserve.close(r));
  // Dictation stand-ins: ffmpeg copies -i <in> to the last argument; the
  // engine reads the "wav" and prints whisper-style output.
  const fakes=path.join(root,'fakebin'); fs.mkdirSync(fakes);
  fs.writeFileSync(path.join(fakes,'ffmpeg'),'#!/bin/sh\nin=""; while [ $# -gt 1 ]; do [ "$1" = -i ] && in="$2"; shift; done\ncp "$in" "$1"\n',{mode:0o755});
  fs.writeFileSync(path.join(fakes,'whisper-cli'),'#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = -f ] && wav="$2"; shift; done\n[ "$(cat "$wav")" = AUDIO ] || exit 3\necho "[00:00:00.000 --> 00:00:01.000]  hello from   the phone"\n',{mode:0o755});
  env.PATH=fakes+':'+env.PATH;
  fs.writeFileSync(path.join(config,'config.toml'),'[web]\nenabled = true\npush = true\nhosts = ["marlin.test"]\nport = '+port+'\n[voice]\nenabled = true\nengine = "whisper-turbo"\nmodel = "/models/x.bin"\nstt_bin = "'+path.join(fakes,'whisper-cli')+'"\n');
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
    assert.deepEqual(settings,{host:'marlin.test',push_enabled:true,paired:true,home:root});
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
    const otherSid=(await post({session_create:{cwd:root,model:'local/testing',title:'Another session'}})).session_created.sid;
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
    // Focusing alone must not move the field: iOS drops a tap whose target
    // shifts under the finger (it took two taps to start typing).
    const inputRect=()=>page.locator('#input').evaluate(i=>JSON.stringify(i.getBoundingClientRect()));
    const beforeFocus=await inputRect();
    await page.locator('#input').focus();
    await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));
    assert.equal(await inputRect(),beforeFocus);
    // The keyboard (the visible height shrinking) drops the home-indicator padding.
    await page.setViewportSize({width:390,height:420});
    await settle();
    assert.equal(await page.evaluate(()=>document.body.style.getPropertyValue('--bottom-inset')),'0px');
    b=await bounds(); assert.ok(Math.abs(b.bottom-b.height-b.offset)<2,JSON.stringify(b));
    assert.equal(b.scroll,0);
    await page.evaluate(async()=>{
      const t=document.querySelector('#transcript');
      for(let i=0;i<150;i++) {const p=document.createElement('p');p.textContent='Reading fixture '+i;t.append(p);}
      await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
      // The reader scrolls back to read.
      t.scrollTop=400;
      await new Promise(r=>t.addEventListener('scroll',r,{once:true}));
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
    assert.deepEqual(await page.locator('#composer > :not(#attachments):not([hidden])').evaluateAll(n=>n.map(e=>e.className||e.id)),['attach-btn','prompt','input','mic-btn','send-btn']);
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
      const c3=g.querySelector('[data-call="c3"]');
      const failed={summary:g.firstElementChild.textContent,open:g.open,callOpen:c3.open,marked:c3.classList.contains('err')};
      addBlock({ts:now,body:{assistant_msg:{text:'done'}}});
      call('c4','ls');
      const next=t.lastElementChild!==g && t.lastElementChild.classList.contains('single');
      addBlock({ts:now,body:{reasoning:{text:'thinking'}}});
      const cs=sel=>getComputedStyle(t.querySelector(sel)).color;
      return {lone,folded,failed,next,reasoning:cs('.reasoning'),body:getComputedStyle(document.body).color,note:cs('.block.note')};
    });
    assert.deepEqual(tools.lone,{single:true,open:true,exe:'git',op:'|'});
    assert.deepEqual(tools.folded,{single:false,open:false,summary:'⚙ Ran 2 commands',rows:2,notes:1,unwrapped:'rg -n x src/'});
    // A failure is marked, never unfolded: some models fail all the time.
    assert.deepEqual(tools.failed,{summary:'⚙ Ran 3 commands · 1 failed',open:false,callOpen:false,marked:true});
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
        await submitComposer(); // Enter on a keyboard, ↑ on a phone
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
      const decisions=sent.map(m=>m.approve&&m.approve.decision);
      // A real keyboard: Shift+Enter is a newline, Enter sends.
      const input=document.querySelector('#input'); input.value='two\nlines';
      input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',shiftKey:true,bubbles:true,cancelable:true}));
      const afterShift=sent.length;
      input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
      return {decisions,shiftSent:afterShift>1,enterText:(sent.find(m=>m.input)||{input:{}}).input.text};
    });
    assert.deepEqual(hotkey,{decisions:['granted'],shiftSent:false,enterText:'two\nlines'});
    await desk.close();
    // Composer and status: multi-line on a phone, queued while busy, no
    // forced scrolling, folder and credits in the status line, session marks.
    const comp=await page.evaluate(async()=>{
      await loadSessions(); // earlier stubbed commands left an empty list
      const out={}, sent=[], realSend=window.send, real=window.matchMedia.bind(window);
      window.send=async raw=>{sent.push(JSON.parse(raw)); return {ok:{}};};
      try {
        out.cwd=document.querySelector('#status .cwd').textContent.replace(/\u200e/g,'');
        // Phone: Return is a newline; the ↑ button sends, newline included.
        window.matchMedia=q=>q==='(pointer: coarse)'?{matches:true}:q==='(pointer: fine)'?{matches:false}:real(q);
        const input=document.querySelector('#input');
        input.value='line one';
        input.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
        out.enterSent=sent.length;
        input.value='line one\nline two'; input.dispatchEvent(new Event('input'));
        out.sendEnabled=!document.querySelector('#send-btn').disabled;
        document.querySelector('#send-btn').dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true}));
        await new Promise(r=>setTimeout(r,0));
        out.sentText=(sent.find(m=>m.input)||{input:{}}).input.text;
        window.matchMedia=real;
        // Queued: sent while running, marked at once (the spinner hid this).
        setState('running');
        input.value='also this'; await submitComposer();
        out.queued=[...document.querySelectorAll('.user.optimistic')].pop().classList.contains('queued');
        setState('idle');
        // Reading older output: new blocks keep the place and offer ↓ new.
        const t=document.querySelector('#transcript');
        for(let i=0;i<60;i++) addBlock({ts:Date.now(),body:{assistant_msg:{text:'filler '+i}}});
        await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
        t.scrollTop=0; t.dispatchEvent(new Event('scroll'));
        addBlock({ts:Date.now(),body:{assistant_msg:{text:'new output'}}});
        out.kept=t.scrollTop===0; out.jump=document.querySelector('#jump').classList.contains('show');
        document.querySelector('#jump').click();
        out.bottom=t.scrollHeight-t.clientHeight-t.scrollTop<2;
        // Credits and context colors as in the TUI.
        handle({status:{sid,state:'idle',usage_credits:true}});
        out.credits=document.querySelector('#status .credits').textContent;
        setContext({context_used:75,context_limit:100}); out.warn=document.querySelector('#status .ctx').className;
        setContext({context_used:95,context_limit:100}); out.hot=document.querySelector('#status .ctx').className;
        // Session marks: running, approval, error, paused, unread completion.
        const base={title:'x',model:'m',cwd:'/'};
        renderSessions([{...base,sid:'91',state:'running'},{...base,sid:'92',state:'awaiting_approval'},{...base,sid:'93',state:'err'},
          {...base,sid:'94',state:'idle',pause:'paused'},{...base,sid:'95',state:'idle'},{...base,sid:'96',state:'running'}]);
        handle({status:{sid:'96',state:'idle'}});
        out.marks=[...document.querySelectorAll('#sessions .mark')].map(m=>m.textContent+m.className.replace('mark ',':'));
      } finally { window.send=realSend; window.matchMedia=real; }
      return out;
    });
    assert.equal(comp.cwd,'~');
    assert.equal(comp.enterSent,0);
    assert.equal(comp.sendEnabled,true);
    assert.equal(comp.sentText,'line one\nline two');
    assert.equal(comp.queued,true);
    assert.deepEqual([comp.kept,comp.jump,comp.bottom],[true,true,true]);
    // Following the bottom survives what moves it without the reader: the
    // keyboard shrinking the view (a scroll event follows on iOS), a block
    // expanding. Only scrolling up stops it.
    const sticks=await page.evaluate(async()=>{
      const frame=()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
      const t=document.querySelector('#transcript');
      const atBottom=()=>t.scrollHeight-t.clientHeight-t.scrollTop<2;
      const out={};
      scrollBottom(true); await frame();
      t.style.maxHeight='120px'; await frame(); t.dispatchEvent(new Event('scroll'));
      addBlock({ts:Date.now(),body:{assistant_msg:{text:'after the keyboard'}}}); await frame();
      out.keyboard=atBottom();
      t.style.maxHeight=''; await frame();
      const d=document.createElement('details'); d.innerHTML='<summary>tool</summary>'+'<p>line</p>'.repeat(30);
      t.appendChild(d); await frame();
      d.open=true; await frame();
      out.expanded=atBottom();
      d.remove(); await frame();
      t.dispatchEvent(new WheelEvent('wheel',{deltaY:-120})); t.scrollTop=0; t.dispatchEvent(new Event('scroll'));
      addBlock({ts:Date.now(),body:{assistant_msg:{text:'while reading'}}}); await frame();
      out.reading=t.scrollTop===0&&document.querySelector('#jump').classList.contains('show');
      scrollBottom(true); await frame();
      out.back=atBottom()&&!document.querySelector('#jump').classList.contains('show');
      return out;
    });
    assert.deepEqual(sticks,{keyboard:true,expanded:true,reading:true,back:true});
    assert.equal(comp.credits,' · api credits');
    assert.deepEqual([comp.warn,comp.hot],['ctx agent warn','ctx agent hot']);
    assert.deepEqual(comp.marks,['●:running','!:approval','×:err','‖:paused','·:idle','✓:done']);
    await page.reload();
    await page.waitForFunction(()=>document.querySelector('#connection-state').textContent==='Connected');
    // Dictation: the clip goes to /transcribe, runs /voice's engine on the
    // daemon host, and the text lands at the cursor; unpaired devices are refused.
    assert.equal((await remote('POST','/transcribe',{body:'AUDIO'})).status,403);
    const dictated=await page.evaluate(async()=>{
      const input=document.querySelector('#input'); input.value='please'; input.setSelectionRange(6,6);
      await finishDictation(sid,new Blob(['AUDIO'],{type:'audio/mp4'}));
      const text=input.value; input.value=''; growInput();
      return {text,visible:!document.querySelector('#mic-btn').hidden};
    });
    assert.deepEqual(dictated,{text:'please hello from the phone',visible:true});
    // Shells: the TUI's SGR rows drawn with their colors, the cursor where the
    // terminal has it; a finished shell as the TUI shows it.
    const sgr=await page.evaluate(()=>{
      const rows=sgrRows('\x1b[31mred\x1b[0m plain\r\n\x1b[1;38;5;208mx\x1b]8;;https://x\x07y\x1b]8;;\x07\x1b[38:2::1:2:3mz',{row:1,col:4});
      addBlock({seq:0,ts:0,body:{shell_transcript:{text:'$ make\nok',styled:'$ make\r\n\x1b[32mok\x1b[0m',exit_code:2,ran:'make test'}}});
      const node=[...document.querySelectorAll('.block.shell')].pop();
      const out={rows,head:node.querySelector('.head').textContent,body:node.querySelector('pre').innerHTML};
      node.remove();
      return out;
    });
    assert.equal(sgr.rows[0],'<span style="color:#f07178">red</span> plain');
    assert.equal(sgr.rows[1],'<span style="color:rgb(255,135,0);font-weight:700">xy</span><span style="color:rgb(1,2,3);font-weight:700">z</span> <span class="cur"> </span>');
    assert.equal(sgr.head,'$ make test · exited 2');
    // Links as the TUI shows them: a file on the Mac is its name, not raw Markdown.
    const links=await page.evaluate(()=>inlineMd('Updated [BLOBS.md](/Users/x/BLOBS.md:19) and [docs](https://x.test/a)'));
    assert.equal(links,'Updated <span class="mdlink" title="/Users/x/BLOBS.md:19">BLOBS.md</span> and <a href="https://x.test/a" target="_blank" rel="noopener noreferrer">docs</a>');
    // A partial live stream (the page opened mid-way) is still cleared by
    // the commentary it became, and live text sent whole replaces it.
    const live=await page.evaluate(()=>{
      handle({delta:{sid,turn_id:0,text:'est the'}});
      handle({delta:{sid,turn_id:0,text:'Test the',replace:true}});
      const replaced=deltaText;
      addBlock({seq:0,ts:0,body:{reasoning:{text:'Test the parser',commentary:true}}});
      const cleared=deltaText===''&&!deltaEl;
      [...document.querySelectorAll('.block.reasoning')].pop().remove();
      return {replaced,cleared};
    });
    assert.deepEqual(live,{replaced:'Test the',cleared:true});
    assert.equal(sgr.body,'$ make\n<span style="color:#73d091">ok</span>');
    // A shell is the whole account: never for a browser that is not paired.
    assert.equal((await fetch(origin+'/shell?sid='+sid+'&cols=40&rows=20')).status,403);
    // Each session keeps its own draft, and a transcription finishing after
    // a switch lands in the session it was recorded in, not the open one.
    const switched=await page.evaluate(async other=>{
      const home=cur, input=document.querySelector('#input');
      input.value='draft here';
      const done=finishDictation(sid,new Blob(['AUDIO'],{type:'audio/mp4'}));
      open(sessionsCache.find(s=>String(s.sid)===String(other)));
      const emptyOnSwitch=input.value;
      await done;
      const otherAfter=input.value;
      input.value='other draft';
      open(home);
      const back=input.value;
      open(sessionsCache.find(s=>String(s.sid)===String(other)));
      const otherKept=input.value;
      input.value='';
      open(home);
      input.value=''; growInput();
      return {emptyOnSwitch,otherAfter,back,otherKept};
    },otherSid);
    assert.deepEqual(switched,{emptyOnSwitch:'',otherAfter:'',back:'draft here hello from the phone',otherKept:'other draft'});
    await page.waitForFunction(()=>document.querySelector('#connection-state').textContent==='Connected');
    // Closed and opened again at "/" (as a Home Screen app always is), it
    // comes back to the session that was open; a link's ?sid= still wins.
    // Both ways round: one of them is not the session listed first.
    for(const want of [otherSid,sid]) {
      await page.evaluate(id=>open(sessionsCache.find(s=>String(s.sid)===String(id))),want);
      await page.goto(origin+'/');
      await page.waitForFunction(()=>document.querySelector('#connection-state').textContent==='Connected');
      assert.equal(await page.evaluate(()=>String(sid)),String(want));
    }
    await page.goto(origin+'/?sid='+otherSid);
    await page.waitForFunction(()=>document.querySelector('#connection-state').textContent==='Connected');
    assert.equal(await page.evaluate(()=>String(sid)),String(otherSid));
    await page.goto(origin+'/?sid='+sid);
    await page.waitForFunction(()=>document.querySelector('#connection-state').textContent==='Connected');
    // A draft's text survives the app closing, per session; sending clears it.
    const connected=()=>page.waitForFunction(()=>document.querySelector('#connection-state').textContent==='Connected');
    await page.locator('#input').fill('half a thought');
    await page.evaluate(id=>open(sessionsCache.find(s=>String(s.sid)===String(id))),otherSid);
    await page.locator('#input').fill('other thought');
    await page.goto(origin+'/?sid='+sid); await connected();
    assert.equal(await page.locator('#input').inputValue(),'half a thought');
    await page.goto(origin+'/?sid='+otherSid); await connected();
    assert.equal(await page.locator('#input').inputValue(),'other thought');
    await page.locator('#input').fill('');
    await page.goto(origin+'/?sid='+otherSid); await connected();
    assert.equal(await page.locator('#input').inputValue(),'');
    await page.goto(origin+'/?sid='+sid); await connected();
    await page.locator('#input').fill('');
    // Where you were reading survives too, as a block and its offset; a view
    // following the bottom stores nothing and reopens at the bottom.
    const reading=await page.evaluate(async()=>{
      const frame=()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
      const t=document.querySelector('#transcript');
      for(let i=0;i<40;i++) addBlock({seq:900000+i,ts:Date.now(),body:{assistant_msg:{text:'reading '+i}}});
      await frame();
      const target=t.querySelector('[data-seq="900010"]');
      t.dispatchEvent(new WheelEvent('wheel',{deltaY:-120}));
      t.scrollTop+=target.getBoundingClientRect().top-t.getBoundingClientRect().top-7;
      t.dispatchEvent(new Event('scroll')); await frame();
      window.dispatchEvent(new Event('pagehide'));
      const kept=(keptState()[String(sid)]||{}).read;
      scrollBottom(true); await frame();
      pendingReading=kept;
      handle({replay_done:{sid,oldest_seq:0,has_older:false}}); await frame();
      const at=Math.round(target.getBoundingClientRect().top-t.getBoundingClientRect().top);
      scrollBottom(true); await frame();
      window.dispatchEvent(new Event('pagehide'));
      const following=!(keptState()[String(sid)]||{}).read;
      t.querySelectorAll('[data-seq^="9000"]').forEach(n=>n.remove());
      return {kept,at,following};
    });
    assert.deepEqual(reading,{kept:{seq:'900010',offset:7},at:7,following:true});
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
    await page.evaluate(()=>submitComposer()); // Enter on a keyboard, ↑ on a phone
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
    assert.deepEqual((await remote('GET','/connection')).json(),{host:'marlin.test',push_enabled:true,paired:false,home:null});
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

      // `!! <command>` from the phone: it runs on the daemon's host and its
      // output joins the transcript once it ends.
      await phonePage.evaluate(()=>{ document.querySelector('#input').value='!! echo ran-$((2+3)); exit 3'; submitComposer(); });
      await phonePage.waitForFunction(()=>[...document.querySelectorAll('.block.shell')].some(n=>n.textContent.includes('ran-5')));
      assert.equal(await phonePage.locator('.block.shell .head').last().textContent(),'$ echo ran-$((2+3)); exit 3 · exited 3');
      assert.equal(await phonePage.locator('#main').getAttribute('class'),'');

      // `!!`: a live shell. The screen is drawn here, Return runs a line,
      // and ^D on the key bar ends it.
      await phonePage.evaluate(()=>{ document.querySelector('#input').value='!!'; submitComposer(); });
      await phonePage.waitForFunction(()=>document.querySelector('#main').classList.contains('shell') && document.querySelector('#term .row'));
      assert.equal(await phonePage.locator('#status .state').textContent(),'shell');
      assert.equal(await phonePage.locator('#status .model').isHidden(),true);
      assert.equal(await phonePage.locator('#composer .prompt').textContent(),'$');
      await phonePage.waitForFunction(()=>document.querySelector('#sessions .mark.shell'));
      await phonePage.evaluate(()=>{ document.querySelector('#input').value='echo live-$((3+4))'; submitComposer(); });
      await phonePage.waitForFunction(()=>document.querySelector('#term').textContent.includes('live-7'));
      assert.equal(await phonePage.locator('#term .cur').count(),1);
      await phonePage.locator('#keybar [data-key="^D"]').dispatchEvent('pointerdown');
      await phonePage.waitForFunction(()=>!document.querySelector('#main').classList.contains('shell'));
      await phonePage.waitForFunction(()=>[...document.querySelectorAll('.block.shell')].some(n=>n.textContent.includes('live-7')));
      assert.equal(await phonePage.locator('#composer .prompt').textContent(),'❯');
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
