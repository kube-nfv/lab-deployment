# Scenario: basic-l2
#
# Two isolated point-to-point L2 segments between the traffic generator and the
# compute node, as untagged access VLANs on the dataplane bridge:
#
#   VLAN 100  upstream    traffic-gen port 0  ->  compute PF0
#   VLAN 200  downstream  compute PF1         ->  traffic-gen port 1
#
# Pure L2 - nothing here takes an IP, and the bridge is never a VLAN member.
# Management lives on ether1, outside this bridge; see base.rsc.

# --- reset, so scenarios are swappable ---------------------------------------
/interface bridge set [find where name=bridge] vlan-filtering=no
/interface bridge vlan remove [find where bridge=bridge && !dynamic]
/interface bridge port set [find where bridge=bridge] pvid=1 frame-types=admit-all

# --- access ports ------------------------------------------------------------
/interface bridge port set [find where interface=qsfp28-1-1] pvid=100 \
    frame-types=admit-only-untagged-and-priority-tagged comment="trex port 0 - upstream"
/interface bridge port set [find where interface=qsfp28-4-1] pvid=100 \
    frame-types=admit-only-untagged-and-priority-tagged comment="compute PF0 - upstream"
/interface bridge port set [find where interface=qsfp28-4-4] pvid=200 \
    frame-types=admit-only-untagged-and-priority-tagged comment="compute PF1 - downstream"
/interface bridge port set [find where interface=qsfp28-1-4] pvid=200 \
    frame-types=admit-only-untagged-and-priority-tagged comment="trex port 1 - downstream"

# --- vlan membership ---------------------------------------------------------
/interface bridge vlan add bridge=bridge vlan-ids=100 \
    untagged=qsfp28-1-1,qsfp28-4-1 comment="upstream: trex p0 -> PF0"
/interface bridge vlan add bridge=bridge vlan-ids=200 \
    untagged=qsfp28-4-4,qsfp28-1-4 comment="downstream: PF1 -> trex p1"

# --- enforce -----------------------------------------------------------------
# Uncabled sub-ports stay on pvid 1 and are isolated from both segments.
/interface bridge set [find where name=bridge] vlan-filtering=yes
