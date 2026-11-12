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
    let b=await bounds(); assert.ok(Math.abs(b.bottom-b.height-b.offset)<2,JSON.stringify(b));
    assert.ok(b.statusBottom<=b.top+1);
    await page.locator('#input').focus();
    await page.setViewportSize({width:390,height:420});
    await sleep(100);
    b=await bounds(); assert.ok(Math.abs(b.bottom-b.height-b.offset)<2,JSON.stringify(b));
    assert.equal(b.scroll,0);
    await page.evaluate(()=>{
      const t=document.querySelector('#transcript');
      for(let i=0;i<150;i++) {const p=document.createElement('p');p.textContent='Reading fixture '+i;t.append(p);}
      t.scrollTop=400;
    });
    await page.setViewportSize({width:390,height:600}); await sleep(100);
    assert.equal(await page.locator('#transcript').evaluate(t=>t.scrollTop),400);
    await context.setOffline(true);
    await page.waitForFunction(()=>document.querySelector('#connection-state').textContent==='Offline');
    await context.setOffline(false);
    await page.waitForFunction(()=>document.querySelector('#connection-state').textContent==='Connected');
    await page.setViewportSize({width:844,height:390}); await sleep(100);
    b=await bounds(); assert.ok(Math.abs(b.bottom-390)<2,JSON.stringify(b));
    assert.deepEqual(errors,[]);
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
