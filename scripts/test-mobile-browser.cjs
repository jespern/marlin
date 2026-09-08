// Real daemon + HTTP bridge + Chromium mobile viewport. No real provider calls.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
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
  fs.writeFileSync(path.join(config,'config.toml'),'[web]\nenabled = true\ntailscale = false\npush = true\nport = '+port+'\n');
  const binary=path.resolve('zig-out/bin/marlin');
  const daemon=spawn(binary,['daemon'],{env,stdio:['ignore','ignore','pipe']});
  let logs=''; daemon.stderr.on('data',b=>logs+=b);
  let browser;
  const origin='http://127.0.0.1:'+port;
  const post=async obj=>{
    const r=await fetch(origin+'/send',{method:'POST',body:JSON.stringify(obj)});
    return JSON.parse((await r.text()).replace(/"sid":(\d+)/g,'"sid":"$1"'));
  };
  try {
    let ready=false;
    for(let i=0;i<150;i++) {
      try { if((await fetch(origin+'/connection')).ok) {ready=true;break;} } catch {}
      await sleep(100);
    }
    assert.ok(ready,logs);
    const settings=await (await fetch(origin+'/connection')).json();
    assert.deepEqual(settings,{tailnet_host:null,push_enabled:true});
    let managed;
    for (let i=0;i<100;i++) {
      managed=(await post({web_status:{}})).web_status_result;
      if (managed.state==='running' && managed.logs.some(line=>line.includes('web access'))) break;
      await sleep(50);
    }
    assert.equal(managed.enabled,true);
    assert.equal(managed.state,'running');
    assert.ok(managed.logs.some(line=>line.includes('web access')));
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
    assert.equal(await page.locator('#canonical-url').getAttribute('href'),origin+'/');
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
    await browser.close(); browser = null;
    const stopped = new Promise(resolve => daemon.once('exit', resolve));
    daemon.kill('SIGTERM');
    await Promise.race([stopped, sleep(5000).then(() => { throw Error('daemon shutdown timed out'); })]);
    await assert.rejects(fetch(origin+'/connection'));

    console.log('Mobile browser: real daemon presence, push key route, deep link, composer bounds, reading position, offline/reconnect, and landscape passed.');
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
