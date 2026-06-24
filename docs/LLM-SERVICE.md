# Burble LLM Service

<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

## Overview

Burble's LLM service provides real-time language model query processing with support for both single responses and streaming outputs. The service uses **QUIC (UDP) + TLS 1.3** as the primary transport with **TCP + TLS 1.3** as fallback.

## Protocol Specification

### Transport Layer

| Protocol | Port | Encryption | Primary/Fallback |
|----------|------|------------|------------------|
| QUIC (UDP) | 8503 | TLS 1.3 | ✅ Primary |
| TCP | 8085 | TLS 1.3 | ⚠️ Fallback |

### IPv6 Support

- **IPv6 preferred** - Service binds to `::` (IPv6) first, falls back to `0.0.0.0` (IPv4)
- **Dual-stack** - Both IPv4 and IPv6 supported simultaneously
- **Happy Eyeballs** - Automatic fallback if IPv6 unavailable

### ALPN Protocol

The service uses **Application-Layer Protocol Negotiation** with the following protocols:
- `llm-burble` - Primary protocol
- `llm-burble-v1` - Versioned protocol

## Message Framing

All messages use a simple text-based frame format:

```
LLM\r\n
TYPE\r\n
header1: value1\r\n
hader2: value2\r\n
\r\n
[BODY if applicable]
```

### Frame Structure

```
Field | Description | Required |
|------|-------------|----------|
| `LLM\r\n` | Frame header | ✅ Yes |
| `TYPE\r\n` | Message type | ✅ Yes |
| Headers | Key:value pairs | ❌ No |
| `\r\n\r\n` | Frame footer | ✅ Yes |
| Body | Message content | ❌ Depends on type |
```

## Authentication

### AUTH Frame (Required First Message)

```
LLM\r\n
auth\r\n
token: YOUR_JWT_TOKEN\r\n
\r\n
```

**Response:**
- Success: `200 OK` frame
- Failure: `401 Unauthorized` frame

## Message Types

### 1. QUERY (Single Response)

**Request:**
```
LLM\r\n
QUERY\r\n
id: msg-123\r\n
prompt: Tell me about quantum computing\r\n
\r\n
```

**Response:**
```
LLM\r\n
RESPONSE\r\n
id: msg-123\r\n
response: Quantum computing uses quantum bits...\r\n
\r\n
```

### 2. STREAM_START (Streaming Response)

**Request:**
```
LLM\r\n
STREAM_START\r\n
id: stream-456\r\n
prompt: Write a poem about the ocean\r\n
\r\n
```

**Stream Chunks:**
```
LLM\r\n
STREAM_CHUNK\r\n
id: stream-456\r\n
chunk: In the deep blue sea,\r\n
\r\n
```

**Stream End:**
```
LLM\r\n
STREAM_END\r\n
id: stream-456\r\n
\r\n
```

### 3. ERROR

```
LLM\r\n
ERROR\r\n
id: msg-123\r\n
code: 400\r\n
message: Invalid prompt format\r\n
\r\n
```

## Security

### TLS Configuration

- **TLS 1.3 only** - No legacy versions
- **Modern cipher suites** - AES-256-GCM, ChaCha20-Poly1305
- **Perfect Forward Secrecy** - Ephemeral keys
- **Certificate pinning** - Optional client-side

### Authentication

- **JWT tokens** required for all connections
- **Token verification** via Burble.Auth
- **Rate limiting** per IP address

## Deployment

### Environment Variables

```bash
# Primary QUIC port (default: 8503)
export LLM_PORT=8503

# Fallback TCP port (default: 8085)  
export LLM_FALLBACK_PORT=8085

# Disable LLM service (default: enabled)
export LLM_ENABLED=false
```

### Certificate Setup

Place certificates in `server/priv/ssl/`:
```bash
server/priv/ssl/
├── cert.pem    # Certificate
├── key.pem     # Private key
└── cacert.pem  # CA certificate (optional)
```

### Generate Self-Signed Cert (Development)

```bash
openssl req -x509 -newkey rsa:4096 -keyout priv/ssl/key.pem \
  -out priv/ssl/cert.pem -days 365 -nodes \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1"
```

## Client Implementation

### JavaScript Example

