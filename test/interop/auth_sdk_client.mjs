// Exercise pinned SDK Auth helpers against Elixir HTTP endpoints. HTTPS logical
// identities map explicitly to a loopback test transport; no production network.
import readline from 'node:readline';
import { ClientCredentialsProvider, PrivateKeyJwtProvider, CrossAppAccessProvider,
  fetchToken, requestJwtAuthorizationGrant } from '@modelcontextprotocol/client';

const input = readline.createInterface({ input: process.stdin });
for await (const line of input) {
  const config = JSON.parse(line);
  const issuer = 'https://as-sdk.example';
  const resource = 'https://resource-sdk.example/mcp';
  const fetchFn = (url, init) => {
    const target = new URL(url);
    if (!['as-sdk.example', 'idp-sdk.example'].includes(target.hostname)) throw new Error('unexpected SDK target');
    return fetch(`${config.origin}${target.pathname}`, init);
  };
  let provider;
  if (config.mode === 'jwt') {
    provider = new PrivateKeyJwtProvider({ clientId: 'as-client', expectedIssuer: issuer, privateKey: config.key, algorithm: 'ES256' });
  } else if (config.mode === 'basic') {
    provider = new ClientCredentialsProvider({ clientId: 'as-client', expectedIssuer: issuer, clientSecret: 'fake-as-secret' });
  } else if (config.mode === 'enterprise') {
    provider = new CrossAppAccessProvider({ clientId: 'as-client', clientSecret: 'fake-as-secret', expectedIssuer: issuer,
      assertion: async () => (await requestJwtAuthorizationGrant({ tokenEndpoint: 'https://idp-sdk.example/idp/token', audience: issuer, resource,
        idToken: 'fixture-id-token', clientId: 'idp-client', clientSecret: 'fake-idp-secret', fetchFn })).jwtAuthGrant });
    provider.saveAuthorizationServerUrl(new URL(issuer));
    provider.saveResourceUrl(new URL(resource));
  } else throw new Error('unknown SDK test mode');
  const tokens = await fetchToken(provider, new URL(issuer), { metadata: { issuer, token_endpoint: `${issuer}/as/token`,
    token_endpoint_auth_methods_supported: ['private_key_jwt', 'client_secret_basic'], token_endpoint_auth_signing_alg_values_supported: ['ES256'] },
    resource: new URL(resource), scope: 'mcp:read', fetchFn });
  console.log(JSON.stringify(tokens));
  input.close();
  break;
}
