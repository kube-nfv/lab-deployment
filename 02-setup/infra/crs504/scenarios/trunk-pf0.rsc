# Scenario: trunk-pf0
#
# Tagged VLANs between the traffic generator and compute PF0, for networks that
# carry a VLAN to the wire. PF1 keeps its access VLAN:
#
#   VLAN 300, 301  trunk       traffic-gen port 0  <->  compute PF0
#   VLAN 200       downstream  compute PF1         ->   traffic-gen port 1
#
# Pure L2 - nothing here takes an IP, and the bridge is never a VLAN member.

# --- reset, so scenarios are swappable ---------------------------------------
/interface bridge set [find where name=bridge] vlan-filtering=no
/interface bridge vlan remove [find where bridge=bridge && !dynamic]
/interface bridge port set [find where bridge=bridge] pvid=1 frame-types=admit-all

# --- trunk ports -------------------------------------------------------------
/interface bridge port set [find where interface=qsfp28-1-1] \
    frame-types=admit-only-vlan-tagged comment="trex port 0 - trunk"
/interface bridge port set [find where interface=qsfp28-4-1] \
    frame-types=admit-only-vlan-tagged comment="compute PF0 - trunk"

# --- access ports ------------------------------------------------------------
/interface bridge port set [find where interface=qsfp28-4-4] pvid=200 \
    frame-types=admit-only-untagged-and-priority-tagged comment="compute PF1 - downstream"
/interface bridge port set [find where interface=qsfp28-1-4] pvid=200 \
    frame-types=admit-only-untagged-and-priority-tagged comment="trex port 1 - downstream"

# --- vlan membership ---------------------------------------------------------
/interface bridge vlan add bridge=bridge vlan-ids=300,301 \
    tagged=qsfp28-1-1,qsfp28-4-1 comment="trunk: trex p0 <-> PF0"
/interface bridge vlan add bridge=bridge vlan-ids=200 \
    untagged=qsfp28-4-4,qsfp28-1-4 comment="downstream: PF1 -> trex p1"

# --- enforce -----------------------------------------------------------------
# Uncabled sub-ports stay on pvid 1 and are isolated from both segments.
/interface bridge set [find where name=bridge] vlan-filtering=yes