```javascript
// Connect to LLM service
async function connectToLLM() {
  const token = await getAuthToken();
  
  try {
    // Try QUIC first
    const quic = await Deno.connect({
      hostname: "localhost",
      port: 8503,
      transport: "quic",
      alpnProtocols: ["llm-burble"]
    });
    
    // Send AUTH frame
    await sendFrame(quic, {
      type: "AUTH",
      token: token
    });
    
    return quic;
  } catch (e) {
    // Fall back to TCP
    const tcp = await Deno.connectTls({
      hostname: "localhost",
      port: 8085,
      alpnProtocols: ["llm-burble"]
    });
    
    await sendFrame(tcp, {
      type: "AUTH",
      token: token
    });
    
    return tcp;
  }
}

function sendFrame(conn, data) {
  const frame = `LLM\r\n${data.type}\r\n` +
                Object.entries(data)
                  .filter(([k]) => k !== 'type')
                  .map(([k, v]) => `${k}: ${v}`)
                  .join('\r\n') +
                '\r\n\r\n';
  
  await conn.write(new TextEncoder().encode(frame));
}
```

### Elixir Example

```elixir
# Connect and query LLM
{:ok, socket} = :gen_tcp.connect(
  'localhost',
  8503,
  [:binary, packet: :raw, active: false]
)

# Send AUTH frame
auth_frame = "LLM\r\nAUTH\r\ntoken: #{get_token()}\r\n\r\n"
:gen_tcp.send(socket, auth_frame)

# Send QUERY frame
query_frame = "LLM\r\nQUERY\r\nid: query-1\r\nprompt: Hello\r\n\r\n"
:gen_tcp.send(socket, query_frame)

# Read response
{:ok, response} = :gen_tcp.recv(socket, 0, 5000)
```

## Cloudflare Setup

### DNS Records

```
Type    | Name          | Content                     | TTL  | Proxy |
|--------|---------------|-----------------------------|------|-------|
| A      | burble.nexus  | [Your Server IPv4]          | Auto | ✅ Proxy |
| AAAA   | burble.nexus  | [Your Server IPv6]          | Auto | ✅ Proxy |
| CNAME  | llm           | burble.nexus                | Auto | ❌ DNS Only |
| CNAME  | llm-fallback  | burble.nexus                | Auto | ❌ DNS Only |
```

### Firewall Rules

```
# Allow LLM ports
IP: 8503/udp
IP: 8085/tcp

# Rate limiting
Action: Block
IP: Any
Path: /llm*
Rate: > 100 requests per minute
```

### SSL/TLS Settings

```
Mode: Full (Strict)
Minimum TLS Version: 1.3
Cipher Suites: Modern compatibility
Always Use HTTPS: ✅ On
HSTS: ✅ Enabled (max-age: 1 year)
```

## Censorship Resistance

### Shadowsocks Equivalent

The QUIC transport provides some censorship resistance features:

1. **UDP-based** - Harder to block than TCP
2. **TLS 1.3 encryption** - Traffic appears as normal HTTPS
3. **ALPN obfuscation** - Can mimic other protocols
4. **Port hopping** - Can switch between 8503/8085

### Additional Measures

1. **Domain Fronting** (via Cloudflare):
   ```elixir
   config :burble, :llm,
     cloudflare_front: "https://popular-site.com"
   ```

2. **Traffic Shaping**:
   ```elixir
   config :burble, :llm,
     traffic_shape: :web  # Mimic web traffic patterns
   ```

3. **Fallback Domains**:
   ```elixir
   config :burble, :llm,
     fallback_domains: [
       "llm1.burble.nexus",
       "llm2.burble.nexus"
     ]
   ```

## Monitoring

### Metrics

```elixir
# In telemetry.ex
:telemetry.execute([:burble, :llm, :query], %{
  duration: duration,
  tokens: token_count,
  protocol: protocol,
  ip_version: ip_version
}, %{})
```

### Health Check

```bash
# Check QUIC port
nc -zv -u localhost 8503

# Check TCP fallback
openssl s_client -connect localhost:8085 -alpn llm-burble
```

## Troubleshooting

### Common Issues

1. **QUIC unavailable**:
   - Check `:quicer` dependency is available
   - Fall back to TCP mode automatically

2. **TLS handshake failure**:
   - Verify certificate paths
   - Check certificate permissions
   - Ensure TLS 1.3 is supported

3. **Connection refused**:
   - Check firewall rules
   - Verify port is listening
   - Test with `nc -zv localhost 8503`

4. **IPv6 issues**:
   - Check IPv6 is enabled on server
   - Verify AAAA DNS records
   - Test with `ping6 burble.nexus`

## Future Enhancements

- **WebTransport** support
- **HTTP/3** compatibility
- **Multi-path QUIC** for redundancy
- **Pluggable LLM backends**
- **Edge caching** for common queries

## References

- [QUIC Protocol](https://datatracker.ietf.org/doc/html/rfc9000)
- [TLS 1.3](https://datatracker.ietf.org/doc/html/rfc8446)
- [ALPN](https://datatracker.ietf.org/doc/html/rfc7301)
- [IPv6](https://datatracker.ietf.org/doc/html/rfc8200)
