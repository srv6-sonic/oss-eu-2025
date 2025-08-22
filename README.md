# SONiC Labs

## Supported Use Cases

- SRv6 AI Backend
- SRv6 L3VPN

Each use case has its own directory, configuration, and deployment script.

## Usage

### Deploy a Use Case

Navigate to the use case directory and run:

```sh
cd use-cases/SRv6-AI-Backend
sudo ./srv6_ai_backend.sh deploy
```

or

```sh
cd use-cases/SRv6-L3VPN
sudo ./srv6_l3vpn.sh deploy
```

### Destroy the topology

Navigate to the use case directory and run:

```sh
cd use-cases/SRv6-AI-Backend
sudo ./srv6_ai_backend.sh destroy
```

or

```sh
cd use-cases/SRv6-L3VPN
sudo ./srv6_l3vpn.sh destroy
```

### Access a Node Shell

To access a shell on a node (switch or host):

```
cd use-cases/SRv6-AI-Backend
sudo ./srv6_ai_backend.sh shell S11
sudo ./srv6_ai_backend.sh shell H100
```

or

```
cd use-cases/SRv6-L3VPN
sudo ./srv6_l3vpn.sh shell S11
sudo ./srv6_l3vpn.sh shell H100
```
