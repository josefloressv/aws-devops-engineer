# {{SCENARIO_SLUG}}

Domain: `{{DOMAIN_FOLDER}}`
Stack name: `{{STACK_NAME}}`

## Objective

<1-2 lines: the exact behavior/output that distinguishes the exam answer options.>

## Resources Created

<keep this list minimal — only what's needed to produce the evidence below.>

## Evidence Commands

<exact AWS CLI commands run after deploy to mutate state and capture the output that
distinguishes the competing answers. Capture command + raw output. Do not state which option
is correct — that's for Jose to decide from the evidence.>

## Teardown

```bash
make destroy LAB={{DOMAIN_FOLDER}}/{{SCENARIO_SLUG}}
```
