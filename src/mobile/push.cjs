// Web Push delivery boundary. Node 22+; only built-in modules, no npm install.
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const b64 = b => Buffer.from(b).toString('base64url');
const un64 = s => Buffer.from(s, 'base64url');
const root = path.join(process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local/state'), 'marlin', 'push');
function endpointURL(endpoint) {
  const u = new URL(endpoint);
  const h = u.hostname;
  if (u.protocol !== 'https:' || u.username || u.password || u.port || u.hash ||
      !(h === 'web.push.apple.com' || h.endsWith('.push.apple.com') ||
        h === 'fcm.googleapis.com' || h === 'updates.push.services.mozilla.com' ||
        h.endsWith('.notify.windows.com'))) throw Error('unsupported push service');
  return u;
}
function validate(s) {
  endpointURL(s.endpoint);
  if (s.endpoint.length > 4096 || !s.keys || typeof s.keys.auth !== 'string' ||
      typeof s.keys.p256dh !== 'string' || un64(s.keys.auth).length !== 16 ||
      un64(s.keys.p256dh).length !== 65) throw Error('invalid subscription');
  crypto.ECDH.convertKey(un64(s.keys.p256dh), 'prime256v1');
  return {endpoint:s.endpoint, keys:{auth:s.keys.auth, p256dh:s.keys.p256dh}};
}
function keyPair() {
  fs.mkdirSync(root, {recursive:true, mode:0o700});
  const file = path.join(root, 'vapid.json');
  if (!fs.existsSync(file)) {
    const {privateKey} = crypto.generateKeyPairSync('ec', {namedCurve:'prime256v1'});
    const tmp = file + '.' + crypto.randomUUID();
    fs.writeFileSync(tmp, JSON.stringify(privateKey.export({format:'jwk'})), {mode:0o600, flag:'wx'});
    try { fs.linkSync(tmp, file); } catch(e) { if(e.code !== 'EEXIST') throw e; }
    finally { fs.unlinkSync(tmp); }
  }
  const jwk = JSON.parse(fs.readFileSync(file, 'utf8'));
  return {key:crypto.createPrivateKey({key:jwk, format:'jwk'}), publicKey:b64(Buffer.concat([Buffer.from([4]),un64(jwk.x),un64(jwk.y)]))};
}
function subscriptionPath(endpoint) {
  return path.join(root, crypto.createHash('sha256').update(endpoint).digest('hex') + '.subscription');
}
function hkdf(ikm, salt, info, length) {
  return Buffer.from(crypto.hkdfSync('sha256', ikm, salt, info, length));
}
function encrypt(subscription, payload) {
  const ua = un64(subscription.keys.p256dh);
  const as = crypto.createECDH('prime256v1'); as.generateKeys();
  const pub = as.getPublicKey();
  const ikm = hkdf(as.computeSecret(ua), un64(subscription.keys.auth),
    Buffer.concat([Buffer.from('WebPush: info\0'), ua, pub]), 32);
  const salt = crypto.randomBytes(16);
  const cek = hkdf(ikm,salt,Buffer.from('Content-Encoding: aes128gcm\0'),16);
  const nonce = hkdf(ikm,salt,Buffer.from('Content-Encoding: nonce\0'),12);
  const cipher = crypto.createCipheriv('aes-128-gcm',cek,nonce);
  const plain = Buffer.concat([Buffer.from(JSON.stringify(payload)),Buffer.from([2])]);
  if (plain.length + 16 > 4096) throw Error('payload too large');
  const header = Buffer.alloc(21); salt.copy(header); header.writeUInt32BE(4096,16); header[20]=65;
  return Buffer.concat([header,pub,cipher.update(plain),cipher.final(),cipher.getAuthTag()]);
}
function authorization(endpoint, pair) {
  const header = b64(JSON.stringify({typ:'JWT',alg:'ES256'}));
  const claims = b64(JSON.stringify({aud:endpointURL(endpoint).origin,exp:Math.floor(Date.now()/1000)+3600,sub:'https://github.com/jespern/marlin'}));
  const token = header+'.'+claims;
  const signature = crypto.sign('sha256', Buffer.from(token), {key:pair.key,dsaEncoding:'ieee-p1363'});
  return 'vapid t='+token+'.'+b64(signature)+', k='+pair.publicKey;
}
async function main(action, input) {
  const pair = keyPair();
  if(action === 'info') return {publicKey:pair.publicKey};
  if(action === 'subscribe') {
    const s=validate(JSON.parse(input));
    const file=subscriptionPath(s.endpoint);
    if(!fs.existsSync(file) && fs.readdirSync(root).filter(n=>n.endsWith('.subscription')).length>=32)
      throw Error('subscription limit reached');
    const tmp=file+'.'+crypto.randomUUID();
    fs.writeFileSync(tmp,JSON.stringify(s),{mode:0o600,flag:'wx'});
    fs.renameSync(tmp,file);
    return {ok:true};
  }
  if(action === 'unsubscribe') {
    const {endpoint}=JSON.parse(input); endpointURL(endpoint);
    fs.rmSync(subscriptionPath(endpoint),{force:true}); return {ok:true};
  }
  if(action !== 'deliver') throw Error('unknown action');
  const payload=JSON.parse(input);
  const files=fs.readdirSync(root).filter(n=>n.endsWith('.subscription')).slice(0,32);
  let failures=0;
  await Promise.all(files.map(async name=>{
    try {
      const file=path.join(root,name);
      const s=validate(JSON.parse(fs.readFileSync(file,'utf8')));
      const response=await fetch(s.endpoint,{method:'POST',redirect:'error',signal:AbortSignal.timeout(8000),
        headers:{Authorization:authorization(s.endpoint,pair),TTL:'300',Urgency:'normal','Content-Encoding':'aes128gcm','Content-Type':'application/octet-stream'},
        body:encrypt(s,payload)});
      if(response.status===404 || response.status===410) fs.rmSync(file,{force:true});
      else if(!response.ok) failures++;
      await response.body?.cancel();
    } catch { failures++; }
  }));
  if(failures) throw Error('push delivery failed for '+failures+' subscription(s)');
  return {ok:true};
}
module.exports={encrypt,authorization,validate,endpointURL,main};
if(['info','subscribe','unsubscribe','deliver'].includes(process.argv[1])) {
  const deadline=setTimeout(()=>process.exit(1),12000);
  main(process.argv[1],process.argv[2]).then(result=>{
    console.log(JSON.stringify(result)); clearTimeout(deadline);
  }).catch(()=>{console.error('Marlin push helper failed');process.exitCode=1;clearTimeout(deadline);});
}
