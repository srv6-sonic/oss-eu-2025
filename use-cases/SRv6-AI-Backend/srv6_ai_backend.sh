#!/bin/bash

# === TOPOLOGY DEFINITION ===
USE_CASE="SRv6-AI-Backend"
UC_ABBR="A1"
SPINES=(01T1 02T1)
LEAVES=(01T0 02T0)
HOSTS=(NIC-A NIC-B)
SONIC_IMAGE="cscarpit/srv6-sonic-vs:latest"
SONIC_SERVERS=2

set -e

# === GLOBAL STATE ===
declare -A IFIDX
ETHNAME=""
declare -A VETH_COUNTER

# === UTILS ===
resource_name() {
    local name="$1"
    echo "${UC_ABBR}-$name"
}

get_next_eth() {
    local node="$1"
    IFIDX[$node]=$(( ${IFIDX[$node]:-0} + 1 ))
    ETHNAME="eth${IFIDX[$node]}"
}

get_veth_names() {
    VETH_COUNTER[$UC_ABBR]=$(( ${VETH_COUNTER[$UC_ABBR]:-0} + 1 ))
    local idx=$(printf "%03d" "${VETH_COUNTER[$UC_ABBR]}")
    echo "${UC_ABBR}v$idx" "${UC_ABBR}p$idx"
}

create_sonic_ns_container() {
    cname=$1
    echo "[INFO] Creating SONiC namespace container: $cname"
    docker rm -f $cname > /dev/null 2>&1 || true
    docker run -d --name $cname --network none --privileged --entrypoint sleep $SONIC_IMAGE infinity > /dev/null \
        || { echo "[ERROR] Failed to start namespace container $cname"; exit 1; }
}

remove_sonic_vs_container() {
    cname=$1
    echo "[INFO] Removing SONiC VS container: $cname"
    docker rm -f vs-$cname > /dev/null 2>&1 || true
    docker rm -f $cname > /dev/null 2>&1 || true
}

create_host_ns() {
    ns=$1
    echo "[INFO] Creating host namespace: $ns"
    ip netns del $ns > /dev/null 2>&1 || true
    ip netns add $ns > /dev/null \
        || { echo "[ERROR] Failed to create namespace $ns"; exit 1; }
    ip netns exec $ns ip link set lo up > /dev/null \
        || { echo "[ERROR] Failed to bring up loopback in namespace $ns"; exit 1; }
}

delete_host_ns() {
    ns=$1
    echo "[INFO] Deleting host namespace: $ns"
    ip netns del $ns > /dev/null 2>&1 || true
}

create_veth_between_vs_eth() {
    vs1=$1
    vs2=$2
    eth1=$3
    eth2=$4

    local tmp1 tmp2
    read tmp1 tmp2 < <(get_veth_names)

    pid1=$(docker inspect -f '{{.State.Pid}}' $vs1)
    pid2=$(docker inspect -f '{{.State.Pid}}' $vs2)

    echo "[INFO] Creating veth pair: $vs1:$eth1 <-> $vs2:$eth2 (tmp ifs: $tmp1 <-> $tmp2)"

    ip link add $tmp1 type veth peer name $tmp2 > /dev/null \
        || { echo "[ERROR] Failed to create veth $tmp1/$tmp2"; exit 1; }
    ip link set $tmp1 netns $pid1 > /dev/null \
        || { echo "[ERROR] Failed to move $tmp1 to $vs1"; exit 1; }
    ip link set $tmp2 netns $pid2 > /dev/null \
        || { echo "[ERROR] Failed to move $tmp2 to $vs2"; exit 1; }

    nsenter -t $pid1 -n ip link show $eth1 > /dev/null 2>&1 && {
        echo "[DEBUG] $vs1: Removing existing $eth1"
        nsenter -t $pid1 -n ip link del $eth1 > /dev/null 2>&1
    }
    nsenter -t $pid1 -n ip link set $tmp1 down > /dev/null 2>&1
    nsenter -t $pid1 -n ip link set $tmp1 name $eth1 > /dev/null 2>&1
    nsenter -t $pid1 -n ip link set $eth1 up > /dev/null 2>&1
    echo "[DEBUG] $vs1: $tmp1 -> $eth1"

    nsenter -t $pid2 -n ip link show $eth2 > /dev/null 2>&1 && {
        echo "[DEBUG] $vs2: Removing existing $eth2"
        nsenter -t $pid2 -n ip link del $eth2 > /dev/null 2>&1
    }
    nsenter -t $pid2 -n ip link set $tmp2 down > /dev/null 2>&1
    nsenter -t $pid2 -n ip link set $tmp2 name $eth2 > /dev/null 2>&1
    nsenter -t $pid2 -n ip link set $eth2 up > /dev/null 2>&1
    echo "[DEBUG] $vs2: $tmp2 -> $eth2"
}

