`sandbox.ts` is copied verbatim from modelcontextprotocol/ext-apps at
`cf599cc462406accc90ec3ca7879e3a22a9fc2a8`,
`examples/basic-host/src/sandbox.ts`. The adjacent LICENSE preserves the full
upstream licensing-transition notice and license texts.

This example serves it behind an additional exact Host-origin `frame-ancestors`
policy and restrictive HTTP CSP. Its local referrer restrictions are appropriate
for this loopback demonstration; do not silently broaden them for deployment.
