# Domain 2 — Configuration Management & IaC (17% of exam)

Priority: **low** (met competencies on the last attempt — refresh only, don't deep-dive).

Typical topics: CloudFormation (StackSets, nested stacks, drift detection, custom resources),
OpsWorks, Systems Manager (State Manager, Patch Manager, Parameter Store), Elastic Beanstalk
config, AMI/golden image pipelines.

Each scenario lives in its own subfolder here:
`scenarios/domain-2-config-iac/<scenario-slug>/{template.yaml,params.json,README.md}`.
Scaffold a new one with `make new DOMAIN=domain-2-config-iac NAME=<scenario-slug>`.
