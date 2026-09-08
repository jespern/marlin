const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const push = require('./push.cjs');
const script = fs.readFileSync(path.join(__dirname,'push.cjs'),'utf8');
const un64 = s => Buffer.from(s,'base64url');
function peer() {
  const key=crypto.createECDH('prime256v1'); key.generateKeys();
  return {key, subscription:{endpoint:'https://web.push.apple.com/test',keys:{
    p256dh:key.getPublicKey().toString('base64url'), auth:crypto.randomBytes(16).toString('base64url')}}};
}
// Receiving peer implements the RFC 8291 HKDF stages using HMAC directly,
// independently of the sender's hkdfSync implementation.
function expand(prk, info, len) { return crypto.createHmac('sha256',prk).update(info).update(Buffer.from([1])).digest().subarray(0,len); }
function extract(salt, ikm) { return crypto.createHmac('sha256',salt).update(ikm).digest(); }
function decrypt(receiver, data) {
  assert.equal(data.readUInt32BE(16),4096); assert.equal(data[20],65);
  const salt=data.subarray(0,16), pub=data.subarray(21,86);
  const keyInfo=Buffer.concat([Buffer.from('WebPush: info\0'),receiver.key.getPublicKey(),pub]);
  const ikm=expand(extract(un64(receiver.subscription.keys.auth),receiver.key.computeSecret(pub)),keyInfo,32);
  const prk=extract(salt,ikm);
  const key=expand(prk,Buffer.from('Content-Encoding: aes128gcm\0'),16);
  const nonce=expand(prk,Buffer.from('Content-Encoding: nonce\0'),12);
  const decipher=crypto.createDecipheriv('aes-128-gcm',key,nonce);
  decipher.setAuthTag(data.subarray(-16));
  const plaintext=Buffer.concat([decipher.update(data.subarray(86,-16)),decipher.final()]);
  assert.equal(plaintext.at(-1),2);
  return JSON.parse(plaintext.subarray(0,-1));
}
test('a receiving push peer decrypts the payload and rejects tampering',()=>{
  const receiver=peer();
  const payload={title:'Marlin needs you',sid:'1874397504305914847'};
  const data=push.encrypt(receiver.subscription,payload);
  assert.deepEqual(decrypt(receiver,data),payload);
  const again=push.encrypt(receiver.subscription,payload);
  assert.notDeepEqual(data,again);
  data[data.length-1]^=1;
  assert.throws(()=>decrypt(receiver,data));
});
test('VAPID signature is valid, audience scoped, and short lived',()=>{
  const {privateKey,publicKey}=crypto.generateKeyPairSync('ec',{namedCurve:'prime256v1'});
  const pair={key:privateKey,publicKey:'public'};
  const header=push.authorization('https://web.push.apple.com/a',pair);
  const token=header.match(/^vapid t=(.*), k=public$/)[1].split('.');
  assert.equal(crypto.verify('sha256',Buffer.from(token[0]+'.'+token[1]),{key:publicKey,dsaEncoding:'ieee-p1363'},un64(token[2])),true);
  const claims=JSON.parse(un64(token[1]));
  assert.equal(claims.aud,'https://web.push.apple.com');
  assert.ok(claims.exp>Date.now()/1000 && claims.exp<Date.now()/1000+3601);
});
test('registration rejects private network, redirects, credentials and malformed keys',()=>{
  for(const url of ['http://web.push.apple.com/a','https://127.0.0.1/a','https://localhost/a',
    'https://web.push.apple.com.evil.test/a','https://user:pass@web.push.apple.com/a','https://web.push.apple.com:8080/a'])
    assert.throws(()=>push.endpointURL(url));
  assert.throws(()=>push.validate({...peer().subscription,keys:{auth:'bad',p256dh:'bad'}}));
  assert.doesNotThrow(()=>push.validate(peer().subscription));
});
test('helper process persists keys and subscriptions privately and supports revocation',()=>{
  const state=fs.mkdtempSync(path.join(os.tmpdir(),'marlin-push-test-'));
  try {
    const env={...process.env,XDG_STATE_HOME:state};
    const run=(action,input='')=>{
      const result=spawnSync(process.execPath,['-e',script,action,input],{env,encoding:'utf8',timeout:15000});
      assert.equal(result.status,0,result.stderr);
      return JSON.parse(result.stdout);
    };
    assert.deepEqual(run('info'),run('info'));
    const subscription=peer().subscription;
    run('subscribe',JSON.stringify(subscription)); run('subscribe',JSON.stringify(subscription));
    const dir=path.join(state,'marlin','push');
    const files=fs.readdirSync(dir).filter(n=>n.endsWith('.subscription'));
    assert.equal(files.length,1);
    assert.equal(fs.statSync(path.join(dir,files[0])).mode & 0o777,0o600);
    assert.equal(fs.statSync(path.join(dir,'vapid.json')).mode & 0o777,0o600);
    run('unsubscribe',JSON.stringify({endpoint:subscription.endpoint}));
    assert.equal(fs.readdirSync(dir).filter(n=>n.endsWith('.subscription')).length,0);
    assert.deepEqual(run('deliver',JSON.stringify({title:'No subscribers'})),{ok:true});
  } finally { fs.rmSync(state,{recursive:true,force:true}); }
});
