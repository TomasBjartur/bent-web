// Passkey ceremonies for the sign-up and log-in pages (vanilla JS).
'use strict';
(() => {
const enc = (buf) => { const b = new Uint8Array(buf); let s = ''; for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]); return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); };
const dec = (s) => { const t = atob(s.replace(/-/g, '+').replace(/_/g, '/')); const b = new Uint8Array(t.length); for (let i = 0; i < t.length; i++) b[i] = t.charCodeAt(i); return b; };
const post = (url, data) => fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(data), credentials: 'same-origin' });
const status = (msg) => { const el = document.getElementById('passkey-status'); if (el) el.textContent = msg; };
const finish = async (res) => { if (res.ok) { status('Done. Taking you in…'); location.assign(await res.text()); return true; } status('That did not work. Please try again.'); return false; };
// Runs a ceremony with the button disabled, so a double click cannot start two.
const run = (btn, f) => btn.addEventListener('click', async () => {
  if (!window.PublicKeyCredential) { status('This browser does not support passkeys. Try a recent Chrome, Safari, Firefox or Edge.'); return; }
  btn.disabled = true;
  status('Waiting for your device…');
  let ok = false;
  try { ok = await f(); } catch (err) { status('Cancelled or not supported on this device.'); }
  if (!ok) btn.disabled = false;
});
const reg = document.getElementById('passkey-register');
if (reg) run(reg, async () => {
  const t = reg.dataset.token;
  const r = await post('/passkey/register/options', { t });
  if (!r.ok) { status('This link has expired. Ask for a new one.'); return false; }
  const o = await r.json();
  const cred = await navigator.credentials.create({ publicKey: { challenge: dec(o.challenge), rp: { id: o.rpId, name: o.rpName }, user: { id: dec(o.userId), name: o.userName, displayName: o.userDisplay }, pubKeyCredParams: [{ type: 'public-key', alg: -7 }], authenticatorSelection: { residentKey: 'required', userVerification: 'required' }, attestation: 'none', timeout: 120000 } });
  return finish(await post('/passkey/register', { t, cd: enc(cred.response.clientDataJSON), att: enc(cred.response.attestationObject) }));
});
const login = document.getElementById('passkey-login');
if (login) run(login, async () => {
  const r = await post('/passkey/login/options', {});
  const o = await r.json();
  const cred = await navigator.credentials.get({ publicKey: { challenge: dec(o.challenge), rpId: o.rpId, userVerification: 'required', timeout: 120000 } });
  return finish(await post('/passkey/login', { id: enc(cred.rawId), cd: enc(cred.response.clientDataJSON), ad: enc(cred.response.authenticatorData), sig: enc(cred.response.signature) }));
});
})();
