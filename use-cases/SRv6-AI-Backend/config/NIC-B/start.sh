#!/bin/bash
set -e

# Enable VRF strict mode
sysctl -w net.vrf.strict_mode=1

# Ensure loopback is up and assign IPv6 loopback address
ip link set lo up
ip -6 addr add fcbb:bbbb:B001::1/128 dev lo

# Assign IPv6 addresses to interfaces
ip -6 addr add 2001:db8:2:B001::B001/64 dev eth1

# Ensure interfaces are up
ip link set eth1 up

# Add default route
ip -6 route add default via 2001:db8:2:B001::2 dev eth1

# Set source address for SRv6 encapsulation
ip sr tunsrc set fcbb:bbbb:B001::1

# Steer IPv6 traffic over SID List
ip -6 route add fcbb:bbbb:A001::/48  encap seg6 mode encap.red segs fcbb:bbbb:2:1002:1:A001:fe09:: dev eth1

# Add uDT46 to decapsulate traffic
ip link add vrfdefault type vrf table main
ip link set vrfdefault up
ip -6 route add fcbb:bbbb:fe09::/48 encap seg6local action End.DT46 vrftable main dev vrfdefault
ip -6 route add fcbb:bbbb:B001:fe09::/64 encap seg6local action End.DT46 vrftable main dev vrfdefault
