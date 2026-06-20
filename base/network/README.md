# base/network

Minimal 2-AZ VPC: 2 public subnets, 2 private subnets, an Internet Gateway, and route tables.
NAT Gateway is **off by default** (`EnableNatGateway=false`) to keep cost at ~$0 — most labs
that need outbound internet from a private subnet can instead use a public subnet with a
public IP, or VPC endpoints.

## Deploy

```bash
make base-plan NAME=network
make base-deploy NAME=network
```

To enable a NAT Gateway for a specific study session (cost: NAT Gateway hourly rate + data
processing, non-trivial — `scripts/base-plan.sh` will print a cost warning), call the script
directly with a parameter override (the `Makefile` target doesn't pass through extra args):

```bash
scripts/base-plan.sh network EnableNatGateway=true
scripts/base-deploy.sh network
```

## Outputs (exported for scenario stacks via Fn::ImportValue)

- `dop-lab-base-network-VpcId`
- `dop-lab-base-network-PublicSubnet1Id` / `PublicSubnet2Id`
- `dop-lab-base-network-PrivateSubnet1Id` / `PrivateSubnet2Id`
- `dop-lab-base-network-PublicRouteTableId` / `PrivateRouteTableId`

## Teardown

```bash
make base-destroy-all
```

Run this only after all scenario stacks referencing these exports are destroyed
(`make destroy-all` first) — CloudFormation refuses to delete a stack whose export is still
imported elsewhere.
