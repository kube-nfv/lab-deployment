# 02-Setup Cloud-Edge Automatic Provisioning

This setup focuses on automatic provisioning of Talos edge nodes that join an existing cloud cluster with preinstalled OSM via network boot and Tailscale overlay networking.

## Architecture

```
                         Internet
                            |
              ┌─────────────┴─────────────┐
              |                           |
     ┌────────┴────────┐        ┌────────┴────────┐
     │   Cloud Side    │        │   Edge Side      │
     └────────┬────────┘        └────────┬────────┘
              |                           |
  ┌───────────┼───────────┐        ┌─────┴─────┐
  |           |           |        |           |
[Talos     [iPXE       [Machine  [DHCP      [Edge
 Cluster]   Server]     Config    Server]    Node]
             |          Server]    (iPXE      (PXE Boot)
             |           |        options)
             └─────┬─────┘
                   |
            [Tailscale Network]
                   |
         ┌─────────┴─────────┐
         |                   |
    [Cloud Nodes]       [Edge Node]
```

## How It Works

### Boot Flow

1. **Edge Node PXE Boot**:
   - Bare-metal (or QEMU) host boots with network boot option
   - Node discovers DHCP server in the local L2 network

2. **DHCP/iPXE Stage** (Edge):
   - DHCP server is preconfigured with iPXE endpoint pointing to the cloud-based iPXE server
   - DHCP response includes security parameters for authenticated communication

3. **iPXE/HTTP Stage** (Cloud):
   - Cloud-based iPXE server identifies the node and its target cluster
   - Serves Talos kernel and initramfs with Tailscale extension included
   - Sets `talos.config` kernel argument pointing to the cloud machine config endpoint

4. **Talos Configuration** (Cloud):
   - Edge node fetches machine config from the authenticated cloud endpoint
   - Machine config contains Tailscale configuration and cluster join parameters
   - Node joins the existing Talos cluster over the Tailscale overlay network

### Security

- All iPXE communication is encrypted and authenticated
- `talos.config` kernel argument endpoint requires authenticated requests
- Machine config is served over encrypted channels

## Edge Node Preconfiguration

The following infrastructure must be prepared at the edge site:

1. **Management Network**:
   - L2 network with connection to the Internet (may be NATed)

2. **DHCP Server**:
   - Must be in the same L2 domain as the edge node (or use DHCP Relay)
   - Preconfigured options for iPXE server endpoint pointing to the cloud
   - Security parameters for secure communication with the cloud iPXE server

## Cloud Preconfiguration

The following components must be available in the cloud:

1. **Existing Talos Cluster**:
   - Running cluster where the edge node will join
   - Tailscale extension installed and configured to join the same Tailscale network as the edge node

2. **iPXE Server**:
   - Internet-reachable endpoint
   - Correlates iPXE requests to the correct cluster
   - Prepares boot images and kernel arguments per node
   - Creates and serves machine config endpoint via `talos.config` kernel argument

3. **Machine Config Server**:
   - Serves Talos machine configuration referenced by the `talos.config` kernel argument
   - Includes Tailscale join configuration and cluster membership parameters

4. **Authentication & Encryption**:
   - All iPXE and Talos machine config communication must be authenticated and encrypted

## Prerequisites

- Existing Talos cluster (cloud side)
- Tailscale network and auth keys
- iPXE server with internet-reachable endpoint
- Machine config HTTP server
- TLS certificates for iPXE and machine config endpoints
- Edge site:
  - Bare-metal or QEMU host with PXE boot support
  - DHCP server with iPXE boot options configured

## Files

- `README.md` - Documentation
- `CONSIDERATIONS.md` - Implementation considerations, design decisions, and open questions
