# AWS credit — applicable services

Services covered by the **AWS Community Builders 2026 Renewal Credit** ($500, redeemed
2026-08-01 into the organization's management account, expires **2027-11-30**).

The list is copied verbatim from the Billing console's Credits page ("Applicable products").
It is the authoritative answer to "will this lab burn real money?" — anything **not** on this
list bills to the actual payment method.

## What this means for this repo

Every resource type in `COST_FLAG_PATTERN` (`scripts/lib.sh`) is covered **except one**:

| Cost-flagged type | Applicable product entry | Covered |
|---|---|---|
| `AWS::EC2::NatGateway` | Amazon Virtual Private Cloud | yes |
| `AWS::RDS::` | Amazon Relational Database Service | yes |
| `AWS::EKS::Cluster` | Amazon Elastic Container Service for Kubernetes | yes |
| `AWS::ElastiCache::` | Amazon ElastiCache | yes |
| `AWS::Redshift::` | Amazon Redshift | yes |
| `AWS::OpenSearchService::` / `AWS::Elasticsearch::` | Amazon OpenSearch Service | yes |
| `AWS::MSK::` | Amazon Managed Streaming for Apache Kafka | yes |
| `AWS::GlobalAccelerator::` | AWS Global Accelerator | yes |
| `AWS::DirectConnect::` | AWS Direct Connect | yes |
| **`AWS::EC2::TransitGateway`** | **absent** | **NO** |

**AWS Transit Gateway is the one cost-flagged type not covered** — the same gap that existed
under the previous credit. Its hourly attachment and data-processing charges hit the real
bill. Call this out explicitly before applying any template that creates one.

Core services used by every lab are all covered: Amazon Elastic Compute Cloud, AWS
CloudFormation, AWS Systems Manager, AmazonCloudWatch, AWS CloudTrail, AWS Config, Amazon
Simple Storage Service, AWS Lambda, Elastic Load Balancing, AWS Key Management Service, AWS
Secrets Manager, Amazon Virtual Private Cloud, AWS Data Transfer, and the full CodePipeline /
CodeBuild / CodeDeploy / CodeArtifact set.

Note that **AWS Marketplace purchases are not on the list**, which is normal for promotional
credits — avoid Marketplace AMIs in scenario templates.

## Full list (verbatim)

Alexa for Business
Alexa Top Sites
Alexa Web Information Service
Amazon API Gateway
Amazon AppFlow
Amazon Athena
Amazon Augmented AI
Amazon Bedrock
Amazon Bedrock AgentCore
Amazon Bedrock Service
Amazon Bio Discovery
Amazon Braket
Amazon Chime
Amazon Chime Business Calling a service sold by AMCS LLC
Amazon Chime Call Me
Amazon Chime Call Me a service sold by AMCS LLC
Amazon Chime Dial In a service sold by AMCS LLC
Amazon Chime Dialin
Amazon Chime Features
Amazon Chime Services
Amazon Chime Voice Connector a service sold by AMCS LLC
Amazon Cloud Directory
Amazon CloudFront
Amazon CloudSearch
Amazon CodeWhisperer
Amazon Cognito
Amazon Cognito Sync
Amazon Comprehend
Amazon Connect
Amazon Connect Customer Profiles
Amazon Connect Decisions
Amazon Connect Voice ID
Amazon DataZone
Amazon Deadline Cloud
Amazon Detective
Amazon DevOps Guru
Amazon DocumentDB (with MongoDB compatibility)
Amazon DynamoDB
Amazon EC2 Container Registry (ECR)
Amazon EC2 Optimize CPU License Included Third Party Fees
Amazon EKS Anywhere
Amazon EVS License Included Fees
Amazon Elastic Compute Cloud
Amazon Elastic Container Registry Public
Amazon Elastic Container Service
Amazon Elastic Container Service for Kubernetes
Amazon Elastic File System
Amazon Elastic Inference
Amazon Elastic MapReduce
Amazon Elastic Transcoder
Amazon ElastiCache
Amazon FinSpace
Amazon Forecast
Amazon Fraud Detector
Amazon FSx
Amazon GameLift
Amazon GameLift Streams
Amazon Glacier
Amazon GuardDuty
Amazon HealthLake
Amazon Honeycode
Amazon Inspector
Amazon Interactive Video Service
Amazon IVS Chat
Amazon Kendra
Amazon Keyspaces (for Apache Cassandra)
Amazon Kinesis
Amazon Kinesis Analytics
Amazon Kinesis Firehose
Amazon Kinesis Video Streams
Amazon Lex
Amazon Lightsail
Amazon Location Service
Amazon Lookout for Equipment
Amazon Lookout for Metrics
Amazon Lookout for Vision
Amazon Machine Learning
Amazon Macie
Amazon Managed Blockchain
Amazon Managed Grafana
Amazon Managed Service for Prometheus
Amazon Managed Streaming for Apache Kafka
Amazon Managed Workflows for Apache Airflow
Amazon MemoryDB
Amazon Mobile Analytics
Amazon Monitron
Amazon MQ
Amazon Neptune
Amazon Nimble Studio
Amazon Omics
Amazon OpenSearch Service
Amazon Personalize
Amazon Polly
Amazon Q
Amazon Quantum Ledger Database
Amazon Quick Suite
Amazon QuickSight
Amazon RDS Optimize CPU License Included Third Party Fees
Amazon Redshift
Amazon Rekognition
Amazon Relational Database Service
Amazon Route 53
Amazon S3 Glacier Deep Archive
Amazon SageMaker
Amazon Security Lake
Amazon Simple Email Service
Amazon Simple Notification Service
Amazon Simple Queue Service
Amazon Simple Storage Service
Amazon Simple Workflow Service
Amazon SimpleDB
Amazon Sumerian
Amazon Textract
Amazon Timestream
Amazon Transcribe
Amazon Translate
Amazon Verified Permissions
Amazon Virtual Private Cloud
Amazon WorkDocs
Amazon WorkLink
Amazon WorkSpaces
Amazon WorkSpaces Application Manager
Amazon WorkSpaces Applications
Amazon WorkSpaces Instances
Amazon WorkSpaces Thin Client
Amazon WorkSpaces Web
AmazonBedrockFoundationModels
AmazonCloudWatch
AmazonConnectCases
AmazonWorkMail
Aurora DSQL
AWS Amplify
AWS App Runner
AWS App Studio
AWS AppFabric
AWS Application Migration Service
AWS AppSync
AWS Audit Manager
AWS B2B Data Interchange
AWS Backup
AWS Billing Conductor
AWS Budgets
AWS Business Support+
AWS Certificate Manager
AWS Clean Rooms
AWS Cloud Map
AWS Cloud WAN
AWS CloudFormation
AWS CloudHSM
AWS CloudTrail
AWS CodeArtifact
AWS CodeCommit
AWS CodeDeploy
AWS CodePipeline
AWS Compute Optimizer
AWS Config
AWS Cost Explorer
AWS Data Exchange
AWS Data Pipeline
AWS Data Transfer
AWS Data Transfer Terminal
AWS Database Migration Service
AWS DataSync
AWS DeepRacer
AWS Device Farm
AWS Direct Connect
AWS Directory Service
AWS Elastic Disaster Recovery
AWS Elemental Inference
AWS Elemental MediaConnect
AWS Elemental MediaConvert
AWS Elemental MediaLive
AWS Elemental MediaPackage
AWS Elemental MediaStore
AWS Elemental MediaTailor
AWS End User Messaging
AWS End User Messaging Third Party Fees
AWS Entity Resolution
AWS Fault Injection Simulator
AWS Firewall Manager
AWS Glue
AWS Glue Elastic Views
AWS Greengrass
AWS Ground Station
AWS HealthImaging
AWS Identity and Access Management Access Analyzer
AWS Import/Export
AWS Import/Export Snowball
AWS Interconnect
AWS IoT
AWS IoT 1 Click
AWS IoT Analytics
AWS IoT Device Defender
AWS IoT Device Management
AWS IoT Events
AWS IoT FleetWise
AWS IoT SiteWise
AWS IoT things Graph
AWS IoT TwinMaker
AWS Key Management Service
AWS Lake Formation
AWS Lambda
AWS Mainframe Modernization
AWS Migration Hub Refactor Spaces
AWS Modular Data Center
AWS Network Firewall
AWS OpsWorks
AWS Outposts
AWS Parallel Computing Service
AWS Payment Cryptography
AWS Pricing Calculator
AWS Private 5G
AWS re:Post Private
AWS Resilience Hub
AWS RoboMaker
AWS Route 53 Application Recovery Controller
AWS RTB Fabric
AWS Secrets Manager
AWS Security Agent
AWS Security Hub
AWS Security Incident Response
AWS Service Catalog
AWS Shield
AWS SimSpace Weaver
AWS Snowball Extra Days
AWS Step Functions
AWS Storage Gateway
AWS Storage Gateway Deep Archive
AWS Support (Business)
AWS Support (Developer)
AWS Systems Manager
AWS Systems Manager for SAP
AWS Telco Network Builder
AWS Transfer Family
AWS Transform
AWS WAF
AWS Wickr
AWS X-Ray
AWSDevOpsAgent
CloudFront Flat-Rate Plans
CloudWatch Events
CodeBuild
CodeCatalyst
CodeGuru
Comprehend Medical
Contact Center Telecommunications (service sold by AMCS, LLC)
Contact Center Telecommunications Korea
Contact Center Telecommunications South Africa
Contact Lens for Amazon Connect
DynamoDB Accelerator (DAX)
Elastic Load Balancing
Elastic VMware Service
Health Agent
Kiro
NovaAct
Q in Connect
VMware Cloud on AWS
