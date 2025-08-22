#!/bin/bash
set -e

# Ensure loopback is up and assign IPv6 loopback address
ip link set lo up
ip -6 addr add fcbb:bbbb:A001::1/128 dev lo

# Assign IPv6 addresses to interfaces
ip -6 addr add 2001:db8:1:A001::A001/64 dev eth1

# Ensure interfaces are up
ip link set eth1 up

# Add default route
ip -6 route add default via 2001:db8:1:A001::1 dev eth1