create_veth_vs_to_ns_eth() {
    vs=$1
    ns=$2
    eth_vs=$3
    eth_ns=$4

    local tmp_vs tmp_ns
    read tmp_vs tmp_ns < <(get_veth_names)

    pid_vs=$(docker inspect -f '{{.State.Pid}}' $vs)

    echo "[INFO] Creating veth pair: $vs:$eth_vs <-> $ns:$eth_ns (tmp ifs: $tmp_vs <-> $tmp_ns)"

    ip link add $tmp_vs type veth peer name $tmp_ns > /dev/null \
        || { echo "[ERROR] Failed to create veth $tmp_vs/$tmp_ns"; exit 1; }
    ip link set $tmp_vs netns $pid_vs > /dev/null \
        || { echo "[ERROR] Failed to move $tmp_vs to $vs"; exit 1; }
    ip link set $tmp_ns netns $ns > /dev/null \
        || { echo "[ERROR] Failed to move $tmp_ns to $ns"; exit 1; }

    nsenter -t $pid_vs -n ip link show $eth_vs > /dev/null 2>&1 && {
        echo "[DEBUG] $vs: Removing existing $eth_vs"
        nsenter -t $pid_vs -n ip link del $eth_vs > /dev/null 2>&1
    }
    nsenter -t $pid_vs -n ip link set $tmp_vs down > /dev/null 2>&1
    nsenter -t $pid_vs -n ip link set $tmp_vs name $eth_vs > /dev/null 2>&1
    nsenter -t $pid_vs -n ip link set $eth_vs up > /dev/null 2>&1
    echo "[DEBUG] $vs: $tmp_vs -> $eth_vs"

    ip netns exec $ns ip link show $eth_ns > /dev/null 2>&1 && {
        echo "[DEBUG] $ns: Removing existing $eth_ns"
        ip netns exec $ns ip link del $eth_ns > /dev/null 2>&1
    }
    ip netns exec $ns ip link set $tmp_ns down > /dev/null 2>&1
    ip netns exec $ns ip link set $tmp_ns name $eth_ns > /dev/null 2>&1
    ip netns exec $ns ip link set $eth_ns up > /dev/null 2>&1
    echo "[DEBUG] $ns: $tmp_ns -> $eth_ns"
}

create_sonic_servers() {
    swname=$1
    servers=${2:-2}

    pid=$(docker inspect --format '{{.State.Pid}}' $swname)

    echo "[INFO] Creating $servers server namespaces for $swname"
    for srv in $(seq 0 $((servers-1))); do
        SRV="${swname}-s$srv"
        NSS="ip netns exec $SRV"

        ip netns add $SRV
        $NSS ip addr add 127.0.0.1/8 dev lo
        $NSS ip addr add ::1/128 dev lo
        $NSS ip link set dev lo up

        IF="eth$((srv+1))"
        ip link add ${SRV}eth0 type veth peer name $swname-$IF
        ip link set ${SRV}eth0 netns $SRV
        ip link set $swname-$IF netns ${pid}
        nsenter -t $pid -n ip link set dev $swname-$IF name $IF

        echo "Bring ${SRV}eth0 up"
        $NSS ip link set dev ${SRV}eth0 name eth0
        $NSS ip link set dev eth0 up

        echo "Bring $IF up in the virtual switch docker"
        nsenter -t $pid -n ip link set dev $IF up
    done
}

destroy_topology() {
    echo "[INFO] Destroying topology..."

    for s in "${SPINES[@]}"; do remove_sonic_vs_container "$(resource_name $s)"; done
    for l in "${LEAVES[@]}"; do remove_sonic_vs_container "$(resource_name $l)"; done
    for h in "${HOSTS[@]}"; do delete_host_ns "$(resource_name $h)"; done

    for ns in $(ip netns list | awk '{print $1}' | grep "^${UC_ABBR}-"); do
        echo "[DEBUG] Deleting orphan namespace: $ns"
        ip netns del "$ns" > /dev/null 2>&1 || true
    done
    ip link | grep -oE "(${UC_ABBR}[vp][0-9]{3})" | while read iface; do
        echo "[DEBUG] Deleting veth: $iface"
        ip link del $iface > /dev/null 2>&1 || true
    done
    # Remove any server netns (B2-<node>-sX)
    ip netns list | awk '{print $1}' | grep "^${UC_ABBR}-.*-s[0-9]\+$" | while read ns; do
        echo "[DEBUG] Deleting server namespace: $ns"
        ip netns del "$ns" > /dev/null 2>&1 || true
    done

    echo "[INFO] Topology destroyed."
}

