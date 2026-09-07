#!/bin/bash

set -e

server_ip="192.168.0.2"
remote_cluster_names=("k3d-cluster-a" "k3d-cluster-b")
argocd_version="v3.5.2"
argocd_port="8080"

deploy_clusters() {
  echo -e "\nCreating k3d-gitops-network docker network"
  docker network create k3d-gitops-network

  echo -e "\nCreating k3d-management cluster"
  k3d cluster create management --network k3d-gitops-network --api-port ${server_ip}:6445 --k3s-arg "--tls-san=${server_ip}@server:0" --port "${server_ip}:81:80@loadbalancer"

  echo -e "\nCreating k3d-cluster-a"
  k3d cluster create cluster-a --network k3d-gitops-network --api-port ${server_ip}:6446 --k3s-arg "--tls-san=${server_ip}@server:0" --port "${server_ip}:82:80@loadbalancer"

  echo -e "\nCreating k3d-cluster-b"
  k3d cluster create cluster-b --network k3d-gitops-network --api-port ${server_ip}:6447 --k3s-arg "--tls-san=${server_ip}@server:0" --port "${server_ip}:83:80@loadbalancer"

  kubectl config use-context k3d-management
}

install_argocd() {
  kubectl config use-context k3d-management

  echo -e "\nInstalling ArgoCD"
  kubectl create namespace argocd
  kubectl apply -n argocd --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/${argocd_version}/manifests/install.yaml
  
  echo -e "\nWaiting for all ArgoCD pods to become ready"
  kubectl wait --for=condition=ready pod --all -n argocd --timeout=300s
}

start_port_forward() {
  kubectl -n argocd port-forward svc/argocd-server --address 0.0.0.0 ${argocd_port}:443 >/dev/null 2>&1 &
  PF_PID=$!
  sleep 2
}

show_argocd_password() {
  echo "Please open a web browser and navigate to https://${server_ip}:${argocd_port} to login."
  echo -e "\nArgoCD Login\nUsername: admin\nPassword: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"
  echo "Waiting 20 seconds before continuing"
  sleep 20
}

login_to_argocd() {
  kubectl config use-context k3d-management
  admin_password=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
  argocd login localhost:${argocd_port} --insecure --username admin --password $admin_password
}

generate_linkerd_certificates() {
  echo "Creating the Linkerd trust anchor certificate"
  mkdir -p pki/trust-anchor
  step certificate create root.linkerd.cluster.local pki/trust-anchor/trust-anchor-ca.crt pki/trust-anchor/trust-anchor-ca.key --profile root-ca --no-password --insecure --not-after 43800h

  echo "Generating the Linkerd intermediate certificate and key pair that will be used to sign the Linkerd proxies CSR"
  mkdir -p pki/intermediate
  step certificate create identity.linkerd.cluster.local pki/intermediate/issuer.crt pki/intermediate/issuer.key --profile intermediate-ca --not-after 8760h --no-password --insecure --ca pki/trust-anchor/trust-anchor-ca.crt --ca-key pki/trust-anchor/trust-anchor-ca.key
}

create_sa_token() {
  for remote_cluster in "${remote_cluster_names[@]}"; do
    kubectl config use-context ${remote_cluster}
    kubectl apply -f - <<EOF
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

  kubectl config use-context k3d-management
}

add_remote_clusters_to_argocd() {
  kubectl config use-context k3d-management

  for remote_cluster in "${remote_cluster_names[@]}"; do
    argocd cluster add ${remote_cluster} --service-account argocd-manager --label linkerd=enabled --yes
  done
}

deploy_prerequisite_appsets() {
  kubectl config use-context k3d-management

  kubectl apply -f applicationsets/gateway-api
  kubectl apply -f applicationsets/sealed-secrets
  kubectl apply -f applicationsets/cert-manager
  kubectl apply -f applicationsets/trust-manager
 
  echo -e "\nWaiting for the prerequisite applications to become ready"
  argocd app wait -l '!app.kubernetes.io/instance' --timeout 600 > /dev/null 2>&1
}

configure_sealed_secrets() {
  for remote_cluster in "${remote_cluster_names[@]}"; do
    kubectl config use-context ${remote_cluster}

    echo "Retrieving the sealed-secrets controller public key"
    mkdir -p pki/trust-anchor/${remote_cluster}

    kubeseal --controller-name sealed-secrets --fetch-cert >pki/trust-anchor/${remote_cluster}/${remote_cluster}-sealed-secrets-pub-cert.pem

    echo "Sealing the Linkerd trust anchor as a kubernetes tls secret for ${remote_cluster}"
    kubectl create secret tls linkerd-trust-anchor \
      --cert=pki/trust-anchor/trust-anchor-ca.crt \
      --key=pki/trust-anchor/trust-anchor-ca.key \
      --namespace=cert-manager \
      --dry-run=client -o yaml |
      kubeseal --cert pki/trust-anchor/${remote_cluster}/${remote_cluster}-sealed-secrets-pub-cert.pem \
        --format yaml \
        --controller-name=sealed-secrets \
        --controller-namespace=kube-system |
      kubectl patch -f - \
        --type=merge \
        --local -o yaml \
        -p '{"spec":{"template":{"metadata":{"labels":{"linkerd":"enabled"}}}}}' \
        >pki/trust-anchor/${remote_cluster}/sealed-linkerd-trust-anchor-certificate.yml
  
    kubectl apply -f pki/trust-anchor/${remote_cluster}/sealed-linkerd-trust-anchor-certificate.yml
  done
  
  kubectl config use-context k3d-management
}

deploy_linkerd() {
  kubectl config use-context k3d-management
  kubectl apply -f management-cluster/management-cluster.yml

  echo -e "\nLinkerd is now being deployed"
}

deploy_linkerd_gitops_example() {
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
  k3d cluster delete management
  k3d cluster delete cluster-a
  k3d cluster delete cluster-b
  docker network rm k3d-gitops-network
  rm -rf ./pki/
}

"$@"
