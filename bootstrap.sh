#!/bin/bash

set -e

tools_dir="./tools"
server_ip="192.168.0.2"
remote_cluster_names=("k3d-cluster-a" "k3d-cluster-b")
argocd_port="8080"

tools_check() {
  if [ ! -d "$tools_dir" ]; then
    mkdir -p $tools_dir
  fi

  echo -e "Checking if cli tools are installed.\n"
  check_for_kubectl
  check_for_argocd
  check_for_k3d
  check_for_linkerd
  check_for_kubeseal
  check_for_step

  echo -e "All needed cli binaries are present.\n"
}

check_for_kubectl() {
  if command -v $tools_dir/kubectl &>/dev/null; then
    echo "Found Kubectl"
  else
    echo -e "Kubectl not found. Downloading."
    curl -sL -o $tools_dir/kubectl "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x $tools_dir/kubectl
    echo -e "Download of Kubectl is complete.\n"
  fi
}

check_for_argocd() {
  if command -v $tools_dir/argocd version &>/dev/null; then
    echo "Found ArgoCD"
  else
    echo "ArgoCD not found. Downloading."
    curl -sL -o $tools_dir/argocd https://github.com/argoproj/argo-cd/releases/download/v3.5.2/argocd-linux-amd64
    chmod +x $tools_dir/argocd
    echo -e "Download of ArgoCD is complete.\n"
  fi
}

check_for_k3d() {
  if command -v $tools_dir/k3d version &>/dev/null; then
    echo "Found K3D"
  else
    echo "K3D not found. Downloading."
    curl -sL -o $tools_dir/k3d https://github.com/k3d-io/k3d/releases/download/v5.9.0/k3d-linux-amd64
    chmod +x $tools_dir/k3d
    echo -e "Download of K3D is complete.\n"
  fi
}

check_for_linkerd() {
  if command -v $tools_dir/linkerd version &>/dev/null; then
    echo "Found Linkerd"
  else
    echo "Linkerd not found. Downloading."
    curl -sL -o $tools_dir/linkerd https://github.com/linkerd/linkerd2/releases/download/edge-26.9.1/linkerd2-cli-edge-26.9.1-linux-amd64
    chmod +x $tools_dir/linkerd
    echo -e "Download of Linkerd is complete.\n"
  fi
}

check_for_kubeseal() {
  if command -v $tools_dir/kubeseal --version &>/dev/null; then
    echo "Found Kubeseal"
  else
    echo "Kubeseal not found. Downloading."
    curl -sL -o $tools_dir/kubeseal.tar.gz https://github.com/bitnami/sealed-secrets/releases/download/v0.40.0/kubeseal-0.40.0-linux-amd64.tar.gz
    tar -xf ~/.local/bin/kubeseal.tar.gz -C $tools_dir kubeseal
    rm $tools_dir/kubeseal.tar.gz
    echo -e "Download of Kubeseal is complete.\n"
  fi
}

check_for_step() {
  if command -v $tools_dir/step version &>/dev/null; then
    echo "Found Step"
  else
    echo "Step cli not found. Downloading."
    curl -sL -o $tools_dir/step_linux_amd64.tar.gz https://dl.smallstep.com/cli/docs-cli-install/latest/step_linux_amd64.tar.gz
    tar -xf $tools_dir/step_linux_amd64.tar.gz -C $tools_dir/ step_linux_amd64/bin/step
    mv $tools_dir/step_linux_amd64/bin/step $tools_dir/step
    rm -rf $tools_dir/step_linux_amd64.tar.gz $tools_dir/step_linux_amd64
    echo -e "Download of Step is complete.\n"
  fi
}

create_docker_network() {
  if docker network inspect k3d-gitops-network > /dev/null 2>&1; then
    echo "The k3d-gitops-network already exists. Skipping creation."
  else
    echo "Creating k3d-gitops-network docker network"
    docker network create k3d-gitops-network
  fi
}

deploy_clusters() {
  echo -e "\nCreating k3d-management cluster"
  $tools_dir/k3d cluster create management --network k3d-gitops-network --api-port ${server_ip}:6445 --k3s-arg "--tls-san=${server_ip}@server:0" --port "${server_ip}:81:80@loadbalancer"

  echo -e "\nCreating k3d-cluster-a"
  $tools_dir/k3d cluster create cluster-a --network k3d-gitops-network --api-port ${server_ip}:6446 --k3s-arg "--tls-san=${server_ip}@server:0" --port "${server_ip}:82:80@loadbalancer"

  echo -e "\nCreating k3d-cluster-b"
  $tools_dir/k3d cluster create cluster-b --network k3d-gitops-network --api-port ${server_ip}:6447 --k3s-arg "--tls-san=${server_ip}@server:0" --port "${server_ip}:83:80@loadbalancer"

  $tools_dir/kubectl config use-context k3d-management
}

install_argocd() {
  $tools_dir/kubectl config use-context k3d-management

  echo -e "\nInstalling ArgoCD"
  $tools_dir/kubectl create namespace argocd
  $tools_dir/kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.2/manifests/install.yaml

  echo -e "\nWaiting for all ArgoCD pods to become ready"
  $tools_dir/kubectl wait --for=condition=ready pod --all -n argocd --timeout=300s
}