deploy_topology() {
    echo "[INFO] Pulling SONiC Docker image: $SONIC_IMAGE"
    docker pull $SONIC_IMAGE
    destroy_topology

    CONFIG_ROOT="config"
    VETH_COUNTER[$UC_ABBR]=0

    echo "[INFO] Creating SONiC namespace containers..."
    for s in "${SPINES[@]}"; do create_sonic_ns_container "$(resource_name $s)"; done
    for l in "${LEAVES[@]}"; do create_sonic_ns_container "$(resource_name $l)"; done

    echo "[INFO] Creating host namespaces..."
    for h in "${HOSTS[@]}"; do create_host_ns "$(resource_name $h)"; done

    echo "[INFO] Running SONIC_SCRIPT for all SONiC VS containers (servers)..."
    for cname in "${SPINES[@]}" "${LEAVES[@]}"; do
        short_cname="$(resource_name $cname)"
        create_sonic_servers "$short_cname" "$SONIC_SERVERS"
    done

    echo "[INFO] Connecting leaves to hosts (1-to-1)..."
    for idx in "${!HOSTS[@]}"; do
        host=${HOSTS[$idx]}
        [ $idx -ge ${#LEAVES[@]} ] && break
        leaf=${LEAVES[$idx]}
        leaf_r=$(resource_name "$leaf")
        host_r=$(resource_name "$host")
        get_next_eth "$leaf_r"; eth_leaf=$ETHNAME
        get_next_eth "$host_r"; eth_host=$ETHNAME
        create_veth_vs_to_ns_eth "$leaf_r" "$host_r" "$eth_leaf" "$eth_host"
    done

    echo "[INFO] Connecting leaves to spines..."
    for leaf in "${LEAVES[@]}"; do
        for spine in "${SPINES[@]}"; do
            leaf_r=$(resource_name "$leaf")
            spine_r=$(resource_name "$spine")
            get_next_eth "$leaf_r"; eth_leaf=$ETHNAME
            get_next_eth "$spine_r"; eth_spine=$ETHNAME
            create_veth_between_vs_eth "$leaf_r" "$spine_r" "$eth_leaf" "$eth_spine"
        done
    done

    # Finalize SONiC VS containers
    for cname in "${SPINES[@]}" "${LEAVES[@]}"; do
        rname=$(resource_name "$cname")
        echo "[INFO] Finalizing SONiC VS container: $rname"
        mkdir -p "$PWD/$CONFIG_ROOT/$cname"
        if [ ! -f "$PWD/$CONFIG_ROOT/$cname/config_db.json" ]; then
            echo '{}' > "$PWD/$CONFIG_ROOT/$cname/config_db.json"
        fi

        docker run --privileged \
            -v /var/run/redis-vs/$rname:/var/run/redis \
            --network container:$rname \
            -d --name vs-$rname \
            $SONIC_IMAGE > /dev/null \
            || { echo "[ERROR] Failed to start SONiC VS container vs-$rname"; exit 1; }

        docker cp "$PWD/$CONFIG_ROOT/$cname/config_db.json" vs-$rname:/etc/sonic/config_db.json > /dev/null \
            || { echo "[ERROR] Failed to copy config_db.json into vs-$rname"; exit 1; }

        if [ -f "$PWD/$CONFIG_ROOT/$cname/port_config.ini" ]; then
            echo "[INFO] Copying port_config.ini into $rname"
        fi
        if [ -f "$PWD/$CONFIG_ROOT/$cname/lanemap.ini" ]; then
            echo "[INFO] Copying lanemap.ini into $rname"
        fi
        if [ -f "$PWD/$CONFIG_ROOT/$cname/frr.conf" ]; then
            echo "[INFO] Copying frr.conf into $rname"
            docker cp "$PWD/$CONFIG_ROOT/$cname/frr.conf" vs-$rname:/etc/frr/frr.conf > /dev/null \
                || { echo "[ERROR] Failed to copy frr.conf into vs-$rname"; exit 1; }
        fi

        echo "export PS1='root@$cname:\w# '" | docker exec -i vs-$rname tee -a /root/.bashrc > /dev/null

        real_hostname=$(docker exec vs-$rname hostname)
        docker exec vs-$rname bash -c "grep -q '$real_hostname' /etc/hosts || echo '127.0.1.1 $real_hostname' >> /etc/hosts" > /dev/null
    done

    for host in "${HOSTS[@]}"; do
        rhost=$(resource_name "$host")
        script="$PWD/$CONFIG_ROOT/$host/start.sh"
        if [ -f "$script" ]; then
            echo "[INFO] Executing $script in namespace $rhost"
            chmod +x "$script"
            ip netns exec "$rhost" "$script" > /dev/null \
                || { echo "[ERROR] Failed to execute $script in namespace $rhost"; exit 1; }
        else
            echo "[INFO] $script not found, skipping."
        fi
    done

    echo "[INFO] Topology with SONiC VS switches created."
}

shell_node() {
    node=$1
    rname=$(resource_name "$node")
    if [[ " ${SPINES[*]} " == *" $node "* ]] || [[ " ${LEAVES[*]} " == *" $node "* ]]; then
        docker exec -it vs-$rname bash
    elif [[ " ${HOSTS[*]} " == *" $node "* ]]; then
        ip netns exec $rname env PS1="root@$node:/# " bash --norc --noprofile
    else
        echo "Node $node not found. Valid names: ${SPINES[*]} ${LEAVES[*]} ${HOSTS[*]}"
        exit 1
    fi
}

case "$1" in
    deploy)
        deploy_topology
        ;;
    destroy)
        destroy_topology
        ;;
    shell)
        if [ -z "$2" ]; then
            echo "Usage: $0 shell <node_name>"
            exit 1
        fi
        shell_node "$2"
        ;;
    *)
        echo "Usage: $0 deploy | destroy | shell <node_name>"
        ;;
esac
