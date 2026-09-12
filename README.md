 # Tetris on AWS EKS

Infrastructure and Kubernetes manifests for running a containerized Tetris application on Amazon EKS.

The repository currently contains deployment infrastructure and manifests rather than the frontend/backend application source code. The applications packaged in the Docker images were vibe coded using Antigravity. The Kubernetes deployments expect these existing container images:

- `jatinthakur029/tetris-frontend:latest`
- `jatinthakur029/tetris-backend:latest`

## Architecture

```text
Internet
	|
	v
AWS VPC (10.0.0.0/16)
	|
	+-- Public subnet us-east-1a
	+-- Public subnet us-east-1b
			  |
			  v
		EKS cluster: tetris-cluster
			  |
			  +-- NGINX Ingress
			  |     +-- /     -> tetris-service:80 (frontend)
			  |     +-- /api  -> tetrisbac-service:3000 (backend)
			  |
			  +-- MongoDB StatefulSet
					  +-- 10 GiB gp2 persistent volume
```

### Components

- **Terraform** provisions the AWS VPC, internet gateway, public subnets, routes, security group, EKS control plane, and one managed node group.
- **Frontend** runs three replicas behind the `tetris-service` NodePort service on port `30100`.
- **Backend** runs three replicas behind the `tetrisbac-service` NodePort service on port `30101` and listens on port `3000`.
- **MongoDB** runs as a single-replica StatefulSet with a 10 GiB persistent volume and a headless service named `mongoservice`.
- **NGINX Ingress** routes `/` to the frontend and `/api` to the backend.
- **Argo CD** watches this repository and synchronizes the `kubernetes/` directory to the cluster.
- **GitHub Actions** runs Terraform validation, planning, and apply on pushes to `main`.

## Repository Layout

```text
.
├── .github/workflows/CI.yaml       # Terraform CI/CD workflow
├── containers/                     # Dockerfiles for the expected app images
├── kubernetes/
│   ├── argocd/application.yaml     # Argo CD Application
│   ├── backend/                    # Backend deployment, service, config, secret
│   ├── frontend/                   # Frontend deployment and service
│   ├── mongodb/                    # MongoDB StatefulSet and headless service
│   └── ingress.yaml                # NGINX ingress routes
└── terraform/                      # AWS and EKS infrastructure
```

## Prerequisites

Install or configure the following tools:

- AWS CLI with credentials allowed to create VPC, IAM, EKS, EC2, and related resources
- Terraform compatible with the AWS provider constraint `~> 5.0`
- `kubectl`
- An existing Kubernetes NGINX Ingress Controller
- Argo CD, if GitOps synchronization is required
- Docker and a container registry, if rebuilding the application images

The Terraform backend expects an existing S3 bucket named `tetris-terraform-state-jatinthakur029` in `us-east-1`. The backend also uses Terraform's S3 lock file. Change `terraform/backend.tf` before deployment if you need a different state bucket or key.

## Deploy Infrastructure Manually

Terraform defaults to `us-east-1`. From the repository root:

```bash
cd terraform
terraform init
terraform validate
terraform plan
terraform apply
```

The configuration creates:

- VPC `10.0.0.0/16`
- Public subnets `10.0.1.0/24` in `us-east-1a` and `10.0.2.0/24` in `us-east-1b`
- EKS cluster `tetris-cluster`
- Managed node group `tetris-node-group` with 1 to 2 nodes
- Cluster and node IAM roles

To use another AWS region, pass the variable during planning and applying. The subnet availability zones in `terraform/vpc.tf` must also be changed to match that region.

```bash
terraform plan -var="region=us-east-1"
terraform apply -var="region=us-east-1"
```

Configure local access to the cluster after Terraform completes:

```bash
aws eks update-kubeconfig --region us-east-1 --name tetris-cluster
kubectl get nodes
```

## Deploy the Kubernetes Workloads

Install an NGINX Ingress Controller in the cluster before applying `kubernetes/ingress.yaml`. Then apply the manifests:

```bash
kubectl apply -f kubernetes/mongodb/
kubectl apply -f kubernetes/backend/
kubectl apply -f kubernetes/frontend/
kubectl apply -f kubernetes/ingress.yaml
```

Check rollout and service status:

```bash
kubectl get pods,svc,ingress
kubectl rollout status statefulset/mongoset
kubectl rollout status deployment/tetris-deployment
kubectl rollout status deployment/tetrisbac-deployment
```

The ingress has no hostname or TLS configuration. The application is therefore reached through the address assigned by the NGINX Ingress Controller, and HTTPS is not configured by these manifests.

## Argo CD Deployment

The Argo CD application in `kubernetes/argocd/application.yaml` points to this repository and recursively syncs `kubernetes/` into the `default` namespace:

```bash
kubectl apply -f kubernetes/argocd/application.yaml
argocd app get tetris-app
argocd app sync tetris-app
```

The application has automated synchronization enabled. Applying the Argo CD resource is enough to let Argo CD manage the workloads after it is installed and connected to the cluster.

## GitHub Actions

The Terraform workflow is automated: `.github/workflows/CI.yaml` runs on every push to `main` and executes `terraform init`, `terraform validate`, `terraform plan`, and `terraform apply -auto-approve` in the `terraform/` directory.

Configure these repository secrets before relying on the workflow:

- `AWS_ACCESS_KEY`
- `AWS_SECRET_ACCESS_KEY`

The workflow does not build or push Docker images, install the EKS add-ons, configure `kubectl`, install NGINX, or apply the Argo CD resource. Those steps must be handled separately or added to the pipeline.

## Configuration

The backend receives `PORT=3000` from `kubernetes/backend/configmap.yaml` and a MongoDB connection string from `kubernetes/backend/secret.yaml`. MongoDB is addressed internally as `mongoservice:27017`.

Do not store production credentials in a committed Kubernetes Secret. The current value is base64-encoded configuration, not encryption. Use a secret manager, an external-secrets controller, or a CI/CD secret injection mechanism for production deployments.

## Container Images

The Kubernetes manifests reference the `latest` tags shown above. The Dockerfiles under `containers/` are only wrappers around those images:

```dockerfile
FROM tetris-backend:latest
```

They do not contain application source or a build pipeline. If the images are private or rebuilt under different names, update the `image` fields in the deployment manifests and configure image pull credentials as needed. Pinning immutable version tags is recommended for repeatable deployments.

## Resource Cleanup

To destroy the AWS resources managed by Terraform:

```bash
cd terraform
terraform destroy
```

Remove Kubernetes resources before destroying the cluster if required by your operating procedure:

```bash
kubectl delete -f kubernetes/ingress.yaml
kubectl delete -f kubernetes/frontend/
kubectl delete -f kubernetes/backend/
kubectl delete -f kubernetes/mongodb/
```

Review persistent volumes and the Terraform state bucket separately. `terraform destroy` does not delete the remote state bucket itself.

## Current Operational Considerations

- The EKS nodes and subnets are public, and the security group allows HTTP and HTTPS from anywhere. Restrict these rules for production use.
- The node group has a minimum and desired size of one, so it is not highly available despite the three application replicas.
- MongoDB has one replica and uses a single persistent volume claim; it is not configured as a replicated database.
- Services use fixed NodePorts (`30100` and `30101`) even though ingress is the intended entry point.
- The manifests do not define resource requests/limits, readiness probes, liveness probes, TLS, NetworkPolicies, or pod disruption budgets.
- The backend Secret is committed to source control and should be replaced before handling sensitive data.