start_port_forward() {
  $tools_dir/kubectl -n argocd port-forward svc/argocd-server --address 0.0.0.0 ${argocd_port}:443 >/dev/null 2>&1 &
  PF_PID=$!
  sleep 2
}

show_argocd_password() {
  echo "Please open a web browser and navigate to https://${server_ip}:${argocd_port} to login."
  echo -e "\nArgoCD Login\nUsername: admin\nPassword: $($tools_dir/kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"
  echo "Waiting 20 seconds before continuing"
  sleep 20
}

login_to_argocd() {
  $tools_dir/kubectl config use-context k3d-management
  admin_password=$(${tools_dir}/kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
  $tools_dir/argocd login localhost:${argocd_port} --insecure --username admin --password $admin_password
}

generate_linkerd_certificates() {
  echo "Creating the Linkerd trust anchor certificate"
  mkdir -p pki/trust-anchor
  $tools_dir/step certificate create root.linkerd.cluster.local pki/trust-anchor/trust-anchor-ca.crt pki/trust-anchor/trust-anchor-ca.key --profile root-ca --no-password --insecure --not-after 43800h

  echo "Generating the Linkerd identity issuer certificate and key pair that will be used to sign the Linkerd proxies CSR"
  mkdir -p pki/identity-issuer
  $tools_dir/step certificate create identity.linkerd.cluster.local pki/identity-issuer/issuer.crt pki/identity-issuer/issuer.key --profile intermediate-ca --not-after 8760h --no-password --insecure --ca pki/trust-anchor/trust-anchor-ca.crt --ca-key pki/trust-anchor/trust-anchor-ca.key
}

create_sa_token() {
  for remote_cluster in "${remote_cluster_names[@]}"; do
    $tools_dir/kubectl config use-context ${remote_cluster}
    $tools_dir/kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: argocd-manager
    namespace: kube-system

---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF
  done

  $tools_dir/kubectl config use-context k3d-management
}

add_remote_clusters_to_argocd() {
  $tools_dir/kubectl config use-context k3d-management

  for remote_cluster in "${remote_cluster_names[@]}"; do
    $tools_dir/argocd cluster add ${remote_cluster} --service-account argocd-manager --label linkerd=enabled --yes
  done
}

deploy_prerequisite_appsets() {
  $tools_dir/kubectl config use-context k3d-management

  $tools_dir/kubectl apply -f applicationsets/gateway-api
  $tools_dir/kubectl apply -f applicationsets/sealed-secrets
  $tools_dir/kubectl apply -f applicationsets/cert-manager
  $tools_dir/kubectl apply -f applicationsets/trust-manager

  echo -e "\nWaiting for the prerequisite applications to become ready"
  $tools_dir/argocd app wait -l '!app.kubernetes.io/instance' --timeout 600 >/dev/null 2>&1
}

configure_sealed_secrets() {
  for remote_cluster in "${remote_cluster_names[@]}"; do
    $tools_dir/kubectl config use-context ${remote_cluster}

    echo "Retrieving the sealed-secrets controller public key"
    mkdir -p pki/trust-anchor/${remote_cluster}

    $tools_dir/kubeseal --controller-name sealed-secrets --fetch-cert >pki/trust-anchor/${remote_cluster}/${remote_cluster}-sealed-secrets-pub-cert.pem

    echo "Sealing the Linkerd trust anchor as a kubernetes tls secret for ${remote_cluster}"
    $tools_dir/kubectl create secret tls linkerd-trust-anchor \
      --cert=pki/trust-anchor/trust-anchor-ca.crt \
      --key=pki/trust-anchor/trust-anchor-ca.key \
      --namespace=cert-manager \
      --dry-run=client -o yaml |
      $tools_dir/kubeseal --cert pki/trust-anchor/${remote_cluster}/${remote_cluster}-sealed-secrets-pub-cert.pem \
        --format yaml \
        --controller-name=sealed-secrets \
        --controller-namespace=kube-system |
      $tools_dir/kubectl patch -f - \
        --type=merge \
        --local -o yaml \
        -p '{"spec":{"template":{"metadata":{"labels":{"linkerd":"enabled"}}}}}' \
        >pki/trust-anchor/${remote_cluster}/sealed-linkerd-trust-anchor-certificate.yml

    $tools_dir/kubectl apply -f pki/trust-anchor/${remote_cluster}/sealed-linkerd-trust-anchor-certificate.yml
  done

  $tools_dir/kubectl config use-context k3d-management
}

deploy_linkerd() {
  $tools_dir/kubectl config use-context k3d-management
  $tools_dir/kubectl apply -f management-cluster/management-cluster.yml

  echo -e "\nLinkerd is now being deployed"
}

deploy_linkerd_gitops_example() {
  tools_check
  create_docker_network
  deploy_clusters
  install_argocd
  start_port_forward
  show_argocd_password
  login_to_argocd
  generate_linkerd_certificates
  create_sa_token
  add_remote_clusters_to_argocd
  deploy_prerequisite_appsets
  configure_sealed_secrets
  deploy_linkerd
}

delete_linkerd_gitops_example() {
  $tools_dir/k3d cluster delete management
  $tools_dir/k3d cluster delete cluster-a
  $tools_dir/k3d cluster delete cluster-b
  docker network rm k3d-gitops-network
  rm -rf ./pki/identity-issuer
  rm -rf ./pki/trust-anchor
}

"$@"
