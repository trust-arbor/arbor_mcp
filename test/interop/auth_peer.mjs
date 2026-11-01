// Independent test IdP/AS/resource peer. Uses jose, never Arbor token helpers.
// This is a protocol fixture, not a deployable OAuth or SAML implementation.
import http from 'node:http';
import readline from 'node:readline';
import { randomUUID } from 'node:crypto';
import { generateKeyPair, exportJWK, importJWK, jwtVerify, SignJWT } from 'jose';

const clients = {
  idp: await generateKeyPair('ES256', { extractable: true }),
  as: await generateKeyPair('ES256', { extractable: true })
};
const idp = await generateKeyPair('ES256');
const issuerKey = await generateKeyPair('ES256');
let origin;
let cimd;
const seen = new Set();
const counts = { idp: 0, as: 0, resource: 0 };

async function authenticate(req, params, leg) {
  const name = leg === 'as' && cimd ? cimd.client_id : `${leg}-client`;
  const secret = `fake-${leg}-secret`;
  let key = clients[leg].publicKey;
  if (leg === 'as' && cimd) {
    if (params.get('client_id') !== name || !params.has('client_assertion') || req.headers.authorization) throw new Error('wrong CIMD authentication');
    const response = await fetch(cimd.metadata_url, { redirect: 'error' });
    if (!response.ok) throw new Error('metadata retrieval failed');
    const metadata = await response.json();
    if (metadata.client_id !== name || metadata.token_endpoint_auth_method !== 'private_key_jwt' ||
        typeof metadata.client_name !== 'string' || !Array.isArray(metadata.redirect_uris) || !metadata.redirect_uris.length) throw new Error('invalid client metadata');
    let jwks = metadata.jwks;
    if (metadata.jwks_uri) {
      if (metadata.jwks_uri !== `${name}/jwks`) throw new Error('unexpected JWKS identity');
      const response = await fetch(cimd.jwks_url, { redirect: 'error' });
      if (!response.ok) throw new Error('JWKS retrieval failed');
      jwks = await response.json();
    }
    if (!Array.isArray(jwks?.keys) || jwks.keys.length !== 1 || jwks.keys[0].d) throw new Error('invalid public key set');
    key = await importJWK(jwks.keys[0], 'ES256');
  }
  if (req.headers.authorization) {
    if (req.headers.authorization !== `Basic ${Buffer.from(`${name}:${secret}`).toString('base64')}` ||
        params.has('client_secret') || params.has('client_assertion')) throw new Error('invalid Basic credentials');
  } else if (params.has('client_assertion')) {
    if (params.has('client_secret') || params.get('client_assertion_type') !== 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer') throw new Error('invalid JWT method');
    const { payload } = await jwtVerify(params.get('client_assertion'), key, {
      issuer: name, subject: name, audience: leg === 'idp' ? `${origin}/idp/token` : [`${origin}/as`, `${origin}/as/token`], algorithms: ['ES256'],
      requiredClaims: ['exp', 'iat', 'jti'], maxTokenAge: '5m'
    });
    if (seen.has(payload.jti)) throw new Error('replayed assertion');
    seen.add(payload.jti);
  } else if (params.get('client_id') !== name || params.get('client_secret') !== secret) {
    throw new Error('missing or wrong credentials');
  }
}

function json(res, status, value) {
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  res.end(JSON.stringify(value));
}

async function sign(claims, key, typ, audience, issuer) {
  return new SignJWT(claims).setProtectedHeader({ alg: 'ES256', typ }).setIssuer(issuer)
    .setAudience(audience).setIssuedAt().setExpirationTime('5m').setJti(randomUUID()).sign(key);
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, origin);
    if (url.pathname.includes('oauth-protected-resource')) {
      return json(res, 200, { resource: `${origin}/mcp`, authorization_servers: [`${origin}/as`] });
    }
    if (url.pathname.includes('.well-known')) {
      const leg = url.pathname.includes('/idp') ? 'idp' : 'as';
      return json(res, 200, {
        issuer: `${origin}/${leg}`, authorization_endpoint: `${origin}/${leg}/authorize`, token_endpoint: `${origin}/${leg}/token`,
        grant_types_supported: ['client_credentials', 'urn:ietf:params:oauth:grant-type:jwt-bearer'],
        authorization_grant_profiles_supported: ['urn:ietf:params:oauth:grant-profile:id-jag'],
        token_endpoint_auth_methods_supported: ['client_secret_basic', 'client_secret_post', 'private_key_jwt'],
        token_endpoint_auth_signing_alg_values_supported: ['ES256'],
        client_id_metadata_document_supported: true
      });
    }
    if (url.pathname === '/mcp') {
      const token = req.headers.authorization?.replace(/^Bearer /, '');
      if (!token) {
        res.setHeader('www-authenticate', `Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource/mcp"`);
        return json(res, 401, { error: 'unauthorized' });
      }
      await jwtVerify(token, issuerKey.publicKey, { issuer: `${origin}/as`, audience: `${origin}/mcp`, algorithms: ['ES256'] });
      counts.resource++;
      return json(res, 200, { jsonrpc: '2.0', id: 1, result: { resultType: 'ping' } });
    }
    const leg = url.pathname === '/idp/token' ? 'idp' : url.pathname === '/as/token' ? 'as' : undefined;
    if (!leg || req.method !== 'POST') return json(res, 404, { error: 'not_found' });
    let body = '';
    for await (const chunk of req) {
      body += chunk;
      if (body.length > 65536) throw new Error('request too large');
    }
    const params = new URLSearchParams(body);
    await authenticate(req, params, leg);
    if (leg === 'idp') {
      counts.idp++;
      if (params.get('grant_type') !== 'urn:ietf:params:oauth:grant-type:token-exchange') throw new Error('wrong exchange grant');
      const type = params.get('subject_token_type');
      if (type === 'urn:ietf:params:oauth:token-type:saml2') {
        if (params.get('subject_token') !== 'fixture-saml' || params.get('requested_token_type') !== 'urn:ietf:params:oauth:token-type:refresh_token' || params.get('scope') !== 'openid offline_access') throw new Error('wrong SAML transition');
        return json(res, 200, { access_token: 'fixture-refresh', token_type: 'N_A', issued_token_type: 'urn:ietf:params:oauth:token-type:refresh_token' });
      }
      const expected = type === 'urn:ietf:params:oauth:token-type:id_token' ? 'fixture-id-token' : type === 'urn:ietf:params:oauth:token-type:refresh_token' ? 'fixture-refresh' : undefined;
      if (!expected || params.get('subject_token') !== expected || params.get('audience') !== `${origin}/as` || params.get('resource') !== `${origin}/mcp` || params.get('requested_token_type') !== 'urn:ietf:params:oauth:token-type:id-jag') throw new Error('wrong exchange target');
      const token = await sign({ sub: 'fixture-user', client_id: cimd?.client_id ?? 'as-client', resource: `${origin}/mcp` }, idp.privateKey, 'oauth-id-jag+jwt', `${origin}/as`, `${origin}/idp`);
      return json(res, 200, { access_token: token, issued_token_type: 'urn:ietf:params:oauth:token-type:id-jag', token_type: 'N_A', expires_in: 300 });
    }
    counts.as++;
    if (params.get('grant_type') === 'urn:ietf:params:oauth:grant-type:jwt-bearer') {
      const { payload, protectedHeader } = await jwtVerify(params.get('assertion'), idp.publicKey, { issuer: `${origin}/idp`, audience: `${origin}/as`, algorithms: ['ES256'] });
      if (protectedHeader.typ !== 'oauth-id-jag+jwt' || payload.client_id !== (cimd?.client_id ?? 'as-client') || payload.resource !== `${origin}/mcp`) throw new Error('wrong ID-JAG binding');
    } else if (params.get('grant_type') !== 'client_credentials') throw new Error('wrong grant');
    if (params.get('resource') !== `${origin}/mcp`) throw new Error('wrong resource');
    const token = await sign({ scope: 'mcp:read' }, issuerKey.privateKey, 'at+jwt', `${origin}/mcp`, `${origin}/as`);
    return json(res, 200, { access_token: token, token_type: 'Bearer', expires_in: 300 });
  } catch {
    return json(res, 400, { error: 'invalid_request' });
  }
});

await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
origin = `http://127.0.0.1:${server.address().port}`;
console.log(JSON.stringify({ origin, privateKey: await exportJWK(clients.as.privateKey), idpPrivateKey: await exportJWK(clients.idp.privateKey) }));
const input = readline.createInterface({ input: process.stdin });
input.on('line', line => {
  if (line.startsWith('{')) {
    const command = JSON.parse(line);
    // Explicit test-only mapping: logical HTTPS client/JWKS identities map to
    // loopback HTTP peers. This does not qualify production DNS/TLS policy.
    if (command.cimd) {
      cimd = command.cimd;
      console.log(JSON.stringify({ configured: true }));
    }
  }
  if (line === 'counts') console.log(JSON.stringify(counts));
  if (line === 'close') { input.close(); server.close(); }
});
input.on('close', () => server.close());
