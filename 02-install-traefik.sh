# Create a cluster role
kubectl apply -f - <<EOF
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: traefik-role

rules:
  - apiGroups:
      - ""
    resources:
      - services
      - endpoints
      - secrets
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - extensions
      - networking.k8s.io
    resources:
      - ingresses
      - ingressclasses
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - extensions
      - networking.k8s.io
    resources:
      - ingresses/status
    verbs:
      - update
EOF

# Crete a service account
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: traefik-account
EOF

# Create a cluster role binding
kubectl apply -f - <<EOF
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: traefik-role-binding

roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: traefik-role
subjects:
  - kind: ServiceAccount
    name: traefik-account
    namespace: default # Using "default" because we did not specify a namespace when creating the ClusterAccount.
EOF

# Create a deployment with traefik
kubectl apply -f - <<EOF
kind: Deployment
apiVersion: apps/v1
metadata:
  name: traefik-deployment
  labels:
    app: traefik

spec:
  replicas: 1
  selector:
    matchLabels:
      app: traefik
  template:
    metadata:
      labels:
        app: traefik
    spec:
      serviceAccountName: traefik-account
      containers:
        - name: traefik
          image: traefik:v2.9
          args:
            - --api.insecure
            - --providers.kubernetesingress
          ports:
            - name: web
              containerPort: 80
            - name: dashboard
              containerPort: 8080
EOF

SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Create services
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: traefik-dashboard-service
spec:
  type: LoadBalancer
  ports:
    - port: 8080
      targetPort: dashboard
  selector:
    app: traefik
---
apiVersion: v1
kind: Service
metadata:
  name: traefik-web-service
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    service.beta.kubernetes.io/azure-pls-create: "true"
    service.beta.kubernetes.io/azure-pls-name: traefik-lb-private-link 
    service.beta.kubernetes.io/azure-pls-ip-configuration-subnet: "$PLS_SUBNET" # Private Link subnet name
    service.beta.kubernetes.io/azure-pls-ip-configuration-ip-address-count: "1"
    service.beta.kubernetes.io/azure-pls-ip-configuration-ip-address: 10.20.0.10
    service.beta.kubernetes.io/azure-pls-visibility: "*"    
spec:
  type: LoadBalancer
  ports:
    - targetPort: web
      port: 80
  selector:
    app: traefik
EOF


ip=""
while [ -z $ip ]; do
  echo -e "${HIGHLIGHT}Waiting for external IP"
  ip=$(kubectl get svc traefik-web-service --template="{{range .status.loadBalancer.ingress}}{{.ip}}{{end}}")
  [ -z "$ip" ] && sleep 10
done
echo -e "${HIGHLIGHT}Found external IP: ${ip}"


# Deploy whoami
kubectl apply -f - <<EOF
kind: Deployment
apiVersion: apps/v1
metadata:
  name: whoami
  labels:
    app: whoami

spec:
  replicas: 1
  selector:
    matchLabels:
      app: whoami
  template:
    metadata:
      labels:
        app: whoami
    spec:
      containers:
        - name: whoami
          image: traefik/whoami
          ports:
            - name: web
              containerPort: 80
EOF

# And it's service
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: whoami

spec:
  ports:
    - name: web
      port: 80
      targetPort: web

  selector:
    app: whoami
EOF

# Create traefik ingress
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: whoami-ingress
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: whoami
            port:
              name: web
EOF

# Check traefik logs
kubectl logs $(kubectl get pods -l app=traefik -o jsonpath='{.items[0].metadata.name}')

# # Test access whoami internally
# kubectl run -it --rm aks-ingress-test --image=mcr.microsoft.com/aks/fundamental/base-ubuntu:v0.0.11
# apt-get update && apt-get install -y curl
# # Directly to the service
# curl http://whoami
# # Through the ingress
# curl http:/traefik-web-service/
# exit

echo -e "${HIGHLIGHT}Traefik installed 🚦👍🏻!"