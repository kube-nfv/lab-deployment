# Matchbox Configuration

Static Matchbox configuration files for Talos PXE boot.

## Structure

```
matchbox/
├── profiles/           # Boot profiles with kernel parameters
│   └── talos-setup01.json
└── groups/            # Node-to-profile assignments
    └── talos-setup01.json
```

## Profile: talos-setup01

Boot configuration for Talos Linux nodes with required kernel parameters:
- `talos.platform=metal` - Talos platform identifier
- `slab_nomerge` - Required for Talos security
- `pti=on` - Page Table Isolation enabled
- Console parameters for debugging

## Group: talos-setup01-all

Matches all nodes (empty selector) and assigns them to the `talos-setup01` profile.

## Usage

These configs are automatically copied to `_out/matchbox-data` when running:

```bash
make matchbox-prepare
```

This target:
1. Creates the directory structure in `_out/matchbox-data`
2. Copies TLS certificates
3. Copies Talos kernel and initramfs assets
4. Copies profiles and groups from this directory

The Matchbox container then mounts `_out/matchbox-data` and serves the configurations.
