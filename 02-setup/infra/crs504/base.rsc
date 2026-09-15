# CRS504-4XQ-IN-1 - permanent base configuration
#
# Management side only. The dataplane layout is a separate, swappable scenario:
# see scenarios/ and `make apply SCENARIO=<name>`.
#
# Intended for a factory-reset device, which comes up as 192.168.88.1 with a
# blank admin password. Running this against an already-configured switch is
# safe - every step is written to be idempotent - but it WILL drop your session
# at the point the address moves, so run it from `make base` rather than an
# interactive shell.
#
# The admin password is NOT set here; push it separately with `make set-password`.

/system identity set name=CRS504-4XQ-IN-1

# ether1 is the management port and must stay OUT of the dataplane bridge.
# The factory config bridges it together with all 16 QSFP sub-ports, which
# merges the 25G dataplane into the lab management LAN - VMs behind the
# compute PFs then reach the lab DHCP server and pick up leases there.
/interface bridge port remove [find where interface=ether1]

# Factory puts the address on qsfp28-1-1, which this setup uses as a dataplane
# access port. Move it to ether1.
/ip address remove [find where address~"^192.168.88."]
/ip address add address=192.168.88.2/24 interface=ether1 network=192.168.88.0 comment="lab mgmt"

# Default route via the lab router, which is the only uplink.
# Needed for /system package update, NTP and DNS.
/ip route remove [find where dst-address="0.0.0.0/0" && static]
/ip route add dst-address=0.0.0.0/0 gateway=192.168.88.1 comment="lab router"
/ip dns set servers=192.168.88.1

/system clock set time-zone-name=Europe/Warsaw
/system ntp client set enabled=yes servers=192.168.88.1
